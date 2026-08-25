// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// A tiny property-based-testing core: a deterministic PRNG, lazy shrink trees,
// a handful of generators and a greedy counterexample search.
//
// This module is copied verbatim into generated snapshot projects, so it may
// only depend on `gleam_stdlib`: no other packages and no FFI. Every
// intermediate integer stays below 2^53 so that the Erlang and JavaScript
// targets produce exactly the same values.

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// --- PRNG -------------------------------------------------------------------

/// The MINSTD modulus: a prime, so every reachable state is in `1..modulus - 1`.
const minstd_modulus = 2_147_483_647

/// The MINSTD multiplier. `multiplier * state` stays below 2^47, which is
/// exact in a float64 and therefore exact on JavaScript.
const minstd_multiplier = 48_271

/// The number of distinct values `next` can return, namely `1..modulus - 1`.
const minstd_states = 2_147_483_646

/// The number of buckets the first of two draws is scaled into when a range is
/// too wide for a single draw. Only the high bits of a linear congruential
/// generator are worth reading, so the draw is scaled rather than split, and
/// a whole second draw is laid out inside each bucket.
///
/// `4_194_304 * 2_147_483_646` is 9_007_199_246_352_384, just below 2^53, so
/// every combined value stays exact on JavaScript; that product is also the
/// widest range two draws reach every value of.
const wide_high_buckets = 4_194_304

/// An odd constant used to decorrelate the two halves of a `split`.
const split_offset = 1_234_567_891

/// The width of the bucket that makes a draw an "interesting" one, so that one
/// draw in four is spent on an edge value instead of a uniform one.
///
/// `4 * 536_870_912` is 2^31, just above the largest draw, which makes the
/// draws below this constant one quarter of them; reading the decision out of
/// how far up a draw sits keeps it in the high bits, where a linear
/// congruential generator keeps its quality.
const interesting_bucket = 536_870_912

/// The width of the bucket that makes a draw a *hinted* one, namely half of
/// `interesting_bucket`.
///
/// It sits directly above the interesting bucket rather than inside it: the
/// edges of a range are what separates a boundary mutant, and a function that
/// writes a literal down is exactly the kind that also has one, so paying for
/// its hints out of its own edge coverage would have halved the thing the
/// hints were added to help. A hinted generator therefore spends a quarter of
/// its draws on the built-in interesting values exactly as an unhinted one
/// does, an eighth more on the hints, and the remaining five eighths on the
/// uniform draw.
const hint_bucket = 268_435_456

/// A pseudo-random number generator state.
pub opaque type Seed {
  Seed(state: Int)
}

/// Builds a seed from any integer. Negative, zero and very large values are
/// folded deterministically into the valid state range `1..2_147_483_646`.
pub fn seed(n: Int) -> Seed {
  Seed(normalise_state(n))
}

/// Advances the generator, returning the new state and a seed holding it.
///
/// The recurrence is `state' = 48_271 * state % 2_147_483_647` (MINSTD), so
/// the returned value is always in `1..2_147_483_646`.
pub fn next(s: Seed) -> #(Int, Seed) {
  let product = minstd_multiplier * s.state
  let state = product % minstd_modulus
  #(state, Seed(state))
}

/// Derives two decorrelated seeds from one. Deterministic: the same input
/// always yields the same pair.
pub fn split(s: Seed) -> #(Seed, Seed) {
  let #(left, advanced) = next(s)
  let #(right, _) = next(advanced)
  #(Seed(left), Seed(normalise_state(right + split_offset)))
}

fn normalise_state(n: Int) -> Int {
  let remainder = n % minstd_modulus
  let positive = case remainder < 0 {
    True -> remainder + minstd_modulus
    False -> remainder
  }
  case positive {
    0 -> 1
    _ -> positive
  }
}

// --- Shrink trees -----------------------------------------------------------

