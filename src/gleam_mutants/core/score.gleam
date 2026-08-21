// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/float
import gleam/int
import gleam/list
import gleam_mutants/core/outcome.{type Outcome}

pub type Score {
  Score(
    total: Int,
    killed: Int,
    timed_out: Int,
    survived: Int,
    errors: Int,
    percent: Float,
  )
}

pub fn calculate(outcomes: List(Outcome)) -> Score {
  let killed = count(outcomes, fn(value) { value == outcome.Killed })
  let timed_out = count(outcomes, fn(value) { value == outcome.TimedOut })
  let survived = count(outcomes, fn(value) { value == outcome.Survived })
  let total = killed + timed_out + survived
  let errors = list.length(outcomes) - total
  let percent = case total {
    0 -> 0.0
    _ -> int.to_float(killed + timed_out) /. int.to_float(total) *. 100.0
  }
  Score(total, killed, timed_out, survived, errors, percent)
}

fn count(values: List(a), predicate: fn(a) -> Bool) -> Int {
  values |> list.filter(predicate) |> list.length
}

pub fn display(score: Score) -> String {
  case score.total {
    0 -> "N/A (0 valid mutants)"
    _ ->
      float.to_string(score.percent)
      <> "% ("
      <> int.to_string(score.killed + score.timed_out)
      <> "/"
      <> int.to_string(score.total)
      <> ")"
  }
}
