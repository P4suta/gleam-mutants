// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile
import smartest/corpus
import smartest/evidence
import smartest/gen
import smartest/property
import smartest/runner
import smartest/scenario
import smartest/storage
import smartest/testing

@external(erlang, "smartest_runner_test_ffi", "block")
@external(javascript, "./smartest_runner_test_ffi.mjs", "block")
fn block(milliseconds: Int) -> Nil

pub fn constructing_examples_properties_and_resources_is_lazy_test() {
  let _example =
    testing.example(fn() { panic as "example construction ran code" })
  let _property =
    property.for_all(gen.int(), fn(_) {
      panic as "property construction ran code"
    })
  let resource =
    scenario.resource(
      setup: fn() { panic as "resource setup ran during construction" },
      teardown: fn(_) { panic as "resource teardown ran during construction" },
      capabilities: [],
    )
  let _scenario =
    scenario.with_resource(resource, fn(_) {
      panic as "scenario body ran during construction"
    })
  Nil
}

pub fn legacy_adapter_results_keep_a_stable_opaque_ledger_entry_test() {
  let passing =
    runner.legacy_result(
      "demo",
      "legacy_test",
      "old_style_test",
      passed: True,
      message: "opaque legacy test",
    )
  let failing =
    runner.legacy_result(
      "demo",
      "legacy_test",
      "broken_test",
      passed: False,
      message: "legacy assertion failed",
    )
  assert passing.status == runner.Passed
  assert evidence.test_id_to_string(passing.id)
    == "demo/legacy_test/old_style_test"
  assert passing.oracle == Some(evidence.ExampleOracle)
  assert failing.status == runner.Failed
  assert string.contains(failing.message, "legacy assertion failed")
}

pub fn runner_executes_a_native_example_and_captures_assert_metadata_test() {
  let passing =
    runner.entry(
      "demo",
      "native_test",
      "passing_test",
      testing.example(fn() {
        assert 1 + 1 == 2
      }),
    )
  let failing =
    runner.entry(
      "demo",
      "native_test",
      "failing_test",
      testing.example(fn() {
        assert 1 + 1 == 3
      }),
    )
  let report = runner.run([passing, failing], runner.default_options())
  let assert [pass_result, fail_result] = report.results
  assert pass_result.status == runner.Passed
  assert fail_result.status == runner.Failed
  assert string.contains(fail_result.message, "1 + 1")
  assert string.contains(fail_result.message, "3")
}

pub fn suites_get_stable_parent_and_child_ids_test() {
  let suite =
    testing.suite("stack", [
      testing.named("empty", testing.example(fn() { Nil })),
      testing.named("push", testing.example(fn() { Nil })),
    ])
  let report =
    runner.run(
      [runner.entry("demo", "stack_test", "stack_test", suite)],
      runner.default_options(),
    )
  assert list.map(report.results, fn(result) {
      evidence.test_id_to_string(result.id)
    })
    == [
      "demo/stack_test/stack_test/stack/empty",
      "demo/stack_test/stack_test/stack/push",
    ]
}

pub fn exact_leaf_selection_keeps_descriptor_order_and_runs_only_the_leaf_test() {
  let entry =
    runner.entry(
      "demo",
      "stack_test",
      "selected_test",
      testing.suite("stack", [
        testing.named("empty", testing.example(fn() { Nil })),
        testing.named("push", testing.example(fn() { Nil })),
        testing.named("pop", testing.example(fn() { Nil })),
      ]),
    )
  let ids =
    runner.test_ids(entry)
    |> list.map(evidence.test_id_to_string)
  assert ids
    == [
      "demo/stack_test/selected_test/stack/empty",
      "demo/stack_test/selected_test/stack/push",
      "demo/stack_test/selected_test/stack/pop",
    ]

  let results =
    runner.run_entry_selected(entry, runner.default_options(), [
      "demo/stack_test/selected_test/stack/push",
    ])
  assert list.map(results, fn(result) { evidence.test_id_to_string(result.id) })
    == ["demo/stack_test/selected_test/stack/push"]
}

