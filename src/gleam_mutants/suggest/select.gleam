// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Pairing mutants with the functions that enclose them, and deciding which
// return types the differential probe can compare at all.

import glance
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/span

/// A parsed function together with the mutants that live inside its span.
pub type FunctionTarget {
  FunctionTarget(function: glance.Function, mutants: List(Mutant))
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
