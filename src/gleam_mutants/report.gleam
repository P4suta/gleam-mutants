// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam_mutants/cache
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
import gleam_mutants/version
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
    selection: SelectionSummary,
    policy: PolicySummary,
    results: List(MutantResult),
    rejected: List(RejectedMutant),
    score: Score,
  )
}

pub type SelectionSummary {
  SelectionSummary(
    mode: String,
    files_selected: Int,
    candidates: Int,
    executed: Int,
    compile_errors: Int,
    skipped: Bool,
    reason: Option(String),
  )
}

pub type PolicySummary {
  PolicySummary(
    strict: Bool,
    minimum_score: Float,
    require_mutants: Bool,
    failure: Option(String),
  )
}

pub fn to_json(report: RunReport) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #("tool", json.string("gleam-mutants")),
    #("tool_version", json.string(version.current)),
    #("run_id", json.string(report.run_id)),
    #("started_ms", json.int(report.started_ms)),
    #("duration_ms", json.int(report.duration_ms)),
    #("workspace_digest", json.string(report.workspace_digest)),
    #("matrix", json.bool(report.matrix)),
    #(
      "selection",
      json.object([
        #("mode", json.string(report.selection.mode)),
        #("files_selected", json.int(report.selection.files_selected)),
        #("candidates", json.int(report.selection.candidates)),
        #("executed", json.int(report.selection.executed)),
        #("compile_errors", json.int(report.selection.compile_errors)),
        #("skipped", json.bool(report.selection.skipped)),
        #("reason", json.nullable(report.selection.reason, json.string)),
      ]),
    ),
    #(
      "policy",
      json.object([
        #("strict", json.bool(report.policy.strict)),
        #("minimum_score", number_json(report.policy.minimum_score)),
        #("require_mutants", json.bool(report.policy.require_mutants)),
        #("failure", json.nullable(report.policy.failure, json.string)),
      ]),
    ),
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
    #("percent", number_json(score.percent)),
  ])
}

fn number_json(value: Float) -> json.Json {
  let rounded = float.round(value)
  case int.to_float(rounded) == value {
    True -> json.int(rounded)
    False -> json.float(value)
  }
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
  let skipped_text = case report.selection.skipped {
    True ->
      "Mutation run skipped: "
      <> option.unwrap(report.selection.reason, "no reason")
      <> ".\n"
    False -> heading
  }
  let empty_reason = case
    report.selection.skipped,
    report.selection.candidates
  {
    False, 0 ->
      "Mutation sites: "
      <> option.unwrap(report.selection.reason, "none")
      <> ".\n"
    _, _ -> ""
  }
  skipped_text
  <> empty_reason
  <> timeout_text
  <> error_text
  <> rejected_text
  <> "\nMutation score: "
  <> score.display(report.score)
  <> "\n"
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

fn run_directory(workspace: String) -> String {
  platform.cache_directory()
  |> path.join("gleam-mutants/v1/workspaces")
  |> path.join(cache.workspace_id(workspace))
  |> path.join("runs")
}

pub fn save(report: RunReport, workspace: String) -> Result(String, String) {
  let directory = run_directory(workspace)
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(simplifile.describe_error),
  )
  let target = path.join(directory, report.run_id <> ".json")
  let text = to_json(report) <> "\n"
  use _ <- result.try(write_atomic(target, text))
  use _ <- result.try(write_atomic(path.join(directory, "latest.json"), text))
  Ok(target)
}

pub fn latest(workspace: String) -> Result(String, String) {
  run_directory(workspace)
  |> path.join("latest.json")
  |> simplifile.read
  |> result.map_error(simplifile.describe_error)
}

fn write_atomic(target: String, text: String) -> Result(Nil, String) {
  let temporary = target <> ".tmp-" <> platform.random_nonce()
  use _ <- result.try(
    simplifile.write(temporary, text)
    |> result.map_error(simplifile.describe_error),
  )
  case simplifile.rename(at: temporary, to: target) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      let _ = simplifile.delete_file(at: temporary)
      Error(simplifile.describe_error(error))
    }
  }
}

pub fn list_runs(workspace: String) -> Result(String, String) {
  case simplifile.read_directory(at: run_directory(workspace)) {
    Error(simplifile.Enoent) -> Ok("No stored runs for this workspace.\n")
    Error(error) -> Error(simplifile.describe_error(error))
    Ok(entries) ->
      entries
      |> list.filter(fn(entry) {
        string.ends_with(entry, ".json") && entry != "latest.json"
      })
      |> list.sort(string.compare)
      |> list.map(fn(entry) { entry <> "\n" })
      |> string.concat
      |> fn(text) {
        case text {
          "" -> Ok("No stored runs for this workspace.\n")
          _ -> Ok(text)
        }
      }
  }
}

pub fn validate_latest(workspace: String) -> Result(Nil, String) {
  use text <- result.try(latest(workspace))
  case json.parse(text, decode.dynamic) {
    Ok(_) -> Ok(Nil)
    Error(error) ->
      Error("latest native report is invalid JSON: " <> string.inspect(error))
  }
}

pub fn clean(workspace: String) -> Result(Nil, String) {
  case simplifile.delete(run_directory(workspace)) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) -> Error(simplifile.describe_error(error))
  }
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
          <> github_property(item.mutant.path)
          <> ",line="
          <> int.to_string(item.mutant.line)
          <> ",col="
          <> int.to_string(item.mutant.column)
          <> "::"
          <> github_data(
            "Surviving Gleam mutant "
            <> item.mutant.display_id
            <> " ("
            <> operator.name(item.mutant.operator)
            <> ")",
          ),
        )
      })
      case platform.env("GITHUB_STEP_SUMMARY") {
        "" -> Nil
        summary_path -> {
          let _ =
            simplifile.append(
              "## gleam-mutants\n\nMutation score: **"
                <> score.display(report.score)
                <> "** — "
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

fn github_data(value: String) -> String {
  value
  |> string.replace("%", "%25")
  |> string.replace("\r", "%0D")
  |> string.replace("\n", "%0A")
}

fn github_property(value: String) -> String {
  value
  |> github_data
  |> string.replace(":", "%3A")
  |> string.replace(",", "%2C")
}
