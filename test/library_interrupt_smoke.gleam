// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam_mutants/api
import gleam_mutants/platform
import gleam_mutants/types

pub fn main() {
  let code =
    platform.env("GLEAM_MUTANTS_INTERRUPT_CODE")
    |> int.parse
    |> result.unwrap(130)
  let script =
    "process.stdout.write('child-interrupt-output'); process.exit("
    <> int.to_string(code)
    <> ")"
  let request =
    platform.ProcessRequest(
      "node",
      ["-e", script],
      platform.current_directory(),
      [],
      10_000,
    )
  let single =
    platform.run_process(
      request.executable,
      request.arguments,
      request.working_directory,
      request.environment,
      request.timeout_ms,
    )
  assert single.status == code
  let batch = platform.run_process_batch([request], 1)
  assert list.length(batch) == 1
  assert list.all(batch, fn(result) { result.process.status == code })
  list.each(
    [
      script,
      "process.stdout.write('child-interrupt-output'); process.exit(process.env.GLEAM_MUTANTS_ACTIVE ? "
        <> int.to_string(code)
        <> " : 0)",
    ],
    fn(command) {
      let options =
        types.Options(
          ..api.default_options(),
          jobs: Some(2),
          test_command: Some(["node", "-e", command]),
        )
      let assert Error(types.Interrupted(actual, diagnostic)) =
        api.run("fixtures/basic_project", options)
      assert actual == code
      assert string.contains(diagnostic, "child-interrupt-output")
    },
  )
  let assert Ok(_) =
    api.list_mutants("fixtures/basic_project", api.default_options())
  io.println("API host continued after " <> int.to_string(code))
}
