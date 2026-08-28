// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{Some}
import smartest/evidence
import smartest/fuzz
import smartest/gen
import smartest/runner
import smartest/testing

pub fn coverage_guided_fuzz_is_lazy_and_mutates_a_seed_through_common_tapes_test() {
  let generator = gen.int_range(0, 3)
  let _lazy =
    fuzz.for_all(
      generator,
      seeds: [[3]],
      feedback: fn(_) { panic as "coverage ran during construction" },
      property: fn(_) { panic as "property ran during construction" },
    )
  let value =
    fuzz.for_all(
      generator,
      seeds: [[3]],
      feedback: fn(value) {
        fuzz.feedback(edges: [value], comparisons: [#(7, value)])
      },
      property: fn(value) {
        assert value != 0
      },
    )
    |> testing.with_budget(evidence.budget(
      cases: 4,
      shrinks: 20,
      timeout_ms: 1000,
      seed: 99,
    ))
  let report =
    runner.run(
      [runner.entry("demo", "fuzz_test", "guided_test", value)],
      runner.default_options(),
    )
  let assert [failure] = report.results
  assert failure.status == runner.Failed
  assert failure.cases == 2
  assert failure.witness == Some("0")
  assert failure.draw_tape == [0]
  assert failure.generator_schema == Some(gen.schema_fingerprint(generator))
  assert failure.oracle == Some(evidence.PropertyOracle("coverage-guided fuzz"))
}

pub fn fuzz_guidance_tracks_new_edges_and_improving_compare_distances_test() {
  let initial = fuzz.new_guidance()
  let #(with_edge, first_edge) =
    fuzz.record_feedback(initial, fuzz.feedback(edges: [10], comparisons: []))
  let #(same_edge, repeated_edge) =
    fuzz.record_feedback(with_edge, fuzz.feedback(edges: [10], comparisons: []))
  let #(far, first_compare) =
    fuzz.record_feedback(
      same_edge,
      fuzz.feedback(edges: [], comparisons: [#(3, 20)]),
    )
  let #(worse, worse_compare) =
    fuzz.record_feedback(far, fuzz.feedback(edges: [], comparisons: [#(3, 30)]))
  let #(_, better_compare) =
    fuzz.record_feedback(
      worse,
      fuzz.feedback(edges: [], comparisons: [#(3, 2)]),
    )

  assert first_edge
  assert !repeated_edge
  assert first_compare
  assert !worse_compare
  assert better_compare
}

pub fn malformed_fuzz_seed_is_stale_instead_of_silently_discarded_test() {
  let value =
    fuzz.for_all(
      gen.int_range(0, 2),
      seeds: [[9]],
      feedback: fn(_) { fuzz.feedback(edges: [], comparisons: []) },
      property: fn(_) { Nil },
    )
  let report =
    runner.run(
      [runner.entry("demo", "fuzz_test", "stale_seed_test", value)],
      runner.default_options(),
    )
  let assert [stale] = report.results
  assert stale.status == runner.Stale
}

pub fn fuzz_failure_replays_portably_without_running_the_search_budget_test() {
  let generator = gen.int_range(0, 3)
  let value =
    fuzz.for_all(
      generator,
      seeds: [],
      feedback: fn(value) { fuzz.feedback(edges: [value], comparisons: []) },
      property: fn(value) {
        assert value != 0
      },
    )
  let id = evidence.test_id("demo", "fuzz_test", "replay_test")
  let report =
    runner.run(
      [runner.entry("demo", "fuzz_test", "replay_test", value)],
      runner.default_options()
        |> runner.with_replay(id, [0], gen.schema_fingerprint(generator)),
    )
  let assert [failure] = report.results
  assert failure.status == runner.Failed
  assert failure.cases == 1
  assert failure.witness == Some("0")
}
