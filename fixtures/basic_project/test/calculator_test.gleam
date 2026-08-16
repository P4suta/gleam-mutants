// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import calculator
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn add_test() {
  assert calculator.add(2, 3) == 5
}

pub fn below_limit_test() {
  assert calculator.below_limit(9)
  assert !calculator.below_limit(10)
}

pub fn enabled_test() {
  assert calculator.enabled()
}
