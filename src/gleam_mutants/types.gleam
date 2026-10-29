//// Public mutation-testing options and results.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{type Option}
import gleam_mutants/core/span

/// A validated, zero-based, end-exclusive byte span.
pub type Span =
  span.Span

pub type Operator {
  BooleanLiteral
  BooleanNegation
  BooleanConnective
  Equality
  ComparisonBoundary
  IntegerArithmetic
  FloatArithmetic
  IntegerNeutral
  FloatNeutral
  StringNeutral
  ListNeutral
  OptionNeutral
  PipelineStageDeletion
  ConcatenationOperand
  IntegerNegation
}

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

pub type Mutant {
  Mutant(
    id: String,
    display_id: String,
    path: String,
    operator: Operator,
    operator_version: Int,
    source_digest: String,
    span: Span,
    original_digest: String,
    replacement_digest: String,
    original: String,
    replacement: String,
    line: Int,
    column: Int,
  )
}

pub type Score {
  Score(
    total: Int,
    killed: Int,
    timed_out: Int,
    survived: Int,
    errors: Int,
    percent: Float,
  )
}

pub type RejectedMutant {
  RejectedMutant(mutant: Mutant, reason: String, diagnostic: String)
}

pub type MutantResult {
  MutantResult(
    mutant: Mutant,
    outcomes: List(RuntimeOutcome),
    aggregate: Outcome,
  )
}

pub type RunReport {
  RunReport(
    run_id: String,
    started_ms: Int,
    duration_ms: Int,
    workspace_digest: String,
    matrix: Bool,
    selection: SelectionSummary,
    policy: PolicySummary,
    results: List(MutantResult),
    rejected: List(RejectedMutant),
    score: Score,
  )
}

pub type SelectionSummary {
  SelectionSummary(
    mode: String,
    files_selected: Int,
    candidates: Int,
    executed: Int,
    compile_errors: Int,
    skipped: Bool,
    reason: Option(String),
  )
}

pub type PolicySummary {
  PolicySummary(
    strict: Bool,
    minimum_score: Float,
    require_mutants: Bool,
    failure: Option(String),
  )
}

pub type TestSelection {
  TestSelectionAuto
  TestSelectionFull
}

/// Workspace configuration overrides; absent values inherit gleam.toml.
pub type Options {
  Options(
    matrix: Bool,
    changed: Option(String),
    includes: List(String),
    operators: Option(List(Operator)),
    strict: Option(Bool),
    jobs: Option(Int),
    test_selection: Option(TestSelection),
    timeout_ms: Option(Int),
    test_command: Option(List(String)),
    mutant_prefix: Option(String),
    write_reports: Bool,
  )
}

pub type Validation {
  Unvalidated
  CompilerValidated
}

pub type Catalog {
  Catalog(
    mutants: List(Mutant),
    rejected: List(RejectedMutant),
    validation: Validation,
  )
}

pub type Operation {
  Listing
  Validating
  Running
}

/// Quality-policy failures remain in RunReport rather than becoming tool errors.
pub type MutationError {
  InvalidOptions(message: String)
  Failure(operation: Operation, code: Option(String), message: String)
  Interrupted(exit_code: Int, message: String)
}

/// The first byte of the original expression.
pub fn start_byte(mutant: Mutant) -> Int {
  span.start(mutant.span)
}

/// The byte immediately after the original expression.
pub fn end_byte(mutant: Mutant) -> Int {
  span.end(mutant.span)
}
