// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/option.{Some}
import gleam/string
import smartest/doctest
import smartest/evidence
import smartest/observe
import smartest/runner

pub fn native_doctest_is_lazy_named_and_uses_an_example_oracle_test() {
  let renderer = observe.renderer(int.to_string)
  let _lazy =
    doctest.expect(
      "lazy example",
      actual: fn() { panic as "doctest ran during construction" },
      expected: 1,
      equal: fn(left, right) { left == right },
      renderer: renderer,
    )
  let value =
    doctest.expect(
      "reverse twice",
      actual: fn() { 42 },
      expected: 42,
      equal: fn(left, right) { left == right },
      renderer: renderer,
    )
  let report =
    runner.run(
      [runner.entry("demo", "guide_test", "readme_test", value)],
      runner.default_options(),
    )
  let assert [passing] = report.results
  assert passing.status == runner.Passed
  assert evidence.test_id_children(passing.id) == ["reverse twice"]
  assert passing.oracle == Some(evidence.ExampleOracle)
}

pub fn native_doctest_mismatch_has_expected_and_actual_renderings_test() {
  let value =
    doctest.expect(
      "documented answer",
      actual: fn() { 41 },
      expected: 42,
      equal: fn(left, right) { left == right },
      renderer: observe.renderer(int.to_string),
    )
  let report =
    runner.run(
      [runner.entry("demo", "guide_test", "answer_test", value)],
      runner.default_options(),
    )
  let assert [failure] = report.results
  assert failure.status == runner.Failed
  assert string.contains(failure.message, "doctest documented answer")
  assert string.contains(failure.message, "expected: 42")
  assert string.contains(failure.message, "actual: 41")
}
