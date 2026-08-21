// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/json
import gleam/option.{None}
import gleam/string
import gleam_mutants/core/catalog.{RejectedMutant}
import gleam_mutants/core/mutant.{Candidate}
import gleam_mutants/core/operator
import gleam_mutants/core/outcome.{
  Erlang, Killed, Node, RuntimeOutcome, Survived, TestError, TimedOut,
}
import gleam_mutants/core/score
import gleam_mutants/core/span
import gleam_mutants/report.{
  MutantResult, PolicySummary, RunReport, SelectionSummary,
}
import gleam_mutants/stryker_report.{SourceFile}

pub fn projection_maps_sorts_and_uses_utf16_locations_test() {
  let source = "// first\r\npub const 😀x = 10\r\n"
  let ten_start = string.byte_size("// first\r\npub const 😀x = ")
  let ten =
    mutant.from_candidate(
      source,
      Candidate(
        "src\\unicode.gleam",
        operator.IntegerNeutral,
        span.unsafe_new(ten_start, ten_start + 2),
        "10",
        "0",
      ),
    )
  let emoji_start = string.byte_size("// first\r\npub const ")
  let emoji =
    mutant.from_candidate(
      source,
      Candidate(
        "src/unicode.gleam",
        operator.StringNeutral,
        span.unsafe_new(emoji_start, emoji_start + 4),
        "😀",
        "\"\"",
      ),
    )
  let invalid =
    mutant.from_candidate(
      source,
      Candidate(
        "src/unicode.gleam",
        operator.IntegerArithmetic,
        span.unsafe_new(ten_start, ten_start + 2),
        "10",
        "-1",
      ),
    )
  let results = [
    MutantResult(
      ten,
      [
        RuntimeOutcome(Erlang, Killed, 7, "failure output", False),
        RuntimeOutcome(Node, Killed, 5, "", True),
      ],
      Killed,
    ),
    MutantResult(
      emoji,
      [RuntimeOutcome(Erlang, Survived, 3, "", False)],
      Survived,
    ),
  ]
  let run_report =
    RunReport(
      "run",
      1,
      15,
      string.repeat("A", 64),
      True,
      SelectionSummary("all", 3, 3, 2, 1, False, None),
      PolicySummary(False, 100.0, True, None),
      results,
      [RejectedMutant(invalid, "compile-invalid", "compiler says no")],
      score.calculate([Killed, Survived]),
    )

  let assert Ok(projected) =
    stryker_report.to_json(
      run_report,
      [
        SourceFile("z/empty.gleam", "pub const empty = Nil\n"),
        SourceFile("src\\unicode.gleam", source),
        SourceFile("a/empty.gleam", "pub const empty = Nil\n"),
      ],
      80,
      60,
    )
  assert string.contains(projected, "\"schemaVersion\":\"1.0\"")
  assert string.contains(projected, "\"thresholds\":{\"high\":80,\"low\":60}")
  assert string.contains(
    projected,
    "\"location\":{\"start\":{\"line\":2,\"column\":17},\"end\":{\"line\":2,\"column\":19}}",
  )
  assert string.contains(projected, "\"duration\":12")
  assert string.contains(projected, "\"replacement\":\"0\"")
  assert string.contains(projected, "\"status\":\"Killed\"")
  assert string.contains(projected, "\"status\":\"Survived\"")
  assert string.contains(projected, "\"status\":\"CompileError\"")
  assert string.contains(projected, "\"statusReason\":\"compiler says no\"")
  assert string.contains(
    projected,
    "\"source\":" <> json.to_string(json.string(source)),
  )
  assert appears_before(projected, emoji.id, invalid.id)
  assert appears_before(projected, invalid.id, ten.id)
  assert appears_before(projected, "a/empty.gleam", "src/unicode.gleam")
  assert appears_before(projected, "src/unicode.gleam", "z/empty.gleam")
  assert !string.contains(projected, "\"outcomes\"")
  assert !string.contains(projected, "\"runtime\"")
  assert !string.contains(projected, "\"cached\"")
}

pub fn projection_maps_runtime_error_without_changing_native_wire_test() {
  let source = "pub const answer = 1\npub const other = 2\n"
  let start = string.byte_size("pub const answer = ")
  let error_mutant =
    mutant.from_candidate(
      source,
      Candidate(
        "src/error.gleam",
        operator.IntegerNeutral,
        span.unsafe_new(start, start + 1),
        "1",
        "0",
      ),
    )
  let result_ =
    MutantResult(
      error_mutant,
      [RuntimeOutcome(Erlang, TestError("test crashed"), 9, "stderr", False)],
      TestError("test crashed"),
    )
  let timeout_start =
    string.byte_size("pub const answer = 1\npub const other = ")
  let timeout_mutant =
    mutant.from_candidate(
      source,
      Candidate(
        "src/error.gleam",
        operator.IntegerNeutral,
        span.unsafe_new(timeout_start, timeout_start + 1),
        "2",
        "0",
      ),
    )
  let timeout_result =
    MutantResult(
      timeout_mutant,
      [RuntimeOutcome(Node, TimedOut, 100, "timed out", False)],
      TimedOut,
    )
  let run_report =
    RunReport(
      "run",
      1,
      9,
      string.repeat("B", 64),
      False,
      SelectionSummary("all", 1, 2, 2, 0, False, None),
      PolicySummary(False, 100.0, True, None),
      [result_, timeout_result],
      [],
      score.calculate([TestError("test crashed"), TimedOut]),
    )
  let native = report.to_json(run_report)
  assert string.contains(native, "\"schema_version\":1")
  assert string.contains(native, "\"aggregate\":\"test-error\"")
  assert !string.contains(native, "schemaVersion")
  assert !string.contains(native, "\"files\":")

  let assert Ok(projected) =
    stryker_report.to_json(
      run_report,
      [SourceFile("src/error.gleam", source)],
      80,
      60,
    )
  assert string.contains(projected, "\"status\":\"RuntimeError\"")
  assert string.contains(projected, "\"status\":\"Timeout\"")
  assert string.contains(projected, "test crashed")
  assert string.contains(projected, "stderr")
  assert !string.contains(projected, "coveredBy")
  assert !string.contains(projected, "killedBy")
  assert !string.contains(projected, "testsCompleted")
  assert !string.contains(projected, "projectRoot")
  assert !string.contains(projected, "\"config\"")
}

fn appears_before(haystack: String, first: String, second: String) -> Bool {
  case string.split_once(haystack, first) {
    Error(_) -> False
    Ok(#(_, after_first)) -> string.contains(after_first, second)
  }
}