/// A value together with its lazily computed shrink candidates.
///
/// Children are ordered by preference: the most aggressive shrink first.
pub type Tree(a) {
  Tree(root: a, children: fn() -> List(Tree(a)))
}

/// The value held by a tree.
pub fn tree_root(tree: Tree(a)) -> a {
  tree.root
}

/// Forces the shrink candidates of a tree.
pub fn tree_children(tree: Tree(a)) -> List(Tree(a)) {
  let children = tree.children
  children()
}

/// Rewrites every value in a tree, keeping its shape.
pub fn tree_map(tree: Tree(a), f: fn(a) -> b) -> Tree(b) {
  Tree(f(tree.root), fn() {
    list.map(tree_children(tree), fn(child) { tree_map(child, f) })
  })
}

/// Chains a tree with a value-dependent tree.
///
/// Shrinks of the outer tree are offered before shrinks of the inner tree, so
/// the structure collapses before the details do.
pub fn tree_bind(tree: Tree(a), f: fn(a) -> Tree(b)) -> Tree(b) {
  let inner = f(tree.root)
  Tree(inner.root, fn() {
    let outer = list.map(tree_children(tree), fn(child) { tree_bind(child, f) })
    list.append(outer, tree_children(inner))
  })
}

/// Turns a list of trees into a tree of lists that shrinks element-wise.
///
/// The children of the result replace one element at a time by one of that
/// element's own shrink candidates; the list length is never changed.
pub fn tree_sequence(trees: List(Tree(a))) -> Tree(List(a)) {
  Tree(list.map(trees, tree_root), fn() {
    element_variants([], trees, tree_sequence)
  })
}

fn element_variants(
  prefix: List(Tree(a)),
  rest: List(Tree(a)),
  rebuild: fn(List(Tree(a))) -> Tree(List(a)),
) -> List(Tree(List(a))) {
  case rest {
    [] -> []
    [element, ..tail] -> {
      let head = list.reverse(prefix)
      let replaced =
        list.map(tree_children(element), fn(child) {
          rebuild(list.append(head, [child, ..tail]))
        })
      list.append(
        replaced,
        element_variants([element, ..prefix], tail, rebuild),
      )
    }
  }
}

fn leaf(value: a) -> Tree(a) {
  Tree(value, fn() { [] })
}

// --- Generators -------------------------------------------------------------

/// A recipe that turns a seed into a shrink tree and the next seed.
pub opaque type Generator(a) {
  Generator(run: fn(Seed) -> #(Tree(a), Seed))
}

/// Runs a generator, returning the generated shrink tree and the seed to use
/// for the next draw.
pub fn generate(generator: Generator(a), s: Seed) -> #(Tree(a), Seed) {
  let run = generator.run
  run(s)
}

