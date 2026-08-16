// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/core/catalog.{type RejectedMutant}
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator
import gleam_mutants/core/outcome.{
  type Outcome, type RuntimeOutcome, Killed, Survived, TestError, TimedOut,
}
import gleam_mutants/core/path
import gleam_mutants/core/score.{type Score}
import gleam_mutants/core/span
import gleam_mutants/platform
import simplifile

pub type MutantResult {
  MutantResult(
    mutant: Mutant,
    outcomes: List(RuntimeOutcome),
    aggregate: Outcome,
  )
}

pub type RunReport {
  RunReport(
    run_id: String,
    started_ms: Int,
    duration_ms: Int,
    workspace_digest: String,
    matrix: Bool,
    results: List(MutantResult),
    rejected: List(RejectedMutant),
    score: Score,
  )
}

pub fn to_json(report: RunReport) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #("tool", json.string("gleam-mutants")),
    #("tool_version", json.string("0.1.0")),
    #("run_id", json.string(report.run_id)),
    #("started_ms", json.int(report.started_ms)),
    #("duration_ms", json.int(report.duration_ms)),
    #("workspace_digest", json.string(report.workspace_digest)),
    #("matrix", json.bool(report.matrix)),
    #("score", score_json(report.score)),
    #("mutants", json.array(report.results, result_json)),
    #("rejected", json.array(report.rejected, rejected_json)),
  ])
  |> json.to_string
}

fn score_json(score: Score) -> json.Json {
  json.object([
    #("total", json.int(score.total)),
    #("killed", json.int(score.killed)),
    #("timed_out", json.int(score.timed_out)),
    #("survived", json.int(score.survived)),
    #("errors", json.int(score.errors)),
    #("percent", json.float(score.percent)),
  ])
}

fn result_json(result_: MutantResult) -> json.Json {
  json.object([
    #("mutant", mutant_json(result_.mutant)),
    #("aggregate", json.string(outcome_name(result_.aggregate))),
    #("outcomes", json.array(result_.outcomes, runtime_outcome_json)),
  ])
}

fn mutant_json(mutant: Mutant) -> json.Json {
  json.object([
    #("id", json.string(mutant.id)),
    #("display_id", json.string(mutant.display_id)),
    #("path", json.string(mutant.path)),
    #("operator", json.string(operator.name(mutant.operator))),
    #("operator_version", json.int(mutant.operator_version)),
    #("source_digest", json.string(mutant.source_digest)),
    #("start_byte", json.int(span.start(mutant.span))),
    #("end_byte", json.int(span.end(mutant.span))),
    #("line", json.int(mutant.line)),
    #("column", json.int(mutant.column)),
    #("original_digest", json.string(mutant.original_digest)),
    #("replacement_digest", json.string(mutant.replacement_digest)),
    #("original", json.string(mutant.original)),
    #("replacement", json.string(mutant.replacement)),
  ])
}

fn runtime_outcome_json(runtime_outcome: RuntimeOutcome) -> json.Json {
  json.object([
    #("runtime", json.string(outcome.runtime_name(runtime_outcome.runtime))),
    #("outcome", json.string(outcome_name(runtime_outcome.outcome))),
    #("duration_ms", json.int(runtime_outcome.duration_ms)),
    #("cached", json.bool(runtime_outcome.cached)),
    #("output", json.string(runtime_outcome.output)),
  ])
}

fn rejected_json(rejected: RejectedMutant) -> json.Json {
  json.object([
    #("mutant", mutant_json(rejected.mutant)),
    #("reason", json.string(rejected.reason)),
    #("diagnostic", json.string(rejected.diagnostic)),
  ])
}

fn outcome_name(value: Outcome) -> String {
  case value {
    Killed -> "killed"
    Survived -> "survived"
    TimedOut -> "timed-out"
    TestError(_) -> "test-error"
  }
}

