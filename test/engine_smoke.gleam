// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/io
import gleam/option.{Some}
import gleam_mutants/engine.{Options}

pub fn main() {
  let options =
    Options(
      ..engine.default_options(),
      strict: Some(False),
      jobs: Some(2),
      timeout_ms: Some(30_000),
    )
  let assert Ok(output) = engine.run("fixtures/basic_project", options)
  assert output.report.score.total > 0
  assert output.report.score.errors == 0
  io.println(
    "engine smoke: " <> int.to_string(output.report.score.total) <> " mutants",
  )
}
