// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// A deliberately under-tested module: every function below keeps at least one
// survivor alive under `test/boundary_test.gleam`, and each one exercises a
// different branch of the suggestion probe.

import gleam/option.{type Option, None, Some}
import gleam/string

pub type Shape {
  Circle(radius: Int)
  Square(side: Int)
}

/// The boundary case: `>` becomes `>=`, which only `0` tells apart.
pub fn is_positive(value: Int) -> Bool {
  value > 0
}

/// Holds an equivalent mutant: `<` becomes `<=`, and `0 - 0` is still `0`.
pub fn abs(value: Int) -> Int {
  case value < 0 {
    True -> 0 - value
    False -> value
  }
}

/// Takes a custom type, so the probe has to generate `Circle` and `Square`.
pub fn area(shape: Shape) -> Int {
  case shape {
    Circle(radius) -> 3 * radius * radius
    Square(side) -> side * side
  }
}

/// Takes an option and returns a result, exercising the wrapper printers.
pub fn maybe_double(value: Option(Int)) -> Result(Int, String) {
  case value {
    Some(v) -> Ok(v + v)
    None -> Error("missing")
  }
}

/// Private, so its mutants must be explored through `uses_helper`.
fn helper(x: Int) -> Int {
  x + 1
}

pub fn uses_helper(x: Int) -> Int {
  helper(x)
}

/// Takes a function, so its mutants can only be reported as unsupported. The
/// `+ 0` is what gives the function-typed parameter a mutant to report at all.
pub fn applies(f: fn(Int) -> Int, x: Int) -> Int {
  f(x) + 0
}

/// Holds a mutant that does not type check, beside one that does.
///
/// Deleting the pipeline stage leaves `parts`, a `List(String)`, where the
/// annotation promises a `String`: the compiler rejects it, exactly as `run`
/// rejects it. Turning the separator into `""` is a perfectly good mutant on
/// the very same line, and the one the probe has to keep reporting on — a
/// single mutant nobody can build must not take the whole file down.
pub fn join(parts: List(String)) -> String {
  parts
  |> string.join("; ")
}
