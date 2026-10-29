// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{None, Some}
import gleam_mutants/error
import gleam_mutants/types

pub fn interruption_preserves_operation_failure_context_test() {
  list.each([130, 143], fn(code) {
    let message =
      error.interruption_message(code) <> "; snapshot cleanup failed"
    assert error.from_message(types.Running, message)
      == types.Interrupted(code, message)
  })
  assert error.interruption_code("GMU3005: interrupted 129") == None
  assert error.interruption_code("GMU3005: interrupted unknown") == None
}

pub fn failure_codes_require_four_ascii_digits_test() {
  assert error.from_message(types.Listing, "GMU4001: empty selection")
    == types.Failure(types.Listing, Some("GMU4001"), "GMU4001: empty selection")
  list.each(
    ["GMU+001: invalid", "GMU-001: invalid", "GMU123: short", "uncoded failure"],
    fn(message) {
      assert error.from_message(types.Validating, message)
        == types.Failure(types.Validating, None, message)
    },
  )
}
