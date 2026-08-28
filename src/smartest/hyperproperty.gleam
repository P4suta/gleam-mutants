//// Properties over pairs of executions/inputs.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/evidence
import smartest/gen.{type Generator}
import smartest/property
import smartest/testing.{type Test}

pub fn for_all(
  first: Generator(a),
  second: Generator(b),
  callback: fn(a, b) -> Nil,
) -> Test {
  property.for_all(gen.tuple2(first, second), fn(pair) {
    let #(first, second) = pair
    callback(first, second)
  })
  |> testing.with_oracle(evidence.PropertyOracle("hyperproperty"))
}
