// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile
import smartest/evidence
import smartest/report
import smartest/runner

pub fn evidence_reports_encode_epistemic_and_performance_statuses_test() {
  let id = evidence.test_id("demo", "report_test", "finding_test")
  let value =
    runner.Report([
      runner.TestResult(
        id,
        runner.Unjudged,
        "left <script> right",
        3,
        1,
        Some("2"),
        [2],
        Some("schema-v1"),
        Some(evidence.DifferentialOnly),
      ),
      runner.TestResult(
        id,
        runner.PerformanceRegression,
        "p95 exceeded",
        0,
        0,
        None,
        [],
        None,
        None,
      ),
      runner.TestResult(
        id,
        runner.BudgetExhausted,
        "checked 2 of 3",
        2,
        0,
        None,
        [],
        None,
        Some(evidence.PropertyOracle(
          "finite exhaustive: states 0 through 2; bound 3",
        )),
      ),
    ])

  let json = report.json(value)
  assert string.contains(json, "\"status\":\"unjudged\"")
  assert string.contains(
    json,
    "\"oracle\":{\"kind\":\"differential-only\",\"detail\":\"\",\"source\":null}",
  )
  assert string.contains(json, "\"status\":\"performance-regression\"")
  assert string.contains(json, "\"status\":\"budget-exhausted\"")
  assert string.contains(
    json,
    "\"detail\":\"finite exhaustive: states 0 through 2; bound 3\"",
  )

  let html = report.html(value)
  assert string.contains(html, "left &lt;script&gt; right")
  assert !string.contains(html, "left <script> right")
  assert string.contains(html, "PERFORMANCE-REGRESSION")
}

pub fn evidence_reports_are_atomically_written_under_the_ephemeral_state_test() {
  let root =
    path.join(
      platform.temporary_directory(),
      "smartest-report-test-" <> platform.random_nonce(),
    )
  let value = runner.Report([])
  let assert Ok(paths) = report.write(root, value)
  assert paths.json == path.join(root, ".smartest/latest.json")
  assert paths.html == path.join(root, ".smartest/latest.html")
  let assert Ok(json) = simplifile.read(paths.json)
  let assert Ok(html) = simplifile.read(paths.html)
  assert string.contains(json, "\"schema_version\":1")
  assert string.contains(html, "Smartest evidence")
  let _ = platform.delete_tree(root)
  Nil
}
