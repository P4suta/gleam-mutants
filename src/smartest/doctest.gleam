//// Compiler-checked documentation examples as lazy Smartest tests.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/evidence
import smartest/observe.{type Renderer}
import smartest/testing.{type Test}

/// Checks one documented value using an explicit renderer and equality rule.
///
/// Both sides are normal Gleam values, so the compiler type-checks the example
/// and no source evaluator or target-specific reflection is required.
pub fn expect(
  name: String,
  actual actual: fn() -> a,
  expected expected: a,
  equal equal: fn(a, a) -> Bool,
  renderer renderer: Renderer(a),
) -> Test {
  testing.named(
    name,
    testing.example(fn() {
      let observed = actual()
      case equal(observed, expected) {
        True -> Nil
        False ->
          panic as {
            "doctest "
            <> name
            <> " did not match\nexpected: "
            <> observe.render(renderer, expected)
            <> "\nactual: "
            <> observe.render(renderer, observed)
          }
      }
    }),
  )
  |> testing.with_oracle(evidence.ExampleOracle)
}
