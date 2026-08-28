//// Finite, capability-gated fault matrices.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import smartest/evidence.{type Capability}
import smartest/scenario
import smartest/testing.{type Test}

/// Builds one resource-safe scenario per declared fault. No setup, teardown,
/// or fault callback runs during construction. Names are explicit so stable
/// test ids never depend on executing a renderer while building the plan.
pub fn for_each(
  name: String,
  faults: List(#(String, fault)),
  capabilities capabilities: List(Capability),
  run run: fn(fault) -> Nil,
) -> Test {
  let tests =
    list.map(faults, fn(named_fault) {
      let #(fault_name, fault) = named_fault
      let resource =
        scenario.resource(
          setup: fn() { Ok(fault) },
          teardown: fn(_) { Ok(Nil) },
          capabilities: capabilities,
        )
      testing.named(fault_name, scenario.with_resource(resource, run))
    })
  testing.suite(name, tests)
}
