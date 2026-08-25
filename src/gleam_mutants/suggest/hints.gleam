// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The literals one function under test writes down, collected so the probe can
// draw them on purpose.
//
// A boundary mutant of `x > 10` is separated by `10` and by nothing else, and
// `string.starts_with(s, "./")` is separated by a string starting `"./"` — both
// are values a uniform draw practically never produces. The function's own
// source already names them, so harvesting its literals turns a search that
// would need millions of cases into one that needs a handful.
//
// Both halves of the source are read: the expressions a function evaluates and
// the patterns it matches on. `case method { "GET" -> .. }` writes its literal
// in a pattern and nowhere else, and it is the shape a probe benefits from
// most.
//
// Everything here is pure: it reads a parsed Glance function and answers with
// values, so the whole of it can be asserted on directly.

import glance
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// The literals one function writes down, by kind, in the order found.
pub type Hints {
  Hints(ints: List(Int), floats: List(Float), strings: List(String))
}

/// No literal at all: what a caller that has nothing to harvest passes on.
pub fn none() -> Hints {
  Hints(ints: [], floats: [], strings: [])
}

/// Every literal the body of `function` holds, deduplicated and capped.
///
/// Both the expressions it evaluates and the patterns it matches on are read.
/// A literal compared against with `<`, `<=`, `>` or `>=` also contributes its
/// neighbours: `x > 10` is separated by `10` from `>=`, and by `9` and `11`
/// from a shifted bound. At most `limit` values of each kind survive, so a
/// module-sized table of constants cannot flood the search.
pub fn harvest(function: glance.Function) -> Hints {
  let found = list.fold(function.body, none(), statement)
  Hints(
    ints: settled(found.ints),
    floats: settled(found.floats),
    strings: settled(found.strings),
  )
}

/// The most hints of one kind a function contributes.
pub const limit = 32

/// The values collected so far, in the order found, deduplicated and capped.
///
/// Every collector prepends, so the accumulator is in reverse; the first
/// literal a reader meets is the first hint the generator draws.
fn settled(collected: List(a)) -> List(a) {
  collected
  |> list.reverse
  |> list.unique
  |> list.take(limit)
}

// --- Walking the body --------------------------------------------------------

fn statement(found: Hints, statement: glance.Statement) -> Hints {
  case statement {
    glance.Use(_, patterns, function) ->
      list.fold(patterns, found, fn(seen, held) { pattern(seen, held.pattern) })
      |> expression(function)
    glance.Assignment(pattern: matched, value: value, ..) ->
      pattern(found, matched)
      |> expression(value)
    glance.Assert(expression: checked, message: message, ..) ->
      expression(found, checked)
      |> optional(message)
    glance.Expression(held) -> expression(found, held)
  }
}

fn expression(found: Hints, held: glance.Expression) -> Hints {
  case held {
    glance.Int(_, raw) -> add_int(found, integer(raw))
    glance.Float(_, raw) -> add_float(found, decimal(raw))
    glance.String(_, raw) -> add_string(found, unescaped(raw))
    glance.NegateInt(_, glance.Int(_, raw)) ->
      add_int(found, negated(integer(raw)))
    glance.NegateInt(_, value) -> expression(found, value)
    glance.NegateBool(_, value) -> expression(found, value)
    glance.Block(_, statements) -> list.fold(statements, found, statement)
    glance.Panic(_, message) -> optional(found, message)
    glance.Todo(_, message) -> optional(found, message)
    glance.Tuple(_, elements) -> list.fold(elements, found, expression)
    glance.List(_, elements, rest) ->
      list.fold(elements, found, expression)
      |> optional(rest)
    glance.Fn(body: body, ..) -> list.fold(body, found, statement)
    glance.RecordUpdate(record: record, fields: updates, ..) ->
      expression(found, record)
      |> list.fold(updates, _, fn(seen, field) { optional(seen, field.item) })
    glance.FieldAccess(container: container, ..) -> expression(found, container)
    glance.Call(function: function, arguments: arguments, ..) ->
      expression(found, function)
      |> fields(arguments)
    glance.TupleIndex(tuple: tuple, ..) -> expression(found, tuple)
    glance.FnCapture(
      function: function,
      arguments_before: before,
      arguments_after: after,
      ..,
    ) ->
      expression(found, function)
      |> fields(before)
      |> fields(after)
    glance.BitString(_, segments) ->
      list.fold(segments, found, fn(seen, segment) {
        expression(seen, segment.0)
      })
    glance.Case(_, subjects, clauses) ->
      list.fold(subjects, found, expression)
      |> list.fold(clauses, _, clause)
    glance.BinaryOperator(_, name, left, right) ->
      comparison(expression(found, left), name, left)
      |> expression(right)
      |> comparison(name, right)
    glance.Echo(expression: echoed, message: message, ..) ->
      optional(found, echoed)
      |> optional(message)
    glance.Variable(..) -> found
  }
}

