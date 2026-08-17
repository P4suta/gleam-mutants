// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{Some}
import gleam/string
import gleam_mutants/engine.{Options}

pub fn main() {
  let options = Options(..engine.default_options(), strict: Some(False))
  let assert Error(error) =
    engine.run("fixtures/compile_invalid_project", options)
  assert string.contains(error, "all mutation candidates failed")
}
