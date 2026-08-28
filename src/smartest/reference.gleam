//// Comparison against an independently supplied reference implementation.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/evidence
import smartest/gen.{type Generator}
import smartest/property
import smartest/testing.{type Test}

pub fn compare(
  generator: Generator(input),
  sut sut: fn(input) -> output,
  oracle oracle: fn(input) -> reference_output,
  equivalent equivalent: fn(output, reference_output) -> Bool,
) -> Test {
  property.for_all(generator, fn(input) {
    case equivalent(sut(input), oracle(input)) {
      True -> Nil
      False -> panic as "reference implementation disagreed with the SUT"
    }
  })
  |> testing.with_oracle(evidence.ExternalOracle("reference implementation"))
}
