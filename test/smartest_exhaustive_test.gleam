// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/option.{None, Some}
import gleam/string
import smartest/evidence
import smartest/exhaustive
import smartest/runner
import smartest/testing

fn finite_domain() -> exhaustive.Domain(Int) {
  exhaustive.domain(
    schema: "protocol-state-v1",
    subset: "states 0 through 2",
    values: [0, 1, 2],
    renderer: int.to_string,
  )
}

pub fn finite_exhaustive_construction_is_lazy_and_finds_the_first_witness_test() {
  let _lazy =
    exhaustive.for_all(finite_domain(), fn(_) {
      panic as "finite callback ran during construction"
    })
  let value =
    exhaustive.for_all(finite_domain(), fn(value) {
      assert value < 2
    })
    |> testing.with_budget(evidence.budget(
      cases: 3,
      shrinks: 0,
      timeout_ms: 1000,
      seed: 7,
    ))
  let entry = runner.entry("demo", "finite_test", "boundary_test", value)
  let report = runner.run([entry], runner.default_options())
  let assert [failure] = report.results
  assert failure.status == runner.Failed
  assert failure.cases == 3
  assert failure.witness == Some("2")
  assert failure.draw_tape == [2]
  assert failure.generator_schema != None
  assert failure.oracle
    == Some(evidence.PropertyOracle(
      "finite exhaustive: states 0 through 2; bound 3",
    ))
}

pub fn finite_exhaustive_witness_replays_by_schema_and_tape_test() {
  let value =
    exhaustive.for_all(finite_domain(), fn(value) {
      assert value < 2
    })
  let id = evidence.test_id("demo", "finite_test", "replay_test")
  let schema = exhaustive.schema_fingerprint(finite_domain())
  let report =
    runner.run(
      [runner.entry("demo", "finite_test", "replay_test", value)],
      runner.default_options()
        |> runner.with_replay(id, [2], schema),
    )
  let assert [failure] = report.results
  assert failure.status == runner.Failed
  assert failure.cases == 1
  assert failure.witness == Some("2")
  assert failure.draw_tape == [2]
}

pub fn finite_exhaustive_budget_exhaustion_is_visible_and_advisory_test() {
  let value =
    exhaustive.for_all(finite_domain(), fn(_) { Nil })
    |> testing.with_budget(evidence.budget(
      cases: 2,
      shrinks: 0,
      timeout_ms: 1000,
      seed: 7,
    ))
  let report =
    runner.run(
      [runner.entry("demo", "finite_test", "bounded_test", value)],
      runner.default_options(),
    )
  let assert [bounded] = report.results
  assert bounded.status == runner.BudgetExhausted
  assert runner.succeeded(bounded)
  assert bounded.cases == 2
  assert string.contains(bounded.message, "2 of 3")
  assert string.contains(bounded.message, "states 0 through 2")
  assert !string.contains(string.lowercase(bounded.message), "equivalent")
}

pub fn finite_exhaustive_full_domain_passes_with_the_declared_bound_test() {
  let value =
    exhaustive.for_all(finite_domain(), fn(value) {
      assert value >= 0
    })
    |> testing.with_budget(evidence.budget(
      cases: 3,
      shrinks: 0,
      timeout_ms: 1000,
      seed: 7,
    ))
  let report =
    runner.run(
      [runner.entry("demo", "finite_test", "complete_test", value)],
      runner.default_options(),
    )
  let assert [passing] = report.results
  assert passing.status == runner.Passed
  assert passing.cases == 3
}