/// A generator that always produces the same value and never shrinks. It does
/// not consume randomness.
pub fn constant(value: a) -> Generator(a) {
  Generator(fn(s) { #(leaf(value), s) })
}

/// Applies a function to every value a generator produces, shrinks included.
pub fn map(generator: Generator(a), f: fn(a) -> b) -> Generator(b) {
  Generator(fn(s) {
    let #(tree, advanced) = generate(generator, s)
    #(tree_map(tree, f), advanced)
  })
}

/// Combines two generators. Shrinks of the first value are tried before
/// shrinks of the second.
pub fn map2(
  first: Generator(a),
  second: Generator(b),
  f: fn(a, b) -> c,
) -> Generator(c) {
  Generator(fn(s) {
    let #(left, after_left) = generate(first, s)
    let #(right, after_right) = generate(second, after_left)
    #(tree_pair(left, right, f), after_right)
  })
}

fn tree_pair(left: Tree(a), right: Tree(b), f: fn(a, b) -> c) -> Tree(c) {
  Tree(f(left.root, right.root), fn() {
    let from_left =
      list.map(tree_children(left), fn(child) { tree_pair(child, right, f) })
    let from_right =
      list.map(tree_children(right), fn(child) { tree_pair(left, child, f) })
    list.append(from_left, from_right)
  })
}

/// Chains a generator with a generator that depends on the drawn value.
///
/// The dependent generator is always run with the same derived seed so that
/// re-generating it while shrinking stays deterministic.
pub fn bind(generator: Generator(a), f: fn(a) -> Generator(b)) -> Generator(b) {
  Generator(fn(s) {
    let #(tree, advanced) = generate(generator, s)
    let #(inner_seed, rest_seed) = split(advanced)
    let bound =
      tree_bind(tree, fn(value) {
        let #(inner, _) = generate(f(value), inner_seed)
        inner
      })
    #(bound, rest_seed)
  })
}

/// Picks one of the given generators uniformly.
///
/// A value drawn from one of `rest` offers the value `first` would have
/// produced as its first shrink candidate, making `first` the shrink target.
pub fn one_of(first: Generator(a), rest: List(Generator(a))) -> Generator(a) {
  let options = [first, ..rest]
  let count = list.length(options)
  Generator(fn(s) {
    let #(raw, advanced) = next(s)
    let index = raw % count
    let #(branch_seed, rest_seed) = split(advanced)
    let chosen = case list.drop(options, index) {
      [generator, ..] -> generator
      [] -> first
    }
    let #(tree, _) = generate(chosen, branch_seed)
    case index {
      0 -> #(tree, rest_seed)
      _ -> {
        let #(fallback, _) = generate(first, branch_seed)
        let with_fallback =
          Tree(tree.root, fn() { [fallback, ..tree_children(tree)] })
        #(with_fallback, rest_seed)
      }
    }
  })
}

/// An integer in the inclusive range `lo..hi`, biased towards its edges.
///
/// If `lo > hi` the bounds are swapped. One draw in four is an *interesting*
/// value rather than a uniform one — zero, either bound, the neighbour just
/// inside either bound, `1` or `-1`, whichever of those the range holds,
/// picked uniformly among them. A boundary mutant such as `>` for `>=` is
/// told apart by an exact edge and by nothing else, and a uniform draw only
/// stumbles on one; the other three draws in four stay uniform over the whole
/// range, which is what covers everything a boundary is not.
///
/// The bias costs no randomness: the draw that would have picked a uniform
/// value decides instead, so a range still costs the draw it always did. What
/// it costs is room, because a draw spent on an edge is a draw no offset is
/// read out of. A range wider than the draws the bias leaves alone therefore
/// takes two of them rather than lose the offsets the reserved draws carried,
/// and every value of a range holding up to 9_007_199_246_352_384 of them is
/// reachable. A range wider than that, which is 2^53 - 2^23 and past what
/// either target draws exactly, would keep its top out of reach.
///
/// Values shrink towards the value of the range closest to zero using
/// binary-search candidates: the target first, then — for a negative value the
/// range holds the mirror of — that mirror, then the halfway points, ending at
/// the neighbour of the value itself. The mirror is offered before the
/// halvings because at equal magnitude `1` and `-1` separate exactly the same
/// mutants and only one of them reads as a value anybody meant.
pub fn int(lo: Int, hi: Int) -> Generator(Int) {
  let #(low, high) = ordered(lo, hi)
  biased_towards(low, high, interesting_values(low, high), [])
}

/// The bounds in the order the generators read them.
fn ordered(lo: Int, hi: Int) -> #(Int, Int) {
  case lo <= hi {
    True -> #(lo, hi)
    False -> #(hi, lo)
  }
}

/// An integer in `-100..100`, biased towards the edges the way `int` is.
pub fn small_int() -> Generator(Int) {
  int(-100, 100)
}

/// A boolean. `True` shrinks to `False`.
pub fn bool() -> Generator(Bool) {
  map(int(0, 1), fn(value) { value == 1 })
}

/// The `Nil` value. Consumes no randomness and never shrinks.
pub fn nil() -> Generator(Nil) {
  constant(Nil)
}

/// A finite float in `-1000.0..1000.0` with three decimals.
///
/// It is drawn as an integer divided by 1000.0 so that both targets agree on
/// every produced value, and it inherits that integer's edge bias: one draw in
/// four is `0.0`, `1000.0`, `-1000.0`, a thousandth inside either of those, or
/// `0.001` or `-0.001`. It shrinks towards `0.0` through the integer tree.
pub fn float() -> Generator(Float) {
  map(int(-1_000_000, 1_000_000), fn(value) { int.to_float(value) /. 1000.0 })
}

/// A string of 0 to 20 printable ASCII characters (codes 32 to 126).
///
/// The length and the characters are both drawn uniformly, unlike `int`: a
/// boundary does not hide in a character code, and an edge-biased length
/// would spend a quarter of every sample on the empty string, which tells no
/// mutant apart.
///
/// The length shrinks first (characters are dropped), then each character
/// shrinks towards `"a"`. The floor is one character: `""` is reached only by
/// being drawn, because a test asserting on the empty string pins an accident
/// of an empty input rather than a behaviour.
pub fn string() -> Generator(String) {
  drawn_string([], [])
}

/// The strings the search draws on purpose whatever the code under test says.
///
/// Each one carries a shape a uniform draw over printable ASCII practically
/// never produces: a single letter, a two-letter word, a word, a digit, the
/// three whitespace characters a line ending is made of, and the four path
/// shapes a string is split, joined or prefixed on.
pub const interesting_strings = [
  "a", "ab", "hello", "0", " ", "\n", "\r\n", "/", "./", "\\",
]

/// `int` with `hints` among the values it draws on purpose.
///
/// One draw in four goes to the built-in interesting values, exactly as `int`
/// spends it, and one draw in eight more goes to the hints the caller
/// supplied, hints outside `lo..hi` dropped. The hints are added to the search
/// rather than traded against the edges: a couple of them are reached within
/// the first tens of cases, and a boundary mutant of the same function still
/// meets its edge as often as it ever did. A hinted value shrinks exactly as
/// any other value of the range does.
pub fn int_with_hints(lo: Int, hi: Int, hints: List(Int)) -> Generator(Int) {
  let #(low, high) = ordered(lo, hi)
  biased_towards(
    low,
    high,
    interesting_values(low, high),
    held(hints, low, high),
  )
}

/// The hints a range holds, each kept once.
///
/// A hint the built-in set already offers is kept all the same: it costs
/// nothing to draw the same value from two buckets, and dropping it would make
/// the hinted eighth narrower the closer a function's literals are to the
/// edges it is already searched at.
fn held(hints: List(Int), low: Int, high: Int) -> List(Int) {
  hints
  |> list.filter(fn(value) { value >= low && value <= high })
  |> list.unique
}

/// `float` with `hints` among the values it draws on purpose.
///
/// A float is drawn as a thousandth, so a hint is offered as the nearest one:
/// `2.5` is `2500` to the integer the draw comes out of, and everything past
/// three decimals is a value this generator has no way to produce anyway.
pub fn float_with_hints(hints: List(Float)) -> Generator(Float) {
  map(
    int_with_hints(-1_000_000, 1_000_000, list.map(hints, thousandths)),
    fn(value) { int.to_float(value) /. 1000.0 },
  )
}

/// The thousandths a float is worth, which is what `float` draws.
fn thousandths(value: Float) -> Int {
  float.round(value *. 1000.0)
}

/// `string` with `hints` and `interesting_strings` among the values it draws
/// on purpose.
///
/// One draw in four goes to the built-in set and one in eight to the hints, so
/// a literal the code under test compares against is reached in a handful of
/// cases rather than never, and the shapes a uniform draw never makes are
/// reached as often as they would be without hints. A hinted value shrinks
/// exactly as any other string does, the floor of one character included.
pub fn string_with_hints(hints: List(String)) -> Generator(String) {
  drawn_string(interesting_strings, list.unique(hints))
}

/// A string of 0 to 20 printable ASCII characters, with one draw in four spent
/// on an `interesting` string and one in eight on a `hinted` one — and
/// neither, when there is nothing to spend them on.
///
/// The single draw the length used to come out of answers all three questions,
/// so a plain string still costs the draws it always did.
fn drawn_string(
  interesting: List(String),
  hinted: List(String),
) -> Generator(String) {
  let choices = list.length(interesting)
  let hints = list.length(hinted)
  let reserved = reserved_bucket(hints)
  Generator(fn(s) {
    let #(raw, advanced) = next(s)
    case
      choices > 0 && raw < interesting_bucket,
      hints > 0 && raw >= interesting_bucket && raw < reserved
    {
      True, _ -> #(text_of(pick_text(interesting, raw % choices)), advanced)
      _, True -> #(
        text_of(pick_text(hinted, { raw - interesting_bucket } % hints)),
        advanced,
      )
      _, _ -> {
        let length = raw % 21
        let #(chars, rest_seed) =
          draw_trees(uniform_towards(32, 126, 97), length, advanced, [])
        #(tree_map(text_tree(chars), codes_to_string), rest_seed)
      }
    }
  })
}

