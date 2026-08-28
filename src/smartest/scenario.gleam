//// Resource-safe scenarios for effectful tests.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{None}
import smartest/evidence.{type Capability}
import smartest/internal/plan
import smartest/testing.{type Test}

pub opaque type Resource(a) {
  Resource(
    setup: fn() -> Result(a, String),
    teardown: fn(a) -> Result(Nil, String),
    capabilities: List(Capability),
  )
}

/// Declares setup and teardown without executing either callback.
pub fn resource(
  setup setup: fn() -> Result(a, String),
  teardown teardown: fn(a) -> Result(Nil, String),
  capabilities capabilities: List(Capability),
) -> Resource(a) {
  Resource(setup, teardown, capabilities)
}

/// Builds a one-shot scenario. Teardown is evaluated after the body even when
/// the body panics or asserts.
pub fn with_resource(resource: Resource(a), body: fn(a) -> Nil) -> Test {
  plan.scenario(
    fn(evaluate, budget, _) {
      case resource.setup() {
        Error(reason) ->
          plan.CheckFailed(reason, None, [], None, cases: 1, shrinks: 0)
        Ok(value) -> {
          let body_result = evaluate(fn() { body(value) }, budget.timeout_ms)
          let cleanup_result =
            evaluate(
              fn() {
                case resource.teardown(value) {
                  Ok(Nil) -> Nil
                  Error(reason) -> panic as reason
                }
              },
              budget.timeout_ms,
            )
          combine(body_result, cleanup_result)
        }
      }
    },
    evidence.Declared(resource.capabilities),
  )
}

fn combine(
  body: plan.Evaluation,
  cleanup: plan.Evaluation,
) -> plan.CheckResult {
  case body, cleanup {
    plan.EvaluationPassed(_), plan.EvaluationPassed(_) -> plan.CheckPassed(1)
    plan.EvaluationTimedOut(message, _), _
    | _, plan.EvaluationTimedOut(message, _)
    -> plan.CheckTimedOut(message, 1)
    plan.EvaluationCancelled(message, _), _
    | _, plan.EvaluationCancelled(message, _)
    -> plan.CheckCancelled(message, 1)
    plan.EvaluationFailed(body_message, _),
      plan.EvaluationFailed(cleanup_message, _)
    ->
      plan.CheckFailed(
        body_message <> "\nteardown failed: " <> cleanup_message,
        None,
        [],
        None,
        cases: 1,
        shrinks: 0,
      )
    plan.EvaluationFailed(message, _), _ ->
      plan.CheckFailed(message, None, [], None, cases: 1, shrinks: 0)
    _, plan.EvaluationFailed(message, _) ->
      plan.CheckFailed(
        "teardown failed: " <> message,
        None,
        [],
        None,
        cases: 1,
        shrinks: 0,
      )
  }
}
