// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{None, Some}
import gleam_mutants/api
import gleam_mutants/types

pub fn api_defaults_require_explicit_report_writes_test() {
  let options = api.default_options()
  assert !options.write_reports
  assert options.jobs == None
}

pub fn api_rejects_invalid_options_before_reading_the_workspace_test() {
  list.each([0, -1, 33], fn(jobs) {
    let options = types.Options(..api.default_options(), jobs: Some(jobs))
    let assert Error(types.InvalidOptions(_)) =
      api.list_mutants("/does-not-exist", options)
    Nil
  })
  list.each([0, 99, 86_400_001], fn(timeout) {
    let assert Error(types.InvalidOptions(_)) =
      api.run(
        "/does-not-exist",
        types.Options(..api.default_options(), timeout_ms: Some(timeout)),
      )
    Nil
  })
  list.each([[], ["", "ignored"]], fn(command) {
    let assert Error(types.InvalidOptions(_)) =
      api.validate_mutants(
        "/does-not-exist",
        types.Options(..api.default_options(), test_command: Some(command)),
      )
    Nil
  })
  let assert Error(types.InvalidOptions(_)) =
    api.list_mutants("", api.default_options())
}

pub fn api_discovery_returns_typed_candidates_without_running_tests_test() {
  let options =
    types.Options(
      ..api.default_options(),
      test_command: Some(["node", "-e", "process.exit(91)"]),
    )
  let assert Ok(catalog) = api.list_mutants("fixtures/basic_project", options)
  assert catalog.validation == types.Unvalidated
  assert catalog.rejected == []
  assert catalog.mutants != []
  assert list.all(catalog.mutants, fn(mutant) {
    types.start_byte(mutant) < types.end_byte(mutant)
  })
}
