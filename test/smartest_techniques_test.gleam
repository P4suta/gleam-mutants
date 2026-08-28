// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import smartest/concurrency
import smartest/corpus
import smartest/differential
import smartest/evidence
import smartest/fault
import smartest/gen
import smartest/hyperproperty
import smartest/metamorphic
import smartest/model
import smartest/observe
import smartest/performance
import smartest/reference
import smartest/runner
import smartest/snapshot
import smartest/storage
import smartest/testing

@external(erlang, "smartest_runner_test_ffi", "block")
@external(javascript, "./smartest_runner_test_ffi.mjs", "block")
fn block(milliseconds: Int) -> Nil

pub fn observers_expose_only_registered_public_observations_test() {
  let size = observe.observer(fn(items: List(Int)) { list.length(items) })
  let positive = observe.then(size, observe.observer(fn(value) { value > 0 }))
  let renderer =
    observe.renderer(fn(value) {
      case value {
        True -> "non-empty"
        False -> "empty"
      }
    })
  assert observe.observe(positive, [1, 2, 3])
  assert observe.render(renderer, True) == "non-empty"
}

pub fn snapshot_construction_is_lazy_and_mismatches_are_structured_test() {
  let renderer = observe.renderer(int.to_string)
  let _lazy =
    snapshot.expect(
      "lazy",
      actual: fn() { panic as "snapshot ran during construction" },
      renderer: renderer,
      expected: "1",
    )
  let passing =
    snapshot.expect(
      "answer",
      actual: fn() { 42 },
      renderer: renderer,
      expected: "42",
    )
  let failing =
    snapshot.expect(
      "answer",
      actual: fn() { 41 },
      renderer: renderer,
      expected: "42",
    )
  let report =
    runner.run(
      [
        runner.entry("demo", "snapshot_test", "passing_test", passing),
        runner.entry("demo", "snapshot_test", "failing_test", failing),
      ],
      runner.default_options(),
    )
  let assert [pass_result, fail_result] = report.results
  assert pass_result.status == runner.Passed
  assert fail_result.status == runner.Failed
  assert string.contains(fail_result.message, "snapshot answer")
  assert string.contains(fail_result.message, "expected: 42")
  assert string.contains(fail_result.message, "actual: 41")
}

pub fn native_snapshot_review_is_provisional_until_acceptance_then_replays_test() {
  let root =
    path.join(
      platform.temporary_directory(),
      "smartest-snapshot-review-" <> platform.random_nonce(),
    )
  let renderer = observe.renderer(int.to_string)
  let value =
    snapshot.review(
      "answer",
      renderer_schema: "decimal-int-v1",
      actual: fn() { 42 },
      renderer: renderer,
    )
  let entry = runner.entry("demo", "snapshot_test", "review_test", value)

  let proposed =
    runner.run(
      [entry],
      runner.default_options()
        |> runner.with_findings(root, created_ms: 10),
    )
  let assert [proposal] = proposed.results
  assert proposal.status == runner.Unsupported
  assert runner.succeeded(proposal)
  let assert Ok([finding]) = storage.list_inbox(root)
  assert finding.lifecycle == corpus.Inbox
  assert finding.state == evidence.ProvisionalEvidence
  assert finding.oracle == evidence.SnapshotOracle("answer")
  assert finding.rendering == "42"

  let assert Ok(accepted) =
    storage.accept(
      root,
      finding.id,
      at_ms: 20,
      review_note: "approved decimal rendering",
      human_oracle: None,
    )
  assert accepted.state == evidence.TrustedEvidence

  let replayed =
    runner.run([entry], runner.workspace_options(root, created_ms: 30))
  let assert [passing] = replayed.results
  assert passing.status == runner.Passed

  let changed =
    snapshot.review(
      "answer",
      renderer_schema: "decimal-int-v1",
      actual: fn() { 41 },
      renderer: renderer,
    )
  let changed_report =
    runner.run(
      [runner.entry("demo", "snapshot_test", "review_test", changed)],
      runner.workspace_options(root, created_ms: 40),
    )
  let assert [failure] = changed_report.results
  assert failure.status == runner.Failed
  assert string.contains(failure.message, "expected: 42")
  assert string.contains(failure.message, "actual: 41")

  let _ = platform.delete_tree(root)
  Nil
}

