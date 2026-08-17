// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam_mutants/core/catalog
import gleam_mutants/core/operator
import gleam_mutants/core/outcome.{
  Bun, Erlang, Killed, Node, RuntimeOutcome, Survived, TestError, TimedOut,
}
import gleam_mutants/platform

pub fn every_v1_operator_has_a_golden_candidate_test() {
  let source =
    "pub fn identity(value) { value }\n\npub fn exercise(flag: Bool, a: Int, b: Int, x: Float, y: Float) {\n  let _ = True\n  let _ = !flag\n  let _ = flag && False\n  let _ = a == b\n  let _ = a < b\n  let _ = a + b\n  let _ = x +. y\n  let _ = 1\n  let _ = 1.0\n  let _ = \"text\"\n  let _ = [1]\n  a |> identity\n}\n"
  let assert Ok(mutants) =
    catalog.discover("src/golden.gleam", source, operator.all())
  let discovered = list.map(mutants, fn(mutant) { mutant.operator })
  operator.all()
  |> list.each(fn(expected) {
    assert list.contains(discovered, expected)
  })
}

pub fn matrix_outcome_precedence_is_conservative_test() {
  assert outcome.aggregate([
      RuntimeOutcome(Erlang, Survived, 1, "", False),
      RuntimeOutcome(Node, TestError("boom"), 1, "", False),
    ])
    == TestError("boom")
  assert outcome.aggregate([
      RuntimeOutcome(Erlang, Killed, 1, "", False),
      RuntimeOutcome(Node, Survived, 1, "", False),
      RuntimeOutcome(Bun, TimedOut, 1, "", False),
    ])
    == Survived
  assert outcome.aggregate([
      RuntimeOutcome(Erlang, Killed, 1, "", False),
      RuntimeOutcome(Bun, TimedOut, 1, "", False),
    ])
    == TimedOut
  assert outcome.aggregate([
      RuntimeOutcome(Erlang, Killed, 1, "", False),
      RuntimeOutcome(Node, Killed, 1, "", False),
    ])
    == Killed
}

pub fn process_timeout_is_reported_test() {
  let result =
    platform.run_process(
      "node",
      ["-e", "setTimeout(() => {}, 5000)"],
      platform.current_directory(),
      [],
      100,
    )
  assert result.timed_out
}
