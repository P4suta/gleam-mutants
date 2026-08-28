// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{None, Some}
import smartest/corpus
import smartest/evidence

pub fn differential_without_oracle_is_always_unjudged_test() {
  assert evidence.initial_state(evidence.DifferentialOnly)
    == evidence.UnjudgedDivergence
  let #(state, _) =
    evidence.review(
      evidence.UnjudgedDivergence,
      evidence.DifferentialOnly,
      None,
    )
  assert state == evidence.UnjudgedDivergence
  assert !evidence.blocks_ci(state)
}

pub fn explicit_human_oracle_can_promote_reviewed_evidence_test() {
  let #(state, oracle) =
    evidence.review(
      evidence.UnjudgedDivergence,
      evidence.DifferentialOnly,
      Some("RFC-42 defines the required result"),
    )
  assert state == evidence.TrustedEvidence
  assert oracle == evidence.HumanOracle("RFC-42 defines the required result")
  assert evidence.blocks_ci(state)
}

pub fn budget_exhaustion_is_not_equivalence_test() {
  let verdict = evidence.NotDistinguishedWithinBudget(evidence.default_budget())
  assert !is_equivalent(verdict)
  assert evidence.formal_proof(method: "", subset: "pure Int", bound: "all")
    == Error(evidence.MissingProofMethod)
  let assert Ok(proof) =
    evidence.formal_proof(
      method: "exhaustive enumeration",
      subset: "Bool -> Bool",
      bound: "the complete finite domain",
    )
  assert evidence.proof_subset(proof) == "Bool -> Bool"
}

fn is_equivalent(verdict: evidence.ExplorationVerdict) -> Bool {
  case verdict {
    evidence.EquivalentByProof(_) -> True
    _ -> False
  }
}

pub fn provisional_and_unjudged_evidence_cannot_gate_ci_test() {
  assert !evidence.blocks_ci(evidence.ProvisionalEvidence)
  assert !evidence.blocks_ci(evidence.UnjudgedDivergence)
  assert evidence.blocks_ci(evidence.TrustedEvidence)
  assert evidence.blocks_ci(evidence.StaleEvidence("generator changed"))
}

pub fn unknown_exploration_is_fail_closed_test() {
  assert evidence.exploration_allowed(evidence.Pure, [])
  assert !evidence.exploration_allowed(evidence.Unknown("not graded"), [
    evidence.Network,
  ])
  assert !evidence.exploration_allowed(
    evidence.Declared([evidence.FileRead, evidence.Network]),
    [evidence.FileRead],
  )
  assert evidence.exploration_allowed(
    evidence.Declared([evidence.FileRead, evidence.Network]),
    [evidence.Network, evidence.FileRead],
  )
}

pub fn corpus_schema_changes_are_visible_as_stale_test() {
  let item =
    corpus.new(
      id: "finding-1",
      test_id: evidence.test_id("demo", "stack_test", "reverse_test"),
      draw_tape: [1, 2, 3],
      generator_schema: "schema-old",
      oracle: evidence.PropertyOracle("reverse twice"),
      targets: [evidence.Erlang, evidence.Node],
      rendering: "[1, 2]",
      created_ms: 10,
    )
  assert corpus.freshness(item, "schema-old") == corpus.Fresh
  assert corpus.freshness(item, "schema-new")
    == corpus.Stale(expected: "schema-old", found: "schema-new")
}

pub fn accepting_characterization_tracks_it_without_trusting_it_test() {
  let item =
    corpus.new(
      id: "finding-2",
      test_id: evidence.test_id("demo", "api_test", "current_output_test"),
      draw_tape: [0],
      generator_schema: "string-v1",
      oracle: evidence.Characterization,
      targets: [evidence.Erlang],
      rendering: "today",
      created_ms: 10,
    )
  let accepted =
    corpus.accept(
      item,
      at_ms: 20,
      review_note: "keep for review",
      human_oracle: None,
    )
  assert accepted.lifecycle == corpus.Accepted
  assert accepted.state == evidence.ProvisionalEvidence
  assert !evidence.blocks_ci(accepted.state)
}