pub fn model_machine_explores_valid_command_sequences_and_shrinks_them_test() {
  let machine =
    model.machine(
      initial_model: 0,
      initial_sut: 0,
      commands: gen.constant(1) |> gen.rendered(fn(_) { "increment" }),
      precondition: fn(_, _) { True },
      transition: fn(state, command) { state + command },
      step: fn(state, command) { Ok(state + command) },
      invariant: fn(reference, sut) { reference == sut && sut < 2 },
    )
  let value =
    model.check(machine, max_commands: 4)
    |> testing.with_budget(evidence.budget(
      cases: 100,
      shrinks: 100,
      timeout_ms: 1000,
      seed: 7,
    ))
  let report =
    runner.run(
      [runner.entry("demo", "counter_test", "model_test", value)],
      runner.default_options(),
    )
  let assert [result] = report.results
  assert result.status == runner.Failed
  assert result.witness != None
  assert string.contains(result.message, "model invariant failed")
  assert result.oracle == Some(evidence.ModelOracle("state machine"))
}

pub fn model_machine_cleanup_runs_after_an_invariant_failure_test() {
  let machine =
    model.machine_with_cleanup(
      initial_model: 0,
      initial_sut: 0,
      commands: gen.constant(1),
      precondition: fn(_, _) { True },
      transition: fn(state, command) { state + command },
      step: fn(state, command) { Ok(state + command) },
      invariant: fn(_, _) { False },
      cleanup: fn(state) {
        case state > 0 {
          True -> Error("cleanup-ran")
          False -> Ok(Nil)
        }
      },
      capabilities: [],
    )
  let report =
    runner.run(
      [
        runner.entry(
          "demo",
          "model_cleanup_test",
          "cleanup_test",
          model.check(machine, max_commands: 1),
        ),
      ],
      runner.default_options(),
    )
  let assert [result] = report.results
  assert result.status == runner.Failed
  assert string.contains(result.message, "model invariant failed")
  assert string.contains(result.message, "cleanup-ran")
}

pub fn independent_relation_and_reference_oracles_fail_as_tests_test() {
  let metamorphic_test =
    metamorphic.relation(
      gen.constant(2),
      original: fn(value) { value * 2 },
      transform: fn(value) { value + 1 },
      follow_up: fn(value) { value * 2 },
      holds: fn(original, follow_up) { original == follow_up },
    )
  let reference_test =
    reference.compare(
      gen.constant(2),
      sut: fn(value) { value + 2 },
      oracle: fn(value) { value + 1 },
      equivalent: fn(left, right) { left == right },
    )
  let hyper_test =
    hyperproperty.for_all(gen.constant(1), gen.constant(2), fn(left, right) {
      assert left == right
    })
  let report =
    runner.run(
      [
        runner.entry(
          "demo",
          "relations_test",
          "metamorphic_test",
          metamorphic_test,
        ),
        runner.entry("demo", "relations_test", "reference_test", reference_test),
        runner.entry("demo", "relations_test", "hyper_test", hyper_test),
      ],
      runner.default_options(),
    )
  let assert [metamorphic_result, reference_result, hyper_result] =
    report.results
  assert metamorphic_result.status == runner.Failed
  assert metamorphic_result.oracle
    == Some(evidence.PropertyOracle("metamorphic relation"))
  assert reference_result.status == runner.Failed
  assert reference_result.oracle
    == Some(evidence.ExternalOracle("reference implementation"))
  assert hyper_result.status == runner.Failed
  assert hyper_result.oracle == Some(evidence.PropertyOracle("hyperproperty"))
}

