// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/cache
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

pub fn catalog_preserves_unicode_comments_and_crlf_test() {
  let source =
    "// 日本語 && comment\r\npub fn classify(n: Int) {\r\n  n < 10 && True\r\n}\r\n"
  let assert Ok(mutants) =
    catalog.discover("src/example.gleam", source, operator.all())
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
    "# keep me\n[tools.gleam_mutants]\nversion = 1\n[tools.gleam_mutants.execution]\njobs = 3\n[tools.gleam_mutants.policy]\nstrict = false\nminimum_score = 80\n"
  let assert Ok(decoded) = config.decode(source, 32)
  assert decoded.jobs == 3
  assert decoded.strict == Some(False)
  assert decoded.minimum_score == 80.0
  let assert Ok(#(initialised, changed)) =
    config.initialise("name = \"demo\" # comment\n")
  assert changed
  assert string.contains(initialised, "# comment")
  assert string.contains(initialised, "[tools.gleam_mutants]")
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
  assert score.display(mutation_score) == "66.66666666666666% (2/3)"
  let empty_score = score.calculate([])
  assert empty_score.percent == 100.0
  assert score.display(score.Score(4, 1, 2, 1, 0, 75.0)) == "75.0% (3/4)"
  assert exit_policy.code(
      mutation_score,
      exit_policy.Context(False, True, None, 100.0),
    )
    == 0
  assert exit_policy.code(
      mutation_score,
      exit_policy.Context(True, False, None, 100.0),
    )
    == 1
  assert exit_policy.code(
      mutation_score,
      exit_policy.Context(False, True, Some(True), 50.0),
    )
    == 0
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
