//// Canonical JSON codec for Smartest corpus schema v1.
////
//// JSON belongs to the storage shell; the corpus and evidence contracts stay
//// stdlib-only and FFI-free.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import smartest/corpus.{type Envelope, Envelope}
import smartest/evidence.{type EvidenceState, type OracleProvenance, type Target}

pub fn encode(envelope: Envelope) -> String {
  json.object([
    #("schema_version", json.int(envelope.schema_version)),
    #("id", json.string(envelope.id)),
    #(
      "test_id",
      json.object([
        #("package", json.string(evidence.test_id_package(envelope.test_id))),
        #("module", json.string(evidence.test_id_module(envelope.test_id))),
        #("function", json.string(evidence.test_id_function(envelope.test_id))),
        #(
          "children",
          json.array(evidence.test_id_children(envelope.test_id), json.string),
        ),
      ]),
    ),
    #("draw_tape", json.array(envelope.draw_tape, json.int)),
    #("generator_schema", json.string(envelope.generator_schema)),
    #("oracle", oracle_json(envelope.oracle)),
    #("state", state_json(envelope.state)),
    #("lifecycle", json.string(lifecycle_name(envelope.lifecycle))),
    #(
      "targets",
      json.array(envelope.targets, fn(target) {
        json.string(evidence.target_name(target))
      }),
    ),
    #("rendering", json.string(envelope.rendering)),
    #("review", json.nullable(envelope.review, json.string)),
    #("created_ms", json.int(envelope.created_ms)),
    #("accepted_ms", json.nullable(envelope.accepted_ms, json.int)),
  ])
  |> json.to_string
}

pub fn decode(text: String) -> Result(Envelope, String) {
  use envelope <- result.try(
    json.parse(text, envelope_decoder())
    |> result.map_error(fn(error) {
      "invalid Smartest corpus JSON: " <> string.inspect(error)
    }),
  )
  use _ <- result.try(
    corpus.validate(envelope)
    |> result.map_error(fn(error) {
      "invalid Smartest corpus schema: "
      <> corpus.validation_error_message(error)
    }),
  )
  Ok(envelope)
}

fn envelope_decoder() -> decode.Decoder(Envelope) {
  use schema_version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use test_id <- decode.field("test_id", test_id_decoder())
  use tape <- decode.field("draw_tape", decode.list(decode.int))
  use generator_schema <- decode.field("generator_schema", decode.string)
  use oracle <- decode.field("oracle", oracle_decoder())
  use state <- decode.field("state", state_decoder())
  use lifecycle <- decode.field("lifecycle", lifecycle_decoder())
  use targets <- decode.field("targets", decode.list(target_decoder()))
  use rendering <- decode.field("rendering", decode.string)
  use review <- decode.field("review", decode.optional(decode.string))
  use created_ms <- decode.field("created_ms", decode.int)
  use accepted_ms <- decode.field("accepted_ms", decode.optional(decode.int))
  decode.success(Envelope(
    schema_version: schema_version,
    id: id,
    test_id: test_id,
    draw_tape: tape,
    generator_schema: generator_schema,
    oracle: oracle,
    state: state,
    lifecycle: lifecycle,
    targets: targets,
    rendering: rendering,
    review: review,
    created_ms: created_ms,
    accepted_ms: accepted_ms,
  ))
}

fn test_id_decoder() -> decode.Decoder(evidence.TestId) {
  use package <- decode.field("package", decode.string)
  use module <- decode.field("module", decode.string)
  use function <- decode.field("function", decode.string)
  use children <- decode.field("children", decode.list(decode.string))
  let root = evidence.test_id(package, module, function)
  decode.success(list.fold(children, root, evidence.child_test_id))
}

