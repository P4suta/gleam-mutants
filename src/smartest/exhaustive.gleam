//// Deterministic enumeration of explicitly finite domains.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import smartest/evidence
import smartest/gen
import smartest/internal/plan
import smartest/testing.{type Test}

/// A caller-versioned finite subset. Values are visited in declared order.
pub opaque type Domain(a) {
  Domain(
    schema: String,
    subset: String,
    values: List(a),
    renderer: fn(a) -> String,
  )
}

/// Declares a finite domain without evaluating a property callback.
pub fn domain(
  schema schema: String,
  subset subset: String,
  values values: List(a),
  renderer renderer: fn(a) -> String,
) -> Domain(a) {
  Domain(schema, subset, values, renderer)
}

/// The portable schema stored beside an index tape.
pub fn schema_fingerprint(domain: Domain(a)) -> String {
  gen.nil()
  |> gen.named(
    "finite-domain("
    <> domain.schema
    <> ",bound:"
    <> int.to_string(list.length(domain.values))
    <> ")",
  )
  |> gen.schema_fingerprint
}

/// Checks each value once, or reports a visible budget boundary.
///
/// A failing value is persisted as its declared-order index, so the witness
/// replays across every target as long as the caller's schema is unchanged.
pub fn for_all(domain: Domain(a), callback: fn(a) -> Nil) -> Test {
  let schema = schema_fingerprint(domain)
  plan.exploration(
    fn(evaluate, budget, replay) {
      case replay {
        Some(plan.Replay(tape, stored_schema)) ->
          replay_case(
            domain,
            callback,
            evaluate,
            budget.timeout_ms,
            schema,
            tape,
            stored_schema,
          )
        None ->
          enumerate(
            domain,
            callback,
            evaluate,
            domain.values,
            budget.timeout_ms,
            budget.cases,
            0,
          )
      }
    },
    Some(schema),
  )
  |> testing.with_oracle(evidence.PropertyOracle(
    "finite exhaustive: "
    <> domain.subset
    <> "; bound "
    <> int.to_string(list.length(domain.values)),
  ))
}

fn replay_case(
  domain: Domain(a),
  callback: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  timeout_ms: Int,
  schema: String,
  tape: List(Int),
  stored_schema: String,
) -> plan.CheckResult {
  case stored_schema == schema, tape {
    False, _ ->
      plan.CheckStale(
        "finite domain schema changed: expected "
        <> stored_schema
        <> ", found "
        <> schema,
      )
    True, [index] ->
      case value_at(domain.values, index) {
        None ->
          plan.CheckStale(
            "finite witness index "
            <> int.to_string(index)
            <> " is outside the declared bound",
          )
        Some(value) ->
          evaluated(
            evaluate(fn() { callback(value) }, timeout_ms),
            domain,
            value,
            index,
            1,
          )
      }
    True, _ -> plan.CheckStale("finite witness tape must contain one index")
  }
}

fn enumerate(
  domain: Domain(a),
  callback: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  remaining_values: List(a),
  timeout_ms: Int,
  remaining_budget: Int,
  completed: Int,
) -> plan.CheckResult {
  case remaining_values, remaining_budget <= 0 {
    [], _ -> plan.CheckPassed(completed)
    [_, ..], True ->
      plan.CheckBudgetExhausted(
        "finite enumeration checked "
          <> int.to_string(completed)
          <> " of "
          <> int.to_string(list.length(domain.values))
          <> " values in "
          <> domain.subset
          <> "; no equivalence claim was made",
        completed,
      )
    [value, ..rest], False -> {
      let evaluation = evaluate(fn() { callback(value) }, timeout_ms)
      case evaluation {
        plan.EvaluationPassed(_) ->
          enumerate(
            domain,
            callback,
            evaluate,
            rest,
            timeout_ms,
            remaining_budget - 1,
            completed + 1,
          )
        _ -> evaluated(evaluation, domain, value, completed, completed + 1)
      }
    }
  }
}

fn evaluated(
  evaluation: plan.Evaluation,
  domain: Domain(a),
  value: a,
  index: Int,
  cases: Int,
) -> plan.CheckResult {
  case evaluation {
    plan.EvaluationPassed(_) -> plan.CheckPassed(cases)
    plan.EvaluationFailed(message, _) ->
      plan.CheckFailed(
        message: message,
        witness: Some(domain.renderer(value)),
        tape: [index],
        generator_schema: Some(schema_fingerprint(domain)),
        cases: cases,
        shrinks: 0,
      )
    plan.EvaluationTimedOut(message, _) -> plan.CheckTimedOut(message, cases)
    plan.EvaluationCancelled(message, _) -> plan.CheckCancelled(message, cases)
  }
}

fn value_at(values: List(a), index: Int) -> Option(a) {
  case values, index {
    _, index if index < 0 -> None
    [], _ -> None
    [value, ..], 0 -> Some(value)
    [_, ..rest], index -> value_at(rest, index - 1)
  }
}
