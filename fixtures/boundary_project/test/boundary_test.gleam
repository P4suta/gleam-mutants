// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// These tests pass, and they deliberately leave survivors behind: nothing
// here calls `is_positive(0)`, and nothing pins `area(Square(_))` down.

import boundary.{Circle}
import gleam/option.{Some}
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn is_positive_test() {
  assert boundary.is_positive(5)
  assert !boundary.is_positive(-3)
}

pub fn abs_test() {
  assert boundary.abs(-4) == 4
  assert boundary.abs(3) == 3
}

pub fn area_test() {
  assert boundary.area(Circle(2)) == 12
}

pub fn maybe_double_test() {
  assert boundary.maybe_double(Some(2)) == Ok(4)
}

pub fn uses_helper_test() {
  assert boundary.uses_helper(1) == 2
}

pub fn applies_test() {
  assert boundary.applies(fn(x) { x * 2 }, 3) == 6
}

/// One part, so the separator is never printed and `"; " -> ""` survives.
pub fn join_test() {
  assert boundary.join(["only"]) == "only"
}
