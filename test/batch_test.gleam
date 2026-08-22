// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam_mutants/platform

pub fn process_batch_honours_job_parallelism_test() {
  let requests = [
    request("one"),
    request("two"),
    request("three"),
    request("four"),
  ]
  let #(serial, serial_elapsed) = measured_batch(requests, 1)
  let #(parallel, parallel_elapsed) = measured_batch(requests, 2)

  assert_batch(serial)
  assert_batch(parallel)
  assert parallel_elapsed < serial_elapsed
  assert parallel_elapsed < total_duration(serial)
}

fn request(label: String) -> platform.ProcessRequest {
  platform.ProcessRequest(
    "node",
    [
      "-e",
      "setTimeout(() => process.stdout.write('" <> label <> "'), 700)",
    ],
    platform.current_directory(),
    [],
    5000,
  )
}

fn measured_batch(
  requests: List(platform.ProcessRequest),
  jobs: Int,
) -> #(List(platform.TimedProcessResult), Int) {
  let started = platform.monotonic_milliseconds()
  let results = platform.run_process_batch(requests, jobs)
  #(results, platform.monotonic_milliseconds() - started)
}

fn total_duration(results: List(platform.TimedProcessResult)) -> Int {
  list.fold(results, 0, fn(total, result) { total + result.duration_ms })
}

fn assert_batch(results: List(platform.TimedProcessResult)) {
  assert list.map(results, fn(result) { result.process.stdout })
    == [
      "one",
      "two",
      "three",
      "four",
    ]
  assert list.all(results, fn(result) {
    result.process.status == 0
    && result.process.timed_out == False
    && result.duration_ms > 0
  })
}
