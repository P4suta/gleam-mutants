// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/io
import gleam/option.{Some}
import gleam_mutants/engine.{Options}
import report_test_support
import simplifile

pub fn main() {
  let options =
    Options(
      ..engine.default_options(),
      strict: Some(False),
      jobs: Some(2),
      timeout_ms: Some(30_000),
    )
  let assert Ok(output) = engine.run("fixtures/basic_project", options)
  assert output.report.score.total > 0
  assert output.report.score.errors == 0
  assert output.execution.narrowed == 0
  assert output.execution.fallbacks == output.report.selection.executed
  assert simplifile.is_file(output.stryker_json_path) == Ok(True)
  assert simplifile.is_file(output.html_report_path) == Ok(True)
  io.println(
    "engine smoke: " <> int.to_string(output.report.score.total) <> " mutants",
  )
  report_test_support.cleanup("fixtures/basic_project")
}
