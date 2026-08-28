//// Deterministic execution of lazy Smartest test values.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import smartest/corpus
import smartest/evidence.{
  type Budget, type Capability, type EffectGrade, type OracleProvenance,
  type Target,
}
import smartest/internal/plan
import smartest/internal/runtime
import smartest/storage
import smartest/testing.{type Test}

pub type Entry {
  Entry(package: String, module: String, function: String, plan: Test)
}

pub type ReplayInput {
  ReplayInput(
    test_id: evidence.TestId,
    tape: List(Int),
    generator_schema: String,
  )
}

pub type Options {
  Options(
    budget: Budget,
    target: Target,
    granted: List(Capability),
    replays: List(ReplayInput),
    snapshots: List(SnapshotInput),
    replay_only: Bool,
    findings: Option(FindingOptions),
    startup_error: Option(String),
  )
}

pub type SnapshotInput {
  SnapshotInput(test_id: evidence.TestId, schema: String, expected: String)
}

pub type FindingOptions {
  FindingOptions(root: String, created_ms: Int)
}

pub type Status {
  Passed
  Failed
  TimedOut
  Cancelled
  Skipped
  Unsafe
  Unsupported
  Unjudged
  BudgetExhausted
  PerformanceRegression
  Stale
}

pub type TestResult {
  TestResult(
    id: evidence.TestId,
    status: Status,
    message: String,
    cases: Int,
    shrinks: Int,
    witness: Option(String),
    draw_tape: List(Int),
    generator_schema: Option(String),
    oracle: Option(OracleProvenance),
  )
}

pub type Report {
  Report(results: List(TestResult))
}

pub fn entry(
  package: String,
  module: String,
  function: String,
  value: Test,
) -> Entry {
  Entry(package, module, function, value)
}

/// Wraps an already-executed legacy test in the common evidence ledger.
pub fn legacy_result(
  package: String,
  module: String,
  function: String,
  passed passed: Bool,
  message message: String,
) -> TestResult {
  TestResult(
    evidence.test_id(package, module, function),
    case passed {
      True -> Passed
      False -> Failed
    },
    message,
    0,
    0,
    None,
    [],
    None,
    Some(evidence.ExampleOracle),
  )
}

pub fn default_options() -> Options {
  Options(
    budget: evidence.default_budget(),
    target: runtime.current_target(),
    granted: [],
    replays: [],
    snapshots: [],
    replay_only: False,
    findings: None,
    startup_error: None,
  )
}

pub fn with_findings(
  options: Options,
  root: String,
  created_ms created_ms: Int,
) -> Options {
  Options(..options, findings: Some(FindingOptions(root, created_ms)))
}

pub fn with_replay(
  options: Options,
  id: evidence.TestId,
  tape: List(Int),
  generator_schema: String,
) -> Options {
  Options(
    ..options,
    replays: [ReplayInput(id, tape, generator_schema)],
    replay_only: True,
  )
}

pub fn with_capabilities(
  options: Options,
  capabilities: List(Capability),
) -> Options {
  Options(..options, granted: capabilities)
}

/// Enables inbox persistence and loads every trusted tracked replay for the
/// current target. A corrupt corpus becomes a startup error; callbacks are not
/// executed in that state.
pub fn workspace_options(root: String, created_ms created_ms: Int) -> Options {
  let options = default_options() |> with_findings(root, created_ms: created_ms)
  case storage.list_corpus(root) {
    Error(reason) -> Options(..options, startup_error: Some(reason))
    Ok(envelopes) -> {
      let replays =
        envelopes
        |> list.filter(fn(envelope) {
          envelope.state == evidence.TrustedEvidence
          && list.contains(envelope.targets, options.target)
          && !is_snapshot_schema(envelope.generator_schema)
        })
        |> list.map(fn(envelope) {
          ReplayInput(
            envelope.test_id,
            envelope.draw_tape,
            envelope.generator_schema,
          )
        })
      let snapshots =
        envelopes
        |> list.filter(fn(envelope) {
          envelope.state == evidence.TrustedEvidence
          && list.contains(envelope.targets, options.target)
          && is_snapshot_schema(envelope.generator_schema)
        })
        |> list.map(fn(envelope) {
          SnapshotInput(
            envelope.test_id,
            envelope.generator_schema,
            envelope.rendering,
          )
        })
      Options(
        ..options,
        replays: replays,
        snapshots: snapshots,
        replay_only: False,
      )
    }
  }
}

