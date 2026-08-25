// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Harvesting the literals one function writes down.
//
// Measured on real code, raising `--max-cases` from 200 to 2000 and changing
// the seed moved nothing: the inputs a boundary or a string comparison needs
// are not rare, they are unreachable. `mutant.normalize_path` needs a path
// starting `"./"`, `mutant.line_column` needs a `"\r"`, and `x > 10` needs
// `10` — every one of them is written down in the function itself.

import glance
import gleam/list
import gleam/string
import gleam_mutants/suggest/hints

// --- helpers -----------------------------------------------------------------

/// The parsed function `name` of `source`.
fn function_in(source: String, name: String) -> glance.Function {
  let assert Ok(module) = glance.module(source)
  let assert Ok(found) =
    list.find(module.functions, fn(definition) {
      definition.definition.name == name
    })
  found.definition
}

/// The hints harvested from function `name` of `source`.
fn harvest(source: String, name: String) -> hints.Hints {
  hints.harvest(function_in(source, name))
}

/// A module wrapping one function body, so a test can write only the body.
fn module_of(body: String) -> String {
  "import gleam/string\n\n" <> body <> "\n"
}

// --- nothing to harvest ------------------------------------------------------

pub fn harvest_of_a_function_with_no_literals_is_empty_test() {
  assert harvest(
      module_of("pub fn twice(x: Int) -> Int {\n  x + x\n}"),
      "twice",
    )
    == hints.none()
  assert hints.none() == hints.Hints(ints: [], floats: [], strings: [])
}

// --- integers ----------------------------------------------------------------

pub fn harvest_collects_integer_literals_test() {
  let found =
    harvest(module_of("pub fn bump(x: Int) -> Int {\n  x + 3\n}"), "bump")
  assert found.ints == [3]
  assert found.floats == []
  assert found.strings == []
}

/// A comparison against a literal is where a boundary mutant hides: `>`
/// becoming `>=` is separated by `10` alone, and a bound shifted by one is
/// separated by `9` or `11`. The literal comes first, then its neighbours.
pub fn harvest_adds_the_neighbours_of_a_compared_integer_test() {
  let found =
    harvest(module_of("pub fn big(x: Int) -> Bool {\n  x > 10\n}"), "big")
  assert found.ints == [10, 9, 11]
}

pub fn harvest_adds_the_neighbours_whichever_side_the_literal_is_on_test() {
  let sources = [
    "pub fn p(x: Int) -> Bool {\n  x > 10\n}",
    "pub fn p(x: Int) -> Bool {\n  x >= 10\n}",
    "pub fn p(x: Int) -> Bool {\n  x < 10\n}",
    "pub fn p(x: Int) -> Bool {\n  x <= 10\n}",
    "pub fn p(x: Int) -> Bool {\n  10 < x\n}",
    "pub fn p(x: Int) -> Bool {\n  10 >= x\n}",
  ]
  assert list.filter(sources, fn(source) {
      harvest(module_of(source), "p").ints != [10, 9, 11]
    })
    == []
}

/// Equality is not a boundary: `==` has no neighbour to shift onto.
pub fn harvest_leaves_an_equality_literal_alone_test() {
  let found =
    harvest(
      module_of("pub fn is_ten(x: Int) -> Bool {\n  x == 10\n}"),
      "is_ten",
    )
  assert found.ints == [10]
}

/// A Gleam integer literal may carry underscores, and the value is what a
/// generator needs.
pub fn harvest_reads_an_underscored_literal_as_its_value_test() {
  let found =
    harvest(module_of("pub fn big(x: Int) -> Bool {\n  x > 1_000\n}"), "big")
  assert found.ints == [1000, 999, 1001]
}

// --- strings and floats -------------------------------------------------------

pub fn harvest_collects_string_literals_test() {
  let found =
    harvest(
      module_of(
        "pub fn is_path(s: String) -> Bool {\n  string.starts_with(s, \"./\")\n}",
      ),
      "is_path",
    )
  assert found.strings == ["./"]
  assert found.ints == []
}

pub fn harvest_collects_float_literals_test() {
  let found =
    harvest(
      module_of("pub fn scale(x: Float) -> Float {\n  x *. 2.5\n}"),
      "scale",
    )
  assert found.floats == [2.5]
}

// --- walking the whole body ---------------------------------------------------

/// Literals hide inside `case` clauses, blocks, `let` bindings and pipelines,
/// not only in a one-expression body.
pub fn harvest_walks_nested_case_and_pipe_bodies_test() {
  let source =
    module_of(
      "pub fn classify(s: String) -> Int {
  case string.starts_with(s, \"./\") {
    True -> {
      let trimmed = string.drop_start(s, 2)
      string.length(trimmed) + 1
    }
    False ->
      s
      |> string.replace(\"\\\\\", \"/\")
      |> string.length
  }
}",
    )
  let found = harvest(source, "classify")
  assert list.filter(["./", "\\", "/"], fn(text) {
      !list.contains(found.strings, text)
    })
    == []
  assert list.filter([1, 2], fn(value) { !list.contains(found.ints, value) })
    == []
}

