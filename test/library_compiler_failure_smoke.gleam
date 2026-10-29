// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam/option.{Some}
import gleam/string
import gleam_mutants/api
import gleam_mutants/platform
import gleam_mutants/types
import simplifile

pub fn main() {
  let counter = platform.env("GLEAM_MUTANTS_COMPILER_COUNTER")
  let options =
    types.Options(
      ..api.default_options(),
      test_command: Some(["node", "-e", "process.exit(0)"]),
    )
  let validation = api.validate_mutants("fixtures/basic_project", options)
  let assert Ok(Nil) = simplifile.write(counter, "0")
  let execution = api.run("fixtures/basic_project", options)
  let assert Error(types.Failure(types.Validating, _, message)) = validation
  assert string.contains(message, "compiler-fixture-failure")
  let assert Error(types.Failure(types.Running, _, message)) = execution
  assert string.contains(message, "compiler-fixture-failure")
  assert !string.contains(message, "GMU4003")
  io.println("Compiler infrastructure failure returned to the API")
}