/// Selects one accepted or inbox artifact for an explicit foreground replay.
pub fn replay_options(
  root: String,
  artifact_id: String,
  created_ms created_ms: Int,
) -> Options {
  let options = default_options() |> with_findings(root, created_ms: created_ms)
  let loaded = case storage.load_corpus(root, artifact_id) {
    Ok(envelope) -> Ok(envelope)
    Error(_) -> storage.load_inbox(root, artifact_id)
  }
  case loaded {
    Error(reason) -> Options(..options, startup_error: Some(reason))
    Ok(envelope) ->
      case list.contains(envelope.targets, options.target) {
        False ->
          Options(
            ..options,
            startup_error: Some(
              "artifact " <> artifact_id <> " does not target this runtime",
            ),
          )
        True ->
          case is_snapshot_schema(envelope.generator_schema) {
            True ->
              Options(
                ..options,
                snapshots: [
                  SnapshotInput(
                    envelope.test_id,
                    envelope.generator_schema,
                    envelope.rendering,
                  ),
                ],
                replay_only: True,
              )
            False ->
              Options(
                ..options,
                replays: [
                  ReplayInput(
                    envelope.test_id,
                    envelope.draw_tape,
                    envelope.generator_schema,
                  ),
                ],
                replay_only: True,
              )
          }
      }
  }
}

pub fn run(entries: List(Entry), options: Options) -> Report {
  let results = case options.startup_error {
    Some(reason) -> [startup_failure(entries, reason)]
    None -> entries |> list.flat_map(fn(entry) { run_entry(entry, options) })
  }
  let results = case options.findings {
    None -> results
    Some(findings) ->
      list.map(results, fn(result) {
        persist_finding(result, options.target, findings)
      })
  }
  Report(results)
}

pub fn run_entry(entry: Entry, options: Options) -> List(TestResult) {
  case options.startup_error {
    Some(reason) -> [
      basic_result(
        evidence.test_id(entry.package, entry.module, entry.function),
        Stale,
        reason,
      ),
    ]
    None -> {
      let root = evidence.test_id(entry.package, entry.module, entry.function)
      walk(entry.plan, root, inherited_metadata(), [], options)
    }
  }
}

/// Extracts generator schemas from a lazy plan without evaluating any test,
/// fixture, or property callback.
pub fn generator_bindings(entry: Entry) -> List(storage.GeneratorBinding) {
  let root = evidence.test_id(entry.package, entry.module, entry.function)
  collect_generator_bindings(entry.plan, root, [])
}

fn collect_generator_bindings(
  value: Test,
  root: evidence.TestId,
  path: List(String),
) -> List(storage.GeneratorBinding) {
  let metadata = plan.metadata(value)
  let path = case metadata.name {
    Some(name) -> list.append(path, [name])
    None -> path
  }
  case plan.node(value) {
    plan.SuiteNode(name, tests) -> {
      let path = list.append(path, [name])
      tests
      |> list.flat_map(fn(child) {
        collect_generator_bindings(child, root, path)
      })
    }
    plan.LeafNode(plan.Exploration(_, Some(schema))) -> {
      let id = list.fold(path, root, evidence.child_test_id)
      [storage.GeneratorBinding(id, schema)]
    }
    plan.LeafNode(_) -> []
  }
}

