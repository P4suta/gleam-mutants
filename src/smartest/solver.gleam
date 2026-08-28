//// Bounded candidate providers for concolic and SMT integrations.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/option.{type Option, None, Some}
import smartest/evidence.{type Capability, type FormalProof}
import smartest/gen
import smartest/internal/plan
import smartest/testing.{type Test}

/// A provider's bounded answer. `Complete` is meaningful only inside the
/// `FormalProof` boundary supplied when the provider is constructed.
pub type Outcome(a) {
  Complete(candidates: List(a))
  Incomplete(candidates: List(a), reason: String)
  Unavailable(reason: String)
}

/// A lazy provider contract. External processes require `Subprocess` (and any
/// other effects they need) in `capabilities`.
pub opaque type Provider(a) {
  Provider(
    name: String,
    schema: String,
    boundary: FormalProof,
    capabilities: List(Capability),
    solve: fn() -> Outcome(a),
    renderer: fn(a) -> String,
  )
}

pub fn provider(
  name name: String,
  schema schema: String,
  boundary boundary: FormalProof,
  capabilities capabilities: List(Capability),
  solve solve: fn() -> Outcome(a),
  renderer renderer: fn(a) -> String,
) -> Provider(a) {
  Provider(name, schema, boundary, capabilities, solve, renderer)
}

pub fn schema_fingerprint(provider: Provider(a)) -> String {
  gen.nil()
  |> gen.named(
    "solver("
    <> provider.name
    <> ",schema:"
    <> provider.schema
    <> ",method:"
    <> evidence.proof_method(provider.boundary)
    <> ",subset:"
    <> evidence.proof_subset(provider.boundary)
    <> ",bound:"
    <> evidence.proof_bound(provider.boundary)
    <> ")",
  )
  |> gen.schema_fingerprint
}

/// Checks the provider's stable candidate order with an independent oracle.
///
/// `Incomplete`, an insufficient case budget, and `Unavailable` are advisory;
/// none is promoted to an equivalence claim.
pub fn check(provider: Provider(a), oracle: fn(a) -> Nil) -> Test {
  let schema = schema_fingerprint(provider)
  let value =
    plan.exploration(
      fn(evaluate, budget, replay) {
        case replay {
          Some(plan.Replay(tape, stored_schema)) ->
            replay_candidate(
              provider,
              oracle,
              evaluate,
              budget.timeout_ms,
              schema,
              tape,
              stored_schema,
            )
          None ->
            case provider.solve() {
              Unavailable(reason) ->
                plan.CheckUnsupported(
                  "solver " <> provider.name <> " is unavailable: " <> reason,
                )
              Complete(candidates) ->
                evaluate_candidates(
                  provider,
                  oracle,
                  evaluate,
                  candidates,
                  budget.timeout_ms,
                  budget.cases,
                  0,
                  None,
                )
              Incomplete(candidates, reason) ->
                evaluate_candidates(
                  provider,
                  oracle,
                  evaluate,
                  candidates,
                  budget.timeout_ms,
                  budget.cases,
                  0,
                  Some(reason),
                )
            }
        }
      },
      Some(schema),
    )
    |> testing.with_oracle(evidence.ExternalOracle(provenance(provider)))
  case provider.capabilities {
    [] -> value
    capabilities -> testing.with_effect(value, evidence.Declared(capabilities))
  }
}

fn replay_candidate(
  provider: Provider(a),
  oracle: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  timeout_ms: Int,
  schema: String,
  tape: List(Int),
  stored_schema: String,
) -> plan.CheckResult {
  case stored_schema == schema, tape {
    False, _ ->
      plan.CheckStale(
        "solver provider schema changed: expected "
        <> stored_schema
        <> ", found "
        <> schema,
      )
    True, [index] ->
      case provider.solve() {
        Unavailable(reason) ->
          plan.CheckUnsupported(
            "solver " <> provider.name <> " is unavailable: " <> reason,
          )
        Complete(candidates) | Incomplete(candidates, _) ->
          case value_at(candidates, index) {
            None ->
              plan.CheckStale(
                "solver witness index "
                <> int.to_string(index)
                <> " is outside the current candidate set",
              )
            Some(candidate) ->
              evaluated(
                evaluate(fn() { oracle(candidate) }, timeout_ms),
                provider,
                candidate,
                index,
                1,
              )
          }
      }
    True, _ -> plan.CheckStale("solver witness tape must contain one index")
  }
}

fn evaluate_candidates(
  provider: Provider(a),
  oracle: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  candidates: List(a),
  timeout_ms: Int,
  remaining_budget: Int,
  completed: Int,
  incomplete: Option(String),
) -> plan.CheckResult {
  case candidates, remaining_budget <= 0 {
    [], _ -> finish_search(provider, completed, incomplete)
    [_, ..], True ->
      budget_exhausted(
        provider,
        completed,
        "case budget ended before all provider candidates were checked",
      )
    [candidate, ..rest], False -> {
      let evaluation = evaluate(fn() { oracle(candidate) }, timeout_ms)
      case evaluation {
        plan.EvaluationPassed(_) ->
          evaluate_candidates(
            provider,
            oracle,
            evaluate,
            rest,
            timeout_ms,
            remaining_budget - 1,
            completed + 1,
            incomplete,
          )
        _ ->
          evaluated(evaluation, provider, candidate, completed, completed + 1)
      }
    }
  }
}

fn finish_search(
  provider: Provider(a),
  completed: Int,
  incomplete: Option(String),
) -> plan.CheckResult {
  case incomplete {
    None -> plan.CheckPassed(completed)
    Some(reason) -> budget_exhausted(provider, completed, reason)
  }
}

fn budget_exhausted(
  provider: Provider(a),
  cases: Int,
  reason: String,
) -> plan.CheckResult {
  plan.CheckBudgetExhausted(
    "solver "
      <> provider.name
      <> " did not complete subset "
      <> evidence.proof_subset(provider.boundary)
      <> " within bound "
      <> evidence.proof_bound(provider.boundary)
      <> ": "
      <> reason
      <> "; no equivalence claim was made",
    cases,
  )
}

fn evaluated(
  evaluation: plan.Evaluation,
  provider: Provider(a),
  candidate: a,
  index: Int,
  cases: Int,
) -> plan.CheckResult {
  case evaluation {
    plan.EvaluationPassed(_) -> plan.CheckPassed(cases)
    plan.EvaluationFailed(message, _) ->
      plan.CheckFailed(
        message: message,
        witness: Some(provider.renderer(candidate)),
        tape: [index],
        generator_schema: Some(schema_fingerprint(provider)),
        cases: cases,
        shrinks: 0,
      )
    plan.EvaluationTimedOut(message, _) -> plan.CheckTimedOut(message, cases)
    plan.EvaluationCancelled(message, _) -> plan.CheckCancelled(message, cases)
  }
}

fn provenance(provider: Provider(a)) -> String {
  "solver "
  <> provider.name
  <> "; method "
  <> evidence.proof_method(provider.boundary)
  <> "; subset "
  <> evidence.proof_subset(provider.boundary)
  <> "; bound "
  <> evidence.proof_bound(provider.boundary)
}

fn value_at(values: List(a), index: Int) -> Option(a) {
  case values, index {
    _, index if index < 0 -> None
    [], _ -> None
    [value, ..], 0 -> Some(value)
    [_, ..rest], index -> value_at(rest, index - 1)
  }
}