fn oracle_json(oracle: OracleProvenance) -> json.Json {
  let #(kind, detail, source) = case oracle {
    evidence.ExampleOracle -> #("example", "", None)
    evidence.PropertyOracle(name) -> #("property", name, None)
    evidence.ModelOracle(name) -> #("model", name, None)
    evidence.SnapshotOracle(name) -> #("snapshot", name, None)
    evidence.ExternalOracle(name) -> #("external", name, None)
    evidence.HumanOracle(review) -> #("human", review, None)
    evidence.DifferentialOnly -> #("differential-only", "", None)
    evidence.Characterization -> #("characterization", "", None)
    evidence.AiProposed(source) -> #("ai-proposed", "", Some(source))
  }
  json.object([
    #("kind", json.string(kind)),
    #("detail", json.string(detail)),
    #("source", json.nullable(source, oracle_json)),
  ])
}

fn oracle_decoder() -> decode.Decoder(OracleProvenance) {
  use kind <- decode.field("kind", decode.string)
  use detail <- decode.field("detail", decode.string)
  use source <- decode.field("source", decode.optional(oracle_decoder()))
  case kind {
    "example" -> decode.success(evidence.ExampleOracle)
    "property" -> decode.success(evidence.PropertyOracle(detail))
    "model" -> decode.success(evidence.ModelOracle(detail))
    "snapshot" -> decode.success(evidence.SnapshotOracle(detail))
    "external" -> decode.success(evidence.ExternalOracle(detail))
    "human" -> decode.success(evidence.HumanOracle(detail))
    "differential-only" -> decode.success(evidence.DifferentialOnly)
    "characterization" -> decode.success(evidence.Characterization)
    "ai-proposed" ->
      case source {
        Some(source) -> decode.success(evidence.AiProposed(source))
        None -> decode.failure(evidence.Characterization, "ai oracle source")
      }
    _ -> decode.failure(evidence.Characterization, "known oracle kind")
  }
}

fn state_json(state: EvidenceState) -> json.Json {
  let #(kind, reason) = case state {
    evidence.ProvisionalEvidence -> #("provisional", "")
    evidence.TrustedEvidence -> #("trusted", "")
    evidence.UnjudgedDivergence -> #("unjudged", "")
    evidence.StaleEvidence(reason) -> #("stale", reason)
    evidence.UnsafeEvidence(reason) -> #("unsafe", reason)
    evidence.UnsupportedEvidence(reason) -> #("unsupported", reason)
    evidence.RejectedEvidence(reason) -> #("rejected", reason)
  }
  json.object([
    #("kind", json.string(kind)),
    #("reason", json.string(reason)),
  ])
}

fn state_decoder() -> decode.Decoder(EvidenceState) {
  use kind <- decode.field("kind", decode.string)
  use reason <- decode.field("reason", decode.string)
  case kind {
    "provisional" -> decode.success(evidence.ProvisionalEvidence)
    "trusted" -> decode.success(evidence.TrustedEvidence)
    "unjudged" -> decode.success(evidence.UnjudgedDivergence)
    "stale" -> decode.success(evidence.StaleEvidence(reason))
    "unsafe" -> decode.success(evidence.UnsafeEvidence(reason))
    "unsupported" -> decode.success(evidence.UnsupportedEvidence(reason))
    "rejected" -> decode.success(evidence.RejectedEvidence(reason))
    _ -> decode.failure(evidence.ProvisionalEvidence, "known evidence state")
  }
}

fn lifecycle_name(lifecycle: corpus.Lifecycle) -> String {
  case lifecycle {
    corpus.Inbox -> "inbox"
    corpus.Accepted -> "accepted"
    corpus.Rejected -> "rejected"
  }
}

fn lifecycle_decoder() -> decode.Decoder(corpus.Lifecycle) {
  decode.string
  |> decode.then(fn(name) {
    case name {
      "inbox" -> decode.success(corpus.Inbox)
      "accepted" -> decode.success(corpus.Accepted)
      "rejected" -> decode.success(corpus.Rejected)
      _ -> decode.failure(corpus.Inbox, "known corpus lifecycle")
    }
  })
}

fn target_decoder() -> decode.Decoder(Target) {
  decode.string
  |> decode.then(fn(name) {
    case evidence.target_from_name(name) {
      Some(target) -> decode.success(target)
      None -> decode.failure(evidence.Erlang, "known Smartest target")
    }
  })
}
