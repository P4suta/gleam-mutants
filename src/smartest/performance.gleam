//// Statistical performance expectations kept distinct from correctness.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import smartest/internal/plan
import smartest/testing.{type Test}

/// Measures a declared-pure callback repeatedly and compares its p95 latency.
/// Apply `testing.with_effect` when the operation needs explicit capabilities.
pub fn expect_p95_under(
  name: String,
  samples samples: Int,
  maximum_ms maximum_ms: Int,
  run run: fn() -> Nil,
) -> Test {
  plan.performance(name, int.max(1, samples), int.max(0, maximum_ms), run)
}
