//// Oracle-free differential observation.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/evidence
import smartest/gen.{type Generator}
import smartest/property
import smartest/testing.{type Test}

/// Searches for a divergence without declaring either implementation correct.
/// A found witness is rendered as `UNJUDGED` and enters review without failing
/// the default lane.
pub fn compare(
  generator: Generator(input),
  left left: fn(input) -> left_output,
  right right: fn(input) -> right_output,
  equivalent equivalent: fn(left_output, right_output) -> Bool,
) -> Test {
  property.for_all(generator, fn(input) {
    case equivalent(left(input), right(input)) {
      True -> Nil
      False -> panic as "implementations diverged without an independent oracle"
    }
  })
  |> testing.with_oracle(evidence.DifferentialOnly)
}