/// Whether a result permits the test process to exit successfully.
pub fn succeeded(result: TestResult) -> Bool {
  case result.status {
    Passed | Skipped | Unsupported | Unjudged | BudgetExhausted -> True
    Failed | TimedOut | Cancelled | Unsafe | PerformanceRegression | Stale ->
      False
  }
}

/// A target-independent line-oriented rendering used by discovery shells.
pub fn render_result(result: TestResult) -> String {
  let status = case result.status {
    Passed -> "PASS"
    Failed -> "FAIL"
    TimedOut -> "TIMEOUT"
    Cancelled -> "CANCELLED"
    Skipped -> "SKIP"
    Unsafe -> "UNSAFE"
    Unsupported -> "UNSUPPORTED"
    Unjudged -> "UNJUDGED"
    BudgetExhausted -> "BUDGET-EXHAUSTED"
    PerformanceRegression -> "PERFORMANCE-REGRESSION"
    Stale -> "STALE"
  }
  let witness = case result.witness {
    Some(value) -> "\nwitness: " <> value
    None -> ""
  }
  let exploration = case result.cases, result.shrinks {
    0, 0 -> ""
    cases, shrinks ->
      "\ncases: "
      <> int.to_string(cases)
      <> ", shrinks: "
      <> int.to_string(shrinks)
  }
  let message = case string.trim(result.message) {
    "" -> ""
    message -> "\n" <> message
  }
  status
  <> " "
  <> evidence.test_id_to_string(result.id)
  <> witness
  <> exploration
  <> message
  <> "\n"
}

fn walk(
  value: Test,
  root: evidence.TestId,
  inherited: plan.Metadata,
  path: List(String),
  options: Options,
) -> List(TestResult) {
  let metadata = merge_metadata(inherited, plan.metadata(value))
  let path = case metadata.name {
    Some(name) -> list.append(path, [name])
    None -> path
  }
  case plan.node(value) {
    plan.SuiteNode(name, tests) -> {
      let path = list.append(path, [name])
      tests
      |> list.flat_map(fn(child) { walk(child, root, metadata, path, options) })
    }
    plan.LeafNode(leaf) -> {
      let id = list.fold(path, root, evidence.child_test_id)
      execute_leaf(id, leaf, metadata, options)
    }
  }
}

fn execute_leaf(
  id: evidence.TestId,
  leaf: plan.Leaf,
  metadata: plan.Metadata,
  options: Options,
) -> List(TestResult) {
  let budget = option_or(metadata.budget, options.budget)
  case
    metadata.targets != [] && !list.contains(metadata.targets, options.target)
  {
    True -> [
      result_with_oracle(
        id,
        Skipped,
        "test does not target this runtime",
        metadata.oracle,
      ),
    ]
    False ->
      case exploratory_refusal(leaf, metadata.effect, options.granted) {
        Some(reason) -> [
          result_with_oracle(id, Unsafe, reason, metadata.oracle),
        ]
        None -> execute_allowed(id, leaf, budget, metadata.oracle, options)
      }
  }
}

fn exploratory_refusal(
  leaf: plan.Leaf,
  grade: Option(EffectGrade),
  granted: List(Capability),
) -> Option(String) {
  case plan.is_exploratory(leaf) {
    False -> None
    True ->
      case grade {
        Some(evidence.Unknown(reason)) -> Some(reason)
        Some(effect) ->
          case evidence.exploration_allowed(effect, granted) {
            True -> None
            False -> Some("required capabilities were not granted")
          }
        None -> Some("effect analysis unavailable")
      }
  }
}

