//// Canonical machine and review reports for Smartest evidence.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/json as gleam_json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import smartest/evidence.{type OracleProvenance}
import smartest/internal/path
import smartest/internal/shell
import smartest/runner.{type Report, type Status, type TestResult}

pub type Paths {
  Paths(json: String, html: String)
}

pub fn json(report: Report) -> String {
  gleam_json.object([
    #("schema_version", gleam_json.int(1)),
    #("results", gleam_json.array(report.results, result_json)),
  ])
  |> gleam_json.to_string
}

fn result_json(result: TestResult) -> gleam_json.Json {
  gleam_json.object([
    #("test_id", gleam_json.string(evidence.test_id_to_string(result.id))),
    #("status", gleam_json.string(status_name(result.status))),
    #("message", gleam_json.string(result.message)),
    #("cases", gleam_json.int(result.cases)),
    #("shrinks", gleam_json.int(result.shrinks)),
    #("witness", gleam_json.nullable(result.witness, gleam_json.string)),
    #("draw_tape", gleam_json.array(result.draw_tape, gleam_json.int)),
    #(
      "generator_schema",
      gleam_json.nullable(result.generator_schema, gleam_json.string),
    ),
    #(
      "oracle",
      gleam_json.nullable(result.oracle, fn(oracle) { oracle_json(oracle) }),
    ),
  ])
}

pub fn html(report: Report) -> String {
  let rows =
    report.results
    |> list.map(fn(result) {
      "<tr><td>"
      <> escape(evidence.test_id_to_string(result.id))
      <> "</td><td>"
      <> escape(display_status(result.status))
      <> "</td><td><pre>"
      <> escape(result.message)
      <> "</pre></td></tr>"
    })
    |> string.concat
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>Smartest evidence</title>"
  <> "<style>body{font-family:system-ui,sans-serif}table{border-collapse:collapse;width:100%}"
  <> "td,th{border:1px solid #ccc;padding:.4rem;text-align:left}pre{white-space:pre-wrap}</style>"
  <> "</head><body><h1>Smartest evidence</h1><table><thead><tr>"
  <> "<th>Test</th><th>Status</th><th>Message</th></tr></thead><tbody>"
  <> rows
  <> "</tbody></table></body></html>"
}

pub fn write(root: String, report: Report) -> Result(Paths, String) {
  let directory = path.join(root, ".smartest")
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(fn(error) {
      "could not create evidence report directory: "
      <> simplifile.describe_error(error)
    }),
  )
  let json_path = path.join(directory, "latest.json")
  let html_path = path.join(directory, "latest.html")
  use _ <- result.try(write_atomic(json_path, json(report) <> "\n"))
  use _ <- result.try(write_atomic(html_path, html(report) <> "\n"))
  Ok(Paths(json_path, html_path))
}

fn write_atomic(target: String, contents: String) -> Result(Nil, String) {
  let temporary = target <> ".tmp-" <> shell.random_nonce()
  use _ <- result.try(
    simplifile.write(temporary, contents)
    |> result.map_error(fn(error) {
      "could not stage evidence report: " <> simplifile.describe_error(error)
    }),
  )
  case simplifile.rename(at: temporary, to: target) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      let _ = simplifile.delete_file(at: temporary)
      Error(
        "could not commit evidence report: " <> simplifile.describe_error(error),
      )
    }
  }
}

fn status_name(status: Status) -> String {
  case status {
    runner.Passed -> "passed"
    runner.Failed -> "failed"
    runner.TimedOut -> "timed-out"
    runner.Cancelled -> "cancelled"
    runner.Skipped -> "skipped"
    runner.Unsafe -> "unsafe"
    runner.Unsupported -> "unsupported"
    runner.Unjudged -> "unjudged"
    runner.BudgetExhausted -> "budget-exhausted"
    runner.PerformanceRegression -> "performance-regression"
    runner.Stale -> "stale"
  }
}

fn display_status(status: Status) -> String {
  status_name(status) |> string.uppercase |> string.replace("_", "-")
}

fn oracle_json(oracle: OracleProvenance) -> gleam_json.Json {
  let #(kind, detail, source) = case oracle {
    evidence.ExampleOracle -> #("example", "", None)
    evidence.PropertyOracle(name) -> #("property", name, None)
    evidence.ModelOracle(name) -> #("model", name, None)
    evidence.SnapshotOracle(name) -> #("snapshot", name, None)
    evidence.ExternalOracle(name) -> #("external", name, None)
    evidence.HumanOracle(review) -> #("human", review, None)
    evidence.DifferentialOnly -> #("differential-only", "", None)
    evidence.Characterization -> #("characterization", "", None)
    evidence.AiProposed(source) -> #("ai-proposed", "", Some(source))
  }
  gleam_json.object([
    #("kind", gleam_json.string(kind)),
    #("detail", gleam_json.string(detail)),
    #("source", gleam_json.nullable(source, oracle_json)),
  ])
}

fn escape(value: String) -> String {
  value
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}
