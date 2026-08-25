// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The wire format between the in-VM differential probe and its host: one JSON
// object per line on stdout, decoded back into a typed result here.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/string

/// How a mutant behaved when run against its original.
pub type Status {
  /// An input was found for which original and mutant disagree.
  Distinguished
  /// No input separated the mutant from the original.
  Indistinguishable
  /// The original disagreed with itself, so no verdict is possible.
  Nondeterministic
  /// The function could not be probed; `reason` says why.
  Unsupported
}

/// Why a mutant an input divided from its original still has no test.
///
/// The search separates values structurally, and Erlang compares a fun by the
/// environment it captured — but every assertion that can be written goes
/// through `string.inspect`, which renders every fun as `//fn(a) { ... }`. A
/// test written from such a separation passes with the mutant in place, which
/// is worse than no test at all, so the probe reports the wall instead. The
/// probe emits this reason and the host refuses to render anything whose two
/// sides read alike, so the two speak with one voice.
pub const inexpressible_reason = "original and mutant differ only by values no assertion can express (function values)"

/// How one call ended.
///
/// A call that did not return has no value to state, which is the difference
/// between a test that can be generated and one that cannot.
pub type Outcome {
  /// The call returned, and the matching `_inspect` field holds its value.
  Returned
  /// The call panicked, so there is no value at all.
  Panicked
  /// The call ran past its timeout.
  TimedOut
}

/// One probe outcome for a single mutant of a single function.
///
/// `inputs` holds the rendered Gleam source of each argument and `expected`
/// the rendered source of the original's result when it can be printed as
/// source; the two `_inspect` fields carry the `string.inspect` rendering of
/// the value each side answered with — the value itself, never the wrapper the
/// probe carried it home in — and are empty unless the matching `_outcome` is
/// `Returned`. `reason` is non-empty for `Unsupported` and `Nondeterministic`
/// results. `kills` names every mutant of the same function that `inputs`
/// separates from the original, its own mutant included, in the order the
/// probe was given them; it is empty unless the status is `Distinguished`.
pub type ProbeResult {
  ProbeResult(
    function: String,
    mutant: String,
    status: Status,
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

/// Decodes one JSON line emitted by the probe.
///
/// `function`, `mutant`, `status` and `inputs` are required; the remaining
/// fields default to `None`, `""` and `0`.
pub fn decode_line(line: String) -> Result(ProbeResult, String) {
  case json.parse(line, decoder()) {
    Ok(decoded) -> Ok(decoded)
    Error(error) ->
      Error("invalid probe result line: " <> string.inspect(error))
  }
}

/// Decodes every probe result found in a captured stdout stream.
///
/// Blank lines and lines that do not begin with `{` are compiler chatter and
/// are ignored. The second element collects the JSON-looking lines that could
/// not be decoded.
pub fn decode_output(stdout: String) -> #(List(ProbeResult), List(String)) {
  let #(results, failures) =
    stdout
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.filter(string.starts_with(_, "{"))
    |> list.fold(#([], []), fn(accumulated, line) {
      let #(results, failures) = accumulated
      case decode_line(line) {
        Ok(decoded) -> #([decoded, ..results], failures)
        Error(_) -> #(results, [line, ..failures])
      }
    })
  #(list.reverse(results), list.reverse(failures))
}

/// Encodes a probe result as the single JSON line the decoder accepts.
pub fn encode(result: ProbeResult) -> String {
  json.object([
    #("function", json.string(result.function)),
    #("mutant", json.string(result.mutant)),
    #("status", json.string(status_name(result.status))),
    #("inputs", json.array(result.inputs, json.string)),
    #("expected", json.nullable(result.expected, json.string)),
    #("expected_inspect", json.string(result.expected_inspect)),
    #("expected_outcome", json.string(outcome_name(result.expected_outcome))),
    #("actual_inspect", json.string(result.actual_inspect)),
    #("actual_outcome", json.string(outcome_name(result.actual_outcome))),
    #("cases", json.int(result.cases)),
    #("shrinks", json.int(result.shrinks)),
    #("reason", json.string(result.reason)),
    #("kills", json.array(result.kills, json.string)),
  ])
  |> json.to_string
}

/// The stable lowercase wire name of an outcome.
pub fn outcome_name(outcome: Outcome) -> String {
  case outcome {
    Returned -> "returned"
    Panicked -> "panicked"
    TimedOut -> "timed_out"
  }
}

/// The stable lowercase wire name of a status.
pub fn status_name(status: Status) -> String {
  case status {
    Distinguished -> "distinguished"
    Indistinguishable -> "indistinguishable"
    Nondeterministic -> "nondeterministic"
    Unsupported -> "unsupported"
  }
}

fn decoder() -> decode.Decoder(ProbeResult) {
  use function <- decode.field("function", decode.string)
  use mutant <- decode.field("mutant", decode.string)
  use status <- decode.field("status", status_decoder())
  use inputs <- decode.field("inputs", decode.list(decode.string))
  use expected <- decode.optional_field(
    "expected",
    None,
    decode.optional(decode.string),
  )
  use expected_inspect <- decode.optional_field(
    "expected_inspect",
    "",
    decode.string,
  )
  use expected_outcome <- decode.optional_field(
    "expected_outcome",
    Returned,
    outcome_decoder(),
  )
  use actual_inspect <- decode.optional_field(
    "actual_inspect",
    "",
    decode.string,
  )
  use actual_outcome <- decode.optional_field(
    "actual_outcome",
    Returned,
    outcome_decoder(),
  )
  use cases <- decode.optional_field("cases", 0, decode.int)
  use shrinks <- decode.optional_field("shrinks", 0, decode.int)
  use reason <- decode.optional_field("reason", "", decode.string)
  use kills <- decode.optional_field("kills", [], decode.list(decode.string))
  decode.success(ProbeResult(
    function: function,
    mutant: mutant,
    status: status,
    inputs: inputs,
    expected: expected,
    expected_inspect: expected_inspect,
    expected_outcome: expected_outcome,
    actual_inspect: actual_inspect,
    actual_outcome: actual_outcome,
    cases: cases,
    shrinks: shrinks,
    reason: reason,
    kills: kills,
  ))
}

fn outcome_decoder() -> decode.Decoder(Outcome) {
  use name <- decode.then(decode.string)
  case name {
    "returned" -> decode.success(Returned)
    "panicked" -> decode.success(Panicked)
    "timed_out" -> decode.success(TimedOut)
    _ -> decode.failure(Returned, "Outcome")
  }
}

fn status_decoder() -> decode.Decoder(Status) {
  use name <- decode.then(decode.string)
  case name {
    "distinguished" -> decode.success(Distinguished)
    "indistinguishable" -> decode.success(Indistinguishable)
    "nondeterministic" -> decode.success(Nondeterministic)
    "unsupported" -> decode.success(Unsupported)
    _ -> decode.failure(Unsupported, "Status")
  }
}
