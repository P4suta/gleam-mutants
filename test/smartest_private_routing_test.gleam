// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import glance
import gleam/list
import gleam/string
import gleam_mutants/core/mutant.{type Mutant, Mutant}
import gleam_mutants/core/operator
import gleam_mutants/core/span
import gleam_mutants/suggest/select

const source = "fn hidden(x: Int) -> Int { x + 1 }\n\nfn middle(x: Int) -> Int { hidden(x) }\n\npub fn direct(x: Int) -> Int { hidden(x) + 0 }\n\npub fn farther(x: Int) -> Int { middle(x) }\n\nfn orphan(x: Int) -> Int { x - 1 }\n"

pub fn smartest_private_mutant_routes_through_the_nearest_public_caller_test() {
  let assert Ok(module) = glance.module(source)
  let hidden = at("+ 1", "hidden-mutant")
  let own = at("+ 0", "direct-mutant")
  let #(targets, _) = select.assign(module, [hidden, own])
  let routed = select.route_private(module, targets)

  let assert [target] = routed.targets
  assert target.function.name == "direct"
  assert list.map(target.mutants, fn(item) { item.id })
    == ["hidden-mutant", "direct-mutant"]
  assert routed.routes == [select.PublicRoute("hidden", "direct", distance: 1)]
  assert routed.unreachable == []
}

pub fn smartest_private_mutant_uses_a_transitive_public_caller_test() {
  let without_direct =
    "fn hidden(x: Int) -> Int { x + 1 }\n\nfn middle(x: Int) -> Int { hidden(x) }\n\npub fn api(x: Int) -> Int { middle(x) }\n"
  let assert Ok(module) = glance.module(without_direct)
  let mutation = at_in(without_direct, "+ 1", "hidden-mutant")
  let #(targets, _) = select.assign(module, [mutation])
  let routed = select.route_private(module, targets)

  let assert [target] = routed.targets
  assert target.function.name == "api"
  assert routed.routes == [select.PublicRoute("hidden", "api", distance: 2)]
}

pub fn smartest_unreachable_private_mutant_is_not_silently_dropped_test() {
  let assert Ok(module) = glance.module(source)
  let orphan = at("- 1", "orphan-mutant")
  let #(targets, _) = select.assign(module, [orphan])
  let routed = select.route_private(module, targets)

  assert routed.targets == []
  let assert [unreachable] = routed.unreachable
  assert unreachable.function.name == "orphan"
  assert list.map(unreachable.mutants, fn(item) { item.id })
    == ["orphan-mutant"]
}

pub fn smartest_call_graph_cycles_terminate_when_routing_private_mutants_test() {
  let cyclic =
    "fn first(x: Int) -> Int { second(x) }\n\nfn second(x: Int) -> Int { first(x) + 1 }\n\npub fn api(x: Int) -> Int { first(x) }\n"
  let assert Ok(module) = glance.module(cyclic)
  let mutation = at_in(cyclic, "+ 1", "cycle-mutant")
  let #(targets, _) = select.assign(module, [mutation])
  let routed = select.route_private(module, targets)

  let assert [target] = routed.targets
  assert target.function.name == "api"
  assert routed.routes == [select.PublicRoute("second", "api", distance: 2)]
}

fn at(needle: String, id: String) -> Mutant {
  at_in(source, needle, id)
}

fn at_in(code: String, needle: String, id: String) -> Mutant {
  let assert Ok(#(before, _)) = string.split_once(code, needle)
  let start = string.byte_size(before)
  Mutant(
    id: id,
    display_id: id,
    path: "src/demo.gleam",
    operator: operator.IntegerArithmetic,
    operator_version: 1,
    source_digest: "source",
    span: span.unsafe_new(start, start + string.byte_size(needle)),
    original_digest: "original",
    replacement_digest: "replacement",
    original: needle,
    replacement: "0",
    line: 1,
    column: 1,
  )
}
