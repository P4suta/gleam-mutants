// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Pairing mutants with the functions that enclose them, and deciding which
// return types the differential probe can compare at all.

import glance
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/span

/// A parsed function together with the mutants that live inside its span.
pub type FunctionTarget {
  FunctionTarget(function: glance.Function, mutants: List(Mutant))
}

/// The public entry point selected for mutants inside a private function.
///
/// `distance` is the number of local call edges between the public function
/// and the private function. It is kept explicit so reports can explain why a
/// particular public boundary was selected.
pub type PublicRoute {
  PublicRoute(private_function: String, public_function: String, distance: Int)
}

/// Result of moving private-function mutants to reachable public boundaries.
///
/// Unreachable private targets are retained separately. Losing them would
/// incorrectly turn an unsupported exploration boundary into evidence that a
/// mutant had been checked.
pub type PrivateRouting {
  PrivateRouting(
    targets: List(FunctionTarget),
    routes: List(PublicRoute),
    unreachable: List(FunctionTarget),
  )
}

/// Groups mutants by the function whose byte span encloses them.
///
/// A mutant belongs to a function when its span lies within the function's
/// location, boundaries included. Glance functions never nest, so at most one
/// function can claim a mutant. Both public and private functions are returned
/// — the caller decides which of them are worth probing — in source order,
/// each carrying its mutants in the order they were supplied. Functions
/// without mutants are omitted, and mutants that fall outside every function,
/// such as those in module constants, are returned in the second element.
pub fn assign(
  module: glance.Module,
  mutants: List(Mutant),
) -> #(List(FunctionTarget), List(Mutant)) {
  let functions = source_order(module)
  let targets =
    list.filter_map(functions, fn(function) {
      case list.filter(mutants, encloses(function, _)) {
        [] -> Error(Nil)
        enclosed -> Ok(FunctionTarget(function, enclosed))
      }
    })
  let outside =
    list.filter(mutants, fn(candidate) {
      !list.any(functions, encloses(_, candidate))
    })
  #(targets, outside)
}

/// Routes private-function mutants through the nearest public local caller.
///
/// The call graph is derived from the parsed module and searched breadth-first
/// from every public function. Cycles are harmless, ties use source order, and
/// mutants keep their input order when they are merged into a public target.
pub fn route_private(
  module: glance.Module,
  targets: List(FunctionTarget),
) -> PrivateRouting {
  let functions = source_order(module)
  let local_names = list.map(functions, fn(function) { function.name })
  let edges =
    list.map(functions, fn(function) {
      #(
        function.name,
        function.body
          |> calls_in_statements
          |> list.filter(fn(name) { list.contains(local_names, name) })
          |> list.unique,
      )
    })
  let public_functions =
    list.filter(functions, fn(function) { function.publicity == glance.Public })

  let routes =
    list.filter_map(targets, fn(target) {
      case target.function.publicity {
        glance.Public -> Error(Nil)
        glance.Private ->
          case nearest_public(public_functions, edges, target.function.name) {
            Ok(#(function, distance)) ->
              Ok(PublicRoute(target.function.name, function.name, distance))
            Error(Nil) -> Error(Nil)
          }
      }
    })

  let unreachable =
    list.filter(targets, fn(target) {
      target.function.publicity == glance.Private
      && !list.any(routes, fn(route) {
        route.private_function == target.function.name
      })
    })

  let routed_targets =
    list.filter_map(public_functions, fn(function) {
      let mutants =
        list.flat_map(targets, fn(target) {
          case target.function.publicity {
            glance.Public if target.function.name == function.name ->
              target.mutants
            glance.Private ->
              case
                list.any(routes, fn(route) {
                  route.private_function == target.function.name
                  && route.public_function == function.name
                })
              {
                True -> target.mutants
                False -> []
              }
            _ -> []
          }
        })
      case mutants {
        [] -> Error(Nil)
        _ -> Ok(FunctionTarget(function, mutants))
      }
    })

  PrivateRouting(routed_targets, routes, unreachable)
}

/// Reports whether a function's result can be compared value-by-value.
///
/// Functions are opaque at runtime, so any return type that is a function, or
/// that hides one inside a tuple, list, option or result, cannot take part in
/// a differential comparison. An unannotated return is assumed comparable.
pub fn comparable_return(function: glance.Function) -> Bool {
  case function.return {
    None -> True
    Some(annotation) -> !holds_function(annotation)
  }
}

fn source_order(module: glance.Module) -> List(glance.Function) {
  module.functions
  |> list.map(fn(definition) { definition.definition })
  |> list.sort(fn(a, b) { int.compare(a.location.start, b.location.start) })
}

fn encloses(function: glance.Function, candidate: Mutant) -> Bool {
  let glance.Span(start, end) = function.location
  span.start(candidate.span) >= start && span.end(candidate.span) <= end
}

fn holds_function(annotation: glance.Type) -> Bool {
  case annotation {
    glance.FunctionType(..) -> True
    glance.NamedType(parameters: parameters, ..) ->
      list.any(parameters, holds_function)
    glance.TupleType(elements: elements, ..) ->
      list.any(elements, holds_function)
    glance.VariableType(..) | glance.HoleType(..) -> False
  }
}

