// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// What `suggest` and `explain` mean on the command line, settled without
// running either of them.
//
// `cli.parse` turns an argument vector into a `Command` and nothing else — no
// workspace, no probe, no exit code — so every flag of the two new commands
// can be pinned here, including the ones a real run would take minutes to
// reach.

import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/cli
import gleam_mutants/core/mutant
import gleam_mutants/core/operator
import gleam_mutants/core/span
import gleam_mutants/suggest/command as suggest_command
import gleam_mutants/suggest/diff_runner
import gleam_mutants/suggest/probe_result
import gleam_mutants/suggest/render

pub fn suggest_parses_every_selection_and_budget_flag_test() {
  let assert Ok(cli.SuggestCommand(options, suggest, json)) =
    cli.parse([
      "suggest", "--root", "fixtures/boundary_project", "--changed",
      "origin/main", "--include", "src/**/*.gleam", "--include",
      "lib/**/*.gleam", "--function", "is_positive", "--mutant", "abc123",
      "--survivors", "--seed", "7", "--max-cases", "25", "--max-shrinks", "5",
      "--budget", "30s", "--style", "should", "--json",
    ])
  assert options.root == Some("fixtures/boundary_project")
  assert json
  assert suggest
    == suggest_command.SuggestOptions(
      changed: Some("origin/main"),
      includes: ["src/**/*.gleam", "lib/**/*.gleam"],
      function: Some("is_positive"),
      mutant_prefix: Some("abc123"),
      survivors_only: True,
      seed: Some(7),
      max_cases: Some(25),
      max_shrinks: Some(5),
      budget_ms: Some(30_000),
      style: Some(render.ShouldEqual),
    )
}

pub fn bare_suggest_overrides_nothing_the_configuration_settles_test() {
  let assert Ok(cli.SuggestCommand(options, suggest, json)) =
    cli.parse(["suggest"])
  assert suggest == suggest_command.default_options()
  assert !json
  assert options.root == None
}

pub fn suggest_style_names_the_two_assertion_forms_test() {
  let assert Ok(cli.SuggestCommand(_, keyword, _)) =
    cli.parse(["suggest", "--style", "assert"])
  assert keyword.style == Some(render.AssertKeyword)
  let assert Ok(cli.SuggestCommand(_, should, _)) =
    cli.parse(["suggest", "--style", "should"])
  assert should.style == Some(render.ShouldEqual)
  assert cli.parse(["suggest", "--style", "loud"])
    == Error("GMU1002: --style must be assert or should")
}

pub fn explain_requires_a_mutant_id_test() {
  assert cli.parse(["explain"])
    == Error("GMU1002: explain requires a mutant id prefix")
  assert cli.parse(["explain", "--json"])
    == Error("GMU1002: explain requires a mutant id prefix")
}

pub fn explain_takes_an_id_and_then_the_same_flags_test() {
  let assert Ok(cli.ExplainCommand(options, display_id, suggest, json)) =
    cli.parse([
      "explain", "9f2c1d", "--root", "fixtures/boundary_project", "--function",
      "is_positive", "--seed", "3", "--style", "assert", "--json",
    ])
  assert display_id == "9f2c1d"
  assert json
  assert options.root == Some("fixtures/boundary_project")
  assert suggest.function == Some("is_positive")
  assert suggest.seed == Some(3)
  assert suggest.style == Some(render.AssertKeyword)
  assert suggest.mutant_prefix == None
}

pub fn budget_accepts_the_durations_timeout_accepts_test() {
  let assert Ok(cli.SuggestCommand(_, milliseconds, _)) =
    cli.parse(["suggest", "--budget", "500ms"])
  assert milliseconds.budget_ms == Some(500)
  let assert Ok(cli.SuggestCommand(_, minutes, _)) =
    cli.parse(["suggest", "--budget", "2m"])
  assert minutes.budget_ms == Some(120_000)
  let assert Ok(cli.SuggestCommand(_, unitless, _)) =
    cli.parse(["suggest", "--budget", "45"])
  assert unitless.budget_ms == Some(45_000)
  let assert Ok(cli.SuggestCommand(_, decimal, _)) =
    cli.parse(["suggest", "--budget", "1.5s"])
  assert decimal.budget_ms == Some(1500)
  assert cli.parse(["suggest", "--budget", "99ms"])
    == Error("--budget must be between 100ms and 24h")
  assert cli.parse(["suggest", "--budget", "25h"])
    == Error("--budget must be between 100ms and 24h")
  assert cli.parse(["explain", "9f2c1d", "--budget", "1d"])
    == Error("--budget must be between 100ms and 24h")
}