/// A clause names its literals in the order a reader meets them: the patterns
/// it matches on, then the guard, then the body.
fn clause(found: Hints, clause: glance.Clause) -> Hints {
  list.fold(clause.patterns, found, fn(seen, alternative) {
    list.fold(alternative, seen, pattern)
  })
  |> optional(clause.guard)
  |> expression(clause.body)
}

/// Every literal one pattern matches on.
///
/// A pattern is where most Gleam code writes the value that separates a string
/// or an equality mutant down: `case method { "GET" -> ... }` names the exact
/// string the function answers differently for, and
/// `case path { "./" <> rest -> ... }` names the exact prefix. Harvesting the
/// expressions alone left every one of them invisible.
///
/// A matched literal contributes no neighbour: matching is equality, and the
/// value either side of it says nothing about the clause that was taken.
fn pattern(found: Hints, held: glance.Pattern) -> Hints {
  case held {
    glance.PatternInt(_, raw) -> add_int(found, integer(raw))
    glance.PatternFloat(_, raw) -> add_float(found, decimal(raw))
    glance.PatternString(_, raw) -> add_string(found, unescaped(raw))
    // The prefix is the whole of what the pattern says about the string it
    // matches, and the rest is bound rather than compared.
    glance.PatternConcatenate(prefix: prefix, ..) ->
      add_string(found, unescaped(prefix))
    glance.PatternTuple(_, elements) -> list.fold(elements, found, pattern)
    glance.PatternList(_, elements, tail) ->
      list.fold(elements, found, pattern)
      |> tail_of(tail)
    glance.PatternAssignment(pattern: inner, ..) -> pattern(found, inner)
    glance.PatternBitString(_, segments) ->
      list.fold(segments, found, fn(seen, segment) { pattern(seen, segment.0) })
    glance.PatternVariant(arguments: arguments, ..) ->
      list.fold(arguments, found, fn(seen, argument) {
        case argument {
          glance.LabelledField(item: item, ..) -> pattern(seen, item)
          glance.UnlabelledField(item) -> pattern(seen, item)
          glance.ShorthandField(..) -> seen
        }
      })
    glance.PatternDiscard(..) | glance.PatternVariable(..) -> found
  }
}

fn tail_of(found: Hints, held: option.Option(glance.Pattern)) -> Hints {
  case held {
    Some(value) -> pattern(found, value)
    None -> found
  }
}

fn fields(
  found: Hints,
  arguments: List(glance.Field(glance.Expression)),
) -> Hints {
  list.fold(arguments, found, fn(seen, argument) {
    case argument {
      glance.LabelledField(item: item, ..) -> expression(seen, item)
      glance.UnlabelledField(item) -> expression(seen, item)
      glance.ShorthandField(..) -> seen
    }
  })
}

fn optional(found: Hints, held: option.Option(glance.Expression)) -> Hints {
  case held {
    Some(value) -> expression(found, value)
    None -> found
  }
}

// --- Boundaries ---------------------------------------------------------------

/// The neighbours of an integer an ordering compares against.
///
/// `x > 10` and `x >= 10` answer differently at `10` alone, and a bound the
/// mutation shifted answers differently at `9` or `11`; equality has no
/// neighbour to shift onto, so it contributes only the literal itself.
fn comparison(
  found: Hints,
  name: glance.BinaryOperator,
  side: glance.Expression,
) -> Hints {
  case ordering(name), integer_of(side) {
    True, Ok(value) ->
      add_int(found, Ok(value - 1))
      |> add_int(Ok(value + 1))
    _, _ -> found
  }
}

