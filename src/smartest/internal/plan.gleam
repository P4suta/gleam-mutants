//// Internal pure representation of lazy test plans.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{type Option, None, Some}
import smartest/evidence.{
  type Budget, type EffectGrade, type OracleProvenance, type Target,
}

pub type Evaluation {
  EvaluationPassed(duration_ms: Int)
  EvaluationFailed(message: String, duration_ms: Int)
  EvaluationTimedOut(message: String, duration_ms: Int)
  EvaluationCancelled(message: String, duration_ms: Int)
}

pub type Evaluator =
  fn(fn() -> Nil, Int) -> Evaluation

pub type Replay {
  Replay(tape: List(Int), generator_schema: String)
}

pub type CheckResult {
  CheckPassed(cases: Int)
  CheckBudgetExhausted(message: String, cases: Int)
  CheckUnsupported(message: String)
  CheckFailed(
    message: String,
    witness: Option(String),
    tape: List(Int),
    generator_schema: Option(String),
    cases: Int,
    shrinks: Int,
  )
  CheckTimedOut(message: String, cases: Int)
  CheckCancelled(message: String, cases: Int)
  CheckStale(message: String)
}

pub type Check =
  fn(Evaluator, Budget, Option(Replay)) -> CheckResult

pub type Leaf {
  Example(callback: fn() -> Nil)
  Exploration(check: Check, generator_schema: Option(String))
  Scenario(check: Check)
  Snapshot(name: String, schema: String, actual: fn() -> String)
  Performance(name: String, samples: Int, maximum_ms: Int, run: fn() -> Nil)
}

pub type Node {
  LeafNode(Leaf)
  SuiteNode(name: String, tests: List(Test))
}

pub type Metadata {
  Metadata(
    name: Option(String),
    tags: List(String),
    targets: List(Target),
    budget: Option(Budget),
    effect: Option(EffectGrade),
    oracle: Option(OracleProvenance),
  )
}

pub opaque type Test {
  Test(node: Node, metadata: Metadata)
}

pub fn example(callback: fn() -> Nil) -> Test {
  Test(LeafNode(Example(callback)), defaults())
}

pub fn exploration(check: Check, generator_schema: Option(String)) -> Test {
  Test(
    LeafNode(Exploration(check, generator_schema)),
    Metadata(
      ..defaults(),
      effect: Some(evidence.Pure),
      oracle: Some(evidence.PropertyOracle("property")),
    ),
  )
}

pub fn scenario(check: Check, effect: EffectGrade) -> Test {
  Test(LeafNode(Scenario(check)), Metadata(..defaults(), effect: Some(effect)))
}

pub fn snapshot(name: String, schema: String, actual: fn() -> String) -> Test {
  Test(
    LeafNode(Snapshot(name, schema, actual)),
    Metadata(..defaults(), name: Some(name)),
  )
}

pub fn performance(
  name: String,
  samples: Int,
  maximum_ms: Int,
  run: fn() -> Nil,
) -> Test {
  Test(
    LeafNode(Performance(name, samples, maximum_ms, run)),
    Metadata(..defaults(), name: Some(name), effect: Some(evidence.Pure)),
  )
}

pub fn suite(name: String, tests: List(Test)) -> Test {
  Test(SuiteNode(name, tests), defaults())
}

pub fn node(value: Test) -> Node {
  value.node
}

pub fn metadata(value: Test) -> Metadata {
  value.metadata
}

pub fn with_name(value: Test, name: String) -> Test {
  Test(..value, metadata: Metadata(..value.metadata, name: Some(name)))
}

pub fn with_budget(value: Test, budget: Budget) -> Test {
  Test(..value, metadata: Metadata(..value.metadata, budget: Some(budget)))
}

pub fn with_effect(value: Test, effect: EffectGrade) -> Test {
  Test(..value, metadata: Metadata(..value.metadata, effect: Some(effect)))
}

pub fn with_tags(value: Test, tags: List(String)) -> Test {
  Test(..value, metadata: Metadata(..value.metadata, tags: tags))
}

pub fn with_targets(value: Test, targets: List(Target)) -> Test {
  Test(..value, metadata: Metadata(..value.metadata, targets: targets))
}

pub fn with_oracle(value: Test, oracle: OracleProvenance) -> Test {
  Test(..value, metadata: Metadata(..value.metadata, oracle: Some(oracle)))
}

pub fn is_exploratory(leaf: Leaf) -> Bool {
  case leaf {
    Example(_) | Snapshot(_, _, _) -> False
    Exploration(_, _) | Scenario(_) | Performance(_, _, _, _) -> True
  }
}

fn defaults() -> Metadata {
  Metadata(
    name: None,
    tags: [],
    targets: [],
    budget: None,
    effect: None,
    oracle: None,
  )
}
