// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam_mutants/platform

pub fn main() {
  let assert [ready_a, ready_b, marker_a, marker_b] = platform.arguments()
  let script =
    "const fs=require('node:fs'); fs.writeFileSync(process.argv[1], 'ready'); "
    <> "setTimeout(() => fs.writeFileSync(process.argv[2], 'orphan'), 2000); "
    <> "setInterval(() => {}, 1000)"
  let request = fn(ready, marker) {
    platform.ProcessRequest(
      "node",
      ["-e", script, ready, marker],
      platform.current_directory(),
      [],
      60_000,
    )
  }
  let _ =
    platform.run_process_batch(
      [request(ready_a, marker_a), request(ready_b, marker_b)],
      2,
    )
  platform.exit(99)
}
