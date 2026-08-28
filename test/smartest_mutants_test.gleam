// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{None}
import gleam_mutants/suggest/probe_result.{
  type ProbeResult, type Status, Distinguished, Indistinguishable,
  Nondeterministic, ProbeResult, Returned, Unsupported,
}
import smartest/evidence
import smartest/mutants

fn observation(status: Status, reason: String) -> ProbeResult {
  ProbeResult(
    function: "demo.add",
    mutant: "mutant-17",
    status: status,
    inputs: ["1", "2"],
    support_modules: [],
    expected: None,
    expected_inspect: "3",
    expected_outcome: Returned,
    actual_inspect: "-1",
    actual_outcome: Returned,
    cases: 23,
    shrinks: 7,
    reason: reason,
    kills: ["mutant-17"],
  )
}

pub fn smartest_distinguished_mutant_is_an_unjudged_divergence_test() {
  let finding =
    mutants.classify(observation(Distinguished, ""), timeout_ms: 900, seed: 42)

  assert finding.verdict == evidence.UnjudgedWitness
  assert finding.state == evidence.UnjudgedDivergence
  assert finding.inputs == ["1", "2"]
  assert finding.kills == ["mutant-17"]
}

pub fn smartest_exhausted_mutation_search_is_never_equivalence_test() {
  let finding =
    mutants.classify(
      observation(Indistinguishable, ""),
      timeout_ms: 900,
      seed: 42,
    )

  assert finding.verdict
    == evidence.NotDistinguishedWithinBudget(evidence.budget(
      cases: 23,
      shrinks: 7,
      timeout_ms: 900,
      seed: 42,
    ))
  assert finding.state == evidence.ProvisionalEvidence
  assert !mutants.claims_equivalence(finding)
}

pub fn smartest_nondeterministic_original_is_unsafe_evidence_test() {
  let finding =
    mutants.classify(
      observation(Nondeterministic, "original changed between runs"),
      timeout_ms: 900,
      seed: 42,
    )

  assert finding.verdict
    == evidence.UnsafeToExplore("original changed between runs")
  assert finding.state
    == evidence.UnsafeEvidence("original changed between runs")
  assert !evidence.blocks_ci(finding.state)
}

pub fn smartest_unsupported_mutant_retains_the_probe_reason_test() {
  let finding =
    mutants.classify(
      observation(Unsupported, "opaque constructor is unavailable"),
      timeout_ms: 900,
      seed: 42,
    )

  assert finding.verdict
    == evidence.UnsupportedTarget("opaque constructor is unavailable")
  assert finding.state
    == evidence.UnsupportedEvidence("opaque constructor is unavailable")
}

pub fn smartest_empty_probe_reasons_are_still_explainable_test() {
  let unsafe =
    mutants.classify(observation(Nondeterministic, ""), timeout_ms: 0, seed: 0)
  let unsupported =
    mutants.classify(observation(Unsupported, ""), timeout_ms: 0, seed: 0)

  assert unsafe.state
    == evidence.UnsafeEvidence("original behaviour was nondeterministic")
  assert unsupported.state
    == evidence.UnsupportedEvidence("mutation probe did not provide a reason")
}
