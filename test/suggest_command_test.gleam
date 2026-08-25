// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The `suggest` use case, driven through its seams rather than through a
// probe.
//
// A real run copies the workspace, compiles it and spawns a VM per module,
// which is what `suggest_smoke` and `suggest_cli_smoke` are for. Everything
// decided *around* that run — which mutants a prefix names, which of them the
// last report saw survive, and which verdicts are worth writing a test for —
// is pure, and is settled here on hand-built reports and hand-built probe
// results.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator.{type Operator}
import gleam_mutants/core/outcome
import gleam_mutants/core/score
import gleam_mutants/core/span
import gleam_mutants/report
import gleam_mutants/suggest/command
import gleam_mutants/suggest/diff_runner
import gleam_mutants/suggest/probe_result.{
  type ProbeResult, Distinguished, Indistinguishable, ProbeResult, Returned,
  Unsupported,
}
import gleam_mutants/suggest/render

// --- The catalogue the tests talk about --------------------------------------

/// `value > 0` becoming `value >= 0`, which only `0` tells apart.
fn boundary_mutant() -> Mutant {
  stub_mutant(
    id: string.repeat("a", 64),
    path: "src/boundary.gleam",
    line: 7,
    column: 3,
    operator: operator.ComparisonBoundary,
    original: "value > 0",
    replacement: "value >= 0",
  )
}

/// A second `is_positive` mutant the boundary input kills as well.
fn redundant_mutant() -> Mutant {
  stub_mutant(
    id: string.repeat("b", 64),
    path: "src/boundary.gleam",
    line: 7,
    column: 3,
    operator: operator.IntegerNeutral,
    original: "0",
    replacement: "1",
  )
}

/// A mutant of another function, which no `is_positive` test can reach.
fn abs_mutant() -> Mutant {
  stub_mutant(
    id: string.repeat("c", 64),
    path: "src/boundary.gleam",
    line: 13,
    column: 5,
    operator: operator.IntegerArithmetic,
    original: "0 - value",
    replacement: "0 + value",
  )
}

/// A mutant of another file entirely, which the stored report never mentions.
fn uncovered_mutant() -> Mutant {
  stub_mutant(
    id: string.repeat("d", 64),
    path: "src/other.gleam",
    line: 2,
    column: 1,
    operator: operator.BooleanLiteral,
    original: "True",
    replacement: "False",
  )
}

/// A mutant of a module constant, which no function of the module holds.
///
/// `select.assign` hands the probe one target per function, so a mutant of a
/// module constant belongs to none of them and no verdict can ever mention it.
fn constant_mutant() -> Mutant {
  stub_mutant(
    id: string.repeat("e", 64),
    path: "src/boundary.gleam",
    line: 3,
    column: 20,
    operator: operator.IntegerNeutral,
    original: "10",
    replacement: "11",
  )
}

// --- Survivor filtering ------------------------------------------------------

pub fn survivor_ids_names_only_the_mutants_that_survived_test() {
  let survivor = boundary_mutant()
  let killed = redundant_mutant()
  let stored =
    report.to_json(
      stub_report([
        graded(survivor, outcome.Survived),
        graded(killed, outcome.Killed),
        graded(abs_mutant(), outcome.TimedOut),
      ]),
    )
  assert report.survivor_ids(stored) == Ok([survivor.id])
}

pub fn survivor_ids_refuses_a_document_that_is_not_a_run_report_test() {
  let assert Error(_) = report.survivor_ids("not json at all")
  let assert Error(_) = report.survivor_ids("{\"schema_version\": 1}")
  Nil
}

