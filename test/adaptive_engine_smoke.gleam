// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam_mutants/cache
import gleam_mutants/config
import gleam_mutants/core/outcome
import gleam_mutants/core/path
import gleam_mutants/engine
import gleam_mutants/platform
import simplifile

const fixture = "fixtures/adaptive_project"

pub fn main() {
  let assert Ok(Nil) = cache.clean(fixture)
  let counter =
    path.join(
      platform.temporary_directory(),
      "adaptive-engine-counter-" <> platform.random_nonce(),
    )
  let common =
    engine.Options(
      ..engine.default_options(),
      jobs: Some(2),
      test_command: Some(["node", "adaptive-runner.mjs", "counter", counter]),
      report_formats: Some([]),
      report_history: Some(False),
    )
  let assert Ok(automatic) =
    engine.run(
      fixture,
      engine.Options(..common, test_selection: Some(config.TestSelectionAuto)),
    )
  let invocations_before_cache = invocation_count(counter)
  let assert Ok(cached) =
    engine.run(
      fixture,
      engine.Options(..common, test_selection: Some(config.TestSelectionAuto)),
    )
  let cache_run_invocations =
    invocation_count(counter) - invocations_before_cache
  let assert Ok(complete_suite) =
    engine.run(
      fixture,
      engine.Options(
        ..common,
        test_selection: Some(config.TestSelectionFull),
        test_command: Some(["node", "adaptive-runner.mjs", "full"]),
      ),
    )
  let assert Ok(matrix_automatic) =
    engine.run(
      fixture,
      engine.Options(
        ..common,
        matrix: True,
        test_selection: Some(config.TestSelectionAuto),
        test_command: Some(["node", "adaptive-runner.mjs", "matrix-auto"]),
      ),
    )
  let assert Ok(matrix_full) =
    engine.run(
      fixture,
      engine.Options(
        ..common,
        matrix: True,
        test_selection: Some(config.TestSelectionFull),
        test_command: Some(["node", "adaptive-runner.mjs", "full", "matrix"]),
      ),
    )
  let assert Ok(Nil) = cache.clean(fixture)
  let assert Ok(Nil) = simplifile.delete_file(at: counter)

  let auto_results =
    list.map(automatic.report.results, fn(item) {
      #(item.mutant.id, item.aggregate)
    })
  let full_results =
    list.map(complete_suite.report.results, fn(item) {
      #(item.mutant.id, item.aggregate)
    })
  assert list.length(auto_results) == 5
  assert auto_results == full_results
  assert list.all(automatic.report.results, fn(item) {
    item.aggregate == outcome.Killed
  })
  assert automatic.report.score == complete_suite.report.score
  assert automatic.exit_code == complete_suite.exit_code
  assert automatic.execution.narrowed == 4
  assert automatic.execution.confirmations == 3
  assert automatic.execution.fallbacks == 1
  assert automatic.execution.cache_hits == 0
  assert complete_suite.execution.narrowed == 0
  assert complete_suite.execution.confirmations == 0
  assert complete_suite.execution.fallbacks == 0
  assert cached.execution.narrowed == 0
  assert cached.execution.confirmations == 0
  assert cached.execution.fallbacks == 0
  assert cached.execution.cache_hits == 5
  // The all-hit run performs only its pristine and instrumented baselines.
  // No partial baseline, worker, or mutant process is created.
  assert cache_run_invocations == 2
  assert list.all(cached.report.results, fn(item) {
    list.all(item.outcomes, fn(runtime) { runtime.cached })
  })
  assert list.map(matrix_automatic.report.results, fn(item) {
      #(item.mutant.id, item.aggregate)
    })
    == list.map(matrix_full.report.results, fn(item) {
      #(item.mutant.id, item.aggregate)
    })
  assert matrix_automatic.report.score == matrix_full.report.score
  assert matrix_automatic.exit_code == matrix_full.exit_code
  assert matrix_automatic.execution.narrowed == 16
  assert matrix_automatic.execution.confirmations == 12
  assert matrix_automatic.execution.fallbacks == 4
  assert matrix_automatic.execution.cache_hits == 0
  assert list.all(matrix_automatic.report.results, fn(item) {
    list.length(item.outcomes) == 4
  })
  assert matrix_full.execution.narrowed == 0
  assert matrix_full.execution.confirmations == 0
  assert matrix_full.execution.fallbacks == 0
  assert list.map(automatic.phase_timings, fn(timing) { timing.0 })
    == ["catalog.discover", "engine.prepare", "engine.execute"]
}

fn invocation_count(counter: String) -> Int {
  simplifile.read(counter)
  |> result.unwrap("")
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
  |> list.length
}