fn execute_allowed(
  id: evidence.TestId,
  leaf: plan.Leaf,
  budget: Budget,
  oracle: Option(OracleProvenance),
  options: Options,
) -> List(TestResult) {
  case leaf {
    plan.Example(callback) -> [
      case runtime.capture(callback, budget.timeout_ms) {
        plan.EvaluationPassed(_) -> result_with_oracle(id, Passed, "", oracle)
        plan.EvaluationFailed(message, _) ->
          result_with_oracle(id, Failed, message, oracle)
        plan.EvaluationTimedOut(message, _) ->
          result_with_oracle(id, TimedOut, message, oracle)
        plan.EvaluationCancelled(message, _) ->
          result_with_oracle(id, Cancelled, message, oracle)
      },
    ]
    plan.Scenario(check) -> [run_check(id, check, budget, None, oracle)]
    plan.Exploration(check, _) -> {
      let matching =
        list.filter(options.replays, fn(replay) { replay.test_id == id })
      let replayed =
        list.map(matching, fn(replay) {
          run_check(
            id,
            check,
            budget,
            Some(plan.Replay(replay.tape, replay.generator_schema)),
            oracle,
          )
        })
      case options.replay_only, matching {
        True, [_, ..] -> replayed
        True, [] -> [
          result_with_oracle(
            id,
            Stale,
            "requested replay does not match this test id",
            oracle,
          ),
        ]
        False, _ ->
          list.append(replayed, [run_check(id, check, budget, None, oracle)])
      }
    }
    plan.Snapshot(name, schema, actual) -> [
      run_snapshot(id, name, schema, actual, budget, options),
    ]
    plan.Performance(name, samples, maximum_ms, callback) -> [
      run_performance(id, name, samples, maximum_ms, callback, budget),
    ]
  }
}

fn run_performance(
  id: evidence.TestId,
  name: String,
  samples: Int,
  maximum_ms: Int,
  callback: fn() -> Nil,
  budget: Budget,
) -> TestResult {
  performance_samples(id, name, samples, maximum_ms, callback, budget, [])
}

fn performance_samples(
  id: evidence.TestId,
  name: String,
  remaining: Int,
  maximum_ms: Int,
  callback: fn() -> Nil,
  budget: Budget,
  durations: List(Int),
) -> TestResult {
  case remaining <= 0 {
    True -> judge_performance(id, name, maximum_ms, durations)
    False ->
      case runtime.capture(callback, budget.timeout_ms) {
        plan.EvaluationPassed(duration_ms) ->
          performance_samples(
            id,
            name,
            remaining - 1,
            maximum_ms,
            callback,
            budget,
            [duration_ms, ..durations],
          )
        plan.EvaluationFailed(message, _) -> basic_result(id, Failed, message)
        plan.EvaluationTimedOut(message, _) ->
          basic_result(id, TimedOut, message)
        plan.EvaluationCancelled(message, _) ->
          basic_result(id, Cancelled, message)
      }
  }
}

fn judge_performance(
  id: evidence.TestId,
  name: String,
  maximum_ms: Int,
  durations: List(Int),
) -> TestResult {
  let sorted = list.sort(durations, int.compare)
  let rank = { list.length(sorted) * 95 + 99 } / 100 - 1
  let p95 = case list.drop(sorted, rank) {
    [value, ..] -> value
    [] -> 0
  }
  case p95 <= maximum_ms {
    True -> basic_result(id, Passed, "")
    False ->
      basic_result(
        id,
        PerformanceRegression,
        "performance "
          <> name
          <> " p95 "
          <> int.to_string(p95)
          <> "ms exceeded "
          <> int.to_string(maximum_ms)
          <> "ms across "
          <> int.to_string(list.length(durations))
          <> " samples",
      )
  }
}

fn run_snapshot(
  id: evidence.TestId,
  name: String,
  schema: String,
  actual: fn() -> String,
  budget: Budget,
  options: Options,
) -> TestResult {
  case runtime.attempt(actual, budget.timeout_ms) {
    runtime.AttemptFailed(message, _) -> basic_result(id, Failed, message)
    runtime.AttemptTimedOut(message, _) -> basic_result(id, TimedOut, message)
    runtime.AttemptCancelled(message, _) -> basic_result(id, Cancelled, message)
    runtime.AttemptPassed(rendered, _) ->
      judge_snapshot(id, name, schema, rendered, options)
  }
}