/// The element of `texts` at `index`, or the empty string if there is none.
fn pick_text(texts: List(String), index: Int) -> String {
  case list.drop(texts, index) {
    [text, ..] -> text
    [] -> ""
  }
}

/// `text` as the tree a drawn string of the same characters would have, so a
/// hint shrinks the way everything else does.
fn text_of(text: String) -> Tree(String) {
  let characters =
    string.to_utf_codepoints(text)
    |> list.map(string.utf_codepoint_to_int)
    |> list.map(fn(code) { int_tree(code, 97, 32, 126) })
  tree_map(text_tree(characters), codes_to_string)
}

/// A bit array of 0 to 16 bytes.
///
/// The length is drawn uniformly — an empty bit array carries nothing to tell
/// a mutant apart with — while the bytes come from `int` and are biased
/// towards `0` and `255` like any other range.
///
/// The length shrinks first, then each byte shrinks towards zero.
pub fn bit_array() -> Generator(BitArray) {
  Generator(fn(s) {
    let #(raw, advanced) = next(s)
    let length = raw % 17
    let #(bytes, rest_seed) = draw_trees(int(0, 255), length, advanced, [])
    #(tree_map(list_tree(bytes), bytes_to_bit_array), rest_seed)
  })
}

/// A list of 0 to 10 values.
///
/// The length is drawn uniformly rather than biased towards the edges of
/// `0..10` the way `int` is: a quarter of every sample would be the empty
/// list, and an empty list carries nothing to tell a mutant apart with.
///
/// Shrinking removes elements first (the empty list, then halves, then single
/// removals) and only then shrinks the remaining elements.
pub fn list(generator: Generator(a)) -> Generator(List(a)) {
  Generator(fn(s) {
    let #(raw, advanced) = next(s)
    let length = raw % 11
    let #(elements, rest_seed) = draw_trees(generator, length, advanced, [])
    #(list_tree(elements), rest_seed)
  })
}

