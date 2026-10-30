// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam_mutants/types.{
  Bun, Deno, Erlang, Killed, Node, Survived, TestError, TimedOut,
}

pub type Runtime =
  types.Runtime

pub type Outcome =
  types.Outcome

pub type RuntimeOutcome =
  types.RuntimeOutcome

pub fn runtime_name(runtime: Runtime) -> String {
  case runtime {
    Erlang -> "erlang"
    Node -> "node"
    Deno -> "deno"
    Bun -> "bun"
  }
}

/// Whether an outcome counts the mutant as dead.
///
/// A mutant that hangs the suite is one the suite noticed, which is how `score.calculate` scores it: killed and timed out are both detected, and a test error is a run that never reached a verdict.
/// Every caller that decides whether one mutant is dead answers from here, so no two of them can disagree about the same workspace.
pub fn detected(value: Outcome) -> Bool {
  case value {
    Killed | TimedOut -> True
    Survived | TestError(_) -> False
  }
}

pub fn aggregate(outcomes: List(RuntimeOutcome)) -> Outcome {
  case outcomes {
    [] -> TestError("no runtime results")
    _ -> aggregate_nonempty(outcomes)
  }
}

fn aggregate_nonempty(outcomes: List(RuntimeOutcome)) -> Outcome {
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
