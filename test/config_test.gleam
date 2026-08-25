// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The `[tools.gleam_mutants.suggest]` section, decoded as strictly as every
// other section: unknown keys and out-of-range values are positioned errors.

import gleam/string
import gleam_mutants/config

const header = "[tools.gleam_mutants]\nversion = 1\n"

const prefix = "[tools.gleam_mutants]\nversion = 1\n[tools.gleam_mutants.suggest]\n"

/// The message of the error `source` decodes to.
fn message(source: String) -> String {
  let assert Error(config.ConfigError(_, _, message)) = config.decode(source, 4)
  message
}

// --- defaults ----------------------------------------------------------------

pub fn suggest_defaults_are_the_documented_ones_test() {
  let defaults = config.defaults(4)
  assert defaults.suggest
    == config.SuggestConfig(
      seed: 1,
      max_cases: 200,
      max_shrinks: 500,
      call_timeout_ms: 1000,
      probe_timeout_ms: 120_000,
      assert_style: config.AssertKeyword,
      exclude_functions: [],
    )
}

pub fn suggest_defaults_survive_a_document_without_the_section_test() {
  let assert Ok(decoded) = config.decode(header, 4)
  assert decoded.suggest == config.defaults(4).suggest

  // An empty section is the same as no section.
  let assert Ok(empty) = config.decode(prefix, 4)
  assert empty.suggest == config.defaults(4).suggest
}

// --- valid values ------------------------------------------------------------

pub fn suggest_section_decodes_every_key_test() {
  let assert Ok(decoded) =
    config.decode(
      prefix
        <> "seed = 7\n"
        <> "max_cases = 50\n"
        <> "max_shrinks = 0\n"
        <> "call_timeout_ms = 250\n"
        <> "probe_timeout_ms = 60000\n"
        <> "assert_style = \"should\"\n"
        <> "exclude_functions = [\"main\", \"now\"]\n",
      4,
    )
  assert decoded.suggest
    == config.SuggestConfig(
      seed: 7,
      max_cases: 50,
      max_shrinks: 0,
      call_timeout_ms: 250,
      probe_timeout_ms: 60_000,
      assert_style: config.ShouldEqual,
      exclude_functions: ["main", "now"],
    )
}

pub fn suggest_accepts_both_assert_styles_test() {
  let assert Ok(keyword) =
    config.decode(prefix <> "assert_style = \"assert\"\n", 4)
  assert keyword.suggest.assert_style == config.AssertKeyword

  let assert Ok(should) =
    config.decode(prefix <> "assert_style = \"should\"\n", 4)
  assert should.suggest.assert_style == config.ShouldEqual
}

pub fn suggest_accepts_the_edges_of_every_range_test() {
  let assert Ok(low) =
    config.decode(
      prefix
        <> "seed = -1\nmax_cases = 1\nmax_shrinks = 0\ncall_timeout_ms = 10\nprobe_timeout_ms = 100\n",
      4,
    )
  assert low.suggest.seed == -1
  assert low.suggest.max_cases == 1
  assert low.suggest.max_shrinks == 0
  assert low.suggest.call_timeout_ms == 10
  assert low.suggest.probe_timeout_ms == 100

  let assert Ok(high) =
    config.decode(
      prefix
        <> "max_cases = 100000\nmax_shrinks = 100000\ncall_timeout_ms = 600000\nprobe_timeout_ms = 86400000\n",
      4,
    )
  assert high.suggest.max_cases == 100_000
  assert high.suggest.max_shrinks == 100_000
  assert high.suggest.call_timeout_ms == 600_000
  assert high.suggest.probe_timeout_ms == 86_400_000
}

// --- invalid values ----------------------------------------------------------

pub fn suggest_rejects_counts_out_of_range_test() {
  assert string.contains(
    message(prefix <> "max_cases = 0\n"),
    "suggest.max_cases must be between 1 and 100000",
  )
  assert string.contains(
    message(prefix <> "max_cases = 100001\n"),
    "suggest.max_cases must be between 1 and 100000",
  )
  assert string.contains(
    message(prefix <> "max_shrinks = -1\n"),
    "suggest.max_shrinks must be between 0 and 100000",
  )
  assert string.contains(
    message(prefix <> "max_shrinks = 100001\n"),
    "suggest.max_shrinks must be between 0 and 100000",
  )
}