/// An optional value. `Some(x)` shrinks to `None` first.
pub fn option(generator: Generator(a)) -> Generator(Option(a)) {
  one_of(constant(None), [map(generator, Some)])
}

/// A result. `Error(e)` offers an `Ok` value as its first shrink candidate.
pub fn result(
  ok: Generator(a),
  error: Generator(e),
) -> Generator(Result(a, e)) {
  one_of(map(ok, Ok), [map(error, Error)])
}

/// A pair. The first component shrinks before the second.
pub fn tuple2(first: Generator(a), second: Generator(b)) -> Generator(#(a, b)) {
  map2(first, second, fn(a, b) { #(a, b) })
}

/// A triple. Components shrink left to right.
pub fn tuple3(
  first: Generator(a),
  second: Generator(b),
  third: Generator(c),
) -> Generator(#(a, b, c)) {
  map2(tuple2(first, second), third, fn(pair, c) {
    let #(a, b) = pair
    #(a, b, c)
  })
}

/// A uniform integer in `low..high` that shrinks towards `target`.
///
/// The unbiased path, for the draws where an edge is not what tells anything
/// apart: the characters of a string.
fn uniform_towards(low: Int, high: Int, target: Int) -> Generator(Int) {
  Generator(fn(s) {
    // Nothing is reserved here: the whole draw is spent on the offset.
    let #(_, offset, advanced) = draw_offset(high - low + 1, 1, s)
    #(int_tree(low + offset, target, low, high), advanced)
  })
}

/// `uniform_towards` with one draw in four spent on an interesting value, and
/// one in eight more on a hint when there are hints.
///
/// One draw answers both questions: the bucket it falls in says which kind of
/// draw this is, and its remainder picks — the offset into the range, the
/// index into the interesting values, or the index into the hints. A range one
/// draw covers therefore still costs the single MINSTD draw it always did, and
/// a range that needs two still costs two, so every generator built on this
/// one keeps drawing in step. What the decision spends is `reserved_bucket`,
/// and `draw_offset` is told the figure: the offsets it may read are the ones
/// above it.
fn biased_towards(
  low: Int,
  high: Int,
  interesting: List(Int),
  hinted: List(Int),
) -> Generator(Int) {
  let target = zero_closest(low, high)
  let choices = list.length(interesting)
  let hints = list.length(hinted)
  let reserved = reserved_bucket(hints)
  Generator(fn(s) {
    let #(raw, offset, advanced) = draw_offset(high - low + 1, reserved, s)
    let value = case raw < interesting_bucket, raw < reserved {
      True, _ -> pick(interesting, raw % choices, low)
      _, True -> pick(hinted, { raw - interesting_bucket } % hints, low)
      _, _ -> low + offset
    }
    #(int_tree(value, target, low, high), advanced)
  })
}

/// The draws a generator spends on a value it chose rather than drew: the
/// interesting quarter, and an eighth more when there are hints to spend it
/// on.
///
/// Everything above it is the uniform draw, and `draw_offset` is told the
/// figure so that the offsets it reads come from the run of draws nothing else
/// claimed.
fn reserved_bucket(hints: Int) -> Int {
  case hints {
    0 -> interesting_bucket
    _ -> interesting_bucket + hint_bucket
  }
}

/// The values a boundary hides at, as far as `low..high` holds them: zero,
/// both bounds, the neighbour just inside either bound, and the units either
/// side of zero.
///
/// Each is kept once, so a range as narrow as `3..5` — where `low + 1` and
/// `high - 1` are the same value — still picks uniformly among the three
/// values it has. `low` always survives, so the list is never empty.
fn interesting_values(low: Int, high: Int) -> List(Int) {
  [0, low, high, low + 1, high - 1, 1, -1]
  |> list.filter(fn(value) { value >= low && value <= high })
  |> list.unique
}

/// The element of `values` at `index`, or `fallback` if there is none.
fn pick(values: List(Int), index: Int, fallback: Int) -> Int {
  case list.drop(values, index) {
    [value, ..] -> value
    [] -> fallback
  }
}

/// Draws a uniform offset in `0..count - 1`, and hands back the draw it came
/// out of so a caller can read a second decision from the same randomness.
///
/// `lowest` is the smallest draw an offset is read out of. A caller that
/// spends the draws below it on something else — the edge bias spends the
/// bottom quarter of them on an interesting value — leaves a run of
/// `minstd_states - lowest + 1` consecutive draws, and a run of consecutive
/// integers holds every remainder of a `count` no wider than itself: that, and
/// not the generator's number of states, is how wide a range a single draw
/// still covers. Reading a wider range out of one draw would lose exactly the
/// offsets the reserved draws used to carry.
///
/// A range too wide for that takes a second draw: the position of the first
/// draw inside the run it may use is scaled to `wide_high_buckets`, and a
/// whole second draw is laid out inside each bucket. That covers
/// `0..9_007_199_246_352_383` with nothing left out, whatever was reserved,
/// and every intermediate stays below 2^53. The draw handed back is the first
/// one either way.
fn draw_offset(count: Int, lowest: Int, s: Seed) -> #(Int, Int, Seed) {
  let window = minstd_states - lowest + 1
  case count <= window {
    True -> {
      let #(raw, advanced) = next(s)
      #(raw, raw % count, advanced)
    }
    False -> {
      let #(high, after_high) = next(s)
      let #(low, advanced) = next(after_high)
      // A draw below `lowest` was spent on something else, and the offset it
      // would give is never read; it stands in for the first position of the
      // run so that the arithmetic below stays inside its bounds.
      let position = case high >= lowest {
        True -> high - lowest
        False -> 0
      }
      let bucket = { position * wide_high_buckets } / window
      let combined = bucket * minstd_states + low - 1
      #(high, combined % count, advanced)
    }
  }
}

fn zero_closest(low: Int, high: Int) -> Int {
  case low > 0, high < 0 {
    True, _ -> low
    _, True -> high
    False, False -> 0
  }
}

fn int_tree(value: Int, target: Int, low: Int, high: Int) -> Tree(Int) {
  Tree(value, fn() {
    int_steps(value, target, low, high)
    |> list.map(fn(candidate) { int_tree(candidate, target, low, high) })
  })
}

/// The candidates a value offers, most aggressive first: the target, then the
/// mirror of a negative value, then the binary-search steps back towards it.
///
/// The mirror is what makes `Score(total: 1, killed: 0, timed_out: 1, ..)`
/// come out of a search that used to answer `timed_out: -1`: at equal
/// magnitude the two separate exactly the same mutants, and only one of them
/// reads as a value anybody meant. It is offered before the halvings because a
/// greedy shrink takes the first candidate that still fails, and a smaller
/// magnitude would be taken first otherwise. A range the mirror falls outside
/// of never offers it.
fn int_steps(value: Int, target: Int, low: Int, high: Int) -> List(Int) {
  case value == target {
    True -> []
    False -> {
      let mirror = case value < 0 && -value <= high && -value >= low {
        True -> [-value]
        False -> []
      }
      [target, ..list.append(mirror, halve_towards(target, value))]
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

fn draw_trees(
  generator: Generator(a),
  count: Int,
  s: Seed,
  acc: List(Tree(a)),
) -> #(List(Tree(a)), Seed) {
  case count <= 0 {
    True -> #(list.reverse(acc), s)
    False -> {
      let #(tree, advanced) = generate(generator, s)
      draw_trees(generator, count - 1, advanced, [tree, ..acc])
    }
  }
}

/// `list_tree` with a floor of one element, which is what a string shrinks by.
///
/// Shrinking to `""` is minimal and meaningless: measured on real code it
/// produced `render.import_line(render.Requirement("", None, ["", ""]))
/// == "import .{, }"`, an artefact of an empty module name rather than any
/// behaviour. The empty string stays reachable by being drawn — a drawn one is
/// a leaf and stays the counterexample — but nothing shrinks onto it.
fn text_tree(characters: List(Tree(Int))) -> Tree(List(Int)) {
  Tree(list.map(characters, tree_root), fn() {
    let shorter =
      removal_plans(list.length(characters))
      |> list.filter(fn(kept) { kept != [] })
      |> list.map(fn(kept) { text_tree(keep(characters, kept)) })
    list.append(shorter, element_variants([], characters, text_tree))
  })
}

fn list_tree(elements: List(Tree(a))) -> Tree(List(a)) {
  Tree(list.map(elements, tree_root), fn() {
    let shorter =
      removal_plans(list.length(elements))
      |> list.map(fn(kept) { list_tree(keep(elements, kept)) })
    list.append(shorter, element_variants([], elements, list_tree))
  })
}

fn removal_plans(count: Int) -> List(List(Int)) {
  case count {
    0 -> []
    _ -> {
      let all = indices(0, count)
      let half = count / 2
      let halves = case half {
        0 -> []
        _ -> [indices(0, half), indices(half, count)]
      }
      let removals = case count {
        1 -> []
        _ ->
          list.map(all, fn(dropped) {
            list.filter(all, fn(index) { index != dropped })
          })
      }
      [[], ..list.append(halves, removals)]
      |> list.unique
    }
  }
}

fn indices(from: Int, to: Int) -> List(Int) {
  case from >= to {
    True -> []
    False -> [from, ..indices(from + 1, to)]
  }
}

fn keep(elements: List(Tree(a)), kept: List(Int)) -> List(Tree(a)) {
  list.filter_map(kept, fn(index) {
    case list.drop(elements, index) {
      [element, ..] -> Ok(element)
      [] -> Error(Nil)
    }
  })
}

fn codes_to_string(codes: List(Int)) -> String {
  codes
  |> list.filter_map(string.utf_codepoint)
  |> string.from_utf_codepoints
}

fn bytes_to_bit_array(bytes: List(Int)) -> BitArray {
  bytes
  |> list.map(fn(byte) { <<byte>> })
  |> bit_array.concat
}

// --- Counterexample search --------------------------------------------------

/// The result of a counterexample search.
pub type Outcome(a) {
  /// A failing value was found: the shrunk value, the value first drawn, how
  /// many cases were drawn and how many shrink steps were taken.
  Found(shrunk: a, original: a, cases: Int, shrinks: Int)
  /// No failing value was found within the given number of cases.
  NotFound(cases: Int)
}

/// Searches for a value that makes `property` return `False`.
///
/// Up to `max_cases` values are drawn. The first failing value is then shrunk
/// greedily: the first shrink candidate that also fails is taken, repeatedly,
/// until no candidate fails or `max_shrinks` steps have been used.
pub fn find_counterexample(
  generator: Generator(a),
  s: Seed,
  max_cases: Int,
  max_shrinks: Int,
  property: fn(a) -> Bool,
) -> Outcome(a) {
  search(generator, s, max_cases, max_shrinks, property, 0)
}

fn search(
  generator: Generator(a),
  s: Seed,
  max_cases: Int,
  max_shrinks: Int,
  property: fn(a) -> Bool,
  drawn: Int,
) -> Outcome(a) {
  case drawn >= max_cases {
    True -> NotFound(drawn)
    False -> {
      let #(tree, advanced) = generate(generator, s)
      let value = tree_root(tree)
      case property(value) {
        True ->
          search(
            generator,
            advanced,
            max_cases,
            max_shrinks,
            property,
            drawn + 1,
          )
        False -> {
          let #(shrunk, shrinks) = shrink(tree, property, max_shrinks, 0)
          Found(
            shrunk: shrunk,
            original: value,
            cases: drawn + 1,
            shrinks: shrinks,
          )
        }
      }
    }
  }
}

fn shrink(
  tree: Tree(a),
  property: fn(a) -> Bool,
  max_shrinks: Int,
  used: Int,
) -> #(a, Int) {
  case used >= max_shrinks {
    True -> #(tree_root(tree), used)
    False ->
      case first_failing(tree_children(tree), property) {
        Some(child) -> shrink(child, property, max_shrinks, used + 1)
        None -> #(tree_root(tree), used)
      }
  }
}

fn first_failing(
  candidates: List(Tree(a)),
  property: fn(a) -> Bool,
) -> Option(Tree(a)) {
  case candidates {
    [] -> None
    [candidate, ..rest] ->
      case property(tree_root(candidate)) {
        False -> Some(candidate)
        True -> first_failing(rest, property)
      }
  }
}
