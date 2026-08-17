// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{Some}
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/engine.{Options}
import gleam_mutants/platform
import report_test_support
import simplifile

pub fn main() {
  let assert [mode, workspace] = platform.arguments()
  case mode {
    "baseline" -> {
      let options =
        Options(
          ..engine.default_options(),
          test_command: Some(["node", "-e", "process.exit(1)"]),
        )
      let assert Error(_) = engine.run(workspace, options)
      assert read_report(workspace, "mutation.json") == "old json\n"
      assert read_report(workspace, "mutation.html") == "old html\n"
    }
    "zero" -> {
      let options =
        Options(
          ..engine.default_options(),
          includes: ["src/no_sites.gleam"],
          strict: Some(False),
        )
      let assert Ok(output) = engine.run(workspace, options)
      assert output.report.score.total == 0
      assert output.report.selection.files_selected == 1
      assert output.report.selection.candidates == 0
      assert output.exit_code == 1
      assert simplifile.is_file(output.stryker_json_path) == Ok(True)
      assert simplifile.is_file(output.html_report_path) == Ok(True)
      report_test_support.cleanup(workspace)
    }
    "strict" -> {
      let options =
        Options(
          ..engine.default_options(),
          test_command: Some(["node", "-e", "process.exit(0)"]),
          strict: Some(True),
          jobs: Some(2),
        )
      let assert Ok(output) = engine.run(workspace, options)
      assert output.exit_code == 1
      assert simplifile.is_file(output.stryker_json_path) == Ok(True)
      assert simplifile.is_file(output.html_report_path) == Ok(True)
      report_test_support.cleanup(workspace)
    }
    "runtime" -> {
      let options =
        Options(
          ..engine.default_options(),
          test_command: Some(["node", "mutant-test-command.mjs"]),
          strict: Some(False),
          jobs: Some(2),
        )
      let assert Ok(output) = engine.run(workspace, options)
      assert output.report.score.errors > 0
      assert output.exit_code == 2
      let report = read_report(workspace, "mutation.json")
      assert string.contains(report, "\"status\":\"RuntimeError\"")
      assert string.contains(report, "runtime boom")
      report_test_support.cleanup(workspace)
    }
    _ -> panic as "unknown report lifecycle smoke mode"
  }
}

fn read_report(workspace: String, name: String) -> String {
  let assert Ok(contents) =
    simplifile.read(path.join(workspace, path.join("reports/mutation", name)))
  contents
}
