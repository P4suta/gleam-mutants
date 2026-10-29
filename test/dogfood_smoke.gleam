// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/api
import gleam_mutants/types

const expected_mutants = 50

const expected_rejections = 7

const workers = 2

const timeout_ms = 60_000

pub type Verdict {
  Passed
  SurvivorsFound
  Inconclusive(String)
}

pub fn assess(report: types.RunReport, expected: types.Catalog) -> Verdict {
  case complete_catalog(report, expected) {
    False -> Inconclusive("candidate identities or execution coverage changed")
    True ->
      case list.all(report.results, measured) {
        False ->
          Inconclusive("missing, cached, timed-out, or erroneous measurements")
        True ->
          case
            list.any(report.results, fn(result) {
              result.aggregate == types.Survived
            })
          {
            True -> SurvivorsFound
            False ->
              case
                report.score
                == types.Score(
                  expected_mutants,
                  expected_mutants,
                  0,
                  0,
                  0,
                  100.0,
                )
                && report.policy.failure == None
              {
                True -> Passed
                False ->
                  Inconclusive("score or policy disagrees with measurements")
              }
          }
      }
  }
}

fn complete_catalog(report: types.RunReport, expected: types.Catalog) -> Bool {
  let expected_ids = list.map(expected.mutants, fn(mutant) { mutant.id })
  let rejected_ids =
    list.map(expected.rejected, fn(rejected) { rejected.mutant.id })
  let all_ids = list.append(expected_ids, rejected_ids)
  let actual = list.map(report.results, fn(result) { result.mutant.id })
  let actual_rejected =
    list.map(report.rejected, fn(rejected) { rejected.mutant.id })
  expected.validation == types.CompilerValidated
  && list.length(expected_ids) == expected_mutants
  && list.length(rejected_ids) == expected_rejections
  && list.length(list.unique(all_ids)) == expected_mutants + expected_rejections
  && list.sort(actual, string.compare)
  == list.sort(expected_ids, string.compare)
  && list.sort(actual_rejected, string.compare)
  == list.sort(rejected_ids, string.compare)
  && list.all(list.append(expected.rejected, report.rejected), fn(rejected) {
    rejected.reason == "compile-invalid"
  })
  && !report.matrix
  && report.selection.candidates == expected_mutants + expected_rejections
  && report.selection.executed == expected_mutants
  && report.selection.compile_errors == expected_rejections
  && !report.selection.skipped
}

fn measured(result: types.MutantResult) -> Bool {
  case result.outcomes {
    [types.RuntimeOutcome(types.Erlang, types.Killed, _, _, False)] ->
      result.aggregate == types.Killed
    [types.RuntimeOutcome(types.Erlang, types.Survived, _, _, False)] ->
      result.aggregate == types.Survived
    _ -> False
  }
}

pub fn main() -> Nil {
  let options =
    types.Options(
      ..api.default_options(),
      includes: ["src/gleam_mutants/core/score.gleam"],
      strict: Some(True),
      jobs: Some(workers),
      test_selection: Some(types.TestSelectionFull),
      timeout_ms: Some(timeout_ms),
      test_command: Some(["gleam", "test", "--target", "erlang"]),
      write_reports: True,
    )
  let assert Ok(catalog) = api.validate_mutants(".", options)
  assert list.length(catalog.mutants) == expected_mutants
  assert list.length(catalog.rejected) == expected_rejections
  let assert Ok(report) = api.run(".", options)
  case assess(report, catalog) {
    Passed ->
      io.println(
        "Score dogfood: 50 killed; 7 compile-invalid; 0 survived; 0 timed out; 0 errors; no cached outcomes",
      )
    SurvivorsFound -> {
      io.println(api.report_json(report))
      panic as "Score dogfood found surviving mutants"
    }
    Inconclusive(reason) -> {
      io.println(api.report_json(report))
      panic as { "Inconclusive score dogfood: " <> reason }
    }
  }
}
