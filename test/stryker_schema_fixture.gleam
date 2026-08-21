// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam/option.{None}
import gleam/string
import gleam_mutants/core/catalog.{RejectedMutant}
import gleam_mutants/core/mutant.{Candidate}
import gleam_mutants/core/operator
import gleam_mutants/core/outcome.{Erlang, RuntimeOutcome, Survived}
import gleam_mutants/core/score
import gleam_mutants/core/span
import gleam_mutants/report.{
  MutantResult, PolicySummary, RunReport, SelectionSummary,
}
import gleam_mutants/stryker_report.{SourceFile}

pub fn fixture_json() -> String {
  let #(report, source) = fixture()
  let assert Ok(json) =
    stryker_report.to_json(
      report,
      [SourceFile("src/adversarial.gleam", source)],
      80,
      60,
    )
  json
}

pub fn native_fixture_json() -> String {
  let #(fixture_report, _) = fixture()
  report.to_json(fixture_report)
}

fn fixture() -> #(report.RunReport, String) {
  let source =
    "// </script><script>globalThis.__gleamMutantsSentinel=true</script><!-- \\\" \\\\ 😀 \u{2028} \u{2029} & >\r\npub const alive = True\r\n"
  let assert Ok(#(before, _)) = string.split_once(source, "True")
  let start = string.byte_size(before)
  let survivor =
    mutant.from_candidate(
      source,
      Candidate(
        "src\\adversarial.gleam",
        operator.BooleanLiteral,
        span.unsafe_new(start, start + 4),
        "True",
        "False",
      ),
    )
  let invalid =
    mutant.from_candidate(
      source,
      Candidate(
        "src/adversarial.gleam",
        operator.BooleanNegation,
        span.unsafe_new(start, start + 4),
        "True",
        "!True",
      ),
    )
  let report =
    RunReport(
      "fixture",
      1,
      4,
      string.repeat("C", 64),
      False,
      SelectionSummary("all", 1, 2, 1, 1, False, None),
      PolicySummary(False, 100.0, True, None),
      [
        MutantResult(
          survivor,
          [RuntimeOutcome(Erlang, Survived, 4, "", False)],
          Survived,
        ),
      ],
      [RejectedMutant(invalid, "compile-invalid", "expected expression")],
      score.calculate([Survived]),
    )
  #(report, source)
}

pub fn main() {
  io.print(fixture_json())
}
