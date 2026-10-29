// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam_mutants/api
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/types
import simplifile

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
  io.println(
    "Child output decoding, all 65,536 byte pairs, truncation, and API report serialization passed",
  )
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
