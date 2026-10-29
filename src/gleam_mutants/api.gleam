//// Workspace-level mutation testing without terminal output or host exit.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{None, Some}
import gleam/result
import gleam_mutants/core/operator
import gleam_mutants/engine
import gleam_mutants/error
import gleam_mutants/platform
import gleam_mutants/report
import gleam_mutants/types.{
  type Catalog, type MutationError, type Options, type RunReport, Catalog,
  CompilerValidated, InvalidOptions, Listing, Options, Running, Unvalidated,
  Validating,
}

/// Overrides inherit gleam.toml; reports stay in memory until write_reports is True.
pub fn default_options() -> Options {
  Options(
    matrix: False,
    changed: None,
    includes: [],
    operators: None,
    strict: None,
    jobs: None,
    test_selection: None,
    timeout_ms: None,
    test_command: None,
    mutant_prefix: None,
    write_reports: False,
  )
}

/// Discovers candidates without building the project or running its tests.
pub fn list_mutants(
  root: String,
  options: Options,
) -> Result(Catalog, MutationError) {
  catalog(root, options, False)
}

/// Compiler-checks candidates without running the project's test suite.
pub fn validate_mutants(
  root: String,
  options: Options,
) -> Result(Catalog, MutationError) {
  catalog(root, options, True)
}

fn catalog(
  root: String,
  options: Options,
  validate: Bool,
) -> Result(Catalog, MutationError) {
  use _ <- result.try(validate_options(root, options))
  let operation = case validate {
    True -> Validating
    False -> Listing
  }
  use output <- result.map(
    engine.list_mutants(
      platform.resolve_path(root),
      execution_options(options),
      validate,
    )
    |> result.map_error(error.from_message(operation, _)),
  )
  Catalog(output.mutants, output.rejected, case output.validated {
    True -> CompilerValidated
    False -> Unvalidated
  })
}

/// Runs baseline checks and mutations in disposable snapshots.
/// A completed run that misses its quality policy remains an Ok report.
pub fn run(root: String, options: Options) -> Result(RunReport, MutationError) {
  use _ <- result.try(validate_options(root, options))
  engine.run(platform.resolve_path(root), execution_options(options))
  |> result.map(fn(output) { output.report })
  |> result.map_error(error.from_message(Running, _))
}

/// Serializes the lossless native report using the CLI's report format.
pub fn report_json(value: RunReport) -> String {
  report.to_json(value)
}

/// The stable configuration name of an operator.
pub fn operator_name(value: types.Operator) -> String {
  operator.name(value)
}

fn execution_options(options: Options) -> engine.Options {
  engine.Options(
    ..engine.default_options(),
    matrix: options.matrix,
    changed: options.changed,
    includes: options.includes,
    operators: options.operators,
    strict: options.strict,
    jobs: options.jobs,
    test_selection: options.test_selection,
    timeout_ms: options.timeout_ms,
    test_command: options.test_command,
    mutant_prefix: options.mutant_prefix,
    report_formats: case options.write_reports {
      True -> None
      False -> Some([])
    },
    report_history: case options.write_reports {
      True -> None
      False -> Some(False)
    },
    annotations: False,
    json: True,
  )
}

fn validate_options(
  root: String,
  options: Options,
) -> Result(Nil, MutationError) {
  case root {
    "" -> Error(InvalidOptions("workspace root cannot be empty"))
    _ ->
      engine.validate_options(execution_options(options))
      |> result.map_error(InvalidOptions)
  }
}