pub fn generator_manifest_is_extracted_from_lazy_plans_without_running_callbacks_test() {
  let integer = gen.int_range(0, 9)
  let value =
    testing.suite("numbers", [
      testing.named(
        "bounded",
        property.for_all(integer, fn(_) {
          panic as "manifest extraction ran a property callback"
        }),
      ),
      testing.example(fn() {
        panic as "manifest extraction ran an example callback"
      }),
    ])
  let entry = runner.entry("demo", "number_test", "manifest_test", value)

  assert runner.generator_bindings(entry)
    == [
      storage.GeneratorBinding(
        evidence.test_id("demo", "number_test", "manifest_test")
          |> evidence.child_test_id("numbers")
          |> evidence.child_test_id("bounded"),
        gen.schema_fingerprint(integer),
      ),
    ]
}

pub fn a_failing_property_is_shrunk_and_returns_its_replay_tape_test() {
  let property =
    property.for_all(gen.int_range(0, 100), fn(value) {
      assert value < 1
    })
    |> testing.with_budget(evidence.budget(
      cases: 100,
      shrinks: 100,
      timeout_ms: 1000,
      seed: 7,
    ))
  let entry =
    runner.entry("demo", "number_test", "less_than_one_test", property)
  let report = runner.run([entry], runner.default_options())
  let assert [result] = report.results
  assert result.status == runner.Failed
  assert result.witness == Some("1")
  assert result.draw_tape == [1]
  assert result.generator_schema != None
}

pub fn replay_refuses_a_changed_generator_schema_test() {
  let property = property.for_all(gen.int_range(0, 5), fn(_) { Nil })
  let entry = runner.entry("demo", "number_test", "replay_test", property)
  let id = evidence.test_id("demo", "number_test", "replay_test")
  let options =
    runner.default_options()
    |> runner.with_replay(id, [1], "old-schema")
  let report = runner.run([entry], options)
  let assert [result] = report.results
  assert result.status == runner.Stale
  assert string.contains(result.message, "generator schema")
}

pub fn unknown_exploratory_effects_are_not_run_test() {
  let property =
    property.for_all(gen.constant(1), fn(_) {
      panic as "unsafe callback was run"
    })
    |> testing.with_effect(evidence.Unknown("effect analysis unavailable"))
  let report =
    runner.run(
      [runner.entry("demo", "unsafe_test", "unknown_test", property)],
      runner.default_options(),
    )
  let assert [result] = report.results
  assert result.status == runner.Unsafe
  assert string.contains(result.message, "effect analysis unavailable")
}

pub fn resource_teardown_runs_even_when_the_body_panics_test() {
  let resource =
    scenario.resource(
      setup: fn() { Ok("resource") },
      teardown: fn(_) { Error("cleanup-ran") },
      capabilities: [],
    )
  let scenario =
    scenario.with_resource(resource, fn(_) { panic as "body-failed" })
  let report =
    runner.run(
      [runner.entry("demo", "resource_test", "cleanup_test", scenario)],
      runner.default_options(),
    )
  let assert [result] = report.results
  assert result.status == runner.Failed
  assert string.contains(result.message, "body-failed")
  assert string.contains(result.message, "cleanup-ran")
}

pub fn resource_setup_panics_are_contained_as_structured_failures_test() {
  let resource =
    scenario.resource(
      setup: fn() { panic as "setup-failed" },
      teardown: fn(_) { Ok(Nil) },
      capabilities: [],
    )
  let value = scenario.with_resource(resource, fn(_) { Nil })
  let report =
    runner.run(
      [runner.entry("demo", "resource_test", "setup_test", value)],
      runner.default_options(),
    )
  let assert [result] = report.results
  assert result.status == runner.Failed
  assert string.contains(result.message, "setup-failed")
}