pub fn render(report: RunReport, explain: Bool) -> String {
  let survivors =
    report.results |> list.filter(fn(item) { item.aggregate == Survived })
  let timeouts =
    report.results |> list.filter(fn(item) { item.aggregate == TimedOut })
  let errors =
    report.results
    |> list.filter(fn(item) {
      case item.aggregate {
        TestError(_) -> True
        _ -> False
      }
    })
  let heading = case survivors {
    [] -> "No surviving mutants.\n"
    _ ->
      "Surviving mutants (fix these tests first):\n"
      <> string.concat(list.map(survivors, render_result))
  }
  let timeout_text = case timeouts {
    [] -> ""
    _ ->
      "\nTimed out (counted as detected):\n"
      <> string.concat(list.map(timeouts, render_result))
  }
  let error_text = case errors {
    [] -> ""
    _ -> "\nTest errors:\n" <> string.concat(list.map(errors, render_result))
  }
  let rejected_text = case explain, report.rejected {
    True, [_, ..] ->
      "\nRejected compile-invalid candidates:\n"
      <> string.concat(
        list.map(report.rejected, fn(item) {
          "  "
          <> location(item.mutant)
          <> " "
          <> operator.name(item.mutant.operator)
          <> ": "
          <> item.reason
          <> "\n"
        }),
      )
    _, _ -> ""
  }
  heading
  <> timeout_text
  <> error_text
  <> rejected_text
  <> "\nMutation score: "
  <> float.to_string(report.score.percent)
  <> "% ("
  <> int.to_string(report.score.killed + report.score.timed_out)
  <> "/"
  <> int.to_string(report.score.total)
  <> ")\n"
  <> "Killed "
  <> int.to_string(report.score.killed)
  <> ", survived "
  <> int.to_string(report.score.survived)
  <> ", timed out "
  <> int.to_string(report.score.timed_out)
  <> ", errors "
  <> int.to_string(report.score.errors)
  <> ".\n"
}

fn render_result(result_: MutantResult) -> String {
  "  "
  <> location(result_.mutant)
  <> " ["
  <> result_.mutant.display_id
  <> "] "
  <> operator.name(result_.mutant.operator)
  <> ": "
  <> compact(result_.mutant.original)
  <> " -> "
  <> compact(result_.mutant.replacement)
  <> "\n"
}

fn location(mutant: Mutant) -> String {
  mutant.path
  <> ":"
  <> int.to_string(mutant.line)
  <> ":"
  <> int.to_string(mutant.column)
}

fn compact(value: String) -> String {
  value |> string.replace("\r", "") |> string.replace("\n", " ") |> string.trim
}

pub fn save(report: RunReport) -> Result(String, String) {
  let directory =
    platform.cache_directory() |> path.join("gleam-mutants/v1/runs")
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(simplifile.describe_error),
  )
  let target = path.join(directory, report.run_id <> ".json")
  let text = to_json(report) <> "\n"
  use _ <- result.try(
    simplifile.write(target, text)
    |> result.map_error(simplifile.describe_error),
  )
  use _ <- result.try(
    simplifile.write(path.join(directory, "latest.json"), text)
    |> result.map_error(simplifile.describe_error),
  )
  Ok(target)
}

pub fn latest() -> Result(String, String) {
  platform.cache_directory()
  |> path.join("gleam-mutants/v1/runs/latest.json")
  |> simplifile.read
  |> result.map_error(simplifile.describe_error)
}

pub fn emit_github(report: RunReport) -> Nil {
  case platform.env("GITHUB_ACTIONS") {
    "" -> Nil
    _ -> {
      report.results
      |> list.filter(fn(item) { item.aggregate == Survived })
      |> list.each(fn(item) {
        io.println(
          "::warning file="
          <> item.mutant.path
          <> ",line="
          <> int.to_string(item.mutant.line)
          <> ",col="
          <> int.to_string(item.mutant.column)
          <> "::Surviving Gleam mutant "
          <> item.mutant.display_id
          <> " ("
          <> operator.name(item.mutant.operator)
          <> ")",
        )
      })
      case platform.env("GITHUB_STEP_SUMMARY") {
        "" -> Nil
        summary_path -> {
          let _ =
            simplifile.append(
              "## gleam-mutants\n\nMutation score: **"
                <> float.to_string(report.score.percent)
                <> "%** — "
                <> int.to_string(report.score.survived)
                <> " survived, "
                <> int.to_string(report.score.timed_out)
                <> " timed out.\n",
              to: summary_path,
            )
          Nil
        }
      }
    }
  }
}