fn judge_snapshot(
  id: evidence.TestId,
  name: String,
  schema: String,
  rendered: String,
  options: Options,
) -> TestResult {
  let for_test =
    list.filter(options.snapshots, fn(snapshot) { snapshot.test_id == id })
  case list.find(for_test, fn(snapshot) { snapshot.schema == schema }) {
    Ok(snapshot) ->
      case snapshot.expected == rendered {
        True -> basic_result(id, Passed, "")
        False ->
          basic_result(
            id,
            Failed,
            "snapshot "
              <> name
              <> " did not match\nexpected: "
              <> snapshot.expected
              <> "\nactual: "
              <> rendered,
          )
      }
    Error(Nil) ->
      case for_test {
        [old, ..] ->
          basic_result(
            id,
            Stale,
            "snapshot renderer schema changed: expected "
              <> old.schema
              <> ", found "
              <> schema,
          )
        [] -> propose_snapshot(id, name, schema, rendered, options)
      }
  }
}

fn propose_snapshot(
  id: evidence.TestId,
  name: String,
  schema: String,
  rendered: String,
  options: Options,
) -> TestResult {
  case options.findings {
    None ->
      basic_result(
        id,
        Unsupported,
        "snapshot " <> name <> " has no approved observation",
      )
    Some(findings) -> {
      let identity_tape =
        { evidence.target_name(options.target) <> "\n" <> rendered }
        |> string.to_utf_codepoints
        |> list.map(string.utf_codepoint_to_int)
      let artifact_id = evidence.finding_id(id, schema, identity_tape)
      let proposal =
        corpus.new(
          id: artifact_id,
          test_id: id,
          draw_tape: [],
          generator_schema: schema,
          oracle: evidence.SnapshotOracle(name),
          targets: [options.target],
          rendering: rendered,
          created_ms: findings.created_ms,
        )
      case storage.put_inbox(findings.root, proposal) {
        Ok(_) -> snapshot_pending(id, name, artifact_id)
        Error(reason) ->
          case storage.load_inbox(findings.root, artifact_id) {
            Ok(existing) if existing == proposal ->
              snapshot_pending(id, name, artifact_id)
            _ ->
              basic_result(
                id,
                Failed,
                "could not store snapshot proposal: " <> reason,
              )
          }
      }
    }
  }
}

fn snapshot_pending(
  id: evidence.TestId,
  name: String,
  artifact_id: String,
) -> TestResult {
  basic_result(
    id,
    Unsupported,
    "snapshot " <> name <> " awaits review as " <> artifact_id,
  )
}

fn run_check(
  id: evidence.TestId,
  check: plan.Check,
  budget: Budget,
  replay: Option(plan.Replay),
  oracle: Option(OracleProvenance),
) -> TestResult {
  case
    runtime.attempt(
      fn() { check(runtime.capture, budget, replay) },
      budget.timeout_ms,
    )
  {
    runtime.AttemptPassed(result, _) -> from_check(result, id, oracle)
    runtime.AttemptFailed(message, _) ->
      result_with_oracle(id, Failed, message, oracle)
    runtime.AttemptTimedOut(message, _) ->
      result_with_oracle(id, TimedOut, message, oracle)
    runtime.AttemptCancelled(message, _) ->
      result_with_oracle(id, Cancelled, message, oracle)
  }
}