pub fn timeout_and_declared_capability_boundaries_are_enforced_test() {
  let timed =
    testing.example(fn() { block(20) })
    |> testing.with_budget(evidence.budget(
      cases: 1,
      shrinks: 0,
      timeout_ms: 1,
      seed: 1,
    ))
  let network_resource =
    scenario.resource(
      setup: fn() { Ok(Nil) },
      teardown: fn(_) { Ok(Nil) },
      capabilities: [evidence.Network],
    )
  let guarded =
    scenario.with_resource(network_resource, fn(_) {
      panic as "capability was granted"
    })
  let default_report =
    runner.run(
      [
        runner.entry("demo", "runtime_test", "timeout_test", timed),
        runner.entry("demo", "runtime_test", "network_test", guarded),
      ],
      runner.default_options(),
    )
  let assert [timeout, unsafe] = default_report.results
  assert timeout.status == runner.TimedOut
  assert unsafe.status == runner.Unsafe

  let granted_report =
    runner.run(
      [runner.entry("demo", "runtime_test", "network_test", guarded)],
      runner.default_options()
        |> runner.with_capabilities([evidence.Network]),
    )
  let assert [executed] = granted_report.results
  assert executed.status == runner.Failed
  assert string.contains(executed.message, "capability was granted")
}

pub fn failing_properties_enter_the_review_inbox_with_the_minimal_tape_test() {
  let root =
    path.join(
      platform.temporary_directory(),
      "smartest-runner-inbox-" <> platform.random_nonce(),
    )
  let property =
    property.for_all(gen.int_range(0, 100), fn(value) {
      assert value < 1
    })
    |> testing.with_budget(evidence.budget(
      cases: 100,
      shrinks: 100,
      timeout_ms: 1000,
      seed: 7,
    ))
  let options =
    runner.default_options()
    |> runner.with_findings(root, created_ms: 123)
  let report =
    runner.run(
      [runner.entry("demo", "number_test", "inbox_test", property)],
      options,
    )
  let assert [failed] = report.results
  let assert Ok([finding]) = storage.list_inbox(root)
  assert finding.lifecycle == corpus.Inbox
  assert finding.state == evidence.ProvisionalEvidence
  assert finding.oracle
    == evidence.PropertyOracle("demo/number_test/inbox_test")
  assert finding.draw_tape == failed.draw_tape
  assert finding.rendering == "1"
  let _ = platform.delete_tree(root)
  Nil
}

pub fn workspace_options_load_trusted_corpus_and_fail_closed_on_corruption_test() {
  let root =
    path.join(
      platform.temporary_directory(),
      "smartest-runner-corpus-" <> platform.random_nonce(),
    )
  let property = property.for_all(gen.int_range(0, 5), fn(_) { Nil })
  let id = evidence.test_id("demo", "number_test", "corpus_test")
  let item =
    corpus.new(
      id: "trusted-replay",
      test_id: id,
      draw_tape: [1],
      generator_schema: "old-schema",
      oracle: evidence.PropertyOracle("corpus property"),
      targets: [evidence.Erlang, evidence.Node, evidence.Deno, evidence.Bun],
      rendering: "1",
      created_ms: 1,
    )
  let assert Ok(_) = storage.put_inbox(root, item)
  let assert Ok(_) =
    storage.accept(
      root,
      item.id,
      at_ms: 2,
      review_note: "reviewed",
      human_oracle: None,
    )
  let options = runner.workspace_options(root, created_ms: 3)
  assert list.length(options.replays) == 1
  let replay_options =
    runner.replay_options(root, "trusted-replay", created_ms: 3)
  assert replay_options.replay_only
  assert list.length(replay_options.replays) == 1
  let report =
    runner.run(
      [runner.entry("demo", "number_test", "corpus_test", property)],
      options,
    )
  assert list.any(report.results, fn(result) { result.status == runner.Stale })

  let broken = storage.corpus_path(root, "broken")
  let assert Ok(Nil) = simplifile.write(broken, "{broken")
  let broken_options = runner.workspace_options(root, created_ms: 4)
  let protected =
    property.for_all(gen.constant(1), fn(_) {
      panic as "corrupt corpus did not fail closed"
    })
  let broken_report =
    runner.run(
      [runner.entry("demo", "number_test", "protected_test", protected)],
      broken_options,
    )
  let assert [failure] = broken_report.results
  assert failure.status == runner.Stale
  let _ = platform.delete_tree(root)
  Nil
}
