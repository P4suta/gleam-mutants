//// Snapshot expectations over explicit renderers.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/internal/plan
import smartest/observe.{type Renderer}
import smartest/testing.{type Test}

/// Builds a lazy snapshot expectation. `actual` is first invoked by the runner;
/// construction never records current behaviour as an oracle.
pub fn expect(
  name: String,
  actual actual: fn() -> a,
  renderer renderer: Renderer(a),
  expected expected: String,
) -> Test {
  testing.example(fn() {
    let rendered = observe.render(renderer, actual())
    case rendered == expected {
      True -> Nil
      False ->
        panic as {
          "snapshot "
          <> name
          <> " did not match\nexpected: "
          <> expected
          <> "\nactual: "
          <> rendered
        }
    }
  })
}

/// Proposes or replays a native reviewed snapshot.
///
/// The renderer schema is explicit so a changed observation format makes old
/// evidence stale. Construction performs no rendering or filesystem access.
pub fn review(
  name: String,
  renderer_schema renderer_schema: String,
  actual actual: fn() -> a,
  renderer renderer: Renderer(a),
) -> Test {
  plan.snapshot(name, "smartest-snapshot-v1:" <> renderer_schema, fn() {
    observe.render(renderer, actual())
  })
}
