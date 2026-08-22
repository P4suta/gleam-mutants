// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mutants/core/mutant.{type Mutant}

pub type Selection {
  All
  Changed
  Single(prefix: String)
}

pub type MutationPlan {
  MutationPlan(selection: Selection, mutants: List(Mutant))
}

pub fn build(
  mutants: List(Mutant),
  changed: Bool,
  prefix: Option(String),
) -> Result(MutationPlan, String) {
  case prefix {
    None ->
      Ok(MutationPlan(
        selection: case changed {
          True -> Changed
          False -> All
        },
        mutants: mutants,
      ))
    Some(prefix) -> {
      let matches =
        list.filter(mutants, fn(mutant) {
          string.starts_with(mutant.id, prefix)
          || string.starts_with(mutant.display_id, prefix)
        })
      case matches {
        [] ->
          Error("GMU4004: no mutant matches prefix " <> string.inspect(prefix))
        [mutant] -> Ok(MutationPlan(Single(prefix), [mutant]))
        _ ->
          Error(
            "GMU4005: mutant prefix is ambiguous: " <> string.inspect(prefix),
          )
      }
    }
  }
}

pub fn mutants(plan: MutationPlan) -> List(Mutant) {
  plan.mutants
}

pub fn mode(plan: MutationPlan) -> String {
  case plan.selection {
    All -> "all"
    Changed -> "changed"
    Single(_) -> "mutant"
  }
}
