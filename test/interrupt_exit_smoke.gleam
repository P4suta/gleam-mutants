// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam_mutants/platform

pub fn main() {
  let request =
    platform.ProcessRequest(
      "node",
      ["-e", "process.exit(130)"],
      platform.current_directory(),
      [],
      10_000,
    )
  case platform.env("GLEAM_MUTANTS_TEST_MODE") {
    "batch" -> {
      let _ = platform.run_process_batch([request], 1)
      Nil
    }
    _ -> {
      let _ =
        platform.run_process(
          request.executable,
          request.arguments,
          request.working_directory,
          request.environment,
          request.timeout_ms,
        )
      Nil
    }
  }
  platform.exit(99)
}
