// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam_mutants/cli
import gleam_mutants/config

pub fn removed_commands_are_usage_errors_test() {
  list.each(
    [["suggest"], ["explain", "abcdef"], ["apply"], ["run", "--suggest"]],
    fn(arguments) {
      let assert Error(_) = cli.parse(arguments)
      Nil
    },
  )
}

pub fn removed_configuration_is_a_positioned_error_test() {
  let assert Error(config.ConfigError(line, column, message)) =
    config.decode(
      "[tools.gleam_mutants]\nversion = 1\n[tools.gleam_mutants.suggest]\nseed = 1\n",
      4,
    )
  assert line > 0
  assert column > 0
  assert message == "unknown key tools.gleam_mutants.suggest"
}
