// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import child_process
import child_process/stdio
import gleam/result

pub type ProcessOutput {
  ProcessOutput(exit_code: Int, output: String)
}

pub fn gleam_test(
  root: String,
  arguments: List(String),
  environment: List(#(String, String)),
) -> Result(ProcessOutput, String) {
  child_process.from_name("gleam")
  |> child_process.args(["test", ..arguments])
  |> child_process.envs(environment)
  |> child_process.cwd(root)
  |> child_process.run(stdio.capture(capture_stderr: True))
  |> result.map(fn(output) { ProcessOutput(output.status_code, output.output) })
  |> result.map_error(child_process.describe_start_error)
}
