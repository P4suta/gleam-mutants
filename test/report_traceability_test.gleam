// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mutants/api
import gleam_mutants/core/mutant
import gleam_mutants/core/score
import gleam_mutants/core/span
import gleam_mutants/types

pub fn native_reports_preserve_error_reasons_and_distinguish_empty_messages_test() {
  let cases = [
    #(types.Killed, None),
    #(types.Survived, None),
    #(types.TimedOut, None),
    #(types.TestError(""), Some("")),
    #(types.TestError("child could not start"), Some("child could not start")),
    #(types.TestError("日本語 😀\n\r\"\\\u{0000}"), Some("日本語 😀\n\r\"\\\u{0000}")),
  ]
  let diagnostic = string.repeat("diagnostic 日本語 😀\n\"\\", 8192)
  let cases = [#(types.TestError(diagnostic), Some(diagnostic)), ..cases]
  let cases =
    int.range(0, 128, cases, fn(cases, value) {
      let assert Ok(codepoint) = string.utf_codepoint(value)
      let message = string.from_utf_codepoints([codepoint])
      [#(types.TestError(message), Some(message)), ..cases]
    })
  list.each(cases, fn(entry) {
    let text = api.report_json(report(entry.0))
    let assert Ok([#(aggregate, runtimes)]) = json.parse(text, errors_decoder())
    assert aggregate == entry.1
    assert runtimes == [entry.1]
  })
}

pub fn main() {
  io.print(api.report_json(report(types.TestError("schema error 日本語\n\"\\"))))
}

fn errors_decoder() -> decode.Decoder(
  List(#(Option(String), List(Option(String)))),
) {
  use values <- decode.field(
    "mutants",
    decode.list({
      use aggregate <- decode.field("error", decode.optional(decode.string))
      use runtimes <- decode.field(
        "outcomes",
        decode.list({
          use message <- decode.field("error", decode.optional(decode.string))
          decode.success(message)
        }),
      )
      decode.success(#(aggregate, runtimes))
    }),
  )
  decode.success(values)
}

fn report(value: types.Outcome) -> types.RunReport {
  let candidate =
    mutant.from_candidate(
      "True",
      mutant.Candidate(
        "src/example.gleam",
        types.BooleanLiteral,
        span.unsafe_new(0, 4),
        "True",
        "False",
      ),
    )
  types.RunReport(
    "traceability",
    0,
    1,
    string.repeat("A", 64),
    False,
    types.SelectionSummary("all", 1, 1, 1, 0, False, None),
    types.PolicySummary(False, 100.0, True, None),
    [
      types.MutantResult(
        candidate,
        [types.RuntimeOutcome(types.Node, value, 1, "", False)],
        value,
      ),
    ],
    [],
    score.calculate([value]),
  )
}
