// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam_mutants/platform.{ProcessRequest}

pub fn process_batch_honours_job_parallelism_test() {
  let request =
    ProcessRequest(
      "node",
      ["-e", "setTimeout(() => {}, 700)"],
      platform.current_directory(),
      [],
      5000,
    )
  let started = platform.now_milliseconds()
  let results = platform.run_process_batch([request, request], 2)
  let elapsed = platform.now_milliseconds() - started
  assert list.length(results) == 2
  assert list.all(results, fn(result) { result.process.status == 0 })
  assert elapsed < 1250
}