fn nearest_public(
  public_functions: List(glance.Function),
  edges: List(#(String, List(String))),
  target: String,
) -> Result(#(glance.Function, Int), Nil) {
  let candidates =
    public_functions
    |> list.filter_map(fn(function) {
      case distance(edges, function.name, target) {
        Ok(distance) -> Ok(#(function, distance))
        Error(Nil) -> Error(Nil)
      }
    })
  case candidates {
    [] -> Error(Nil)
    [first, ..rest] -> Ok(list.fold(rest, first, nearer_route))
  }
}

fn nearer_route(
  current: #(glance.Function, Int),
  candidate: #(glance.Function, Int),
) -> #(glance.Function, Int) {
  case candidate.1 < current.1 {
    True -> candidate
    False -> current
  }
}

fn distance(
  edges: List(#(String, List(String))),
  from: String,
  to: String,
) -> Result(Int, Nil) {
  search_distance(edges, [#(from, 0)], [], to)
}

fn search_distance(
  edges: List(#(String, List(String))),
  queue: List(#(String, Int)),
  visited: List(String),
  target: String,
) -> Result(Int, Nil) {
  case queue {
    [] -> Error(Nil)
    [#(name, found_distance), ..rest] ->
      case name == target, list.contains(visited, name) {
        True, _ -> Ok(found_distance)
        False, True -> search_distance(edges, rest, visited, target)
        False, False -> {
          let children =
            calls_from(edges, name)
            |> list.map(fn(child) { #(child, found_distance + 1) })
          search_distance(
            edges,
            list.append(rest, children),
            [name, ..visited],
            target,
          )
        }
      }
  }
}

fn calls_from(
  edges: List(#(String, List(String))),
  name: String,
) -> List(String) {
  case list.find(edges, fn(edge) { edge.0 == name }) {
    Ok(edge) -> edge.1
    Error(Nil) -> []
  }
}

fn calls_in_statements(statements: List(glance.Statement)) -> List(String) {
  list.flat_map(statements, fn(statement) {
    case statement {
      glance.Use(_, _, function) -> calls_in_expression(function)
      glance.Assignment(_, kind, _, _, value) ->
        list.append(calls_in_expression(value), assignment_message_calls(kind))
      glance.Assert(_, expression, message) ->
        list.append(calls_in_expression(expression), option_calls(message))
      glance.Expression(expression) -> calls_in_expression(expression)
    }
  })
}

fn assignment_message_calls(kind: glance.AssignmentKind) -> List(String) {
  case kind {
    glance.Let -> []
    glance.LetAssert(message) -> option_calls(message)
  }
}

fn calls_in_expression(expression: glance.Expression) -> List(String) {
  case expression {
    glance.Int(_, _)
    | glance.Float(_, _)
    | glance.String(_, _)
    | glance.Variable(_, _) -> []
    glance.NegateInt(_, value) | glance.NegateBool(_, value) ->
      calls_in_expression(value)
    glance.Block(_, statements) -> calls_in_statements(statements)
    glance.Panic(_, message) | glance.Todo(_, message) -> option_calls(message)
    glance.Tuple(_, elements) -> list.flat_map(elements, calls_in_expression)
    glance.List(_, elements, rest) ->
      list.append(
        list.flat_map(elements, calls_in_expression),
        option_calls(rest),
      )
    glance.Fn(_, _, _, body) -> calls_in_statements(body)
    glance.RecordUpdate(_, _, _, record, fields) ->
      list.append(
        calls_in_expression(record),
        list.flat_map(fields, record_update_calls),
      )
    glance.FieldAccess(_, container, _) -> calls_in_expression(container)
    glance.Call(_, function, arguments) ->
      list.append(
        direct_call(function),
        list.append(
          calls_in_expression(function),
          list.flat_map(arguments, field_calls),
        ),
      )
    glance.TupleIndex(_, tuple, _) -> calls_in_expression(tuple)
    glance.FnCapture(_, _, function, before, after) ->
      list.append(
        direct_call(function),
        list.append(
          calls_in_expression(function),
          list.append(
            list.flat_map(before, field_calls),
            list.flat_map(after, field_calls),
          ),
        ),
      )
    glance.BitString(_, segments) ->
      list.flat_map(segments, fn(segment) {
        list.append(
          calls_in_expression(segment.0),
          list.flat_map(segment.1, bit_string_option_calls),
        )
      })
    glance.Case(_, subjects, clauses) ->
      list.append(
        list.flat_map(subjects, calls_in_expression),
        list.flat_map(clauses, clause_calls),
      )
    glance.BinaryOperator(_, operator, left, right) -> {
      let pipe_call = case operator {
        glance.Pipe -> direct_call(right)
        _ -> []
      }
      list.append(
        pipe_call,
        list.append(calls_in_expression(left), calls_in_expression(right)),
      )
    }
    glance.Echo(_, expression, message) ->
      list.append(option_calls(expression), option_calls(message))
  }
}

fn direct_call(expression: glance.Expression) -> List(String) {
  case expression {
    glance.Variable(_, name) -> [name]
    _ -> []
  }
}

fn option_calls(expression: Option(glance.Expression)) -> List(String) {
  case expression {
    Some(expression) -> calls_in_expression(expression)
    None -> []
  }
}

fn field_calls(field: glance.Field(glance.Expression)) -> List(String) {
  case field {
    glance.LabelledField(_, _, item) | glance.UnlabelledField(item) ->
      calls_in_expression(item)
    glance.ShorthandField(_, _) -> []
  }
}

fn record_update_calls(
  field: glance.RecordUpdateField(glance.Expression),
) -> List(String) {
  let glance.RecordUpdateField(_, item) = field
  option_calls(item)
}

fn bit_string_option_calls(
  option: glance.BitStringSegmentOption(glance.Expression),
) -> List(String) {
  case option {
    glance.SizeValueOption(expression) -> calls_in_expression(expression)
    _ -> []
  }
}

fn clause_calls(clause: glance.Clause) -> List(String) {
  list.append(option_calls(clause.guard), calls_in_expression(clause.body))
}
