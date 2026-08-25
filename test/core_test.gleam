// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/cache
import gleam_mutants/cli
import gleam_mutants/config
import gleam_mutants/core/catalog
import gleam_mutants/core/exit_policy
import gleam_mutants/core/glob
import gleam_mutants/core/interval_tree
import gleam_mutants/core/mutant
import gleam_mutants/core/operator
import gleam_mutants/core/outcome
import gleam_mutants/core/score
import gleam_mutants/core/span

pub fn span_boundaries_test() {
  assert span.new(0, 0) == Ok(span.unsafe_new(0, 0))
  assert span.new(-1, 0) == Error(span.NegativeStart)
  assert span.new(2, 1) == Error(span.EndBeforeStart)
  let outer = span.unsafe_new(1, 10)
  let inner = span.unsafe_new(2, 4)
  assert span.contains(outer, inner)
  assert !span.partially_overlaps(outer, inner)
  assert span.partially_overlaps(span.unsafe_new(0, 4), span.unsafe_new(3, 7))
}

pub fn glob_double_star_matches_zero_or_more_directories_test() {
  assert glob.matches("src/**/*.gleam", "src/app.gleam")
  assert glob.matches("src/**/*.gleam", "src/domain/app.gleam")
  assert !glob.matches("src/**/*.gleam", "test/app.gleam")
  assert glob.included("src/app.gleam", ["src/**/*.gleam"], ["src/generated/**"])
}

pub fn stable_id_is_path_separator_portable_and_content_sensitive_test() {
  let candidate =
    mutant.Candidate(
      "src\\math.gleam",
      operator.IntegerNeutral,
      span.unsafe_new(10, 11),
      "1",
      "0",
    )
  let same =
    mutant.Candidate(
      "src/math.gleam",
      operator.IntegerNeutral,
      span.unsafe_new(10, 11),
      "1",
      "0",
    )
  assert mutant.stable_id("pub const x = 1\n", candidate)
    == mutant.stable_id("pub const x = 1\n", same)
  assert mutant.stable_id("pub const x = 1\n", candidate)
    != mutant.stable_id("pub const x = 2\n", candidate)
  assert string.length(mutant.stable_id("source", candidate)) == 64
}

