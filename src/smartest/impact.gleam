//// Pure changed-code impact index.
////
//// Runtime first-touch evidence is preferred. The static call graph is a
//// fallback, and an unmapped change conservatively selects every known test.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
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
  Index(touches: List(Touch), roots: List(StaticRoot), calls: List(CallEdge))
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
  Index(touches: [], roots: [], calls: [])
}

/// Records a runtime hit once. Repeated probes do not change ordering.
pub fn record_touch(index: Index, test_id: TestId, entity: EntityId) -> Index {
  let touch = Touch(test_id, entity)
  case list.contains(index.touches, touch) {
    True -> index
    False -> Index(..index, touches: list.append(index.touches, [touch]))
  }
}

/// Associates a test with a public/static entry entity.
pub fn record_static_root(
  index: Index,
  test_id: TestId,
  entity: EntityId,
) -> Index {
  let root = StaticRoot(test_id, entity)
  case list.contains(index.roots, root) {
    True -> index
    False -> Index(..index, roots: list.append(index.roots, [root]))
  }
}

/// Records a caller-to-callee edge from typed static analysis.
pub fn record_call(index: Index, caller: EntityId, callee: EntityId) -> Index {
  let edge = CallEdge(caller, callee)
  case list.contains(index.calls, edge) {
    True -> index
    False -> Index(..index, calls: list.append(index.calls, [edge]))
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
        [_, ..] as selected -> #(
          list.append(dynamic, selected),
          static,
          unmapped,
        )
        [] ->
          case static_tests(index, changed_entity) {
            [_, ..] as selected -> #(
              dynamic,
              list.append(static, selected),
              unmapped,
            )
            [] -> #(dynamic, static, list.append(unmapped, [changed_entity]))
          }
      }
    })
  let dynamic = unique(dynamic)
  let static = static |> unique |> without(dynamic)
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
  index.touches
  |> list.filter_map(fn(touch) {
    case touch.entity == changed {
      True -> Ok(touch.test_id)
      False -> Error(Nil)
    }
  })
  |> unique
}

fn static_tests(index: Index, changed: EntityId) -> List(TestId) {
  index.roots
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
  breadth_first(index.calls, [from], [], to, 0)
}

fn breadth_first(
  calls: List(CallEdge),
  frontier: List(EntityId),
  visited: List(EntityId),
  target: EntityId,
  distance: Int,
) -> Result(Int, Nil) {
  case list.contains(frontier, target), frontier {
    True, _ -> Ok(distance)
    False, [] -> Error(Nil)
    False, _ -> {
      let visited = unique(list.append(visited, frontier))
      let next =
        frontier
        |> list.flat_map(fn(caller) {
          calls
          |> list.filter_map(fn(edge) {
            case edge.caller == caller {
              True -> Ok(edge.callee)
              False -> Error(Nil)
            }
          })
        })
        |> unique
        |> list.filter(fn(entity) { !list.contains(visited, entity) })
      breadth_first(calls, next, visited, target, distance + 1)
    }
  }
}

fn without(values: List(a), excluded: List(a)) -> List(a) {
  list.filter(values, fn(value) { !list.contains(excluded, value) })
}

fn unique(values: List(a)) -> List(a) {
  values
  |> list.fold([], fn(accumulated, value) {
    case list.contains(accumulated, value) {
      True -> accumulated
      False -> list.append(accumulated, [value])
    }
  })
}
