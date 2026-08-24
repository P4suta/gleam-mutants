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

/// One probe outcome for a single mutant of a single function.
///
/// `inputs` holds the rendered Gleam source of each argument and `expected`
/// the rendered source of the original's result when it can be printed as
/// source; the two `_inspect` fields carry `string.inspect`-style renderings
/// for explain output. `reason` is non-empty for `Unsupported` and
/// `Nondeterministic` results.
pub type ProbeResult {
  ProbeResult(
    function: String,
    mutant: String,
    status: Status,
    inputs: List(String),
    expected: Option(String),
    expected_inspect: String,
    actual_inspect: String,
    cases: Int,
    shrinks: Int,
    reason: String,
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
    #("actual_inspect", json.string(result.actual_inspect)),
    #("cases", json.int(result.cases)),
    #("shrinks", json.int(result.shrinks)),
    #("reason", json.string(result.reason)),
  ])
  |> json.to_string
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
  use actual_inspect <- decode.optional_field(
    "actual_inspect",
    "",
    decode.string,
  )
  use cases <- decode.optional_field("cases", 0, decode.int)
  use shrinks <- decode.optional_field("shrinks", 0, decode.int)
  use reason <- decode.optional_field("reason", "", decode.string)
  decode.success(ProbeResult(
    function: function,
    mutant: mutant,
    status: status,
    inputs: inputs,
    expected: expected,
    expected_inspect: expected_inspect,
    actual_inspect: actual_inspect,
    cases: cases,
    shrinks: shrinks,
    reason: reason,
  ))
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
