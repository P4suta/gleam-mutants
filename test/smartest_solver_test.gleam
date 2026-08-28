// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/option.{Some}
import gleam/string
import smartest/evidence
import smartest/runner
import smartest/solver

fn proof() -> evidence.FormalProof {
  let assert Ok(proof) =
    evidence.formal_proof(
      method: "bounded SMT enumeration",
      subset: "integer inputs 0 through 2",
      bound: "three concrete models",
    )
  proof
}

fn complete_provider() -> solver.Provider(Int) {
  solver.provider(
    name: "test-solver",
    schema: "models-v1",
    boundary: proof(),
    capabilities: [evidence.Subprocess],
    solve: fn() { solver.Complete([0, 1, 2]) },
    renderer: int.to_string,
  )
}

pub fn bounded_solver_is_lazy_capability_gated_and_persists_a_witness_test() {
  let _lazy =
    solver.check(
      solver.provider(
        name: "lazy",
        schema: "lazy-v1",
        boundary: proof(),
        capabilities: [],
        solve: fn() { panic as "solver ran during construction" },
        renderer: int.to_string,
      ),
      fn(_) { panic as "oracle ran during construction" },
    )
  let value =
    solver.check(complete_provider(), fn(value) {
      assert value < 2
    })
  let entry = runner.entry("demo", "solver_test", "boundary_test", value)

  let guarded = runner.run([entry], runner.default_options())
  let assert [unsafe] = guarded.results
  assert unsafe.status == runner.Unsafe

  let report =
    runner.run(
      [entry],
      runner.default_options()
        |> runner.with_capabilities([evidence.Subprocess]),
    )
  let assert [failure] = report.results
  assert failure.status == runner.Failed
  assert failure.cases == 3
  assert failure.witness == Some("2")
  assert failure.draw_tape == [2]
  assert failure.generator_schema
    == Some(solver.schema_fingerprint(complete_provider()))
  let assert Some(evidence.ExternalOracle(provenance)) = failure.oracle
  assert string.contains(provenance, "bounded SMT enumeration")
  assert string.contains(provenance, "integer inputs 0 through 2")
  assert string.contains(provenance, "three concrete models")
}

pub fn bounded_solver_witness_replays_without_searching_other_candidates_test() {
  let value =
    solver.check(complete_provider(), fn(value) {
      assert value < 2
    })
  let id = evidence.test_id("demo", "solver_test", "replay_test")
  let report =
    runner.run(
      [runner.entry("demo", "solver_test", "replay_test", value)],
      runner.default_options()
        |> runner.with_capabilities([evidence.Subprocess])
        |> runner.with_replay(
          id,
          [2],
          solver.schema_fingerprint(complete_provider()),
        ),
    )
  let assert [failure] = report.results
  assert failure.status == runner.Failed
  assert failure.cases == 1
  assert failure.witness == Some("2")
}

pub fn incomplete_solver_result_is_budget_exhausted_not_equivalent_test() {
  let provider =
    solver.provider(
      name: "bounded-search",
      schema: "incomplete-v1",
      boundary: proof(),
      capabilities: [],
      solve: fn() { solver.Incomplete([0, 1], "model budget reached") },
      renderer: int.to_string,
    )
  let report =
    runner.run(
      [
        runner.entry(
          "demo",
          "solver_test",
          "incomplete_test",
          solver.check(provider, fn(value) {
            assert value >= 0
          }),
        ),
      ],
      runner.default_options(),
    )
  let assert [bounded] = report.results
  assert bounded.status == runner.BudgetExhausted
  assert runner.succeeded(bounded)
  assert bounded.cases == 2
  assert string.contains(bounded.message, "model budget reached")
  assert string.contains(bounded.message, "integer inputs 0 through 2")
  assert string.contains(bounded.message, "three concrete models")
  assert !string.contains(string.lowercase(bounded.message), "equivalent")
}

pub fn unavailable_solver_is_advisory_unsupported_test() {
  let provider =
    solver.provider(
      name: "optional-z3",
      schema: "z3-v1",
      boundary: proof(),
      capabilities: [],
      solve: fn() { solver.Unavailable("z3 is not installed") },
      renderer: int.to_string,
    )
  let report =
    runner.run(
      [
        runner.entry(
          "demo",
          "solver_test",
          "unavailable_test",
          solver.check(provider, fn(_) { panic as "oracle must not run" }),
        ),
      ],
      runner.default_options(),
    )
  let assert [unsupported] = report.results
  assert unsupported.status == runner.Unsupported
  assert runner.succeeded(unsupported)
  assert string.contains(unsupported.message, "z3 is not installed")
}