pub fn explain_refuses_a_mutant_flag_beside_its_argument_test() {
  // `explain` narrows the run to the mutant its argument names, so a
  // `--mutant` beside it either repeats that argument or contradicts it.
  // Accepting the flag and dropping it silently answers a question nobody
  // asked.
  assert cli.parse(["explain", "9f2c1d", "--mutant", "abc123"])
    == Error(
      "GMU1002: explain takes its mutant id as an argument, not with --mutant",
    )
  assert cli.parse(["explain", "9f2c1d", "--mutant", "9f2c1d"])
    == Error(
      "GMU1002: explain takes its mutant id as an argument, not with --mutant",
    )
}

pub fn suggest_and_explain_refuse_flags_they_do_not_have_test() {
  assert cli.parse(["suggest", "--matrix"])
    == Error("GMU1002: unknown suggest option \"--matrix\"")
  assert cli.parse(["explain", "9f2c1d", "--strict"])
    == Error("GMU1002: unknown explain option \"--strict\"")
}

pub fn suggest_refuses_a_value_flag_with_no_value_test() {
  let assert Error(_) = cli.parse(["suggest", "--seed"])
  let assert Error(_) = cli.parse(["suggest", "--function"])
  let assert Error(_) = cli.parse(["explain", "9f2c1d", "--budget"])
  Nil
}

pub fn suggest_refuses_a_search_budget_outside_its_range_test() {
  let assert Error(_) = cli.parse(["suggest", "--seed", "abc"])
  let assert Error(_) = cli.parse(["suggest", "--max-cases", "0"])
  let assert Error(_) = cli.parse(["suggest", "--max-shrinks", "-1"])
  Nil
}

// --- Applying what a suggestion found ----------------------------------------

/// `apply` takes every flag `suggest` takes, and three of its own.
///
/// The selection and the budget decide which mutants are probed, exactly as
/// they do for `suggest`; `--yes`, `--verify` and `--json` decide what is done
/// with the answer.
pub fn apply_parses_the_suggest_flags_and_its_own_test() {
  let assert Ok(cli.ApplyCommand(options, suggest, yes, verify, json)) =
    cli.parse([
      "apply", "--root", "fixtures/boundary_project", "--changed", "origin/main",
      "--include", "src/**/*.gleam", "--function", "is_positive", "--mutant",
      "abc123", "--survivors", "--seed", "7", "--max-cases", "25",
      "--max-shrinks", "5", "--budget", "30s", "--style", "should", "--yes",
      "--verify", "--json",
    ])
  assert options.root == Some("fixtures/boundary_project")
  assert yes
  assert verify
  assert json
  assert suggest
    == suggest_command.SuggestOptions(
      changed: Some("origin/main"),
      includes: ["src/**/*.gleam"],
      function: Some("is_positive"),
      mutant_prefix: Some("abc123"),
      survivors_only: True,
      seed: Some(7),
      max_cases: Some(25),
      max_shrinks: Some(5),
      budget_ms: Some(30_000),
      style: Some(render.ShouldEqual),
    )
}

/// Without `--yes`, `apply` is a dry run: it says what it would write.
pub fn bare_apply_plans_without_writing_anything_test() {
  let assert Ok(cli.ApplyCommand(_, suggest, yes, verify, json)) =
    cli.parse(["apply"])
  assert suggest == suggest_command.default_options()
  assert !yes
  assert !verify
  assert !json
}

/// `--verify` writes and then checks, so it implies `--yes`.
///
/// There is nothing to verify about a run that changed no file, and asking for
/// the check without the write is a request that cannot be honoured either
/// way.
pub fn apply_verify_implies_yes_test() {
  let assert Ok(cli.ApplyCommand(_, _, yes, verify, _)) =
    cli.parse(["apply", "--verify"])
  assert yes
  assert verify
}

pub fn apply_refuses_flags_it_does_not_have_test() {
  assert cli.parse(["apply", "--matrix"])
    == Error("GMU1002: unknown apply option \"--matrix\"")
  assert cli.parse(["apply", "--dry-run"])
    == Error("GMU1002: unknown apply option \"--dry-run\"")
  let assert Error(_) = cli.parse(["apply", "--style"])
  Nil
}