pub fn oracle_free_differential_divergence_is_advisory_and_unjudged_test() {
  let root =
    path.join(
      platform.temporary_directory(),
      "smartest-differential-" <> platform.random_nonce(),
    )
  let value =
    differential.compare(
      gen.constant(2),
      left: fn(value) { value + 1 },
      right: fn(value) { value + 2 },
      equivalent: fn(left, right) { left == right },
    )
  let report =
    runner.run(
      [runner.entry("demo", "differential_test", "compare_test", value)],
      runner.default_options()
        |> runner.with_findings(root, created_ms: 10),
    )
  let assert [result] = report.results
  assert result.status == runner.Unjudged
  assert runner.succeeded(result)
  assert result.oracle == Some(evidence.DifferentialOnly)
  let assert Ok([finding]) = storage.list_inbox(root)
  assert finding.state == evidence.UnjudgedDivergence
  assert finding.oracle == evidence.DifferentialOnly

  let assert Ok(still_unjudged) =
    storage.accept(
      root,
      finding.id,
      at_ms: 20,
      review_note: "recorded difference",
      human_oracle: None,
    )
  assert still_unjudged.state == evidence.UnjudgedDivergence
  let _ = platform.delete_tree(root)
  Nil
}

pub fn fault_matrix_is_lazy_capability_gated_and_reports_each_fault_test() {
  let value =
    fault.for_each(
      "transport",
      [#("timeout", "timeout"), #("reset", "reset")],
      capabilities: [evidence.Network],
      run: fn(value) {
        case value {
          "timeout" -> Nil
          _ -> panic as "reset was not handled"
        }
      },
    )
  let entry = runner.entry("demo", "fault_test", "transport_test", value)
  let guarded = runner.run([entry], runner.default_options())
  assert list.all(guarded.results, fn(result) { result.status == runner.Unsafe })

  let exercised =
    runner.run(
      [entry],
      runner.default_options()
        |> runner.with_capabilities([evidence.Network]),
    )
  let assert [timeout, reset] = exercised.results
  assert timeout.status == runner.Passed
  assert reset.status == runner.Failed
  assert evidence.test_id_children(timeout.id) == ["transport", "timeout"]
  assert evidence.test_id_children(reset.id) == ["transport", "reset"]
}

pub fn performance_regressions_have_a_distinct_statistical_status_test() {
  let slow =
    performance.expect_p95_under(
      "slow operation",
      samples: 3,
      maximum_ms: 1,
      run: fn() { block(20) },
    )
  let broken =
    performance.expect_p95_under(
      "broken operation",
      samples: 2,
      maximum_ms: 1000,
      run: fn() { panic as "correctness-failure" },
    )
  let report =
    runner.run(
      [
        runner.entry("demo", "performance_test", "slow_test", slow),
        runner.entry("demo", "performance_test", "broken_test", broken),
      ],
      runner.default_options(),
    )
  let assert [regression, correctness] = report.results
  assert regression.status == runner.PerformanceRegression
  assert string.contains(regression.message, "p95")
  assert correctness.status == runner.Failed
  assert string.contains(correctness.message, "correctness-failure")
}

pub fn bounded_concurrency_schedules_shrink_to_a_replayable_witness_test() {
  let value =
    concurrency.check(
      actor_count: 2,
      max_steps: 4,
      capabilities: [],
      run: fn(schedule) {
        case concurrency.choices(schedule) {
          [] -> Ok(Nil)
          _ -> Error("deadlock detected")
        }
      },
    )
    |> testing.with_budget(evidence.budget(
      cases: 100,
      shrinks: 100,
      timeout_ms: 1000,
      seed: 7,
    ))
  let report =
    runner.run(
      [runner.entry("demo", "concurrency_test", "deadlock_test", value)],
      runner.default_options(),
    )
  let assert [result] = report.results
  assert result.status == runner.Failed
  assert string.contains(result.message, "deadlock detected")
  assert result.witness != None
  assert result.draw_tape != []
  assert result.oracle == Some(evidence.ModelOracle("concurrency schedule"))
}
