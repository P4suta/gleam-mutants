// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/string
import gleam_mutants/platform
import gleam_mutants/workspace_lock

pub fn main() {
  let assert [mode, workspace] = platform.arguments()
  case mode {
    "hold" -> {
      let assert Ok(lock) = workspace_lock.acquire(workspace)
      let process =
        platform.run_process(
          "node",
          ["-e", "setTimeout(() => {}, 4000)"],
          workspace,
          [],
          10_000,
        )
      assert process.status == 0
      let assert Ok(Nil) = workspace_lock.release(lock)
      Nil
    }
    "contend" -> {
      let started = platform.monotonic_milliseconds()
      let assert Error(error) = workspace_lock.acquire(workspace)
      let duration = platform.monotonic_milliseconds() - started
      assert duration <= 3000
      assert string.contains(error, "workspace is locked by pid")
      assert string.contains(error, "run")
      assert string.contains(error, "started")
    }
    _ -> panic as "unknown workspace lock smoke mode"
  }
}