// --- Suggesting straight after a run -----------------------------------------

/// `run --suggest` prints the suggestions under the summary of the run.
pub fn run_suggest_asks_for_suggestions_after_the_summary_test() {
  let assert Ok(cli.RunCommand(options)) = cli.parse(["run", "--suggest"])
  assert options.suggest
  assert !options.json
  let assert Ok(cli.RunCommand(plain)) = cli.parse(["run"])
  assert !plain.suggest
}

/// In JSON mode there is nowhere to put them.
///
/// `run --json` prints exactly one JSON value, and a second one after it would
/// break every reader of the first. The suggestions are a command of their
/// own, and the message says which one.
pub fn run_suggest_is_refused_in_json_mode_test() {
  assert cli.parse(["run", "--suggest", "--json"]) == Error(suggest_needs_text)
  assert cli.parse(["run", "--json", "--suggest"]) == Error(suggest_needs_text)
}

const suggest_needs_text = "GMU1002: --suggest cannot be combined with --json; run `suggest --survivors` instead"

// --- What one suggestion looks like on a terminal -----------------------------

/// The boundary case of `is_positive`, as a probe would have found it.
fn boundary_suggestion() -> render.Suggestion {
  render.Suggestion(
    module_path: "boundary",
    function: "is_positive",
    mutant_id: string.repeat("a", 64),
    display_id: "8E1A6C7E61A90D7463C5",
    operator: "comparison-boundary",
    location: "src/boundary.gleam:17:3",
    original: "value > 0",
    replacement: "value >= 0",
    inputs: ["0"],
    expected: Some("False"),
    expected_inspect: "False",
    expected_outcome: probe_result.Returned,
    actual_inspect: "True",
    actual_outcome: probe_result.Returned,
    kills: [string.repeat("a", 64), string.repeat("b", 64)],
  )
}

/// A mutant of `is_positive`, for the buckets a suggestion does not fill.
fn stub_mutant(id: String, display_id: String) -> mutant.Mutant {
  mutant.Mutant(
    id: id,
    display_id: display_id,
    path: "src/boundary.gleam",
    operator: operator.ComparisonBoundary,
    operator_version: operator.version(operator.ComparisonBoundary),
    source_digest: string.repeat("0", 64),
    span: span.unsafe_new(0, 1),
    original_digest: string.repeat("1", 64),
    replacement_digest: string.repeat("2", 64),
    original: "value < 0",
    replacement: "value <= 0",
    line: 22,
    column: 8,
  )
}

/// A whole `suggest` report, with one entry in every bucket it prints.
fn stub_report() -> suggest_command.Report {
  let equivalent = stub_mutant(string.repeat("c", 64), "C0A27F78ED058C1CCCD8")
  let unsupported = stub_mutant(string.repeat("d", 64), "23BD793156BAC322DCC8")
  suggest_command.Report(
    suggestions: [boundary_suggestion()],
    indistinguishable: [
      suggest_command.Indistinguishable(equivalent, "abs", 200),
    ],
    unsupported: [
      suggest_command.Unsupported(
        unsupported,
        "applies",
        "parameter f: function-typed values are not supported",
      ),
    ],
    skipped: [
      diff_runner.Skipped(
        "boundary",
        "applies",
        "parameter f: function-typed values are not supported",
      ),
    ],
    survivors_missing: ["src/extra.gleam"],
    distinguishable: [string.repeat("a", 64), string.repeat("b", 64)],
    style: render.AssertKeyword,
    snapshot_root: "",
    unmatched_function: None,
  )
}

/// The header line, the test under it, the import hints and the summary, to
/// the character.
///
/// Every field of that header is what a reader scans for — which mutant, which
/// operator, where, what it rewrites, how much one test buys — so the line is
/// pinned here rather than described.
pub fn a_suggestion_is_printed_as_a_header_and_the_test_that_kills_it_test() {
  assert cli.render_suggestions(stub_report())
    == "8E1A6C7E61A90D7463C5 comparison-boundary at src/boundary.gleam:17:3: "
    <> "value > 0 -> value >= 0; kills 2 mutant(s)\n"
    <> "/// Generated by gleam_mutants: kills mutant 8E1A6C7E "
    <> "(comparison-boundary at src/boundary.gleam:17:3, `value > 0` -> "
    <> "`value >= 0`).\n"
    <> "pub fn is_positive_kills_8e1a6c7e_test() {\n"
    <> "  assert boundary.is_positive(0) == False\n"
    <> "}\n"
    <> "\n"
    <> "Imports for boundary:\n"
    <> "  import boundary\n"
    <> "\n"
    <> "1 suggestion(s) kill 2 of 2 distinguishable mutant(s); "
    <> "1 indistinguishable (possibly equivalent); 1 unsupported; "
    <> "1 function(s) skipped.\n"
    <> "The latest report never covered src/extra.gleam.\n"
}

