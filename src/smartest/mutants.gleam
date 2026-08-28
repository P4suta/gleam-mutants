//// Conservative adaptation of the compatible `gleam_mutants` probe wire
//// format into Smartest evidence. A differential probe observes behaviour;
//// it never decides which behaviour is correct.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{type Option}
import gleam/string
import gleam_mutants/suggest/probe_result.{
  type Outcome, type ProbeResult, Distinguished, Indistinguishable,
  Nondeterministic, Unsupported,
}
import smartest/evidence

/// One mutation observation represented in Smartest's evidence vocabulary.
///
/// This is an integration-shell value rather than a correctness oracle. In
/// particular, a `Distinguished` probe always becomes `UnjudgedWitness`.
pub type MutationFinding {
  MutationFinding(
    function: String,
    mutant: String,
    verdict: evidence.ExplorationVerdict,
    state: evidence.EvidenceState,
    inputs: List(String),
    expected: Option(String),
    expected_inspect: String,
    expected_outcome: Outcome,
    actual_inspect: String,
    actual_outcome: Outcome,
    cases: Int,
    shrinks: Int,
    reason: String,
    kills: List(String),
  )
}

/// Classifies an existing compatible mutation probe result.
///
/// `timeout_ms` and `seed` complete the actual case/shrink counts recorded by
/// the probe into the bounded-search description shown in the ledger.
pub fn classify(
  observation: ProbeResult,
  timeout_ms timeout_ms: Int,
  seed seed: Int,
) -> MutationFinding {
  let #(verdict, state, reason) = case observation.status {
    Distinguished -> #(
      evidence.UnjudgedWitness,
      evidence.UnjudgedDivergence,
      observation.reason,
    )
    Indistinguishable -> #(
      evidence.NotDistinguishedWithinBudget(evidence.budget(
        cases: observation.cases,
        shrinks: observation.shrinks,
        timeout_ms: timeout_ms,
        seed: seed,
      )),
      evidence.ProvisionalEvidence,
      observation.reason,
    )
    Nondeterministic -> {
      let reason =
        with_default_reason(
          observation.reason,
          "original behaviour was nondeterministic",
        )
      #(
        evidence.UnsafeToExplore(reason),
        evidence.UnsafeEvidence(reason),
        reason,
      )
    }
    Unsupported -> {
      let reason =
        with_default_reason(
          observation.reason,
          "mutation probe did not provide a reason",
        )
      #(
        evidence.UnsupportedTarget(reason),
        evidence.UnsupportedEvidence(reason),
        reason,
      )
    }
  }

  MutationFinding(
    function: observation.function,
    mutant: observation.mutant,
    verdict: verdict,
    state: state,
    inputs: observation.inputs,
    expected: observation.expected,
    expected_inspect: observation.expected_inspect,
    expected_outcome: observation.expected_outcome,
    actual_inspect: observation.actual_inspect,
    actual_outcome: observation.actual_outcome,
    cases: observation.cases,
    shrinks: observation.shrinks,
    reason: reason,
    kills: observation.kills,
  )
}

/// Whether a finding contains a genuine formal equivalence proof.
///
/// Results produced by `classify` always answer `False`; this function makes
/// the epistemic distinction explicit for report and policy code.
pub fn claims_equivalence(finding: MutationFinding) -> Bool {
  case finding.verdict {
    evidence.EquivalentByProof(_) -> True
    _ -> False
  }
}

fn with_default_reason(reason: String, fallback: String) -> String {
  case string.trim(reason) {
    "" -> fallback
    reason -> reason
  }
}
