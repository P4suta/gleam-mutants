// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{Some}
import gleam_mutants/engine.{Options}

pub fn main() {
  let options = Options(..engine.default_options(), strict: Some(False))
  let assert Ok(output) =
    engine.run("fixtures/compile_invalid_project", options)
  assert output.report.score.total == 0
  assert list.length(output.report.rejected) == 1
}