pub fn keep_survivors_drops_killed_mutants_and_names_uncovered_files_test() {
  let survivor = boundary_mutant()
  let killed = redundant_mutant()
  let elsewhere = uncovered_mutant()
  let stored =
    report.to_json(
      stub_report([
        graded(survivor, outcome.Survived),
        graded(killed, outcome.Killed),
      ]),
    )
  assert command.keep_survivors([survivor, killed, elsewhere], stored)
    == Ok(#([survivor], ["src/other.gleam"]))
}

// --- Mutant prefixes ---------------------------------------------------------

pub fn matching_narrows_to_the_one_mutant_a_prefix_names_test() {
  let alpha = boundary_mutant()
  let beta = redundant_mutant()
  assert command.matching([alpha, beta], None) == Ok([alpha, beta])
  assert command.matching([alpha, beta], Some("aaaa")) == Ok([alpha])
  assert command.matching([alpha, beta], Some(beta.display_id)) == Ok([beta])
}

pub fn matching_refuses_an_ambiguous_or_unknown_mutant_prefix_test() {
  let alpha = boundary_mutant()
  let twin = mutant.Mutant(..alpha, id: string.repeat("a", 63) <> "e")
  let assert Error(ambiguous) = command.matching([alpha, twin], Some("aaaa"))
  assert string.starts_with(ambiguous, "GMU")
  assert string.contains(ambiguous, "ambiguous")
  let assert Error(unknown) = command.matching([alpha, twin], Some("zzzz"))
  assert string.starts_with(unknown, "GMU")
  assert string.contains(unknown, "no mutant")
  Nil
}

// --- Minimisation ------------------------------------------------------------

pub fn suggestions_keep_the_fewest_tests_that_kill_every_mutant_test() {
  let boundary = boundary_mutant()
  let redundant = redundant_mutant()
  let arithmetic = abs_mutant()
  let equivalent = uncovered_mutant()
  let results = [
    // `0` separates the boundary mutant and, on the way, the redundant one.
    distinguished(
      "is_positive",
      boundary,
      ["0"],
      Some("False"),
      "False",
      "True",
      [boundary.id, redundant.id],
    ),
    // A second test for the same function that adds nothing.
    distinguished(
      "is_positive",
      redundant,
      ["1"],
      Some("True"),
      "True",
      "False",
      [redundant.id],
    ),
    // Another function: no `is_positive` test can reach it.
    distinguished("abs", arithmetic, ["-1"], Some("1"), "1", "-1", [
      arithmetic.id,
    ]),
    // Nothing told this one apart, so there is nothing to write.
    ProbeResult(
      function: "abs",
      mutant: equivalent.id,
      status: Indistinguishable,
      inputs: [],
      expected: None,
      expected_inspect: "",
      expected_outcome: Returned,
      actual_inspect: "",
      actual_outcome: Returned,
      cases: 200,
      shrinks: 0,
      reason: "",
      kills: [],
    ),
  ]

  let suggestions =
    command.suggestions(results, [boundary, redundant, arithmetic, equivalent])

  assert list.map(suggestions, fn(suggestion) { suggestion.mutant_id })
    == [boundary.id, arithmetic.id]
  let assert [first, ..] = suggestions
  assert first
    == render.Suggestion(
      module_path: "boundary",
      function: "is_positive",
      mutant_id: boundary.id,
      display_id: boundary.display_id,
      operator: "comparison-boundary",
      location: "src/boundary.gleam:7:3",
      original: "value > 0",
      replacement: "value >= 0",
      inputs: ["0"],
      expected: Some("False"),
      expected_inspect: "False",
      expected_outcome: Returned,
      actual_inspect: "True",
      actual_outcome: Returned,
      kills: [boundary.id, redundant.id],
    )
}

pub fn suggestions_only_claim_the_mutants_the_run_selected_test() {
  let boundary = boundary_mutant()
  let unselected = redundant_mutant()
  // The probe knows every mutant of the function it probes, so an input found
  // for one selected mutant reports the unselected ones it happens to kill
  // too. A run narrowed by `--mutant` never discovered those, and a report
  // that names them says it killed mutants it never lists anywhere else.
  let results = [
    distinguished(
      "is_positive",
      boundary,
      ["0"],
      Some("False"),
      "False",
      "True",
      [
        boundary.id,
        unselected.id,
      ],
    ),
  ]

  let assert [suggestion] = command.suggestions(results, [boundary])

  assert suggestion.kills == [boundary.id]
}

pub fn suggestions_drop_a_verdict_whose_mutant_is_unknown_test() {
  let stray = abs_mutant()
  let results = [
    distinguished("abs", stray, ["-1"], Some("1"), "1", "-1", [stray.id]),
  ]
  assert command.suggestions(results, []) == []
}

// --- Accounting for every selected mutant ------------------------------------

pub fn unreported_names_the_selected_mutants_no_verdict_mentions_test() {
  let boundary = boundary_mutant()
  let outside = constant_mutant()
  let results = [
    distinguished(
      "is_positive",
      boundary,
      ["0"],
      Some("False"),
      "False",
      "True",
      [
        boundary.id,
      ],
    ),
  ]

  let assert [verdict] = command.unreported([boundary, outside], results)

  assert verdict.mutant == outside.id
  assert verdict.status == Unsupported
  assert verdict.function == ""
  assert string.contains(verdict.reason, "function")
}

pub fn unreported_says_nothing_about_a_mutant_a_verdict_covers_test() {
  let boundary = boundary_mutant()
  let equivalent = abs_mutant()
  let results = [
    distinguished(
      "is_positive",
      boundary,
      ["0"],
      Some("False"),
      "False",
      "True",
      [
        boundary.id,
      ],
    ),
    indistinguishable("abs", equivalent),
  ]
  assert command.unreported([boundary, equivalent], results) == []
}

pub fn summarise_puts_every_selected_mutant_in_exactly_one_bucket_test() {
  let boundary = boundary_mutant()
  let redundant = redundant_mutant()
  let equivalent = abs_mutant()
  let outside = constant_mutant()
  let skipped = [diff_runner.Skipped("boundary", "helper", "private function")]
  let results = [
    distinguished(
      "is_positive",
      boundary,
      ["0"],
      Some("False"),
      "False",
      "True",
      [
        boundary.id,
        redundant.id,
      ],
    ),
    distinguished(
      "is_positive",
      redundant,
      ["1"],
      Some("True"),
      "True",
      "False",
      [
        redundant.id,
      ],
    ),
    indistinguishable("abs", equivalent),
  ]

  let found =
    command.summarise(
      results: results,
      mutants: [boundary, redundant, equivalent, outside],
      skipped: skipped,
      survivors_missing: ["src/other.gleam"],
      style: render.AssertKeyword,
      snapshot_root: "/tmp/snapshot",
      machine: render.no_machine(),
    )

  assert list.map(found.suggestions, fn(suggestion) { suggestion.mutant_id })
    == [boundary.id]
  assert list.map(found.indistinguishable, fn(entry) { entry.mutant.id })
    == [equivalent.id]
  let assert [unsupported] = found.unsupported
  assert unsupported.mutant == outside
  assert unsupported.function == ""
  assert string.contains(unsupported.reason, "function")
  assert found.skipped == skipped
  assert found.survivors_missing == ["src/other.gleam"]
  assert found.style == render.AssertKeyword
  assert found.snapshot_root == "/tmp/snapshot"
  // Nothing selected is silently dropped: a mutant is killed by a suggestion,
  // named as one no input told apart, or named as one nothing can be written
  // for.
  assert list.sort(accounted(found), string.compare)
    == list.sort(
      [boundary.id, redundant.id, equivalent.id, outside.id],
      string.compare,
    )
}

// --- Values that only hold on the machine that found them ---------------------
//
// Measured on real code: `assert cache.status("") == "cache: empty\nworkspace:
// 5EE2D07D...\npath: /home/yasunobu/.cache/gleam-mutants/v1/..."`. Committed,
// that test fails for every other developer and in CI, and `apply --verify`
// passes it here. A suggestion carrying such a value is reported as
// unsupported rather than written.

/// The machine the probe is pretending to have run on.
fn this_machine() -> render.Machine {
  render.Machine(
    home: "/home/dev",
    cache: "/home/dev/.cache",
    temporary: "/var/tmp/build-7f3a",
  )
}

fn summarised(
  results: List(ProbeResult),
  mutants: List(Mutant),
  machine: render.Machine,
) -> command.Report {
  command.summarise(
    results: results,
    mutants: mutants,
    skipped: [],
    survivors_missing: [],
    style: render.AssertKeyword,
    snapshot_root: "",
    machine: machine,
  )
}

pub fn summarise_refuses_an_expected_value_naming_this_machine_test() {
  let bound = boundary_mutant()
  let cached = "\"/home/dev/.cache/gleam-mutants/v1/workspaces\""
  let found =
    summarised(
      [
        distinguished("status", bound, ["\"\""], Some(cached), cached, "\"\"", [
          bound.id,
        ]),
      ],
      [bound],
      this_machine(),
    )

  assert found.suggestions == []
  let assert [refused] = found.unsupported
  assert refused.mutant == bound
  assert refused.function == "status"
  assert refused.reason == "expected value depends on this machine"
  // The mutant is still accounted for exactly once.
  assert accounted(found) == [bound.id]
}

pub fn summarise_refuses_an_input_naming_an_absolute_path_test() {
  let bound = boundary_mutant()
  let found =
    summarised(
      [
        distinguished(
          "reads",
          bound,
          ["\"/tmp/gleam-mutants-ab12/src\""],
          Some("True"),
          "True",
          "False",
          [bound.id],
        ),
      ],
      [bound],
      render.no_machine(),
    )

  assert found.suggestions == []
  let assert [refused] = found.unsupported
  assert refused.reason == "expected value depends on this machine"
}

/// A value naming nothing of this machine is written exactly as before.
pub fn summarise_keeps_a_portable_suggestion_test() {
  let bound = boundary_mutant()
  let found =
    summarised(
      [
        distinguished(
          "is_positive",
          bound,
          ["0"],
          Some("False"),
          "False",
          "True",
          [
            bound.id,
          ],
        ),
      ],
      [bound],
      this_machine(),
    )

  assert list.map(found.suggestions, fn(entry) { entry.mutant_id })
    == [bound.id]
  assert found.unsupported == []
}

/// Every mutant an input told apart is counted, writable test or not.
///
/// `distinguishable` is what the summary line divides the kills by, and its
/// contract is the wall a mutant hit *after* it was separated: a mutant no
/// test can be written for is still one an input told apart, and dropping it
/// would quietly flatter the run — `0 of 0` where five mutants were in fact
/// separated is a report that hides its own gap.
pub fn summarise_counts_every_separated_mutant_as_distinguishable_test() {
  let portable = boundary_mutant()
  let bound = redundant_mutant()
  let unstatable = abs_mutant()
  let cached = "\"/home/dev/.cache/gleam-mutants/v1\""
  let held = "//fn(a) { ... }"
  let found =
    summarised(
      [
        distinguished(
          "is_positive",
          portable,
          ["0"],
          Some("False"),
          "False",
          "True",
          [
            portable.id,
          ],
        ),
        distinguished("status", bound, ["\"\""], Some(cached), cached, "\"\"", [
          bound.id,
        ]),
        distinguished("held", unstatable, ["0"], None, held, held, [
          unstatable.id,
        ]),
      ],
      [portable, bound, unstatable],
      this_machine(),
    )

  assert found.distinguishable == [portable.id, bound.id, unstatable.id]
  assert list.map(found.suggestions, fn(entry) { entry.mutant_id })
    == [portable.id]
  assert list.map(found.unsupported, fn(entry) { entry.reason })
    == [
      probe_result.inexpressible_reason,
      "expected value depends on this machine",
    ]
  assert accounted(found) == [portable.id, unstatable.id, bound.id]
}

// --- `explain` refuses what `suggest` refuses ---------------------------------
//
// The two commands print the same generated test, so a value only this machine
// holds has to be refused by both: `explain` inviting a paste of
// `assert cache.status("a") == "...path: /home/dev/.cache/..."` while `suggest`
// and `apply` refuse the very same mutant is the report contradicting itself.

fn explanation(verdict: ProbeResult, item: Mutant) -> command.Explanation {
  command.explained(item, verdict, render.AssertKeyword, this_machine())
}

pub fn explained_refuses_an_expected_value_naming_this_machine_test() {
  let bound = boundary_mutant()
  let cached = "\"/home/dev/.cache/gleam-mutants/v1/workspaces\""
  let found =
    explanation(
      distinguished("status", bound, ["\"\""], Some(cached), cached, "\"\"", [
        bound.id,
      ]),
      bound,
    )

  assert found.test_source == None
  assert found.reason == "expected value depends on this machine"
  // The verdict itself is unchanged: an input did tell the mutant apart, and
  // the two answers are still reported for a reader to judge.
  assert found.status == Distinguished
  assert found.expected == Some(cached)
  assert found.actual_inspect == "\"\""
}

pub fn explained_refuses_an_input_naming_an_absolute_path_test() {
  let bound = boundary_mutant()
  let found =
    explanation(
      distinguished(
        "reads",
        bound,
        ["\"/tmp/gleam-mutants-ab12/src\""],
        Some("True"),
        "True",
        "False",
        [bound.id],
      ),
      bound,
    )

  assert found.test_source == None
  assert found.reason == "expected value depends on this machine"
}

/// A portable value is written exactly as it always was.
pub fn explained_writes_a_portable_test_test() {
  let bound = boundary_mutant()
  let found =
    explanation(
      distinguished(
        "is_positive",
        bound,
        ["0"],
        Some("False"),
        "False",
        "True",
        [
          bound.id,
        ],
      ),
      bound,
    )

  let assert Some(source) = found.test_source
  assert string.contains(source, "boundary.is_positive(0) == False")
  assert found.reason == ""
}

// --- A --function name the probe never saw -----------------------------------

pub fn unmatched_function_names_a_filter_no_verdict_mentions_test() {
  let judged = [
    distinguished(
      "is_positive",
      boundary_mutant(),
      ["0"],
      Some("False"),
      "False",
      "True",
      [boundary_mutant().id],
    ),
  ]
  assert command.unmatched_function(Some("is_positive"), judged) == None
  assert command.unmatched_function(Some("positive"), judged)
    == Some("positive")
  assert command.unmatched_function(Some("is_positive"), [])
    == Some("is_positive")
}

/// A run that narrowed nothing has no name to report back: every function of
/// every selected file was fair game, so there is no typo to point at.
pub fn unmatched_function_says_nothing_about_a_run_that_named_none_test() {
  assert command.unmatched_function(None, []) == None
}

/// A function the probe walked past was still found: `--function helper` on a
/// private function is answered by the skipped list, not by a typo.
pub fn unmatched_function_counts_a_verdict_of_any_status_as_a_match_test() {
  let equivalent = abs_mutant()
  assert command.unmatched_function(Some("abs"), [
      indistinguishable("abs", equivalent),
    ])
    == None
}

// --- Helpers -----------------------------------------------------------------

/// Every mutant a report accounts for, however it accounts for it.
fn accounted(found: command.Report) -> List(String) {
  list.flatten([
    list.flat_map(found.suggestions, fn(suggestion) { suggestion.kills }),
    list.map(found.indistinguishable, fn(entry) { entry.mutant.id }),
    list.map(found.unsupported, fn(entry) { entry.mutant.id }),
  ])
  |> list.unique
}

fn indistinguishable(function: String, item: Mutant) -> ProbeResult {
  ProbeResult(
    function: function,
    mutant: item.id,
    status: Indistinguishable,
    inputs: [],
    expected: None,
    expected_inspect: "",
    expected_outcome: Returned,
    actual_inspect: "",
    actual_outcome: Returned,
    cases: 200,
    shrinks: 0,
    reason: "",
    kills: [],
  )
}

fn stub_mutant(
  id id: String,
  path path: String,
  line line: Int,
  column column: Int,
  operator kind: Operator,
  original original: String,
  replacement replacement: String,
) -> Mutant {
  mutant.Mutant(
    id: id,
    display_id: string.slice(id, 0, 20),
    path: path,
    operator: kind,
    operator_version: operator.version(kind),
    source_digest: string.repeat("0", 64),
    span: span.unsafe_new(0, 1),
    original_digest: string.repeat("1", 64),
    replacement_digest: string.repeat("2", 64),
    original: original,
    replacement: replacement,
    line: line,
    column: column,
  )
}

fn graded(item: Mutant, aggregate: outcome.Outcome) -> report.MutantResult {
  report.MutantResult(
    mutant: item,
    outcomes: [outcome.RuntimeOutcome(outcome.Erlang, aggregate, 1, "", False)],
    aggregate: aggregate,
  )
}

fn stub_report(results: List(report.MutantResult)) -> report.RunReport {
  report.RunReport(
    run_id: "20260101T000000Z-000000",
    started_ms: 0,
    duration_ms: 1,
    workspace_digest: string.repeat("f", 64),
    matrix: False,
    selection: report.SelectionSummary(
      mode: "all",
      files_selected: 1,
      candidates: list.length(results),
      executed: list.length(results),
      compile_errors: 0,
      skipped: False,
      reason: None,
    ),
    policy: report.PolicySummary(
      strict: False,
      minimum_score: 100.0,
      require_mutants: True,
      failure: None,
    ),
    results: results,
    rejected: [],
    score: score.calculate(list.map(results, fn(item) { item.aggregate })),
  )
}

fn distinguished(
  function: String,
  item: Mutant,
  inputs: List(String),
  expected: Option(String),
  expected_inspect: String,
  actual_inspect: String,
  kills: List(String),
) -> ProbeResult {
  ProbeResult(
    function: function,
    mutant: item.id,
    status: Distinguished,
    inputs: inputs,
    expected: expected,
    expected_inspect: expected_inspect,
    expected_outcome: Returned,
    actual_inspect: actual_inspect,
    actual_outcome: Returned,
    cases: 3,
    shrinks: 1,
    reason: "",
    kills: kills,
  )
}