// --- patterns -----------------------------------------------------------------
//
// A literal a function matches on is a literal it compares against: `case
// method { "GET" -> ... }` and `case s { "./" <> rest -> ... }` name the exact
// values that separate a string mutant, and a pattern is where most Gleam code
// writes them. Harvesting the expressions alone left those invisible.

pub fn harvest_collects_a_literal_a_clause_matches_on_test() {
  let found =
    harvest(
      module_of(
        "pub fn allowed(method: String) -> Bool {
  case method {
    \"GET\" -> True
    _ -> False
  }
}",
      ),
      "allowed",
    )
  assert found.strings == ["GET"]
}

/// The prefix of a string-concatenation pattern is the literal a probe needs:
/// nothing else in the function names it.
pub fn harvest_collects_the_prefix_of_a_concatenation_pattern_test() {
  let found =
    harvest(
      module_of(
        "pub fn strip(s: String) -> String {
  case s {
    \"./\" <> rest -> rest
    _ -> s
  }
}",
      ),
      "strip",
    )
  assert found.strings == ["./"]
}

pub fn harvest_collects_numbers_a_clause_matches_on_test() {
  let found =
    harvest(
      module_of(
        "pub fn name(code: Int) -> Float {
  case code {
    10 -> 1.5
    -3 -> 0.25
    _ -> 0.0
  }
}",
      ),
      "name",
    )
  // Matching is equality, so a matched number contributes no neighbour.
  assert found.ints == [10, -3]
  assert found.floats == [1.5, 0.25, 0.0]
}

/// A literal nested inside a pattern is one the same way: a tuple, a list, a
/// variant field, an alias and the tail of a list all carry one.
pub fn harvest_walks_nested_patterns_test() {
  let found =
    harvest(
      module_of(
        "pub fn read(pair: #(Int, List(Int)), value: Result(String, Int)) -> Int {
  case pair, value {
    #(4, [5, ..]), Ok(\"ok\") -> 4
    #(_, [_, 6 as seen]), Error(7) -> seen
    _, _ -> 0
  }
}",
      ),
      "read",
    )
  assert list.filter([4, 5, 6, 7], fn(value) {
      !list.contains(found.ints, value)
    })
    == []
  assert list.contains(found.strings, "ok")
}

/// An escape in a pattern denotes the character it stands for, exactly as one
/// in an expression does: a probe drawing a backslash and an `n` would draw a
/// string the function never matches.
pub fn harvest_unescapes_a_pattern_literal_test() {
  let found =
    harvest(
      module_of(
        "pub fn ending(s: String) -> Bool {
  case s {
    \"\\r\\n\" -> True
    _ -> False
  }
}",
      ),
      "ending",
    )
  assert found.strings == ["\r\n"]
}

/// `let assert` matches, so its pattern names literals too — and nothing else
/// in this function does.
pub fn harvest_collects_a_literal_an_assignment_matches_on_test() {
  let found =
    harvest(
      module_of(
        "pub fn first(xs: List(Int)) -> String {
  let assert [8, ..] = xs
  \"ok\"
}",
      ),
      "first",
    )
  assert found.ints == [8]
  assert found.strings == ["ok"]
}

/// A pattern literal is deduplicated with every other one, expression or
/// pattern.
pub fn harvest_keeps_a_pattern_literal_once_test() {
  let found =
    harvest(
      module_of(
        "pub fn twice(s: String, t: String) -> Bool {
  case s {
    \"/\" -> True
    _ ->
      case t {
        \"/\" -> False
        _ -> t == \"/\"
      }
  }
}",
      ),
      "twice",
    )
  assert found.strings == ["/"]
}

// --- shape --------------------------------------------------------------------

pub fn harvest_keeps_each_value_once_test() {
  let found =
    harvest(
      module_of("pub fn thrice(x: Int) -> Int {\n  x + 7 + 7 + 7\n}"),
      "thrice",
    )
  assert found.ints == [7]
}

/// A comparison neighbour that another literal already contributed is not a
/// second entry.
pub fn harvest_keeps_a_neighbour_that_is_also_a_literal_once_test() {
  let found =
    harvest(
      module_of(
        "pub fn p(x: Int) -> Int {\n  case x > 10 {\n    True -> 9\n    False -> 11\n  }\n}",
      ),
      "p",
    )
  assert found.ints == [10, 9, 11]
}

/// A table of constants must not flood the search with hints.
pub fn harvest_caps_each_kind_test() {
  let body =
    counting(0, 40)
    |> list.map(fn(value) { int_source(value) })
    |> string.join(" + ")
  let found =
    harvest(
      module_of("pub fn table(x: Int) -> Int {\n  x + " <> body <> "\n}"),
      "table",
    )
  assert hints.limit == 32
  assert list.length(found.ints) == hints.limit
  assert list.take(found.ints, 3) == [0, 1, 2]
}

fn counting(from: Int, to: Int) -> List(Int) {
  case from >= to {
    True -> []
    False -> [from, ..counting(from + 1, to)]
  }
}

fn int_source(value: Int) -> String {
  string.inspect(value)
}