fn ordering(name: glance.BinaryOperator) -> Bool {
  case name {
    glance.LtInt | glance.LtEqInt | glance.GtInt | glance.GtEqInt -> True
    _ -> False
  }
}

fn integer_of(held: glance.Expression) -> Result(Int, Nil) {
  case held {
    glance.Int(_, raw) -> integer(raw)
    glance.NegateInt(_, glance.Int(_, raw)) -> negated(integer(raw))
    _ -> Error(Nil)
  }
}

// --- Reading a literal --------------------------------------------------------

/// The value of a Gleam integer literal: underscores are spacing, and a
/// literal may be written in another base.
fn integer(raw: String) -> Result(Int, Nil) {
  // A pattern carries its sign inside the literal — `case n { -3 -> .. }` is
  // one `PatternInt` of `"-3"` — where an expression carries it outside, in a
  // `NegateInt`. Reading the sign here answers both.
  case string.replace(raw, "_", "") {
    "-" <> digits -> negated(unsigned(digits))
    digits -> unsigned(digits)
  }
}

/// The value of an unsigned integer literal, whichever base it is written in.
fn unsigned(digits: String) -> Result(Int, Nil) {
  case string.lowercase(digits) {
    "0x" <> rest -> int.base_parse(rest, 16)
    "0o" <> rest -> int.base_parse(rest, 8)
    "0b" <> rest -> int.base_parse(rest, 2)
    _ -> int.parse(digits)
  }
}

/// The same integer with its sign flipped, when there was one.
fn negated(value: Result(Int, Nil)) -> Result(Int, Nil) {
  result.map(value, fn(value) { -value })
}

/// The value of a Gleam float literal, underscores aside.
fn decimal(raw: String) -> Result(Float, Nil) {
  float.parse(string.replace(raw, "_", ""))
}

/// The text a Gleam string literal denotes, its escapes resolved.
///
/// Glance keeps the source between the quotes, so `"\n"` arrives as a
/// backslash and an `n`; a generator drawing that would draw two characters
/// the function never sees.
fn unescaped(raw: String) -> String {
  unescaping(raw, "")
}

fn unescaping(rest: String, done: String) -> String {
  case rest {
    "" -> done
    "\\\"" <> tail -> unescaping(tail, done <> "\"")
    "\\\\" <> tail -> unescaping(tail, done <> "\\")
    "\\f" <> tail -> unescaping(tail, done <> "\f")
    "\\n" <> tail -> unescaping(tail, done <> "\n")
    "\\r" <> tail -> unescaping(tail, done <> "\r")
    "\\t" <> tail -> unescaping(tail, done <> "\t")
    "\\u{" <> tail -> codepoint(tail, done, "")
    _ ->
      case string.pop_grapheme(rest) {
        Ok(#(grapheme, tail)) -> unescaping(tail, done <> grapheme)
        Error(_) -> done
      }
  }
}

fn codepoint(rest: String, done: String, digits: String) -> String {
  case string.pop_grapheme(rest) {
    Ok(#("}", tail)) ->
      case
        int.base_parse(digits, 16)
        |> result.try(string.utf_codepoint)
      {
        Ok(character) ->
          unescaping(tail, done <> string.from_utf_codepoints([character]))
        Error(_) -> unescaping(tail, done)
      }
    Ok(#(digit, tail)) -> codepoint(tail, done, digits <> digit)
    Error(_) -> done
  }
}

// --- Collecting ---------------------------------------------------------------

fn add_int(found: Hints, value: Result(Int, Nil)) -> Hints {
  case value {
    Ok(value) -> Hints(..found, ints: [value, ..found.ints])
    Error(_) -> found
  }
}

fn add_float(found: Hints, value: Result(Float, Nil)) -> Hints {
  case value {
    Ok(value) -> Hints(..found, floats: [value, ..found.floats])
    Error(_) -> found
  }
}

fn add_string(found: Hints, value: String) -> Hints {
  Hints(..found, strings: [value, ..found.strings])
}