pub fn suggest_rejects_timeouts_out_of_range_test() {
  assert string.contains(
    message(prefix <> "call_timeout_ms = 9\n"),
    "suggest.call_timeout_ms must be between 10 and 600000",
  )
  assert string.contains(
    message(prefix <> "call_timeout_ms = 600001\n"),
    "suggest.call_timeout_ms must be between 10 and 600000",
  )
  // The same range `--budget` accepts, so that no `gleam.toml` refuses what a
  // flag would have taken.
  assert string.contains(
    message(prefix <> "probe_timeout_ms = 99\n"),
    "suggest.probe_timeout_ms must be between 100 and 86400000",
  )
  assert string.contains(
    message(prefix <> "probe_timeout_ms = 86400001\n"),
    "suggest.probe_timeout_ms must be between 100 and 86400000",
  )
}

pub fn suggest_rejects_an_unknown_assert_style_test() {
  assert string.contains(
    message(prefix <> "assert_style = \"expect\"\n"),
    "suggest.assert_style must be assert or should",
  )
  assert string.contains(
    message(prefix <> "assert_style = true\n"),
    "suggest.assert_style must be a string",
  )
}

pub fn suggest_rejects_values_of_the_wrong_type_test() {
  assert string.contains(
    message(prefix <> "seed = 1.5\n"),
    "suggest.seed must be an integer",
  )
  assert string.contains(
    message(prefix <> "max_cases = \"200\"\n"),
    "suggest.max_cases must be an integer",
  )
  assert string.contains(
    message(prefix <> "exclude_functions = \"main\"\n"),
    "suggest.exclude_functions must be an array of strings",
  )
  assert string.contains(
    message(prefix <> "exclude_functions = [1, 2]\n"),
    "suggest.exclude_functions must be an array of strings",
  )
}

pub fn suggest_rejects_an_unknown_key_with_a_position_test() {
  let assert Error(config.ConfigError(line, column, message)) =
    config.decode(prefix <> "seed = 7\nbogus = true\n", 4)
  assert line == 5
  assert column == 1
  assert string.contains(
    message,
    "unknown key tools.gleam_mutants.suggest.bogus",
  )
}

pub fn suggest_keys_do_not_steal_another_sections_position_test() {
  // `timeout_ms` is a substring of `call_timeout_ms`: the position of a
  // `test.timeout_ms` error has to be the line that key is written on, not
  // the first line that happens to contain its letters.
  let assert Error(config.ConfigError(line, column, message)) =
    config.decode(
      "[tools.gleam_mutants]\n"
        <> "version = 1\n"
        <> "[tools.gleam_mutants.suggest]\n"
        <> "call_timeout_ms = 1000\n"
        <> "[tools.gleam_mutants.test]\n"
        <> "timeout_ms = 1\n",
      4,
    )
  assert string.contains(
    message,
    "tools.gleam_mutants.test.timeout_ms must be between 100 and 86400000",
  )
  assert line == 6
  assert column == 1
}

// --- init --------------------------------------------------------------------

pub fn init_leaves_the_suggest_section_alone_test() {
  // `init` writes only the sections it has always written, and stays
  // idempotent now that another section exists.
  let assert Ok(#(initialised, changed)) =
    config.initialise("name = \"demo\"\n")
  assert changed
  assert !string.contains(initialised, "[tools.gleam_mutants.suggest]")
  let assert Ok(#(again, second_changed)) = config.initialise(initialised)
  assert !second_changed
  assert again == initialised

  // A section the user wrote themselves survives `init` untouched.
  let assert Ok(#(kept, _)) =
    config.initialise(prefix <> "assert_style = \"should\"\n")
  assert string.contains(kept, "[tools.gleam_mutants.suggest]")
  assert string.contains(kept, "assert_style = \"should\"")
}
