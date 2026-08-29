//// Pure changed-code impact index.
////
//// Runtime first-touch evidence is preferred. The static call graph is a
//// fallback, and an unmapped change conservatively selects every known test.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import smartest/evidence.{type TestId}

/// A target-independent semantic code identity.
pub opaque type EntityId {
  EntityId(package: String, module: String, name: String)
}

type Touch {
  Touch(test_id: TestId, entity: EntityId)
}

type StaticRoot {
  StaticRoot(test_id: TestId, entity: EntityId)
}

type CallEdge {
  CallEdge(caller: EntityId, callee: EntityId)
}

/// Immutable dynamic and static impact evidence.
pub opaque type Index {
  Index(
    touches: Dict(EntityId, List(TestId)),
    touch_seen: Set(Touch),
    roots: List(StaticRoot),
    root_seen: Set(StaticRoot),
    calls: Dict(EntityId, List(EntityId)),
    call_seen: Set(CallEdge),
  )
}

/// Why each affected test was selected, plus any conservative mapping gaps.
pub type Selection {
  Selection(
    tests: List(TestId),
    dynamic: List(TestId),
    static: List(TestId),
    unmapped: List(EntityId),
  )
}

pub fn entity(package: String, module: String, name: String) -> EntityId {
  EntityId(package, module, name)
}

pub fn new() -> Index {
  Index(
    touches: dict.new(),
    touch_seen: set.new(),
    roots: [],
    root_seen: set.new(),
    calls: dict.new(),
    call_seen: set.new(),
  )
}

/// Records a runtime hit once. Repeated probes do not change ordering.
pub fn record_touch(index: Index, test_id: TestId, entity: EntityId) -> Index {
  let touch = Touch(test_id, entity)
  case set.contains(index.touch_seen, touch) {
    True -> index
    False -> {
      let existing = dict.get(index.touches, entity) |> result.unwrap([])
      Index(
        ..index,
        touches: dict.insert(index.touches, entity, [test_id, ..existing]),
        touch_seen: set.insert(index.touch_seen, touch),
      )
    }
  }
}

/// Associates a test with a public/static entry entity.
pub fn record_static_root(
  index: Index,
  test_id: TestId,
  entity: EntityId,
) -> Index {
  let root = StaticRoot(test_id, entity)
  case set.contains(index.root_seen, root) {
    True -> index
    False ->
      Index(
        ..index,
        roots: [root, ..index.roots],
        root_seen: set.insert(index.root_seen, root),
      )
  }
}

/// Records a caller-to-callee edge from typed static analysis.
pub fn record_call(index: Index, caller: EntityId, callee: EntityId) -> Index {
  let edge = CallEdge(caller, callee)
  case set.contains(index.call_seen, edge) {
    True -> index
    False -> {
      let outgoing = dict.get(index.calls, caller) |> result.unwrap([])
      Index(
        ..index,
        calls: dict.insert(index.calls, caller, [callee, ..outgoing]),
        call_seen: set.insert(index.call_seen, edge),
      )
    }
  }
}

/// Selects affected tests in dynamic, nearest-static, then all-test order.
pub fn select(
  index: Index,
  changed changed: List(EntityId),
  all_tests all_tests: List(TestId),
) -> Selection {
  let #(dynamic, static, unmapped) =
    changed
    |> unique
    |> list.fold(#([], [], []), fn(accumulator, changed_entity) {
      let #(dynamic, static, unmapped) = accumulator
      case dynamic_tests(index, changed_entity) {
        [_, ..] as selected -> #([selected, ..dynamic], static, unmapped)
        [] ->
          case static_tests(index, changed_entity) {
            [_, ..] as selected -> #(dynamic, [selected, ..static], unmapped)
            [] -> #(dynamic, static, [changed_entity, ..unmapped])
          }
      }
    })
  let dynamic = dynamic |> list.reverse |> list.flatten |> unique
  let static =
    static |> list.reverse |> list.flatten |> unique |> without(dynamic)
  let unmapped = list.reverse(unmapped)
  let fallback = case unmapped {
    [] -> []
    [_, ..] -> all_tests
  }
  Selection(
    tests: unique(list.flatten([dynamic, static, fallback])),
    dynamic: dynamic,
    static: static,
    unmapped: unmapped,
  )
}

fn dynamic_tests(index: Index, changed: EntityId) -> List(TestId) {
  dict.get(index.touches, changed)
  |> result.map(list.reverse)
  |> result.unwrap([])
}

fn static_tests(index: Index, changed: EntityId) -> List(TestId) {
  index.roots
  |> list.reverse
  |> list.index_map(fn(root, order) { #(root, order) })
  |> list.filter_map(fn(indexed) {
    let #(root, order) = indexed
    case shortest_distance(index, from: root.entity, to: changed) {
      Ok(distance) -> Ok(#(root.test_id, distance, order))
      Error(_) -> Error(Nil)
    }
  })
  |> list.sort(fn(left, right) {
    case left.1 == right.1 {
      True -> int.compare(left.2, right.2)
      False -> int.compare(left.1, right.1)
    }
  })
  |> list.map(fn(candidate) { candidate.0 })
  |> unique
}

/// Returns the shortest caller-to-callee distance in the static graph.
pub fn shortest_distance(
  index: Index,
  from from: EntityId,
  to to: EntityId,
) -> Result(Int, Nil) {
  breadth_first(index.calls, [from], [], set.from_list([from]), to, 0)
}

fn breadth_first(
  calls: Dict(EntityId, List(EntityId)),
  frontier: List(EntityId),
  next: List(EntityId),
  visited: Set(EntityId),
  target: EntityId,
  distance: Int,
) -> Result(Int, Nil) {
  case frontier {
    [] ->
      case next {
        [] -> Error(Nil)
        _ ->
          breadth_first(
            calls,
            list.reverse(next),
            [],
            visited,
            target,
            distance + 1,
          )
      }
    [entity, ..] if entity == target -> Ok(distance)
    [entity, ..rest] -> {
      let neighbours = dict.get(calls, entity) |> result.unwrap([])
      let #(visited, next) =
        list.fold(neighbours, #(visited, next), fn(state, neighbour) {
          case set.contains(state.0, neighbour) {
            True -> state
            False -> #(set.insert(state.0, neighbour), [neighbour, ..state.1])
          }
        })
      breadth_first(calls, rest, next, visited, target, distance)
    }
  }
}

fn without(values: List(a), excluded: List(a)) -> List(a) {
  let excluded = set.from_list(excluded)
  list.filter(values, fn(value) { !set.contains(excluded, value) })
}

fn unique(values: List(a)) -> List(a) {
  values
  |> list.fold(#(set.new(), []), fn(state, value) {
    case set.contains(state.0, value) {
      True -> state
      False -> #(set.insert(state.0, value), [value, ..state.1])
    }
  })
  |> fn(state) { list.reverse(state.1) }
}