/// Every test of one module is named the way that module's import line names
/// it.
///
/// The generated tests of one module belong in one file, and that file's own
/// imports decide which names are free: a file that writes `None` imports
/// `gleam/option`, so a module under test called `option` is imported and
/// called as `option_under_test` — in the test that never mentions `None` as
/// much as in the one that does. Naming it per test would print an import line
/// no reader could paste under a call it does not match.
pub fn every_test_of_one_module_is_named_one_way_test() {
  let plain =
    render.Suggestion(
      ..boundary_suggestion(),
      module_path: "option",
      location: "src/option.gleam:17:3",
    )
  let optional =
    render.Suggestion(
      ..plain,
      function: "unwrap_or",
      display_id: "C0A27F78ED058C1CCCD8",
      inputs: ["None"],
      expected: Some("0"),
      expected_inspect: "0",
    )
  let printed =
    cli.render_suggestions(
      suggest_command.Report(..stub_report(), suggestions: [plain, optional]),
    )

  assert string.contains(printed, "  import option as option_under_test\n")
  assert string.contains(printed, "  import gleam/option.{None}\n")
  assert string.contains(
    printed,
    "assert option_under_test.is_positive(0) == False",
  )
  assert string.contains(
    printed,
    "assert option_under_test.unwrap_or(None) == 0",
  )
  assert !string.contains(printed, "assert option.")
}

// --- What one explanation looks like on a terminal ----------------------------

pub fn an_explained_mutant_names_the_diff_the_input_and_the_test_test() {
  let explanation =
    suggest_command.Explanation(
      mutant: mutant.Mutant(
        ..stub_mutant(string.repeat("a", 64), "8E1A6C7E61A90D7463C5"),
        original: "value > 0",
        replacement: "value >= 0",
        line: 17,
        column: 3,
      ),
      function: "is_positive",
      status: probe_result.Distinguished,
      inputs: ["0"],
      expected: Some("False"),
      expected_inspect: "False",
      actual_inspect: "True",
      test_source: Some(
        "pub fn is_positive_kills_8e1a6c7e_test() {\n"
        <> "  assert boundary.is_positive(0) == False\n"
        <> "}",
      ),
      reason: "",
    )

  assert cli.render_explanation(explanation)
    == "8E1A6C7E61A90D7463C5 comparison-boundary at src/boundary.gleam:17:3 "
    <> "in is_positive\n"
    <> "value > 0 -> value >= 0\n"
    <> "status: distinguished\n"
    <> "inputs: 0\n"
    <> "the original is False, the mutant answers True\n"
    <> "pub fn is_positive_kills_8e1a6c7e_test() {\n"
    <> "  assert boundary.is_positive(0) == False\n"
    <> "}\n"
}

/// A mutant nothing separated has no input and no answers, and says so in
/// place of both — an empty gap would read as a value that was never printed.
pub fn an_unseparated_mutant_is_explained_without_an_empty_gap_test() {
  let explanation =
    suggest_command.Explanation(
      mutant: stub_mutant(string.repeat("c", 64), "A88EB89BD4A4E46E77B0"),
      function: "abs",
      status: probe_result.Indistinguishable,
      inputs: [],
      expected: None,
      expected_inspect: "",
      actual_inspect: "",
      test_source: None,
      reason: "no input told this mutant apart in 200 cases",
    )

  assert cli.render_explanation(explanation)
    == "A88EB89BD4A4E46E77B0 comparison-boundary at src/boundary.gleam:22:8 "
    <> "in abs\n"
    <> "value < 0 -> value <= 0\n"
    <> "status: indistinguishable\n"
    <> "inputs: (none found)\n"
    <> "no result was recorded for either side\n"
    <> "no test can be written: no input told this mutant apart in 200 "
    <> "cases\n"
}
