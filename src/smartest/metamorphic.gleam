//// Metamorphic relations over the deterministic property engine.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/evidence
import smartest/gen.{type Generator}
import smartest/property
import smartest/testing.{type Test}

/// Checks a relation between an original observation and a derived follow-up.
pub fn relation(
  generator: Generator(input),
  original original: fn(input) -> observation,
  transform transform: fn(input) -> follow_up,
  follow_up follow_up: fn(follow_up) -> observation,
  holds holds: fn(observation, observation) -> Bool,
) -> Test {
  property.for_all(generator, fn(input) {
    let before = original(input)
    let after = follow_up(transform(input))
    case holds(before, after) {
      True -> Nil
      False -> panic as "metamorphic relation failed"
    }
  })
  |> testing.with_oracle(evidence.PropertyOracle("metamorphic relation"))
}
