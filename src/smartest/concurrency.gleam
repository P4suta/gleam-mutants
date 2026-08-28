//// Bounded, replayable schedule exploration.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/string
import smartest/evidence.{type Capability}
import smartest/gen.{type Generator}
import smartest/property
import smartest/testing.{type Test}

/// Each integer selects the actor allowed to take the next logical step.
pub opaque type Schedule {
  Schedule(choices: List(Int))
}

pub fn choices(schedule: Schedule) -> List(Int) {
  schedule.choices
}

pub fn schedules(actor_count: Int, max_steps: Int) -> Generator(Schedule) {
  let actors = int.max(1, actor_count)
  gen.list_with_max(gen.int_range(0, actors - 1), int.max(0, max_steps))
  |> gen.map(Schedule)
  |> gen.named(
    "schedule(actors:"
    <> int.to_string(actors)
    <> ",steps:"
    <> int.to_string(int.max(0, max_steps))
    <> ")",
  )
  |> gen.rendered(fn(schedule) { string.inspect(schedule.choices) })
}

/// Explores schedules through the shared tape/shrink/replay engine. The user
/// supplies the actual scheduler hook or deterministic simulation boundary.
pub fn check(
  actor_count actor_count: Int,
  max_steps max_steps: Int,
  capabilities capabilities: List(Capability),
  run run: fn(Schedule) -> Result(Nil, String),
) -> Test {
  let value =
    property.for_all(schedules(actor_count, max_steps), fn(schedule) {
      case run(schedule) {
        Ok(Nil) -> Nil
        Error(reason) -> panic as reason
      }
    })
    |> testing.with_oracle(evidence.ModelOracle("concurrency schedule"))
  case capabilities {
    [] -> value
    capabilities -> testing.with_effect(value, evidence.Declared(capabilities))
  }
}
