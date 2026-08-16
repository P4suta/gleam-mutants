// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam_mutants/platform

pub fn main() {
  let assert [marker] = platform.arguments()
  let child =
    "setTimeout(() => require('node:fs').writeFileSync(process.argv[1], 'orphan'), 1500)"
  let parent =
    "const { spawn } = require('node:child_process'); spawn(process.execPath, ['-e', "
    <> "process.argv[1], process.argv[2]], { stdio: 'ignore' }); "
    <> "setInterval(() => {}, 1000)"
  let result =
    platform.run_process(
      "node",
      ["-e", parent, child, marker],
      platform.current_directory(),
      [],
      250,
    )
  assert result.timed_out
}
