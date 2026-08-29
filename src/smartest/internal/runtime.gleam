//// Runtime shell used by the in-process runner.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/evidence.{type Target}
import smartest/internal/plan

pub type Attempt(a) {
  AttemptPassed(value: a, duration_ms: Int)
  AttemptFailed(message: String, duration_ms: Int)
  AttemptTimedOut(message: String, duration_ms: Int)
  AttemptCancelled(message: String, duration_ms: Int)
}

@external(erlang, "smartest_runtime_ffi", "capture")
@external(javascript, "./smartest_runtime_ffi.mjs", "capture")
fn capture_ffi(callback: fn() -> Nil, timeout_ms: Int) -> #(String, String, Int)

@external(erlang, "smartest_runtime_ffi", "attempt")
@external(javascript, "./smartest_runtime_ffi.mjs", "attempt")
fn attempt_ffi(
  callback: fn() -> a,
  timeout_ms: Int,
) -> #(String, a, String, Int)

@external(erlang, "smartest_runtime_ffi", "runtime_name")
@external(javascript, "./smartest_runtime_ffi.mjs", "runtime_name")
fn runtime_name() -> String

@external(erlang, "smartest_runtime_ffi", "with_test_context")
@external(javascript, "./smartest_runtime_ffi.mjs", "with_test_context")
fn with_test_context_ffi(id: String, callback: fn() -> a) -> a

/// Runs a single leaf under the context consumed by instrumented mutation
/// sites, restoring any outer context even when the callback fails.
pub fn with_test_context(id: String, callback: fn() -> a) -> a {
  with_test_context_ffi(id, callback)
}

pub fn capture(callback: fn() -> Nil, timeout_ms: Int) -> plan.Evaluation {
  let #(status, message, duration_ms) = capture_ffi(callback, timeout_ms)
  case status {
    "passed" -> plan.EvaluationPassed(duration_ms)
    "timed-out" -> plan.EvaluationTimedOut(message, duration_ms)
    "cancelled" -> plan.EvaluationCancelled(message, duration_ms)
    _ -> plan.EvaluationFailed(message, duration_ms)
  }
}

pub fn attempt(callback: fn() -> a, timeout_ms: Int) -> Attempt(a) {
  let #(status, value, message, duration_ms) = attempt_ffi(callback, timeout_ms)
  case status {
    "passed" -> AttemptPassed(value, duration_ms)
    "timed-out" -> AttemptTimedOut(message, duration_ms)
    "cancelled" -> AttemptCancelled(message, duration_ms)
    _ -> AttemptFailed(message, duration_ms)
  }
}

pub fn current_target() -> Target {
  case runtime_name() {
    "node" -> evidence.Node
    "deno" -> evidence.Deno
    "bun" -> evidence.Bun
    _ -> evidence.Erlang
  }
}
