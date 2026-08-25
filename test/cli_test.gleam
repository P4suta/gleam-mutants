// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// What `suggest` and `explain` mean on the command line, settled without
// running either of them.
//
// `cli.parse` turns an argument vector into a `Command` and nothing else — no
// workspace, no probe, no exit code — so every flag of the two new commands
// can be pinned here, including the ones a real run would take minutes to
// reach.
//
// Two sections are about a different kind of output: the diagnostics a run
// prints. A message that names neither a code nor a path costs the reader an
// afternoon, so the three that used to carry a bare errno are pinned against
// real filesystem failures rather than described; and the line a diagnostic
// is rendered as is pinned on its own, because that is where a warning is
// given its code — and where it used to be given a code it already carried.

import gleam/dict
@target(erlang)
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/cli
import gleam_mutants/config
import gleam_mutants/core/mutant
import gleam_mutants/core/operator
@target(erlang)
import gleam_mutants/core/path
@target(erlang)
import gleam_mutants/core/score
import gleam_mutants/core/span
@target(erlang)
import gleam_mutants/platform
@target(erlang)
import gleam_mutants/project_report
import gleam_mutants/report
@target(erlang)
import gleam_mutants/snapshot
import gleam_mutants/suggest/command as suggest_command
import gleam_mutants/suggest/diff_runner
import gleam_mutants/suggest/probe_result
import gleam_mutants/suggest/render
@target(erlang)
import gleam_mutants/workspace_lock
@target(erlang)
import report_test_support
@target(erlang)
import simplifile

