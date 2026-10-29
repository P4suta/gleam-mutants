// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam_mutants/api
import gleam_mutants/core/bytes
import gleam_mutants/core/path
import gleam_mutants/engine
import gleam_mutants/report
import gleam_mutants/snapshot
import gleam_mutants/types
import simplifile

pub fn main() {
  let assert Ok(copy) = snapshot.create("fixtures/basic_project")
  let root = snapshot.root(copy)
  let options =
    types.Options(..api.default_options(), jobs: Some(2), strict: Some(False))
  let assert Ok(catalog) =
    api.validate_mutants(
      root,
      types.Options(
        ..options,
        test_command: Some(["node", "-e", "process.exit(91)"]),
      ),
    )
  assert catalog.validation == types.CompilerValidated
  assert catalog.mutants != []
  let assert Ok(actual) = api.run(root, options)
  assert actual.score.total > 0
  assert actual.score.errors == 0
  assert api.report_json(actual) == report.to_json(actual)
  assert simplifile.is_file(path.join(root, "reports/mutation/mutation.json"))
    == Ok(False)
  let assert Error(_) = report.latest(root)
  let assert Ok(expected) =
    engine.run(
      root,
      engine.Options(
        ..engine.default_options(),
        jobs: Some(2),
        strict: Some(False),
        report_formats: Some([]),
        report_history: Some(False),
      ),
    )
  assert actual.score == expected.report.score
  assert actual.selection == expected.report.selection
  assert actual.policy == expected.report.policy
  assert actual.workspace_digest == expected.report.workspace_digest
  assert verdicts(actual) == verdicts(expected.report)
  let assert Ok(_) =
    api.run(root, types.Options(..options, write_reports: True))
  assert simplifile.is_file(path.join(root, "reports/mutation/mutation.json"))
    == Ok(True)
  let assert Ok(latest) = report.latest(root)
  assert report.latest(root <> "/.") == Ok(latest)
  assert report.latest(root <> "/src/..") == Ok(latest)
  list.each(snapshot.entries(copy), fn(entry) {
    let assert Ok(contents) = simplifile.read(path.join(root, entry.path))
    assert bytes.sha256(contents) == entry.digest
  })
  let assert Ok(Nil) = report.clean(root)
  let assert Ok(Nil) = snapshot.dispose(copy)

  let assert Ok(rejected) =
    api.validate_mutants(
      "fixtures/compile_invalid_project",
      api.default_options(),
    )
  assert rejected.validation == types.CompilerValidated
  assert rejected.mutants == []
  assert rejected.rejected != []
  let assert Error(types.Failure(types.Running, _, message)) =
    api.run(
      "fixtures/basic_project",
      types.Options(
        ..options,
        test_command: Some(["node", "-e", "process.exit(91)"]),
      ),
    )
  assert string.contains(message, "baseline failed")
  let assert Ok(versions) =
    engine.toolchain_versions(".", [
      types.Erlang,
      types.Node,
      types.Deno,
      types.Bun,
    ])
  assert list.map(versions, fn(version) {
      string.split(version, "\u{0}") |> list.first |> result.unwrap("")
    })
    == ["gleam", "erl", "node", "deno", "bun"]
  assert list.all(versions, fn(version) { string.byte_size(version) > 8 })
  io.println(
    "API discovery, validation, run parity, report opt-in, source preservation, and toolchain identity passed",
  )
}

fn verdicts(value: types.RunReport) -> List(#(String, types.Outcome)) {
  list.map(value.results, fn(item) { #(item.mutant.id, item.aggregate) })
}