pub fn display_ids_are_unique_across_the_selected_catalogue_test() {
  let first =
    mutant.from_candidate(
      "True",
      mutant.Candidate(
        "src/first.gleam",
        operator.BooleanLiteral,
        span.unsafe_new(0, 4),
        "True",
        "False",
      ),
    )
  let second =
    mutant.from_candidate(
      "True",
      mutant.Candidate(
        "src/second.gleam",
        operator.BooleanLiteral,
        span.unsafe_new(0, 4),
        "True",
        "False",
      ),
    )
  let first =
    mutant.Mutant(
      ..first,
      id: "aaaaaaaaaaaaaaaaaaaa0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    )
  let second =
    mutant.Mutant(
      ..second,
      id: "aaaaaaaaaaaaaaaaaaaa1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    )
  let assert [first, second] = catalog.assign_display_ids([first, second])
  assert first.display_id == "aaaaaaaaaaaaaaaaaaaa0"
  assert second.display_id == "aaaaaaaaaaaaaaaaaaaa1"
}

pub fn catalog_preserves_unicode_comments_and_crlf_test() {
  let source =
    "// 日本語 && comment\r\npub fn classify(n: Int) {\r\n  n < 10 && True\r\n}\r\n"
  let assert Ok(discovered) =
    catalog.discover("src/example.gleam", source, operator.all())
  let mutants = discovered.mutants
  assert list.any(mutants, fn(item) {
    item.operator == operator.ComparisonBoundary
  })
  assert list.any(mutants, fn(item) {
    item.operator == operator.BooleanConnective
  })
  assert list.any(mutants, fn(item) { item.operator == operator.BooleanLiteral })
  let assert Ok(forest) = interval_tree.build(source, mutants)
  let instrumented = interval_tree.render(source, forest, "internal/runtime")
  assert string.contains(instrumented, "// 日本語 && comment\r\n")
  assert list.any(discovered.rejected, fn(item) {
    item.reason == "type-evidence-unavailable"
  })
  assert string.contains(instrumented, "internal/runtime.select")
  assert string.contains(instrumented, "\r\n")
}

pub fn nested_instrumentation_selects_each_mutant_once_test() {
  let source = "1 + 2"
  let outer_candidate =
    mutant.Candidate(
      "src/a.gleam",
      operator.IntegerArithmetic,
      span.unsafe_new(0, 5),
      source,
      "1 - 2",
    )
  let inner_candidate =
    mutant.Candidate(
      "src/a.gleam",
      operator.IntegerNeutral,
      span.unsafe_new(0, 1),
      "1",
      "0",
    )
  let outer = mutant.from_candidate(source, outer_candidate)
  let inner = mutant.from_candidate(source, inner_candidate)
  let assert Ok(forest) = interval_tree.build(source, [outer, inner])
  let rendered = interval_tree.render(source, forest, "runtime")
  assert string.contains(rendered, outer.id)
  assert string.contains(rendered, inner.id)
  assert string.contains(rendered, "1 - 2")
}

pub fn config_defaults_and_toml_precedence_test() {
  let source =
    "# keep me\n[tools.gleam_mutants]\nversion = 1\n[tools.gleam_mutants.execution]\njobs = 3\n[tools.gleam_mutants.policy]\nstrict = false\nminimum_score = 80\n[tools.gleam_mutants.report]\ndirectory = \"artifacts/mutation\"\nhigh = 90\nlow = 70\n"
  let assert Ok(decoded) = config.decode(source, 32)
  assert decoded.jobs == 3
  assert decoded.strict == Some(False)
  assert decoded.minimum_score == 80.0
  assert decoded.report.directory == "artifacts/mutation"
  assert decoded.report.high == 90
  assert decoded.report.low == 70
  let defaults = config.defaults(4)
  assert defaults.report.directory == "reports/mutation"
  assert defaults.report.high == 80
  assert defaults.report.low == 60
  let assert Ok(#(initialised, changed)) =
    config.initialise("name = \"demo\" # comment\n")
  assert changed
  assert string.contains(initialised, "# comment")
  assert string.contains(initialised, "[tools.gleam_mutants]")
  assert string.contains(initialised, "[tools.gleam_mutants.report]")
  assert string.contains(initialised, "directory = \"reports/mutation\"")
  assert string.contains(initialised, "high = 80")
  assert string.contains(initialised, "low = 60")
  let assert Ok(#(_, second_changed)) = config.initialise(initialised)
  assert !second_changed
}

pub fn config_unknown_key_has_position_test() {
  let error =
    config.decode("[tools.gleam_mutants]\nversion = 1\nunknown = true\n", 4)
  let assert Error(config.ConfigError(line, column, message)) = error
  assert line == 3
  assert column == 1
  assert string.contains(message, "unknown key")

  let report_error =
    config.decode(
      "[tools.gleam_mutants]\nversion = 1\n[tools.gleam_mutants.report]\nunknown = true\n",
      4,
    )
  let assert Error(config.ConfigError(report_line, _, report_message)) =
    report_error
  assert report_line == 4
  assert string.contains(report_message, "tools.gleam_mutants.report.unknown")
}

pub fn report_config_rejects_unsafe_paths_and_thresholds_test() {
  let prefix =
    "[tools.gleam_mutants]\nversion = 1\n[tools.gleam_mutants.report]\n"
  let assert Error(config.ConfigError(_, _, absolute_message)) =
    config.decode(prefix <> "directory = \"/tmp/report\"\n", 4)
  assert string.contains(absolute_message, "safe relative subdirectory")

  let assert Error(config.ConfigError(_, _, parent_message)) =
    config.decode(prefix <> "directory = \"reports/../escape\"\n", 4)
  assert string.contains(parent_message, "safe relative subdirectory")

  let assert Error(config.ConfigError(_, _, ordering_message)) =
    config.decode(prefix <> "high = 50\nlow = 60\n", 4)
  assert string.contains(ordering_message, "0 <= low <= high <= 100")

  let assert Error(config.ConfigError(_, _, integer_message)) =
    config.decode(prefix <> "high = 80.5\n", 4)
  assert string.contains(integer_message, "must be an integer")

  let assert Error(config.ConfigError(_, _, device_message)) =
    config.decode(prefix <> "directory = \"reports/NUL\"\n", 4)
  assert string.contains(device_message, "safe relative subdirectory")

  let assert Ok(overlapping) =
    config.decode(prefix <> "directory = \"src/generated\"\n", 4)
  assert config.report_overlaps_mutation_sources(overlapping)
  let assert Ok(safe) = config.decode(prefix, 4)
  assert !config.report_overlaps_mutation_sources(safe)
}

pub fn a_mutant_the_suite_noticed_is_detected_test() {
  // A mutant that hangs the suite is one the suite noticed, and the score has
  // always counted it with the kills. Everything that decides whether a mutant
  // is dead — `apply --verify` included — has to agree with the number the
  // same workspace reports, so the two answer from one predicate.
  let outcomes = [
    outcome.Killed,
    outcome.TimedOut,
    outcome.Survived,
    outcome.TestError("boom"),
  ]
  assert list.map(outcomes, outcome.detected) == [True, True, False, False]

  let counted = score.calculate(outcomes)
  assert list.length(list.filter(outcomes, outcome.detected))
    == counted.killed + counted.timed_out
}

pub fn score_timeout_and_exit_policy_test() {
  let mutation_score =
    score.calculate([
      outcome.Killed,
      outcome.TimedOut,
      outcome.Survived,
    ])
  assert mutation_score.total == 3
  assert mutation_score.killed == 1
  assert mutation_score.timed_out == 1
  assert mutation_score.survived == 1
  assert score.display(mutation_score) == "66.67% (2/3)"
  let empty_score = score.calculate([])
  assert empty_score.percent == 0.0
  assert score.display(empty_score) == "N/A (0 valid mutants)"
  assert score.display(score.Score(4, 1, 2, 1, 0, 75.0)) == "75% (3/4)"
  assert score.display(score.Score(2, 1, 0, 1, 0, 75.5)) == "75.5% (1/2)"
  assert score.display(score.Score(2, 1, 0, 1, 0, 75.05)) == "75.05% (1/2)"
  assert score.display(score.Score(3, 1, 0, 2, 0, 33.33333333333333))
    == "33.33% (1/3)"
  assert score.display(score.Score(29, 26, 0, 3, 0, 89.65517241379311))
    == "89.66% (26/29)"
  assert exit_policy.code(
      mutation_score,
      exit_policy.Context(False, True, None, 100.0),
    )
    == 0
  assert exit_policy.code(
      mutation_score,
      exit_policy.Context(True, False, None, 100.0),
    )
    == 0
  assert exit_policy.code(
      mutation_score,
      exit_policy.Context(False, True, Some(True), 50.0),
    )
    == 0

  let with_runtime_error =
    score.calculate([outcome.Killed, outcome.TestError("boom")])
  assert with_runtime_error.total == 1
  assert with_runtime_error.errors == 1
  assert with_runtime_error.percent == 100.0
  assert exit_policy.code(
      with_runtime_error,
      exit_policy.Context(False, True, Some(False), 0.0),
    )
    == 2
}

pub fn stable_cli_safety_defaults_test() {
  assert cli.parse([]) == Ok(cli.HelpCommand)
  let assert Ok(cli.ListCommand(_, False)) = cli.parse(["list"])
  let assert Ok(cli.ListCommand(_, True)) = cli.parse(["list", "--validate"])
  assert cli.parse(["report", "latest"])
    == cli.parse(["report", "latest", "--json"])
  assert cli.parse(["run", "--jobs", "1"])
    != Error("--jobs must be between 1 and 32")
  assert cli.parse(["run", "--jobs", "33"])
    == Error("--jobs must be between 1 and 32")
  let assert Ok(cli.RunCommand(milliseconds)) =
    cli.parse(["run", "--timeout", "30000ms"])
  assert milliseconds.timeout_ms == Some(30_000)
  let assert Ok(cli.RunCommand(seconds)) =
    cli.parse(["run", "--timeout", "30s"])
  assert seconds.timeout_ms == Some(30_000)
  let assert Ok(cli.RunCommand(decimal_seconds)) =
    cli.parse(["run", "--timeout", "1.5s"])
  assert decimal_seconds.timeout_ms == Some(1500)
  let assert Ok(cli.RunCommand(minutes)) = cli.parse(["run", "--timeout", "1m"])
  assert minutes.timeout_ms == Some(60_000)
  let assert Ok(cli.RunCommand(hours)) = cli.parse(["run", "--timeout", "1h"])
  assert hours.timeout_ms == Some(3_600_000)
  let assert Ok(cli.RunCommand(unitless_seconds)) =
    cli.parse(["run", "--timeout", "30"])
  assert unitless_seconds.timeout_ms == Some(30_000)
  let assert Ok(cli.RunCommand(lower_boundary)) =
    cli.parse(["run", "--timeout", "100ms"])
  assert lower_boundary.timeout_ms == Some(100)
  let assert Ok(cli.RunCommand(upper_boundary)) =
    cli.parse(["run", "--timeout", "24h"])
  assert upper_boundary.timeout_ms == Some(86_400_000)
  assert cli.parse(["run", "--timeout", "99ms"])
    == Error("--timeout must be between 100ms and 24h")
  assert cli.parse(["run", "--timeout", "0.05s"])
    == Error("--timeout must be between 100ms and 24h")
  assert cli.parse(["run", "--timeout", "24.0001h"])
    == Error("--timeout must be between 100ms and 24h")
  assert cli.parse(["run", "--timeout", "86401s"])
    == Error("--timeout must be between 100ms and 24h")
  assert cli.parse(["run", "--timeout", "1.5"])
    == Error("--timeout must be between 100ms and 24h")
  assert cli.parse(["run", "--timeout", "1d"])
    == Error("--timeout must be between 100ms and 24h")
  assert cli.parse(["run", "--timeout", "NaN"])
    == Error("--timeout must be between 100ms and 24h")
  assert cli.parse(["run", "--timeout", "Infinity"])
    == Error("--timeout must be between 100ms and 24h")
  assert cli.parse(["init", "--dry-run", "--check"])
    == Error("GMU1002: --dry-run and --check are mutually exclusive")

  let defaults = config.defaults(64)
  assert defaults.jobs == 8
  assert defaults.strict == Some(False)
  assert defaults.cache_mode == config.CacheAuto
}

pub fn cache_fingerprint_is_order_and_input_sensitive_test() {
  let first =
    cache.fingerprint(
      "abc",
      [outcome.Erlang, outcome.Node],
      ["gleam", "test"],
      10_000,
    )
  assert first
    == cache.fingerprint(
      "abc",
      [outcome.Erlang, outcome.Node],
      ["gleam", "test"],
      10_000,
    )
  assert first
    != cache.fingerprint(
      "abcd",
      [outcome.Erlang, outcome.Node],
      ["gleam", "test"],
      10_000,
    )
  assert first
    != cache.fingerprint(
      "abc",
      [outcome.Node, outcome.Erlang],
      ["gleam", "test"],
      10_000,
    )
}

pub fn cache_directional_modes_decode_test() {
  let assert Ok(read_only) =
    config.decode(
      "[tools.gleam_mutants]\nversion = 1\n[tools.gleam_mutants.cache]\nmode = \"read-only\"\n",
      4,
    )
  assert read_only.cache_mode == config.CacheReadOnly
  let assert Ok(write_only) =
    config.decode(
      "[tools.gleam_mutants]\nversion = 1\n[tools.gleam_mutants.cache]\nmode = \"write-only\"\n",
      4,
    )
  assert write_only.cache_mode == config.CacheWriteOnly
}
