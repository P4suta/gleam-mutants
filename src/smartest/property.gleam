//// Property tests over the shared deterministic generator engine.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{type Option, None, Some}
import gleam/string
import smartest/evidence.{type Budget}
import smartest/gen.{type Generator, type Tree, Generated}
import smartest/internal/plan
import smartest/testing.{type Test}

/// Constructs a bounded property test without executing its callback.
pub fn for_all(generator: Generator(a), callback: fn(a) -> Nil) -> Test {
  plan.exploration(
    fn(evaluate, budget, replay) {
      case replay {
        Some(plan.Replay(tape, stored_schema)) ->
          replay_case(
            generator,
            callback,
            evaluate,
            budget,
            tape,
            stored_schema,
          )
        None -> search(generator, callback, evaluate, budget)
      }
    },
    Some(gen.schema_fingerprint(generator)),
  )
}

fn replay_case(
  generator: Generator(a),
  callback: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  budget: Budget,
  tape: List(Int),
  stored_schema: String,
) -> plan.CheckResult {
  let current_schema = gen.schema_fingerprint(generator)
  case current_schema == stored_schema {
    False ->
      plan.CheckStale(
        "generator schema changed: expected "
        <> stored_schema
        <> ", found "
        <> current_schema,
      )
    True ->
      case gen.replay(generator, tape) {
        Error(error) ->
          plan.CheckStale(
            "replay tape no longer decodes: " <> string.inspect(error),
          )
        Ok(tree) ->
          evaluation_result(
            evaluate(fn() { callback(gen.tree_value(tree)) }, budget.timeout_ms),
            generator,
            tree,
            1,
            0,
          )
      }
  }
}

fn search(
  generator: Generator(a),
  callback: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  budget: Budget,
) -> plan.CheckResult {
  search_loop(
    generator,
    callback,
    evaluate,
    budget,
    budget.cases,
    budget.seed,
    0,
  )
}

fn search_loop(
  generator: Generator(a),
  callback: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  budget: Budget,
  remaining: Int,
  seed: Int,
  completed: Int,
) -> plan.CheckResult {
  case remaining <= 0 {
    True -> plan.CheckPassed(completed)
    False ->
      case gen.generate(generator, seed) {
        Error(error) ->
          plan.CheckStale(
            "generator could not draw a case: " <> string.inspect(error),
          )
        Ok(Generated(tree, next_seed)) -> {
          let evaluation =
            evaluate(fn() { callback(gen.tree_value(tree)) }, budget.timeout_ms)
          case evaluation {
            plan.EvaluationPassed(_) ->
              search_loop(
                generator,
                callback,
                evaluate,
                budget,
                remaining - 1,
                next_seed,
                completed + 1,
              )
            plan.EvaluationFailed(_, _)
            | plan.EvaluationTimedOut(_, _)
            | plan.EvaluationCancelled(_, _) -> {
              let #(smallest, final_evaluation, shrinks) =
                shrink(
                  tree,
                  evaluation,
                  callback,
                  evaluate,
                  budget.timeout_ms,
                  budget.shrinks,
                  0,
                )
              evaluation_result(
                final_evaluation,
                generator,
                smallest,
                completed + 1,
                shrinks,
              )
            }
          }
        }
      }
  }
}

fn shrink(
  tree: Tree(a),
  failure: plan.Evaluation,
  callback: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  timeout_ms: Int,
  remaining: Int,
  attempted: Int,
) -> #(Tree(a), plan.Evaluation, Int) {
  case remaining <= 0 {
    True -> #(tree, failure, attempted)
    False ->
      case
        first_failing_child(
          gen.tree_children(tree),
          callback,
          evaluate,
          timeout_ms,
          remaining,
          0,
        )
      {
        None -> #(tree, failure, attempted)
        Some(#(child, child_failure, spent)) ->
          shrink(
            child,
            child_failure,
            callback,
            evaluate,
            timeout_ms,
            remaining - spent,
            attempted + spent,
          )
      }
  }
}

fn first_failing_child(
  children: List(Tree(a)),
  callback: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  timeout_ms: Int,
  remaining: Int,
  spent: Int,
) -> Option(#(Tree(a), plan.Evaluation, Int)) {
  case children, remaining <= 0 {
    _, True | [], _ -> None
    [child, ..rest], False -> {
      let evaluation =
        evaluate(fn() { callback(gen.tree_value(child)) }, timeout_ms)
      case evaluation {
        plan.EvaluationPassed(_) ->
          first_failing_child(
            rest,
            callback,
            evaluate,
            timeout_ms,
            remaining - 1,
            spent + 1,
          )
        _ -> Some(#(child, evaluation, spent + 1))
      }
    }
  }
}

fn evaluation_result(
  evaluation: plan.Evaluation,
  generator: Generator(a),
  tree: Tree(a),
  cases: Int,
  shrinks: Int,
) -> plan.CheckResult {
  case evaluation {
    plan.EvaluationPassed(_) -> plan.CheckPassed(cases)
    plan.EvaluationFailed(message, _) ->
      plan.CheckFailed(
        message: message,
        witness: Some(gen.render(generator, gen.tree_value(tree))),
        tape: gen.tree_tape(tree),
        generator_schema: Some(gen.schema_fingerprint(generator)),
        cases: cases,
        shrinks: shrinks,
      )
    plan.EvaluationTimedOut(message, _) -> plan.CheckTimedOut(message, cases)
    plan.EvaluationCancelled(message, _) -> plan.CheckCancelled(message, cases)
  }
}
