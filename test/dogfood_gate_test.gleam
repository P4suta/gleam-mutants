// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import dogfood_smoke
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/core/mutant
import gleam_mutants/core/span
import gleam_mutants/types

const candidate_count = 50

const rejection_count = 7

pub fn complete_measurements_pass_independently_of_result_order_test() {
  let report = fixture()
  assert dogfood_smoke.assess(report, catalog(report)) == dogfood_smoke.Passed
  assert dogfood_smoke.assess(
      types.RunReport(..report, results: list.reverse(report.results)),
      catalog(report),
    )
    == dogfood_smoke.Passed
}

pub fn a_measured_survivor_is_a_failure_test() {
  let report = fixture()
  let changed = measurement(report, types.Survived, types.Erlang, False)
  assert dogfood_smoke.assess(changed, catalog(report))
    == dogfood_smoke.SurvivorsFound
}

pub fn timeouts_errors_and_unmeasured_results_are_inconclusive_test() {
  let report = fixture()
  let assert [first, ..rest] = report.results
  let cases = [
    measurement(report, types.TimedOut, types.Erlang, False),
    measurement(report, types.TestError("child failed"), types.Erlang, False),
    measurement(report, types.Killed, types.Erlang, True),
    measurement(report, types.Killed, types.Node, False),
    measurement(report, types.Killed, types.Deno, False),
    measurement(report, types.Killed, types.Bun, False),
    types.RunReport(..report, results: [
      types.MutantResult(..first, outcomes: []),
      ..rest
    ]),
    types.RunReport(..report, results: [
      types.MutantResult(..first, aggregate: types.Survived),
      ..rest
    ]),
    types.RunReport(..report, results: [
      types.MutantResult(
        ..first,
        outcomes: list.append(first.outcomes, first.outcomes),
      ),
      ..rest
    ]),
  ]
  list.each(cases, fn(changed) { inconclusive(changed, catalog(report)) })
}

pub fn missing_duplicate_or_misclassified_candidates_are_inconclusive_test() {
  let report = fixture()
  let assert [first, ..rest] = report.results
  let assert [rejected, ..other_rejected] = report.rejected
  let expected = catalog(report)
  let cases = [
    types.RunReport(..report, results: rest),
    types.RunReport(..report, results: [first, first, ..list.drop(rest, 1)]),
    types.RunReport(..report, rejected: [
      types.RejectedMutant(first.mutant, "compile error", "diagnostic"),
    ]),
    types.RunReport(..report, rejected: [
      types.RejectedMutant(..rejected, mutant: first.mutant),
      ..other_rejected
    ]),
    types.RunReport(..report, rejected: [
      types.RejectedMutant(..rejected, reason: "infrastructure failure"),
      ..other_rejected
    ]),
    types.RunReport(..report, matrix: True),
    types.RunReport(
      ..report,
      selection: types.SelectionSummary(..report.selection, skipped: True),
    ),
    types.RunReport(
      ..report,
      selection: types.SelectionSummary(..report.selection, compile_errors: 1),
    ),
    types.RunReport(
      ..report,
      selection: types.SelectionSummary(
        ..report.selection,
        candidates: candidate_count - 1,
      ),
    ),
    types.RunReport(
      ..report,
      selection: types.SelectionSummary(
        ..report.selection,
        executed: candidate_count - 1,
      ),
    ),
  ]
  list.each(cases, fn(changed) { inconclusive(changed, expected) })
  inconclusive(report, types.Catalog(..expected, mutants: []))
  inconclusive(report, types.Catalog(..expected, validation: types.Unvalidated))
  inconclusive(
    report,
    types.Catalog(
      ..expected,
      mutants: list.repeat(first.mutant, candidate_count),
    ),
  )
  inconclusive(
    report,
    types.Catalog(..expected, mutants: [
      types.Mutant(..first.mutant, id: "unexpected-id"),
      ..list.drop(expected.mutants, 1)
    ]),
  )
}

pub fn a_perfect_score_without_matching_counts_is_inconclusive_test() {
  let report = fixture()
  let cases = [
    types.Score(..report.score, total: candidate_count - 1),
    types.Score(..report.score, killed: candidate_count - 1),
    types.Score(..report.score, timed_out: 1),
    types.Score(..report.score, survived: 1),
    types.Score(..report.score, errors: 1),
    types.Score(..report.score, percent: 99.0),
  ]
  list.each(cases, fn(changed) {
    inconclusive(types.RunReport(..report, score: changed), catalog(report))
  })
}

pub fn a_policy_failure_is_inconclusive_test() {
  let report = fixture()
  inconclusive(
    types.RunReport(
      ..report,
      policy: types.PolicySummary(..report.policy, failure: Some("failed")),
    ),
    catalog(report),
  )
}

fn inconclusive(report: types.RunReport, expected: types.Catalog) -> Nil {
  let assert dogfood_smoke.Inconclusive(_) =
    dogfood_smoke.assess(report, expected)
  Nil
}

fn catalog(report: types.RunReport) -> types.Catalog {
  types.Catalog(
    list.map(report.results, fn(result) { result.mutant }),
    report.rejected,
    types.CompilerValidated,
  )
}

fn measurement(
  report: types.RunReport,
  outcome: types.Outcome,
  runtime: types.Runtime,
  cached: Bool,
) -> types.RunReport {
  let assert [first, ..rest] = report.results
  types.RunReport(..report, results: [
    types.MutantResult(..first, aggregate: outcome, outcomes: [
      types.RuntimeOutcome(runtime, outcome, 1, "", cached),
    ]),
    ..rest
  ])
}

fn fixture() -> types.RunReport {
  let all =
    list.repeat(Nil, candidate_count + rejection_count)
    |> list.index_map(fn(_, index) {
      let candidate =
        mutant.from_candidate(
          "True",
          mutant.Candidate(
            "src/score_" <> int.to_string(index) <> ".gleam",
            types.BooleanLiteral,
            span.unsafe_new(0, 4),
            "True",
            "False",
          ),
        )
      types.MutantResult(
        candidate,
        [types.RuntimeOutcome(types.Erlang, types.Killed, 1, "", False)],
        types.Killed,
      )
    })
  let results = list.take(all, candidate_count)
  let rejected =
    list.drop(all, candidate_count)
    |> list.map(fn(result) {
      types.RejectedMutant(
        result.mutant,
        "compile-invalid",
        "compiler diagnostic",
      )
    })
  types.RunReport(
    "dogfood-fixture",
    0,
    1,
    string.repeat("A", 64),
    False,
    types.SelectionSummary(
      "all",
      1,
      candidate_count + rejection_count,
      candidate_count,
      rejection_count,
      False,
      None,
    ),
    types.PolicySummary(True, 100.0, True, None),
    results,
    rejected,
    types.Score(candidate_count, candidate_count, 0, 0, 0, 100.0),
  )
}
