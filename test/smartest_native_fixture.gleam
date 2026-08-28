// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest.{type Test}
import smartest/gen
import smartest/property
import smartest/testing

pub fn native_example_test() -> Test {
  testing.example(fn() {
    assert 2 * 3 == 6
  })
}

pub fn native_property_test() -> Test {
  property.for_all(gen.int(), fn(value) {
    assert value - value == 0
  })
}
