// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam_mutants/api
import gleam_mutants/cache
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/snapshot
import gleam_mutants/stryker_report
import gleam_mutants/types
import simplifile
import tomlet

const byte_values = 256

const reference_script = "const first = Number(process.argv[1]);"
  <> "const bytes = Buffer.from(Array.from({length: 256}, (_, second) => [first, second, 124]).flat());"
  <> "require('node:fs').writeFileSync(process.argv[2], bytes.toString('utf8'));"
  <> "process.stdout.write(bytes);"

pub fn main() {
  let vectors = [
    #("ff", "\u{fffd}"),
    #("e282", "\u{fffd}"),
    #("e28241", "\u{fffd}A"),
    #("c0af", "\u{fffd}\u{fffd}"),
    #("eda080", "\u{fffd}\u{fffd}\u{fffd}"),
    #("f4908080", "\u{fffd}\u{fffd}\u{fffd}\u{fffd}"),
    #("e228a1", "\u{fffd}(\u{fffd}"),
    #("f09f92", "\u{fffd}"),
    #("f09f92a9", "\u{1f4a9}"),
    #("e282ac", "\u{20ac}"),
    #("efbbbf41", "\u{feff}A"),
  ]
  list.each(vectors, fn(vector) {
    let actual =
      platform.run_process(
        "node",
        [
          "-e",
          "process.stdout.write(Buffer.from(process.argv[1], 'hex'))",
          vector.0,
        ],
        ".",
        [],
        10_000,
      )
    assert actual.status == 0
    let assert Ok(_) = bit_array.to_string(<<actual.stdout:utf8>>)
    assert actual.stdout == vector.1
  })
  check_two_byte_inputs()
  let large =
    platform.run_process(
      "node",
      ["-e", "process.stdout.write('€'.repeat(100000))"],
      ".",
      [],
      10_000,
    )
  assert large.status == 0
  let assert Ok(_) = bit_array.to_string(<<large.stdout:utf8>>)
  assert string.contains(large.stdout, "...")
  let options =
    types.Options(
      ..api.default_options(),
      operators: Some([types.IntegerArithmetic]),
      test_command: Some([
        "node",
        "-e",
        "if (process.env.GLEAM_MUTANTS_ACTIVE) { process.stdout.write(Buffer.from([255])); process.exit(91); }",
      ]),
    )
  let assert Ok(report) = api.run("fixtures/basic_project", options)
  assert report.score.errors == 1
  let assert [result] = report.results
  assert list.all(result.outcomes, fn(outcome) {
    string.contains(outcome.output, "\u{fffd}")
  })
  let assert Ok(_) = bit_array.to_string(<<api.report_json(report):utf8>>)
  check_diagnostic_modes()
  io.println(
    "Child output decoding, all 65,536 byte pairs, truncation, JSON error reasons, and diagnostic modes passed",
  )
}

fn check_diagnostic_modes() -> Nil {
  let marker = "private diagnostic marker"
  let assert Ok(captured) =
    snapshot.create_excluding("fixtures/basic_project", ["reports/mutation"])
  let root = snapshot.root(captured)
  let configuration = path.join(root, "gleam.toml")
  let assert Ok(text) = simplifile.read(configuration)
  let assert Ok(document) = tomlet.parse(text)
  let assert Ok(document) =
    tomlet.set_string(
      document,
      ["tools", "gleam_mutants", "cache", "mode"],
      "off",
    )
  let assert Ok(source) =
    simplifile.read(path.join(root, "src/calculator.gleam"))
  let options =
    types.Options(
      ..api.default_options(),
      operators: Some([types.IntegerArithmetic]),
      jobs: Some(1),
      test_selection: Some(types.TestSelectionFull),
      test_command: Some([
        "node",
        "-e",
        "if (process.env.GLEAM_MUTANTS_ACTIVE) { process.stdout.write('private diagnostic marker'); process.exit(91); }",
      ]),
    )
  let observed =
    list.map(["none", "errors", "all"], fn(mode) {
      let assert Ok(configured) =
        tomlet.set_string(
          document,
          ["tools", "gleam_mutants", "report", "diagnostics"],
          mode,
        )
      let assert Ok(Nil) =
        simplifile.write(configuration, tomlet.to_string(configured))
      let assert Ok(report) = api.run(root, options)
      let assert Ok(projected) =
        stryker_report.to_json(
          report,
          [stryker_report.SourceFile("src/calculator.gleam", source)],
          80,
          60,
        )
      #(mode, report, api.report_json(report), projected)
    })
  let assert Ok(Nil) =
    platform.delete_tree(path.parent(cache.workspace_snapshot(root)))
  let assert Ok(Nil) = snapshot.dispose(captured)
  list.each(observed, fn(entry) {
    let #(mode, report, native, projected) = entry
    assert report.score.errors == 1
    let assert [result] = report.results
    case mode {
      "none" -> {
        assert result.aggregate == types.TestError("")
        assert list.all(result.outcomes, fn(outcome) {
          outcome.output == "" && outcome.outcome == types.TestError("")
        })
        assert !string.contains(native, marker)
        assert !string.contains(projected, marker)
      }
      _ -> {
        assert result.aggregate == types.TestError(marker)
        assert list.all(result.outcomes, fn(outcome) {
          outcome.output == marker
        })
        assert string.contains(native, marker)
        assert string.contains(projected, marker)
      }
    }
  })
}

fn check_two_byte_inputs() -> Nil {
  let directory =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-output-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory(directory)
  let requests =
    list.index_map(list.repeat(Nil, byte_values), fn(_, first) {
      let expected = path.join(directory, int.to_string(first) <> ".txt")
      platform.ProcessRequest(
        "node",
        ["-e", reference_script, int.to_string(first), expected],
        directory,
        [],
        10_000,
      )
    })
  let outputs = platform.run_process_batch(requests, 4)
  let mismatches =
    list.index_map(outputs, fn(output, first) {
      let expected =
        simplifile.read(path.join(directory, int.to_string(first) <> ".txt"))
      #(
        first,
        output.process.status == 0 && expected == Ok(output.process.stdout),
      )
    })
    |> list.filter(fn(item) { !item.1 })
  let assert Ok(Nil) = platform.delete_tree(directory)
  assert list.length(outputs) == byte_values
  assert mismatches == []
}
