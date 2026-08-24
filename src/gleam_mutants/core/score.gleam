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
      display_percent(score.percent)
      <> "% ("
      <> int.to_string(score.killed + score.timed_out)
      <> "/"
      <> int.to_string(score.total)
      <> ")"
  }
}

fn display_percent(percent: Float) -> String {
  let hundredths = float.round(percent *. 100.0)
  let whole = hundredths / 100
  let remainder = hundredths % 100
  case remainder {
    0 -> int.to_string(whole)
    value if value % 10 == 0 ->
      int.to_string(whole) <> "." <> int.to_string(value / 10)
    value if value < 10 -> int.to_string(whole) <> ".0" <> int.to_string(value)
    value -> int.to_string(whole) <> "." <> int.to_string(value)
  }
}