pub fn suggest_parses_every_selection_and_budget_flag_test() {
  let assert Ok(cli.SuggestCommand(options, suggest, json)) =
    cli.parse([
      "suggest", "--root", "fixtures/boundary_project", "--changed",
      "origin/main", "--include", "src/**/*.gleam", "--include",
      "lib/**/*.gleam", "--function", "is_positive", "--mutant", "abc123",
      "--survivors", "--operator", "string-neutral", "--operator",
      "boolean-connective", "--seed", "7", "--max-cases", "25", "--max-shrinks",
      "5", "--budget", "30s", "--style", "should", "--json",
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
      operators: [operator.StringNeutral, operator.BooleanConnective],
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

// --- Narrowing a probe to one operator ---------------------------------------

/// `--operator` narrows `suggest` the way it narrows `run` and `list`.
///
/// It is repeatable, it takes the same names, and the order it was given in is
/// the order it is kept in — a selection is a list, not a set of flags.
pub fn suggest_takes_a_repeatable_operator_filter_test() {
  let assert Ok(cli.SuggestCommand(_, one, _)) =
    cli.parse(["suggest", "--operator", "string-neutral"])
  assert one.operators == [operator.StringNeutral]
  let assert Ok(cli.SuggestCommand(_, many, _)) =
    cli.parse([
      "suggest", "--operator", "pipeline-stage-deletion", "--operator",
      "string-neutral",
    ])
  assert many.operators
    == [operator.PipelineStageDeletion, operator.StringNeutral]
  let assert Ok(cli.SuggestCommand(_, none, _)) = cli.parse(["suggest"])
  assert none.operators == []
}

/// `explain` and `apply` share the flag, because they share the probe.
pub fn explain_and_apply_take_the_operator_filter_too_test() {
  let assert Ok(cli.ExplainCommand(_, _, explained, _)) =
    cli.parse(["explain", "9f2c1d", "--operator", "comparison-boundary"])
  assert explained.operators == [operator.ComparisonBoundary]
  let assert Ok(cli.ApplyCommand(_, applied, _, _, _, _)) =
    cli.parse(["apply", "--operator", "comparison-boundary"])
  assert applied.operators == [operator.ComparisonBoundary]
}

/// `--operator=<name>` is the same request written the other way round.
pub fn suggest_accepts_the_operator_filter_joined_by_an_equals_test() {
  let assert Ok(cli.SuggestCommand(_, joined, _)) =
    cli.parse(["suggest", "--operator=list-neutral"])
  assert joined.operators == [operator.ListNeutral]
}

/// A name no operator answers to is refused, not silently dropped.
pub fn suggest_refuses_an_operator_name_nothing_answers_to_test() {
  assert cli.parse(["suggest", "--operator", "loud"])
    == Error("unknown mutation operator loud")
  let assert Error(_) = cli.parse(["suggest", "--operator"])
  Nil
}

// --- Applying what a suggestion found ----------------------------------------

/// `apply` takes every flag `suggest` takes, and three of its own.
///
/// The selection and the budget decide which mutants are probed, exactly as
/// they do for `suggest`; `--yes`, `--verify` and `--json` decide what is done
/// with the answer.
pub fn apply_parses_the_suggest_flags_and_its_own_test() {
  let assert Ok(cli.ApplyCommand(options, suggest, yes, verify, _, json)) =
    cli.parse([
      "apply", "--root", "fixtures/boundary_project", "--changed", "origin/main",
      "--include", "src/**/*.gleam", "--function", "is_positive", "--mutant",
      "abc123", "--survivors", "--operator", "pipeline-stage-deletion", "--seed",
      "7", "--max-cases", "25", "--max-shrinks", "5", "--budget", "30s",
      "--style", "should", "--yes", "--verify", "--json",
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
      operators: [operator.PipelineStageDeletion],
      seed: Some(7),
      max_cases: Some(25),
      max_shrinks: Some(5),
      budget_ms: Some(30_000),
      style: Some(render.ShouldEqual),
    )
}

/// Without `--yes`, `apply` is a dry run: it says what it would write.
pub fn bare_apply_plans_without_writing_anything_test() {
  let assert Ok(cli.ApplyCommand(_, suggest, yes, verify, _, json)) =
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
  let assert Ok(cli.ApplyCommand(_, _, yes, verify, _, _)) =
    cli.parse(["apply", "--verify"])
  assert yes
  assert verify
}

/// `--no-reuse` measures the baseline `--verify` grades against.
///
/// The shortcut reads modification times to decide whether the workspace's
/// last stored run is still a verdict on the suite in the tree. A filesystem
/// that keeps no useful times, or a checkout that rewrote them, is a reason to
/// be able to say "measure it anyway" out loud.
pub fn apply_takes_a_flag_that_refuses_the_stored_baseline_test() {
  let assert Ok(cli.ApplyCommand(_, _, _, _, reuse, _)) =
    cli.parse(["apply", "--verify", "--no-reuse"])
  assert !reuse
  let assert Ok(cli.ApplyCommand(_, _, _, _, default, _)) =
    cli.parse(["apply", "--verify"])
  assert default
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
  let unstable = stub_mutant(string.repeat("e", 64), "6D1C5E7A4B93F0E2A1D7")
  suggest_command.Report(
    suggestions: [boundary_suggestion()],
    indistinguishable: [
      suggest_command.Indistinguishable(equivalent, "abs", 200),
    ],
    nondeterministic: [
      suggest_command.Unsupported(
        unstable,
        "roll",
        "original produced different results for the same input",
      ),
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
    <> "1 indistinguishable (possibly equivalent); 1 nondeterministic; "
    <> "1 unsupported; 1 function(s) skipped.\n"
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

// --- A verdict no assertion could state ---------------------------------------

/// A distinguished verdict whose two sides render identically is refused.
///
/// The differential search separates values structurally, and Erlang funs
/// compare by the environment they captured — but every assertion the renderer
/// can write goes through `string.inspect`, which prints every fun as
/// `//fn(a) { ... }`. A test written from such a verdict passes with the mutant
/// in place, which is worse than no test at all, so the host refuses to render
/// one and reports the mutant as unsupported instead.
pub fn a_verdict_whose_two_sides_render_alike_is_never_suggested_test() {
  let item = stub_mutant(string.repeat("a", 64), "8E1A6C7E61A90D7463C5")
  let alike = "Decoder(//fn(a) { ... })"
  let verdict =
    probe_result.ProbeResult(
      function: "decoder",
      mutant: item.id,
      status: probe_result.Distinguished,
      inputs: [],
      expected: Some(alike),
      expected_inspect: alike,
      expected_outcome: probe_result.Returned,
      actual_inspect: alike,
      actual_outcome: probe_result.Returned,
      cases: 4,
      shrinks: 0,
      reason: "",
      kills: [item.id],
    )

  let found =
    suggest_command.summarise(
      results: [verdict],
      mutants: [item],
      skipped: [],
      survivors_missing: [],
      style: render.AssertKeyword,
      snapshot_root: "",
      machine: render.no_machine(),
    )

  assert found.suggestions == []
  let assert [refused] = found.unsupported
  assert refused.mutant == item
  assert refused.function == "decoder"
  assert refused.reason == inexpressible_reason
  // The mutant is still accounted for, and the terminal says so rather than
  // printing a test that does not kill.
  let printed = cli.render_suggestions(found)
  assert string.contains(printed, "0 suggestion(s)")
  assert !string.contains(printed, alike)
}

const inexpressible_reason = "original and mutant differ only by values no assertion can express (function values)"

// --- A mutant whose original disagreed with itself ---------------------------

/// A nondeterministic verdict is a bucket of its own, not a kind of
/// unsupported.
///
/// The four documented statuses are meant to be four; folding this one into
/// `unsupported` leaves a reader string-matching a reason to recover the status
/// the docs advertise, and leaves a JSON consumer unable to recover it at all.
pub fn a_nondeterministic_verdict_is_counted_on_its_own_test() {
  let unstable = stub_mutant(string.repeat("e", 64), "6D1C5E7A4B93F0E2A1D7")
  let reason = "original produced different results for the same input"
  let verdict =
    probe_result.ProbeResult(
      function: "roll",
      mutant: unstable.id,
      status: probe_result.Nondeterministic,
      inputs: [],
      expected: None,
      expected_inspect: "",
      expected_outcome: probe_result.Returned,
      actual_inspect: "",
      actual_outcome: probe_result.Returned,
      cases: 0,
      shrinks: 0,
      reason: reason,
      kills: [],
    )

  let found =
    suggest_command.summarise(
      results: [verdict],
      mutants: [unstable],
      skipped: [],
      survivors_missing: [],
      style: render.AssertKeyword,
      snapshot_root: "",
      machine: render.no_machine(),
    )

  assert found.unsupported == []
  let assert [entry] = found.nondeterministic
  assert entry.mutant == unstable
  assert entry.function == "roll"
  assert entry.reason == reason
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

// --- Diagnostics a filesystem failure has to carry ---------------------------

@target(erlang)
/// A history write that fails says which code it is and where it failed.
///
/// The report history lives under the cache directory, so a run in a sandbox
/// that cannot write there fails — and it used to fail with nothing but the
/// errno the operating system handed back:
///
///     gleam-mutants: mutation run started
///     gleam-mutants: Read-only file system
///
/// No code, no path, and no way to tell which of the several files a run
/// writes was the one that went wrong. A cache directory that is a regular
/// file makes the same failure on purpose: nothing can be created below it,
/// for any user, on any platform.
pub fn a_report_history_write_failure_names_its_code_and_path_test() {
  let previous = platform.env(report_test_support.cache_variable)
  let blocked =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-red-cache-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.write(blocked, "not a directory\n")
  report_test_support.set_cache_directory(blocked)
  let moved = string.starts_with(platform.cache_directory(), blocked)
  let written = report.save(stub_run_report(), "/nowhere/a-workspace")
  report_test_support.restore_cache_directory(previous)
  let _ = simplifile.delete(blocked)

  case moved {
    False ->
      io.println(
        "skipped: this platform does not read its cache directory from "
        <> report_test_support.cache_variable,
      )
    True -> {
      let assert Error(message) = written
      assert string.starts_with(message, "GMU6002: ")
      assert string.contains(message, blocked)
    }
  }
}

@target(erlang)
/// A project report that cannot be written says the same two things.
///
/// The same sandbox that stops the history stops this, and a reader who is
/// told only `Read-only file system` cannot tell the two apart.
pub fn a_project_report_write_failure_names_its_code_and_path_test() {
  let workspace =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-red-report-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let _ = simplifile.set_permissions_octal(workspace, 0o500)
  let unwritable = case
    simplifile.create_directory(path.join(workspace, "probe"))
  {
    Ok(Nil) -> False
    Error(_) -> True
  }
  let written = project_report.write(workspace, "reports/mutation", "{}", "")
  let _ = simplifile.set_permissions_octal(workspace, 0o700)
  let _ = platform.delete_tree(workspace)

  case unwritable {
    False ->
      io.println(
        "skipped: this user can write into a directory it holds no write "
        <> "permission on",
      )
    True -> {
      let assert Error(message) = written
      assert string.starts_with(message, "GMU6003: ")
      assert string.contains(message, path.join(workspace, "reports/mutation"))
    }
  }
}

@target(erlang)
/// A special file in the workspace is still refused, and now says what to do.
///
/// A character device or a named pipe cannot be copied into a snapshot and
/// must not be, so the refusal stays. What it owes the reader is a code to
/// look up, the path it is refusing, and one sentence on how to get past it —
/// a bare `refusing special file in workspace: .bash_profile` over a dotfile
/// no build step reads is a dead end.
pub fn a_refused_special_file_names_its_code_and_a_way_forward_test() {
  let workspace =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-red-special-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let assert Ok(Nil) =
    simplifile.write(path.join(workspace, "gleam.toml"), "name = \"red\"\n")
  let pipe = path.join(workspace, "a_named_pipe")
  let _ = platform.run_process("mkfifo", [pipe], workspace, [], 10_000)
  let special = case simplifile.link_info(pipe) {
    Ok(info) -> simplifile.file_info_type(info) == simplifile.Other
    Error(_) -> False
  }
  let captured = snapshot.create(workspace)
  let _ = platform.delete_tree(workspace)

  case special {
    False -> io.println("skipped: this platform made no named pipe to refuse")
    True -> {
      let assert Error(message) = captured
      assert string.starts_with(message, "GMU7004: ")
      assert string.contains(message, "a_named_pipe")
      assert string.contains(message, "remove it")
    }
  }
}

@target(erlang)
/// A report with nothing in it, which is all a write failure needs.
fn stub_run_report() -> report.RunReport {
  report.RunReport(
    run_id: "20260101T000000Z-000000",
    started_ms: 0,
    duration_ms: 1,
    workspace_digest: string.repeat("f", 64),
    matrix: False,
    selection: report.SelectionSummary(
      mode: "all",
      files_selected: 0,
      candidates: 0,
      executed: 0,
      compile_errors: 0,
      skipped: True,
      reason: Some("nothing to run"),
    ),
    policy: report.PolicySummary(
      strict: False,
      minimum_score: 100.0,
      require_mutants: False,
      failure: None,
    ),
    results: [],
    rejected: [],
    score: score.Score(0, 0, 0, 0, 0, 0.0),
  )
}

// --- The shape of a diagnostic line ------------------------------------------

/// A warning whose message already names its code does not name it twice.
///
/// `run --suggest` reports a probe that could not be made as a warning: the
/// run itself succeeded, and having nothing to suggest is not a failure of it.
/// What it hands to the line is the suggest error, and every one of those
/// carries its own `GMU8xxx` in front of its message — so the line must not be
/// given the code a second time. It used to read
///
///     gleam-mutants: GMU8001: GMU8001: suggest supports the Erlang target only
///
/// The message is taken from the check that really raises it rather than
/// copied out here, so re-wording one of them moves both.
pub fn a_warning_that_carries_its_code_names_it_once_test() {
  let assert Error(message) = javascript_target_verdict()
  let line = cli.diagnostic_line("warning", "GMU8001", message, None)

  assert line
    == "gleam-mutants: GMU8001: suggest supports the Erlang target only"
  assert list.length(string.split(line, "GMU8001")) == 2
}

/// A warning whose message names no code is still given one.
///
/// `GMU8012` and `GMU8017` are raised from the command line itself and their
/// messages are plain sentences, so the code has to come from somewhere: the
/// line is the only place left to put it, and `docs/suggest.md` promises a
/// reader it is there.
pub fn a_warning_that_carries_no_code_is_given_one_test() {
  assert cli.diagnostic_line(
      "warning",
      "GMU8012",
      "this run selected no mutant inside a function named `abs`",
      None,
    )
    == "gleam-mutants: GMU8012: this run selected no mutant inside a function "
    <> "named `abs`"
}

/// An error is printed as its message wrote itself, and its usage follows.
///
/// Every failure names its code in its own text — that is the text
/// `diagnostic_code` reads the code back out of — so the line adds nothing but
/// the program name, whatever code it was handed.
pub fn an_error_line_names_the_code_its_message_carries_test() {
  assert cli.diagnostic_line(
      "error",
      "GMU8011",
      "GMU8011: no mutant with id 0F1E2D lives in this run",
      Some("usage: gleam-mutants explain <id>"),
    )
    == "gleam-mutants: GMU8011: no mutant with id 0F1E2D lives in this run"
    <> "\n\nusage: gleam-mutants explain <id>"
}

/// The refusal a workspace whose tests run on JavaScript really raises.
fn javascript_target_verdict() -> Result(Nil, String) {
  let gleam_toml =
    "name = \"demo\"\nversion = \"1.0.0\"\ntarget = \"javascript\"\n"
  let assert Ok(configured) = config.decode(gleam_toml, 1)
  diff_runner.check_target(configured, gleam_toml)
}

// --- The baseline `--verify` grades against ----------------------------------

/// Every verdict a stored run recorded, read the way `--verify` reads them.
///
/// This is the shortcut's whole foundation: `apply --verify` skips its own
/// baseline run when the workspace's last stored run already graded every
/// mutant in question, and then attributes every kill from what this function
/// answers. Inverting one of these four mappings would turn `new` into
/// `already_killed` across the board and, with it, print `GMU8017` over tests
/// that are the only thing killing their mutant — so the mapping is pinned
/// rather than trusted.
pub fn a_stored_run_says_which_of_its_mutants_died_test() {
  let assert Ok(graded) = report.graded_outcomes(stored_run_json())
  assert graded
    == [
      #("A1", True),
      #("B2", True),
      #("C3", False),
      #("D4", False),
    ]
}

/// A document that is not a run report grades nothing, rather than nothing.
///
/// An empty answer would look exactly like a run that killed everything, and
/// a baseline that says "everything was already dead" is the one that makes
/// `--verify` libel the tests it just wrote.
pub fn a_document_that_is_not_a_run_report_grades_nothing_test() {
  let assert Error(message) = report.graded_outcomes("{\"schema_version\":1}")
  assert string.contains(message, "not a native Run Report v1 document")
  let assert Error(_) = report.graded_outcomes("[]")
  Nil
}

/// When the stored run began, which is what its baseline is judged against.
pub fn a_stored_run_says_when_it_began_test() {
  assert report.run_started_ms(stored_run_json()) == Ok(1_700_000_000_000)
  let assert Error(_) = report.run_started_ms("{\"schema_version\":1}")
  Nil
}

/// Nothing partial is reused: a missing mutant takes the whole shortcut away.
///
/// A baseline that grades three of four mutants would credit the generated
/// tests with a kill nobody measured, so the fourth one's absence is the end
/// of it.
pub fn a_stored_baseline_is_reused_only_when_it_grades_every_mutant_test() {
  let graded = [#("A1", True), #("C3", False)]
  let assert Some(reused) = cli.reusable_outcomes(graded, ["A1", "C3"])
  assert dict.get(reused, "A1") == Ok(True)
  assert dict.get(reused, "C3") == Ok(False)
  assert cli.reusable_outcomes(graded, ["A1", "B2"]) == None
  assert cli.reusable_outcomes([], ["A1"]) == None
}

/// A stored Run Report v1 document with one mutant of every graded verdict.
fn stored_run_json() -> String {
  "{\"schema_version\":1,\"tool\":\"gleam-mutants\",\"run_id\":\"r\","
  <> "\"started_ms\":1700000000000,\"duration_ms\":1,"
  <> "\"mutants\":["
  <> graded_mutant_json("A1", "killed")
  <> ","
  <> graded_mutant_json("B2", "timed-out")
  <> ","
  <> graded_mutant_json("C3", "survived")
  <> ","
  <> graded_mutant_json("D4", "test-error")
  <> "]}"
}

fn graded_mutant_json(id: String, aggregate: String) -> String {
  "{\"mutant\":{\"id\":\""
  <> id
  <> "\",\"path\":\"src/a.gleam\"},\"aggregate\":\""
  <> aggregate
  <> "\"}"
}

@target(erlang)
/// A run stored before the suite was last touched is no baseline for it.
///
/// A mutant id carries the digest of the source it was cut from, so an id the
/// stored run named is a verdict on exactly this source — and on nothing
/// else. It says nothing about the tests, which are the other half of every
/// kill: a suite edited since that run graded a mutant as dead is a suite
/// whose verdict may have been the work of a test that is no longer there.
/// The tree's own modification times are what settles it, and a run that
/// started inside the same second as the last write is not trusted to have
/// seen it.
pub fn a_run_stored_before_the_suite_was_touched_is_no_baseline_test() {
  let workspace = red_workspace()
  let now = platform.now_milliseconds()

  assert cli.suite_predates(workspace, now + 10_000)
  assert !cli.suite_predates(workspace, now)

  let _ = platform.delete_tree(workspace)
}

@target(erlang)
/// A test module deleted since the stored run takes the shortcut away.
///
/// This is the direction that costs the reader something. The stored run was
/// taken while a test that killed a mutant was still in the tree; delete it,
/// and a baseline reused from that run still calls the mutant dead, so the
/// generated test that now kills it is reported as adding nothing and named
/// under `GMU8017` — advice that deletes the only test standing. Removing a
/// file moves the modification time of the directory that held it, which is
/// what closes the hole.
pub fn a_test_module_deleted_since_the_stored_run_is_no_baseline_test() {
  let workspace = red_workspace()
  let tests = path.join(workspace, "test")
  let backdated = backdate(workspace)
  // 2021-09-13, which is after the timestamp `backdate` writes and long
  // before anything this test does.
  let stored = 1_631_500_000_000

  case backdated {
    False -> io.println("skipped: this platform kept no modification times")
    True -> {
      assert cli.suite_predates(workspace, stored)
      let assert Ok(Nil) =
        simplifile.delete(path.join(tests, "boundary_test.gleam"))
      assert !cli.suite_predates(workspace, stored)
    }
  }

  let _ = platform.delete_tree(workspace)
}

@target(erlang)
/// A workspace holding one source module and one test module.
fn red_workspace() -> String {
  let workspace =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-red-suite-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(workspace, "src"))
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(workspace, "test"))
  let assert Ok(Nil) =
    simplifile.write(path.join(workspace, "gleam.toml"), "name = \"red\"\n")
  let assert Ok(Nil) =
    simplifile.write(
      path.join(workspace, "src/boundary.gleam"),
      "pub fn is_positive(value: Int) -> Bool {\n  value > 0\n}\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      path.join(workspace, "test/boundary_test.gleam"),
      "pub fn is_positive_test() {\n  assert True\n}\n",
    )
  workspace
}

@target(erlang)
/// Stamps the whole workspace with a modification time in 2021.
///
/// A test about what changed since a stored run needs a tree older than that
/// run, and the only portable way to get one is to say so: `touch` is POSIX,
/// and a platform whose `touch` does not move a directory's time answers
/// `False` so the caller can skip rather than fail.
fn backdate(workspace: String) -> Bool {
  let stamp = "202101010000"
  list.each(
    [
      "gleam.toml", "src/boundary.gleam", "test/boundary_test.gleam", "src",
      "test", ".",
    ],
    fn(relative) {
      let _ =
        platform.run_process(
          "touch",
          ["-t", stamp, path.join(workspace, relative)],
          workspace,
          [],
          10_000,
        )
      Nil
    },
  )
  case simplifile.link_info(path.join(workspace, "test")) {
    Ok(info) -> info.mtime_seconds < 1_631_500_000
    Error(_) -> False
  }
}

@target(erlang)
/// A cache directory that cannot be created says which code and where.
///
/// Every run takes the workspace lock first, and the lock lives under the
/// cache directory, so a sandbox that cannot write there fails before a
/// single mutant is cut. It used to fail with nothing but the errno the
/// operating system handed back — `gleam-mutants: No such file or directory`,
/// no code and no path, which is the report's bug 7 word for word and reached
/// long before `report.save` ever runs.
pub fn a_workspace_cache_directory_that_cannot_be_created_names_its_code_and_path_test() {
  let previous = platform.env(report_test_support.cache_variable)
  let blocked =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-red-lock-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.write(blocked, "not a directory\n")
  report_test_support.set_cache_directory(blocked)
  let moved = string.starts_with(platform.cache_directory(), blocked)
  let acquired = workspace_lock.acquire("/nowhere/a-workspace")
  report_test_support.restore_cache_directory(previous)
  let _ = simplifile.delete(blocked)

  case moved {
    False ->
      io.println(
        "skipped: this platform does not read its cache directory from "
        <> report_test_support.cache_variable,
      )
    True -> {
      let assert Error(message) = acquired
      assert string.starts_with(message, "GMU7005: ")
      assert string.contains(message, blocked)
    }
  }
}
