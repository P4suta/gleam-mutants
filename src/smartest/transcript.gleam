//// Pure record/replay transcripts for integration boundaries.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{None}
import smartest/evidence.{type Capability}
import smartest/gen
import smartest/internal/plan
import smartest/testing.{type Test}

/// A caller-versioned sequence of recorded request/response exchanges.
pub opaque type Transcript(request, response) {
  Transcript(
    schema: String,
    exchanges: List(#(request, response)),
    render_request: fn(request) -> String,
  )
}

/// Immutable cursor threaded through a replaying integration test.
pub opaque type Replay(request, response) {
  Replay(
    transcript: Transcript(request, response),
    index: Int,
    remaining: List(#(request, response)),
  )
}

pub type ReplayError {
  UnexpectedRequest(index: Int, expected: String, actual: String)
  UnexpectedEnd(index: Int, actual: String)
  UnconsumedExchanges(count: Int)
  ApplicationFailure(reason: String)
}

/// Declares recorded exchanges without invoking a request renderer or test.
pub fn new(
  schema schema: String,
  exchanges exchanges: List(#(request, response)),
  render_request render_request: fn(request) -> String,
) -> Transcript(request, response) {
  Transcript(schema, exchanges, render_request)
}

pub fn schema_fingerprint(transcript: Transcript(request, response)) -> String {
  gen.nil()
  |> gen.named(
    "transcript("
    <> transcript.schema
    <> ",exchanges:"
    <> int.to_string(list.length(transcript.exchanges))
    <> ")",
  )
  |> gen.schema_fingerprint
}

pub fn start(
  transcript: Transcript(request, response),
) -> Replay(request, response) {
  Replay(transcript, 0, transcript.exchanges)
}

/// Consumes exactly one matching request and returns its recorded response.
pub fn exchange(
  replay: Replay(request, response),
  actual: request,
  equivalent: fn(request, request) -> Bool,
) -> Result(#(Replay(request, response), response), ReplayError) {
  case replay.remaining {
    [] ->
      Error(UnexpectedEnd(
        replay.index,
        replay.transcript.render_request(actual),
      ))
    [#(expected, response), ..rest] ->
      case equivalent(expected, actual) {
        False ->
          Error(UnexpectedRequest(
            replay.index,
            replay.transcript.render_request(expected),
            replay.transcript.render_request(actual),
          ))
        True ->
          Ok(#(
            Replay(..replay, index: replay.index + 1, remaining: rest),
            response,
          ))
      }
  }
}

/// Proves the callback consumed the whole recorded contract.
pub fn finish(replay: Replay(request, response)) -> Result(Nil, ReplayError) {
  case replay.remaining {
    [] -> Ok(Nil)
    remaining -> Error(UnconsumedExchanges(list.length(remaining)))
  }
}

pub fn describe_error(error: ReplayError) -> String {
  case error {
    UnexpectedRequest(index, expected, actual) ->
      "transcript event "
      <> int.to_string(index)
      <> " expected "
      <> expected
      <> ", received "
      <> actual
    UnexpectedEnd(index, actual) ->
      "transcript ended before event "
      <> int.to_string(index)
      <> "; received "
      <> actual
    UnconsumedExchanges(count) ->
      "transcript has " <> int.to_string(count) <> " unconsumed exchange(s)"
    ApplicationFailure(reason) -> reason
  }
}

/// Lifts an integration-specific failure into the replay result channel.
pub fn application_failure(reason: String) -> ReplayError {
  ApplicationFailure(reason)
}

/// Runs a deterministic transcript-backed integration test.
///
/// The callback must return its final cursor. This makes consumption explicit
/// and avoids process-local mutable state that could leak between workers.
pub fn replay(
  transcript: Transcript(request, response),
  capabilities capabilities: List(Capability),
  run run: fn(Replay(request, response)) ->
    Result(Replay(request, response), ReplayError),
) -> Test {
  plan.scenario(
    fn(evaluate, budget, _) {
      let evaluation =
        evaluate(
          fn() {
            case run(start(transcript)) {
              Error(error) -> panic as describe_error(error)
              Ok(replay) ->
                case finish(replay) {
                  Ok(Nil) -> Nil
                  Error(error) -> panic as describe_error(error)
                }
            }
          },
          budget.timeout_ms,
        )
      case evaluation {
        plan.EvaluationPassed(_) -> plan.CheckPassed(1)
        plan.EvaluationFailed(message, _) ->
          plan.CheckFailed(message, None, [], None, cases: 1, shrinks: 0)
        plan.EvaluationTimedOut(message, _) -> plan.CheckTimedOut(message, 1)
        plan.EvaluationCancelled(message, _) -> plan.CheckCancelled(message, 1)
      }
    },
    evidence.Declared(capabilities),
  )
  |> testing.with_oracle(evidence.ExternalOracle(
    "recorded transcript: " <> transcript.schema,
  ))
}
