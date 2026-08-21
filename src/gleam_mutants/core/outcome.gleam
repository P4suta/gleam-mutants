// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list

pub type Runtime {
  Erlang
  Node
  Deno
  Bun
}

pub type Outcome {
  Killed
  Survived
  TimedOut
  TestError(message: String)
}

pub type RuntimeOutcome {
  RuntimeOutcome(
    runtime: Runtime,
    outcome: Outcome,
    duration_ms: Int,
    output: String,
    cached: Bool,
  )
}

pub fn runtime_name(runtime: Runtime) -> String {
  case runtime {
    Erlang -> "erlang"
    Node -> "node"
    Deno -> "deno"
    Bun -> "bun"
  }
}

pub fn aggregate(outcomes: List(RuntimeOutcome)) -> Outcome {
  case
    list.find(outcomes, fn(item) {
      case item.outcome {
        TestError(_) -> True
        _ -> False
      }
    })
  {
    Ok(item) -> item.outcome
    Error(_) ->
      case list.any(outcomes, fn(item) { item.outcome == Survived }) {
        True -> Survived
        False ->
          case list.any(outcomes, fn(item) { item.outcome == TimedOut }) {
            True -> TimedOut
            False -> Killed
          }
      }
  }
}

pub fn is_detected(outcome: Outcome) -> Bool {
  outcome == Killed || outcome == TimedOut
}