fn from_check(
  check: plan.CheckResult,
  id: evidence.TestId,
  oracle: Option(OracleProvenance),
) -> TestResult {
  case check {
    plan.CheckPassed(cases) ->
      TestResult(id, Passed, "", cases, 0, None, [], None, oracle)
    plan.CheckBudgetExhausted(message, cases) ->
      TestResult(id, BudgetExhausted, message, cases, 0, None, [], None, oracle)
    plan.CheckUnsupported(message) ->
      TestResult(id, Unsupported, message, 0, 0, None, [], None, oracle)
    plan.CheckFailed(message, witness, tape, schema, cases, shrinks) -> {
      let status = case oracle {
        Some(evidence.DifferentialOnly) -> Unjudged
        _ -> Failed
      }
      TestResult(
        id,
        status,
        message,
        cases,
        shrinks,
        witness,
        tape,
        schema,
        oracle,
      )
    }
    plan.CheckTimedOut(message, cases) ->
      TestResult(id, TimedOut, message, cases, 0, None, [], None, oracle)
    plan.CheckCancelled(message, cases) ->
      TestResult(id, Cancelled, message, cases, 0, None, [], None, oracle)
    plan.CheckStale(message) -> result_with_oracle(id, Stale, message, oracle)
  }
}

fn basic_result(
  id: evidence.TestId,
  status: Status,
  message: String,
) -> TestResult {
  result_with_oracle(id, status, message, None)
}

fn result_with_oracle(
  id: evidence.TestId,
  status: Status,
  message: String,
  oracle: Option(OracleProvenance),
) -> TestResult {
  TestResult(id, status, message, 0, 0, None, [], None, oracle)
}

fn startup_failure(entries: List(Entry), reason: String) -> TestResult {
  let id = case entries {
    [entry, ..] -> evidence.test_id(entry.package, entry.module, entry.function)
    [] -> evidence.test_id("smartest", "corpus", "startup")
  }
  basic_result(id, Stale, reason)
}

fn persist_finding(
  result: TestResult,
  target: Target,
  options: FindingOptions,
) -> TestResult {
  case result.status, result.generator_schema, result.witness {
    status, Some(schema), Some(rendering)
      if status == Failed || status == Unjudged
    -> {
      let id = evidence.finding_id(result.id, schema, result.draw_tape)
      let oracle = case result.oracle {
        Some(evidence.PropertyOracle("property")) ->
          evidence.PropertyOracle(evidence.test_id_to_string(result.id))
        Some(oracle) -> oracle
        None -> evidence.PropertyOracle(evidence.test_id_to_string(result.id))
      }
      let envelope =
        corpus.new(
          id: id,
          test_id: result.id,
          draw_tape: result.draw_tape,
          generator_schema: schema,
          oracle: oracle,
          targets: [target],
          rendering: rendering,
          created_ms: options.created_ms,
        )
      case storage.put_inbox(options.root, envelope) {
        Ok(_) -> result
        Error(reason) ->
          case storage.load_inbox(options.root, id) {
            Ok(existing)
              if existing.test_id == envelope.test_id
              && existing.draw_tape == envelope.draw_tape
              && existing.generator_schema == envelope.generator_schema
            -> result
            _ ->
              TestResult(
                ..result,
                message: result.message
                  <> "\ncould not store finding: "
                  <> reason,
              )
          }
      }
    }
    _, _, _ -> result
  }
}

fn inherited_metadata() -> plan.Metadata {
  plan.Metadata(
    name: None,
    tags: [],
    targets: [],
    budget: None,
    effect: None,
    oracle: None,
  )
}

fn merge_metadata(
  parent: plan.Metadata,
  child: plan.Metadata,
) -> plan.Metadata {
  plan.Metadata(
    name: child.name,
    tags: list.append(parent.tags, child.tags),
    targets: case child.targets {
      [] -> parent.targets
      targets -> targets
    },
    budget: choose(child.budget, parent.budget),
    effect: choose(child.effect, parent.effect),
    oracle: choose(child.oracle, parent.oracle),
  )
}

fn choose(first: Option(a), second: Option(a)) -> Option(a) {
  case first {
    Some(_) -> first
    None -> second
  }
}

fn option_or(value: Option(a), default: a) -> a {
  case value {
    Some(value) -> value
    None -> default
  }
}

fn is_snapshot_schema(schema: String) -> Bool {
  string.starts_with(schema, "smartest-snapshot-v1:")
}
