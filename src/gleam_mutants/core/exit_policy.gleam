// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{type Option, None, Some}
import gleam_mutants/core/score.{type Score}

pub type Context {
  Context(ci: Bool, tty: Bool, strict: Option(Bool), minimum_score: Float)
}

pub fn strict(context: Context) -> Bool {
  case context.strict {
    Some(value) -> value
    None -> False
  }
}

pub fn code(score: Score, context: Context) -> Int {
  case
    score.errors > 0,
    strict(context) && score.percent <. context.minimum_score
  {
    True, _ -> 2
    False, True -> 1
    False, False -> 0
  }
}
