//// Deterministic, replayable generators with portable draw tapes.
////
//// A tape stores semantic choices rather than VM random values. The same
//// schema and tape therefore decode to the same value on Erlang and all
//// JavaScript runtimes, and every shrink candidate carries its own replay
//// tape.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int as gleam_int
import gleam/list as gleam_list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const minstd_modulus = 2_147_483_647

const minstd_multiplier = 48_271

/// A portable sequence of generator decisions.
pub type Tape =
  List(Int)

/// A value and the deterministic candidates to which it can shrink.
pub opaque type Tree(a) {
  Tree(value: a, tape: Tape, children: fn() -> List(Tree(a)))
}

/// A generator recipe. Its schema is part of every persisted witness.
pub opaque type Generator(a) {
  Generator(
    schema: String,
    run: fn(Source) -> Result(#(Tree(a), Source), ReplayError),
    render: fn(a) -> String,
  )
}

type Source {
  RandomSource(state: Int)
  ReplaySource(remaining: Tape, offset: Int)
}

pub type ReplayError {
  TapeExhausted(offset: Int, schema: String)
  InvalidChoice(offset: Int, choice: Int, choices: Int, schema: String)
  TrailingChoices(count: Int)
}

/// One generated root value, its tape, and the seed for the next case.
pub type Generated(a) {
  Generated(tree: Tree(a), next_seed: Int)
}

pub fn tree_value(tree: Tree(a)) -> a {
  tree.value
}

pub fn tree_tape(tree: Tree(a)) -> Tape {
  tree.tape
}

pub fn tree_children(tree: Tree(a)) -> List(Tree(a)) {
  let children = tree.children
  children()
}

/// Generates one case from `seed`.
pub fn generate(
  generator: Generator(a),
  seed: Int,
) -> Result(Generated(a), ReplayError) {
  use generated <- result.map(run(generator, RandomSource(normalise_seed(seed))))
  let #(tree, source) = generated
  let next_seed = case source {
    RandomSource(state) -> state
    ReplaySource(_, _) -> normalise_seed(seed)
  }
  Generated(tree, next_seed)
}

/// Reconstructs a value exactly from a persisted tape.
pub fn replay(
  generator: Generator(a),
  tape: Tape,
) -> Result(Tree(a), ReplayError) {
  use generated <- result.try(run(generator, ReplaySource(tape, 0)))
  let #(tree, source) = generated
  case source {
    ReplaySource([], _) -> Ok(tree)
    ReplaySource(remaining, _) ->
      Error(TrailingChoices(gleam_list.length(remaining)))
    RandomSource(_) -> Ok(tree)
  }
}

fn run(
  generator: Generator(a),
  source: Source,
) -> Result(#(Tree(a), Source), ReplayError) {
  let generate = generator.run
  generate(source)
}

/// A stable fingerprint used to invalidate stale corpus entries.
pub fn schema_fingerprint(generator: Generator(a)) -> String {
  "smartest-gen-v1-" <> gleam_int.to_string(schema_hash(generator.schema))
}

pub fn schema_description(generator: Generator(a)) -> String {
  generator.schema
}

pub fn render(generator: Generator(a), value: a) -> String {
  let render_value = generator.render
  render_value(value)
}

/// Replaces a generator's schema label. Use this around application-specific
/// mappings so a mapping change makes old evidence visibly stale.
pub fn named(generator: Generator(a), schema: String) -> Generator(a) {
  Generator(
    ..generator,
    schema: "named(" <> schema <> ":" <> generator.schema <> ")",
  )
}

/// Supplies a stable human-readable renderer. Rendering is never an oracle.
pub fn rendered(
  generator: Generator(a),
  renderer: fn(a) -> String,
) -> Generator(a) {
  Generator(..generator, render: renderer)
}

/// Adds caller-versioned boundary and corpus hints to a normal generator.
///
/// Hints use ordinary branch choices, so random generation, replay, and
/// shrinking still share one portable tape engine. Change `schema` whenever
/// the meaning or ordering of `hints` changes.
pub fn hinted(
  generator: Generator(a),
  hints: List(a),
  schema schema: String,
) -> Generator(a) {
  let named_schema = "hints(" <> schema <> ")"
  case hints {
    [] -> named(generator, named_schema)
    hints -> {
      let branches =
        gleam_list.map(hints, fn(value) {
          constant(value)
          |> rendered(fn(value) { render(generator, value) })
          |> named("hint")
        })
      one_of(generator, branches)
      |> named(named_schema)
      |> rendered(fn(value) { render(generator, value) })
    }
  }
}

/// A generator that consumes no tape and never shrinks.
pub fn constant(value: a) -> Generator(a) {
  Generator(
    schema: "constant",
    run: fn(source) { Ok(#(leaf(value, []), source)) },
    render: string.inspect,
  )
}

/// Integers in the bounded default domain `-100..100`.
pub fn int() -> Generator(Int) {
  int_range(-100, 100)
}

/// Integers in the inclusive range. Reversed bounds are accepted.
pub fn int_range(first: Int, second: Int) -> Generator(Int) {
  let #(low, high) = case first <= second {
    True -> #(first, second)
    False -> #(second, first)
  }
  let width = high - low + 1
  let schema =
    "int("
    <> gleam_int.to_string(low)
    <> ","
    <> gleam_int.to_string(high)
    <> ")"
  Generator(
    schema: schema,
    run: fn(source) {
      use choice <- result.try(draw(source, width, schema))
      let #(offset, next) = choice
      let value = low + offset
      Ok(#(int_tree(value, low, high), next))
    },
    render: gleam_int.to_string,
  )
}

pub fn bool() -> Generator(Bool) {
  int_range(0, 1)
  |> map(fn(value) { value == 1 })
  |> named("bool")
  |> rendered(fn(value) {
    case value {
      True -> "True"
      False -> "False"
    }
  })
}

pub fn nil() -> Generator(Nil) {
  constant(Nil) |> named("nil") |> rendered(fn(_) { "Nil" })
}

/// Printable ASCII strings of at most 20 characters.
pub fn string() -> Generator(String) {
  list_with_max(int_range(32, 126), 20)
  |> map(codepoints_to_string)
  |> named("printable-ascii-string(max:20)")
  |> rendered(string.inspect)
}

/// Lists of at most ten generated elements.
pub fn list(generator: Generator(a)) -> Generator(List(a)) {
  list_with_max(generator, 10)
}

pub fn list_with_max(
  generator: Generator(a),
  maximum: Int,
) -> Generator(List(a)) {
  let maximum = case maximum < 0 {
    True -> 0
    False -> maximum
  }
  let schema =
    "list(max:"
    <> gleam_int.to_string(maximum)
    <> ",of:"
    <> generator.schema
    <> ")"
  Generator(
    schema: schema,
    run: fn(source) {
      use length_draw <- result.try(draw(source, maximum + 1, schema))
      let #(length, after_length) = length_draw
      use generated <- result.try(
        generate_many(generator, length, after_length, []),
      )
      let #(elements, next) = generated
      Ok(#(list_tree(elements), next))
    },
    render: fn(values) {
      values
      |> gleam_list.map(fn(value) { render(generator, value) })
      |> string.join(", ")
      |> fn(items) { "[" <> items <> "]" }
    },
  )
}

pub fn option(generator: Generator(a)) -> Generator(Option(a)) {
  one_of(constant(None) |> rendered(fn(_) { "None" }), [
    map(generator, Some)
    |> rendered(fn(value) {
      case value {
        Some(inner) -> "Some(" <> render(generator, inner) <> ")"
        None -> "None"
      }
    }),
  ])
  |> named("option(" <> generator.schema <> ")")
}

pub fn result(
  ok: Generator(a),
  error: Generator(e),
) -> Generator(Result(a, e)) {
  one_of(
    map(ok, Ok)
      |> rendered(fn(value) {
        case value {
          Ok(inner) -> "Ok(" <> render(ok, inner) <> ")"
          Error(_) -> "Error(?)"
        }
      }),
    [
      map(error, Error)
      |> rendered(fn(value) {
        case value {
          Error(inner) -> "Error(" <> render(error, inner) <> ")"
          Ok(_) -> "Ok(?)"
        }
      }),
    ],
  )
  |> named("result(ok:" <> ok.schema <> ",error:" <> error.schema <> ")")
}

pub fn tuple2(first: Generator(a), second: Generator(b)) -> Generator(#(a, b)) {
  map2(first, second, fn(a, b) { #(a, b) })
  |> named("tuple2(" <> first.schema <> "," <> second.schema <> ")")
  |> rendered(fn(pair) {
    "#(" <> render(first, pair.0) <> ", " <> render(second, pair.1) <> ")"
  })
}

/// Applies a pure mapping to roots and every shrink candidate.
///
/// Wrap application-specific mappings in `named` so schema changes are
/// intentional and reviewable.
pub fn map(generator: Generator(a), transform: fn(a) -> b) -> Generator(b) {
  Generator(
    schema: "map(" <> generator.schema <> ")",
    run: fn(source) {
      use generated <- result.map(run(generator, source))
      let #(tree, next) = generated
      #(tree_map(tree, transform), next)
    },
    render: string.inspect,
  )
}

pub fn map2(
  first: Generator(a),
  second: Generator(b),
  combine: fn(a, b) -> c,
) -> Generator(c) {
  Generator(
    schema: "map2(" <> first.schema <> "," <> second.schema <> ")",
    run: fn(source) {
      use left_generated <- result.try(run(first, source))
      let #(left, after_left) = left_generated
      use right_generated <- result.map(run(second, after_left))
      let #(right, next) = right_generated
      #(tree_pair(left, right, combine), next)
    },
    render: string.inspect,
  )
}

/// Chooses a generator. Later branches shrink to the first branch before
/// shrinking within themselves.
pub fn one_of(first: Generator(a), rest: List(Generator(a))) -> Generator(a) {
  let choices = [first, ..rest]
  let count = gleam_list.length(choices)
  let schema =
    choices
    |> gleam_list.map(fn(generator) { generator.schema })
    |> string.join(",")
    |> fn(parts) { "one_of(" <> parts <> ")" }
  Generator(
    schema: schema,
    run: fn(source) {
      use branch_draw <- result.try(draw(source, count, schema))
      let #(branch, after_branch) = branch_draw
      let selected = generator_at(choices, branch, first)
      use selected_generated <- result.try(run(selected, after_branch))
      let #(selected_tree, next) = selected_generated
      let selected_tree = prefix_tree(branch, selected_tree)
      case branch {
        0 -> Ok(#(selected_tree, next))
        _ ->
          case run(first, after_branch) {
            Ok(#(fallback, _)) ->
              Ok(#(
                with_first_child(selected_tree, prefix_tree(0, fallback)),
                next,
              ))
            Error(_) -> Ok(#(selected_tree, next))
          }
      }
    },
    render: fn(value) { render(first, value) },
  )
}

fn generator_at(
  generators: List(Generator(a)),
  index: Int,
  fallback: Generator(a),
) -> Generator(a) {
  case gleam_list.drop(generators, index) {
    [generator, ..] -> generator
    [] -> fallback
  }
}

fn generate_many(
  generator: Generator(a),
  remaining: Int,
  source: Source,
  accumulated: List(Tree(a)),
) -> Result(#(List(Tree(a)), Source), ReplayError) {
  case remaining <= 0 {
    True -> Ok(#(gleam_list.reverse(accumulated), source))
    False -> {
      use generated <- result.try(run(generator, source))
      let #(tree, next) = generated
      generate_many(generator, remaining - 1, next, [tree, ..accumulated])
    }
  }
}

fn draw(
  source: Source,
  choices: Int,
  schema: String,
) -> Result(#(Int, Source), ReplayError) {
  case source {
    RandomSource(state) -> {
      let next = { minstd_multiplier * state } % minstd_modulus
      Ok(#(next % choices, RandomSource(next)))
    }
    ReplaySource([], offset) -> Error(TapeExhausted(offset, schema))
    ReplaySource([choice, ..remaining], offset) ->
      case choice >= 0 && choice < choices {
        True -> Ok(#(choice, ReplaySource(remaining, offset + 1)))
        False -> Error(InvalidChoice(offset, choice, choices, schema))
      }
  }
}

fn normalise_seed(seed: Int) -> Int {
  let remainder = seed % minstd_modulus
  let positive = case remainder < 0 {
    True -> remainder + minstd_modulus
    False -> remainder
  }
  case positive {
    0 -> 1
    _ -> positive
  }
}

fn leaf(value: a, tape: Tape) -> Tree(a) {
  Tree(value, tape, fn() { [] })
}

fn tree_map(tree: Tree(a), transform: fn(a) -> b) -> Tree(b) {
  Tree(transform(tree.value), tree.tape, fn() {
    tree_children(tree)
    |> gleam_list.map(fn(child) { tree_map(child, transform) })
  })
}

fn int_tree(value: Int, low: Int, high: Int) -> Tree(Int) {
  Tree(value, [value - low], fn() {
    int_steps(value, zero_closest(low, high), low, high)
    |> gleam_list.map(fn(candidate) { int_tree(candidate, low, high) })
  })
}

fn zero_closest(low: Int, high: Int) -> Int {
  case low > 0, high < 0 {
    True, _ -> low
    _, True -> high
    False, False -> 0
  }
}

fn int_steps(value: Int, target: Int, low: Int, high: Int) -> List(Int) {
  case value == target {
    True -> []
    False -> {
      let mirror = case value < 0 && 0 - value >= low && 0 - value <= high {
        True -> [0 - value]
        False -> []
      }
      [target, ..gleam_list.append(mirror, halve_towards(target, value))]
      |> gleam_list.unique
      |> gleam_list.filter(fn(candidate) { candidate != value })
    }
  }
}

fn halve_towards(current: Int, value: Int) -> List(Int) {
  let candidate = current + { value - current } / 2
  case candidate == current || candidate == value {
    True -> []
    False -> [candidate, ..halve_towards(candidate, value)]
  }
}

fn tree_pair(left: Tree(a), right: Tree(b), combine: fn(a, b) -> c) -> Tree(c) {
  Tree(
    combine(left.value, right.value),
    gleam_list.append(left.tape, right.tape),
    fn() {
      let left_children =
        tree_children(left)
        |> gleam_list.map(fn(child) { tree_pair(child, right, combine) })
      let right_children =
        tree_children(right)
        |> gleam_list.map(fn(child) { tree_pair(left, child, combine) })
      gleam_list.append(left_children, right_children)
    },
  )
}

fn list_tree(elements: List(Tree(a))) -> Tree(List(a)) {
  Tree(
    gleam_list.map(elements, tree_value),
    [gleam_list.length(elements), ..flatten_tapes(elements)],
    fn() {
      let shorter =
        removal_plans(gleam_list.length(elements))
        |> gleam_list.map(fn(indices) { list_tree(keep(elements, indices)) })
      gleam_list.append(shorter, element_variants([], elements))
    },
  )
}

fn flatten_tapes(trees: List(Tree(a))) -> Tape {
  trees
  |> gleam_list.map(tree_tape)
  |> gleam_list.flatten
}

fn element_variants(
  prefix: List(Tree(a)),
  remaining: List(Tree(a)),
) -> List(Tree(List(a))) {
  case remaining {
    [] -> []
    [element, ..tail] -> {
      let before = gleam_list.reverse(prefix)
      let changed =
        tree_children(element)
        |> gleam_list.map(fn(child) {
          list_tree(gleam_list.append(before, [child, ..tail]))
        })
      gleam_list.append(changed, element_variants([element, ..prefix], tail))
    }
  }
}

fn removal_plans(count: Int) -> List(List(Int)) {
  case count <= 0 {
    True -> []
    False -> {
      let empty = [[]]
      let half = count / 2
      let halves = case half > 0 {
        True -> [indices(0, half), indices(half, count)]
        False -> []
      }
      let single_removals =
        indices(0, count)
        |> gleam_list.map(fn(removed) {
          indices(0, count)
          |> gleam_list.filter(fn(index) { index != removed })
        })
      gleam_list.flatten([empty, halves, single_removals])
      |> gleam_list.filter(fn(plan) { gleam_list.length(plan) < count })
      |> gleam_list.unique
    }
  }
}

fn indices(start: Int, end: Int) -> List(Int) {
  case start >= end {
    True -> []
    False -> [start, ..indices(start + 1, end)]
  }
}

fn keep(values: List(a), wanted: List(Int)) -> List(a) {
  keep_loop(values, wanted, 0, [])
}

fn keep_loop(
  values: List(a),
  wanted: List(Int),
  index: Int,
  accumulated: List(a),
) -> List(a) {
  case values, wanted {
    _, [] | [], _ -> gleam_list.reverse(accumulated)
    [value, ..rest], [next, ..wanted_rest] ->
      case index == next {
        True -> keep_loop(rest, wanted_rest, index + 1, [value, ..accumulated])
        False -> keep_loop(rest, wanted, index + 1, accumulated)
      }
  }
}

fn prefix_tree(choice: Int, tree: Tree(a)) -> Tree(a) {
  Tree(tree.value, [choice, ..tree.tape], fn() {
    tree_children(tree)
    |> gleam_list.map(fn(child) { prefix_tree(choice, child) })
  })
}

fn with_first_child(tree: Tree(a), first: Tree(a)) -> Tree(a) {
  Tree(tree.value, tree.tape, fn() { [first, ..tree_children(tree)] })
}

fn codepoints_to_string(codes: List(Int)) -> String {
  codes
  |> gleam_list.map(fn(code) {
    let assert Ok(point) = string.utf_codepoint(code)
    point
  })
  |> string.from_utf_codepoints
}

fn schema_hash(schema: String) -> Int {
  schema
  |> string.to_utf_codepoints
  |> gleam_list.map(string.utf_codepoint_to_int)
  |> hash_codes(17)
}

fn hash_codes(codes: List(Int), accumulator: Int) -> Int {
  case codes {
    [] -> accumulator
    [code, ..rest] ->
      hash_codes(rest, { accumulator * 131 + code } % minstd_modulus)
  }
}
