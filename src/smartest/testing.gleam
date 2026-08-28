//// Pure constructors and metadata for lazy Smartest tests.
////
//// Gleam 1.18 reserves `test` as a keyword, so the compilable module name is
//// `smartest/testing` rather than `smartest/test`.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/evidence.{
  type Budget, type EffectGrade, type OracleProvenance, type Target,
}
import smartest/internal/plan

pub type Test =
  plan.Test

/// Builds a lazy example. `callback` is not invoked during construction.
pub fn example(callback: fn() -> Nil) -> Test {
  plan.example(callback)
}

pub fn suite(name: String, tests: List(Test)) -> Test {
  plan.suite(name, tests)
}

pub fn named(name: String, value: Test) -> Test {
  plan.with_name(value, name)
}

pub fn with_budget(value: Test, budget: Budget) -> Test {
  plan.with_budget(value, budget)
}

pub fn with_effect(value: Test, effect: EffectGrade) -> Test {
  plan.with_effect(value, effect)
}

pub fn tagged(value: Test, tags: List(String)) -> Test {
  plan.with_tags(value, tags)
}

pub fn on_targets(value: Test, targets: List(Target)) -> Test {
  plan.with_targets(value, targets)
}

/// Describes the independent judgement (or lack of one) for generated
/// evidence. This changes ledger provenance, never callback execution.
pub fn with_oracle(value: Test, oracle: OracleProvenance) -> Test {
  plan.with_oracle(value, oracle)
}
