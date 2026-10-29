// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{Some}
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/engine.{Options}
import gleam_mutants/snapshot
import simplifile

pub fn main() {
  let options = Options(..engine.default_options(), strict: Some(False))
  let assert Error(error) =
    engine.run("fixtures/compile_invalid_project", options)
  assert string.contains(error, "all mutation candidates failed")
  let assert Ok(captured) = snapshot.create("fixtures/basic_project")
  let assert Ok(Nil) =
    simplifile.write(
      path.join(snapshot.root(captured), "src/calculator.gleam"),
      "pub fn add(a: Int, b: Int) -> Int { missing(a) + b }\n",
    )
  let attempted =
    engine.run(
      snapshot.root(captured),
      Options(..options, test_command: Some(["node", "-e", "process.exit(0)"])),
    )
  let assert Ok(Nil) = snapshot.dispose(captured)
  let assert Error(error) = attempted
  assert string.contains(error, "missing")
  assert !string.contains(error, "GMU4003")
}
