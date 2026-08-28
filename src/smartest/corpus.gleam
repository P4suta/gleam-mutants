//// Pure, versioned corpus envelope.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{type Option, None, Some}
import gleam/string
import smartest/evidence.{type EvidenceState, type OracleProvenance, type Target}

pub const schema_version = 1

/// Whether an artifact is waiting for review or is part of the tracked corpus.
pub type Lifecycle {
  Inbox
  Accepted
  Rejected
}

/// The canonical, target-portable representation of one replay input.
pub type Envelope {
  Envelope(
    schema_version: Int,
    id: String,
    test_id: evidence.TestId,
    draw_tape: List(Int),
    generator_schema: String,
    oracle: OracleProvenance,
    state: EvidenceState,
    lifecycle: Lifecycle,
    targets: List(Target),
    rendering: String,
    review: Option(String),
    created_ms: Int,
    accepted_ms: Option(Int),
  )
}

pub type ValidationError {
  UnsupportedSchema(found: Int)
  EmptyArtifactId
  EmptyGeneratorSchema
  MissingTarget
  AcceptedWithoutTimestamp
  UnacceptedWithTimestamp
  AcceptedWithoutReview
  TrustedWithoutIndependentOracle
}

pub type Freshness {
  Fresh
  Stale(expected: String, found: String)
}

pub fn new(
  id id: String,
  test_id test_id: evidence.TestId,
  draw_tape draw_tape: List(Int),
  generator_schema generator_schema: String,
  oracle oracle: OracleProvenance,
  targets targets: List(Target),
  rendering rendering: String,
  created_ms created_ms: Int,
) -> Envelope {
  Envelope(
    schema_version: schema_version,
    id: id,
    test_id: test_id,
    draw_tape: draw_tape,
    generator_schema: generator_schema,
    oracle: oracle,
    state: evidence.initial_state(oracle),
    lifecycle: Inbox,
    targets: targets,
    rendering: rendering,
    review: None,
    created_ms: created_ms,
    accepted_ms: None,
  )
}

pub fn validate(envelope: Envelope) -> Result(Nil, ValidationError) {
  case envelope.schema_version {
    version if version != schema_version -> Error(UnsupportedSchema(version))
    _ ->
      case envelope.id, envelope.generator_schema, envelope.targets {
        "", _, _ -> Error(EmptyArtifactId)
        _, "", _ -> Error(EmptyGeneratorSchema)
        _, _, [] -> Error(MissingTarget)
        _, _, _ -> validate_review_and_trust(envelope)
      }
  }
}

fn validate_review_and_trust(
  envelope: Envelope,
) -> Result(Nil, ValidationError) {
  case envelope.lifecycle, envelope.accepted_ms, envelope.review {
    Accepted, None, _ -> Error(AcceptedWithoutTimestamp)
    Inbox, Some(_), _ | Rejected, Some(_), _ -> Error(UnacceptedWithTimestamp)
    Accepted, _, None -> Error(AcceptedWithoutReview)
    Accepted, _, Some(note) ->
      case string.trim(note) {
        "" -> Error(AcceptedWithoutReview)
        _ -> validate_trust(envelope)
      }
    _, _, _ -> validate_trust(envelope)
  }
}

fn validate_trust(envelope: Envelope) -> Result(Nil, ValidationError) {
  case envelope.state, evidence.oracle_is_independent(envelope.oracle) {
    evidence.TrustedEvidence, False -> Error(TrustedWithoutIndependentOracle)
    _, _ -> Ok(Nil)
  }
}

/// Stable, human-readable validation diagnostics used by storage and doctor.
pub fn validation_error_message(error: ValidationError) -> String {
  case error {
    UnsupportedSchema(found) ->
      "unsupported corpus schema " <> string.inspect(found)
    EmptyArtifactId -> "artifact id is empty"
    EmptyGeneratorSchema -> "generator schema is empty"
    MissingTarget -> "corpus artifact has no target"
    AcceptedWithoutTimestamp -> "accepted artifact has no acceptance timestamp"
    UnacceptedWithTimestamp -> "unaccepted artifact has an acceptance timestamp"
    AcceptedWithoutReview -> "accepted artifact requires a non-empty review"
    TrustedWithoutIndependentOracle ->
      "trusted evidence requires an independent oracle"
  }
}

/// Reviews an inbox artifact. Without an independent oracle it can be tracked,
/// but it remains provisional or unjudged and therefore cannot gate CI.
pub fn accept(
  envelope: Envelope,
  at_ms at_ms: Int,
  review_note review_note: String,
  human_oracle human_oracle: Option(String),
) -> Envelope {
  let #(state, oracle) =
    evidence.review(envelope.state, envelope.oracle, human_oracle)
  Envelope(
    ..envelope,
    oracle: oracle,
    state: state,
    lifecycle: Accepted,
    review: Some(review_note),
    accepted_ms: Some(at_ms),
  )
}

pub fn reject(envelope: Envelope, reason: String) -> Envelope {
  Envelope(
    ..envelope,
    state: evidence.RejectedEvidence(reason),
    lifecycle: Rejected,
    review: Some(reason),
    accepted_ms: None,
  )
}

pub fn freshness(envelope: Envelope, current_schema: String) -> Freshness {
  case envelope.generator_schema == current_schema {
    True -> Fresh
    False -> Stale(expected: envelope.generator_schema, found: current_schema)
  }
}

pub fn with_test_id(envelope: Envelope, id: evidence.TestId) -> Envelope {
  Envelope(..envelope, test_id: id)
}
