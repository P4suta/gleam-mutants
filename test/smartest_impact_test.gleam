// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/evidence
import smartest/impact

fn test_id(name: String) -> evidence.TestId {
  evidence.test_id("demo", "demo_test", name)
}

fn entity(name: String) -> impact.EntityId {
  impact.entity("demo", "demo", name)
}

pub fn smartest_runtime_first_touch_has_priority_over_static_fallback_test() {
  let changed = entity("changed")
  let dynamic_test = test_id("dynamic_test")
  let static_test = test_id("static_test")
  let index =
    impact.new()
    |> impact.record_touch(dynamic_test, changed)
    |> impact.record_touch(dynamic_test, changed)
    |> impact.record_static_root(static_test, changed)

  let selection =
    impact.select(index, changed: [changed], all_tests: [
      dynamic_test,
      static_test,
    ])
  assert selection.tests == [dynamic_test]
  assert selection.dynamic == [dynamic_test]
  assert selection.static == []
  assert selection.unmapped == []
}

pub fn smartest_private_change_uses_the_shortest_public_static_caller_test() {
  let private = entity("private_helper")
  let near_public = entity("public_api")
  let far_public = entity("other_api")
  let near_test = test_id("public_api_test")
  let far_test = test_id("other_api_test")
  let index =
    impact.new()
    |> impact.record_static_root(far_test, far_public)
    |> impact.record_static_root(near_test, near_public)
    |> impact.record_call(far_public, near_public)
    |> impact.record_call(near_public, private)

  let selection =
    impact.select(index, changed: [private], all_tests: [near_test, far_test])
  assert selection.tests == [near_test, far_test]
  assert selection.static == [near_test, far_test]
  assert selection.unmapped == []
  assert impact.shortest_distance(index, from: near_public, to: private)
    == Ok(1)
  assert impact.shortest_distance(index, from: far_public, to: private) == Ok(2)
}

pub fn smartest_unmapped_change_falls_back_to_all_tests_and_reports_gap_test() {
  let unknown = entity("new_unmapped_function")
  let first = test_id("first_test")
  let second = test_id("second_test")
  let selection =
    impact.select(impact.new(), changed: [unknown], all_tests: [first, second])

  assert selection.tests == [first, second]
  assert selection.dynamic == []
  assert selection.static == []
  assert selection.unmapped == [unknown]
}

pub fn smartest_call_graph_cycles_do_not_break_impact_selection_test() {
  let one = entity("one")
  let two = entity("two")
  let selected = test_id("cycle_test")
  let index =
    impact.new()
    |> impact.record_static_root(selected, one)
    |> impact.record_call(one, two)
    |> impact.record_call(two, one)
  let selection = impact.select(index, changed: [two], all_tests: [selected])

  assert selection.tests == [selected]
  assert impact.shortest_distance(index, from: one, to: two) == Ok(1)
}

pub fn smartest_no_changed_entities_selects_no_tests_test() {
  let all = [test_id("first_test"), test_id("second_test")]
  let selection = impact.select(impact.new(), changed: [], all_tests: all)
  assert selection.tests == []
  assert selection.unmapped == []
}
