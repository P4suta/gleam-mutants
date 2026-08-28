// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/pbt.{Found, NotFound, Tree}

// --- PRNG -------------------------------------------------------------------

/// The MINSTD recurrence s' = (48_271 * s) mod 2_147_483_647 starting from 1.
/// Computed independently with Erlang integers and with JavaScript BigInt.
pub fn minstd_golden_sequence_test() {
  assert take_values(pbt.seed(1), 5)
    == [48_271, 182_605_794, 1_291_394_886, 1_914_720_637, 2_078_669_041]
}

pub fn seed_normalises_any_int_to_a_valid_state_test() {
  assert stays_in_range(pbt.seed(0), 5000)
  assert stays_in_range(pbt.seed(-5), 5000)
  assert stays_in_range(pbt.seed(1), 5000)
  assert stays_in_range(pbt.seed(2_147_483_647), 5000)
  assert stays_in_range(pbt.seed(9_007_199_254_740_991), 5000)
}

pub fn seed_zero_and_negative_seeds_still_advance_test() {
  let #(from_zero, _) = pbt.next(pbt.seed(0))
  let #(from_negative, _) = pbt.next(pbt.seed(-5))
  assert from_zero >= 1
  assert from_negative >= 1
  assert from_zero != from_negative
}

pub fn split_is_deterministic_and_decorrelated_test() {
  let #(left, right) = pbt.split(pbt.seed(7))
  let #(left_again, right_again) = pbt.split(pbt.seed(7))
  assert pbt.next(left) == pbt.next(left_again)
  assert pbt.next(right) == pbt.next(right_again)
  assert left != right
  let #(left_value, _) = pbt.next(left)
  let #(right_value, _) = pbt.next(right)
  assert left_value != right_value
}

// --- Shrink trees -----------------------------------------------------------

pub fn tree_map_rewrites_root_and_children_test() {
  let tree = node(2, [1, 0])
  let doubled = pbt.tree_map(tree, fn(value) { value * 10 })
  assert pbt.tree_root(doubled) == 20
  assert child_roots(doubled) == [10, 0]
}

pub fn tree_bind_shrinks_outer_before_inner_test() {
  let tree = node(2, [1])
  let bound = pbt.tree_bind(tree, fn(value) { node(value * 10, [value]) })
  assert pbt.tree_root(bound) == 20
  assert child_roots(bound) == [10, 2]
}

pub fn tree_sequence_shrinks_element_wise_test() {
  let first = node(1, [11])
  let second = node(2, [21, 22])
  let third = node(3, [31, 32, 33])
  let sequenced = pbt.tree_sequence([first, second, third])
  assert pbt.tree_root(sequenced) == [1, 2, 3]
  let children = pbt.tree_children(sequenced)
  assert list.length(children) == 6
  assert list.map(children, pbt.tree_root)
    == [
      [11, 2, 3],
      [1, 21, 3],
      [1, 22, 3],
      [1, 2, 31],
      [1, 2, 32],
      [1, 2, 33],
    ]
}

pub fn tree_sequence_of_leaves_has_no_children_test() {
  let sequenced = pbt.tree_sequence([leaf(1), leaf(2)])
  assert pbt.tree_root(sequenced) == [1, 2]
  assert list.is_empty(pbt.tree_children(sequenced))
}

// --- Generator basics -------------------------------------------------------

pub fn constant_never_varies_and_never_shrinks_test() {
  let #(tree, _) = pbt.generate(pbt.constant("fixed"), pbt.seed(1))
  assert pbt.tree_root(tree) == "fixed"
  assert list.is_empty(pbt.tree_children(tree))
}

pub fn generators_are_deterministic_for_the_same_seed_test() {
  let #(first, _) = pbt.generate(pbt.string(), pbt.seed(42))
  let #(again, _) = pbt.generate(pbt.string(), pbt.seed(42))
  assert pbt.tree_root(first) == pbt.tree_root(again)

  let #(other, _) = pbt.generate(pbt.string(), pbt.seed(15))
  let #(other_again, _) = pbt.generate(pbt.string(), pbt.seed(15))
  assert pbt.tree_root(other) == pbt.tree_root(other_again)
  assert string.length(pbt.tree_root(other)) > 0
}

pub fn different_seeds_give_different_roots_test() {
  let #(one, _) = pbt.generate(pbt.int(0, 1_000_000), pbt.seed(1))
  let #(two, _) = pbt.generate(pbt.int(0, 1_000_000), pbt.seed(2))
  assert pbt.tree_root(one) != pbt.tree_root(two)
}

pub fn map_transforms_generated_values_test() {
  let generator = pbt.map(pbt.int(0, 100), fn(value) { value * 2 })
  assert list.all(sample(generator, pbt.seed(3), 100), fn(value) {
    value >= 0 && value <= 200
  })
}

pub fn map2_combines_two_generators_test() {
  let generator = pbt.map2(pbt.constant(2), pbt.constant(3), fn(a, b) { a * b })
  let #(tree, _) = pbt.generate(generator, pbt.seed(1))
  assert pbt.tree_root(tree) == 6
}

pub fn bind_chooses_the_next_generator_from_the_first_value_test() {
  let generator = pbt.bind(pbt.int(3, 3), fn(value) { pbt.constant(value * 7) })
  let #(tree, _) = pbt.generate(generator, pbt.seed(2))
  assert pbt.tree_root(tree) == 21
}

pub fn filter_map_is_deterministic_and_keeps_only_accepted_values_test() {
  let even =
    pbt.filter_map(pbt.int(0, 100), 200, fn(value) {
      case value % 2 == 0 {
        True -> Some(value / 2)
        False -> None
      }
    })
  let first = sample(even, pbt.seed(27), 100)
  let again = sample(even, pbt.seed(27), 100)

  assert first == again
  assert list.all(first, fn(value) { value >= 0 && value <= 50 })
}

pub fn filter_map_drops_rejected_shrink_candidates_test() {
  let filtered =
    pbt.filter_map(pbt.int(0, 100), 200, fn(value) {
      case value % 2 == 0 {
        True -> Some(value)
        False -> None
      }
    })
  let #(tree, _) = pbt.generate(filtered, pbt.seed(1))

  assert list.all(tree_values(tree), fn(value) { value % 2 == 0 })
}

pub fn one_of_picks_every_branch_and_shrinks_to_the_first_test() {
  let generator =
    pbt.one_of(pbt.constant(0), [pbt.int(20, 29), pbt.int(30, 39)])
  let trees = sample_trees(generator, pbt.seed(13), 60)
  let roots = list.map(trees, pbt.tree_root)
  assert list.contains(roots, 0)
  assert list.any(roots, fn(value) { value >= 20 && value <= 29 })
  assert list.any(roots, fn(value) { value >= 30 && value <= 39 })
  assert list.all(trees, fn(tree) {
    case pbt.tree_root(tree) {
      0 -> list.is_empty(pbt.tree_children(tree))
      _ -> list.first(child_roots(tree)) == Ok(0)
    }
  })
}

// --- Generator bounds -------------------------------------------------------

pub fn int_stays_within_bounds_and_reaches_both_endpoints_test() {
  let values = sample(pbt.int(-7, 7), pbt.seed(42), 500)
  assert list.length(values) == 500
  assert list.all(values, fn(value) { value >= -7 && value <= 7 })
  assert list.contains(values, -7)
  assert list.contains(values, 7)
}

pub fn int_offers_the_zero_closest_target_as_first_shrink_test() {
  let trees = sample_trees(pbt.int(-7, 7), pbt.seed(42), 100)
  assert list.all(trees, fn(tree) {
    case pbt.tree_root(tree) {
      0 -> list.is_empty(pbt.tree_children(tree))
      _ -> list.first(child_roots(tree)) == Ok(0)
    }
  })
  let above = sample_trees(pbt.int(5, 9), pbt.seed(4), 100)
  assert list.all(above, fn(tree) {
    case pbt.tree_root(tree) {
      5 -> list.is_empty(pbt.tree_children(tree))
      _ -> list.first(child_roots(tree)) == Ok(5)
    }
  })
}

pub fn int_with_a_single_value_range_is_constant_test() {
  assert sample(pbt.int(4, 4), pbt.seed(6), 20) == list.repeat(4, 20)
}

pub fn int_swaps_reversed_bounds_test() {
  let values = sample(pbt.int(9, 3), pbt.seed(3), 200)
  assert list.all(values, fn(value) { value >= 3 && value <= 9 })
  assert list.contains(values, 3)
  assert list.contains(values, 9)
}

pub fn int_covers_ranges_wider_than_the_prng_period_test() {
  let values = sample(pbt.int(0, 4_000_000_000), pbt.seed(5), 200)
  assert list.all(values, fn(value) { value >= 0 && value <= 4_000_000_000 })
  assert list.any(values, fn(value) { value > 2_147_483_646 })
  assert list.any(values, fn(value) { value < 2_147_483_646 })
  assert list.any(values, fn(value) { value < 400_000_000 })
}

// --- Edge-value bias --------------------------------------------------------

/// A boundary mutant — `>` becoming `>=` — is told apart by an exact boundary
/// value and by nothing else, so the edges of a range have to be drawn on
/// purpose. Drawn uniformly, `int(-100, 100)` from seed 1 first produces `0`
/// on draw 182 of 200: one unlucky seed away from never producing it at all.
pub fn int_draws_the_interesting_values_early_test() {
  let values = sample(pbt.int(-100, 100), pbt.seed(1), 200)
  assert list.contains(list.take(values, 40), 0)
  assert list.contains(values, -100)
  assert list.contains(values, 100)
}

/// The interesting values belong to the range they are drawn from: in a
/// three-value range `lo + 1` and `hi - 1` overlap the bounds, and `0`, `1`
/// and `-1` are outside it altogether. None of them may escape, and a range
/// holding one value stays constant.
pub fn int_interesting_values_stay_inside_a_narrow_range_test() {
  let narrow = sample(pbt.int(3, 5), pbt.seed(1), 200)
  assert list.all(narrow, fn(value) { value >= 3 && value <= 5 })
  assert list.contains(narrow, 3)
  assert list.contains(narrow, 5)

  assert sample(pbt.int(-2, -2), pbt.seed(1), 200) == list.repeat(-2, 200)
}

/// The bias reserves the bottom quarter of every draw for its interesting
/// values, which is a quarter the uniform draws no longer come out of. A range
/// too wide to be read out of what is left of a single draw would lose exactly
/// the offsets that quarter used to carry: read that way,
/// `int(0, 2_000_000_000)` never produced a value in three of twenty equal
/// slices of its own range, a hole covering a sixth of it.
pub fn int_covers_every_slice_of_a_range_near_the_draw_space_test() {
  assert missing_slices(pbt.int(0, 2_000_000_000), 0, 2_000_000_000) == []
  assert missing_slices(
      pbt.int(-1_000_000_000, 1_000_000_000),
      -1_000_000_000,
      1_000_000_000,
    )
    == []
  // The widest range a single draw still covers, one either side of it: the
  // narrow one is read out of one draw, the wide one out of two, and both have
  // to reach every slice of themselves.
  assert missing_slices(pbt.int(0, 1_610_612_734), 0, 1_610_612_734) == []
  assert missing_slices(pbt.int(0, 1_610_612_735), 0, 1_610_612_735) == []
}

/// Two draws carry a range of quadrillions, and the reserved quarter must not
/// eat into that one either: the whole of the widest range `int` documents is
/// reachable.
pub fn int_covers_every_slice_of_the_widest_documented_range_test() {
  assert missing_slices(
      pbt.int(0, 9_007_199_246_352_383),
      0,
      9_007_199_246_352_383,
    )
    == []
}

/// Lengths are not where a boundary hides, and pulling them towards the edges
/// of `0..10` and `0..20` would spend a quarter of every sample on the empty
/// list and the empty string: a drawn container still has to carry something
/// to tell a mutant apart with.
pub fn container_lengths_are_not_pulled_towards_empty_test() {
  let lists = sample(pbt.list(pbt.small_int()), pbt.seed(11), 300)
  assert list.count(lists, list.is_empty) * 4 < 300

  let strings = sample(pbt.string(), pbt.seed(5), 300)
  assert list.count(strings, fn(value) { value == "" }) * 4 < 300
}

pub fn small_int_covers_the_documented_range_test() {
  let values = sample(pbt.small_int(), pbt.seed(8), 2000)
  assert list.all(values, fn(value) { value >= -100 && value <= 100 })
  assert list.any(values, fn(value) { value < 0 })
  assert list.any(values, fn(value) { value > 0 })
  assert list.contains(values, -100)
  assert list.contains(values, 100)
}

pub fn bool_generates_both_values_and_shrinks_towards_false_test() {
  let trees = sample_trees(pbt.bool(), pbt.seed(6), 60)
  let roots = list.map(trees, pbt.tree_root)
  assert list.contains(roots, True)
  assert list.contains(roots, False)
  assert list.all(trees, fn(tree) {
    case pbt.tree_root(tree) {
      True -> child_roots(tree) == [False]
      False -> list.is_empty(pbt.tree_children(tree))
    }
  })
}

pub fn nil_generates_nil_test() {
  assert sample(pbt.nil(), pbt.seed(5), 5) == [Nil, Nil, Nil, Nil, Nil]
}

pub fn float_is_finite_and_scaled_by_a_thousand_test() {
  let values = sample(pbt.float(), pbt.seed(3), 300)
  let lower = 0.0 -. 1000.0
  assert list.all(values, fn(value) { value >=. lower && value <=. 1000.0 })
  assert list.any(values, fn(value) { value <. 0.0 })
  assert list.any(values, fn(value) { value >. 0.0 })
  // Every value is an exact multiple of 1/1000: it round-trips through the
  // integer scale it was drawn from.
  assert list.all(values, fn(value) {
    int.to_float(float.round(value *. 1000.0)) /. 1000.0 == value
  })
  // ... and the scale really is thousandths, not whole numbers.
  assert list.any(values, fn(value) {
    value != int.to_float(float.truncate(value))
  })
  assert list.any(values, fn(value) {
    let thousandths = float.round(value *. 1000.0)
    thousandths % 10 != 0
  })
}

pub fn float_offers_zero_as_its_first_shrink_test() {
  let trees = sample_trees(pbt.float(), pbt.seed(12), 100)
  assert list.any(trees, fn(tree) { pbt.tree_root(tree) != 0.0 })
  assert list.all(trees, fn(tree) {
    case pbt.tree_root(tree) == 0.0 {
      True -> list.is_empty(pbt.tree_children(tree))
      False -> list.first(child_roots(tree)) == Ok(0.0)
    }
  })
}

pub fn string_is_short_printable_ascii_test() {
  let values = sample(pbt.string(), pbt.seed(5), 300)
  assert list.all(values, fn(value) { string.length(value) <= 20 })
  assert list.all(values, is_printable_ascii)
  assert list.any(values, fn(value) { string.length(value) == 0 })
  assert list.any(values, fn(value) { string.length(value) == 20 })

  let codes = list.flat_map(values, character_codes)
  assert list.all(codes, fn(code) { code >= 32 && code <= 126 })
  assert list.any(codes, fn(code) { code < 48 })
  assert list.any(codes, fn(code) { code > 100 })
}

/// Length shrinks before characters, and the floor is one character.
///
/// Re-pinned for the shrink policy this milestone changes: the empty string
/// is no longer offered as a candidate, because a test asserting on `""` pins
/// an accident rather than a behaviour (`glob.included("", [""], []) == True`
/// was the measured example). A string of two characters or more still
/// collapses by length first; a string of one has nothing shorter to offer and
/// moves its character towards `"a"` instead; the empty string is still a
/// leaf, because it is only ever reached by being drawn.
pub fn string_shrinks_length_before_characters_test() {
  let trees = sample_trees(pbt.string(), pbt.seed(15), 100)
  assert list.any(trees, fn(tree) { string.length(pbt.tree_root(tree)) == 1 })
  assert list.all(trees, fn(tree) {
    let root = pbt.tree_root(tree)
    case string.length(root) {
      0 -> list.is_empty(pbt.tree_children(tree))
      1 ->
        case root == "a" {
          True -> list.is_empty(pbt.tree_children(tree))
          False ->
            child_roots(tree) != []
            && list.all(child_roots(tree), fn(child) {
              string.length(child) == 1
            })
        }
      length ->
        case list.first(child_roots(tree)) {
          Ok(first) -> string.length(first) < length
          Error(_) -> False
        }
    }
  })
}

/// The empty string is a value, not a shrink target.
///
/// Shrinking towards `""` is minimal and meaningless: measured on real code it
/// produced `render.import_line(render.Requirement("", None, ["", ""]))
/// == "import .{, }"`, which pins an artefact of an empty module name. A drawn
/// string keeps at least one character, whatever it shrinks to.
///
/// Stated twice, because an exhaustive walk of a shrink tree is exponential:
/// once one step deep over every string drawn, which is the whole statement by
/// induction — a tree whose every child is non-empty and built the same way
/// holds no empty string anywhere — and once four steps deep over the roots
/// short enough to enumerate, which is where a length actually collapses.
pub fn string_never_shrinks_to_the_empty_string_test() {
  let trees = sample_trees(pbt.string(), pbt.seed(15), 100)
  let nonempty = list.filter(trees, fn(tree) { pbt.tree_root(tree) != "" })
  assert nonempty != []
  assert list.all(nonempty, fn(tree) { !list.contains(child_roots(tree), "") })

  let short =
    list.filter(nonempty, fn(tree) { string.length(pbt.tree_root(tree)) <= 2 })
  assert short != []
  assert list.all(short, fn(tree) {
    !list.contains(descendant_roots(tree, 4), "")
  })
}

/// A property nothing satisfies shrinks to one character, not to none.
pub fn string_shrinks_to_a_single_character_test() {
  let assert Found(shrunk:, original:, ..) =
    pbt.find_counterexample(pbt.string(), pbt.seed(15), 200, 500, fn(_) {
      False
    })
  assert original != ""
  assert shrunk == "a"
}

/// Unless the empty string is what was drawn: then it is the counterexample.
pub fn string_keeps_the_empty_string_it_actually_drew_test() {
  let empty_seed = first_seed_drawing_empty(pbt.seed(1), 500)
  let assert Found(shrunk:, original:, ..) =
    pbt.find_counterexample(pbt.string(), empty_seed, 200, 500, fn(_) { False })
  assert original == ""
  assert shrunk == ""
}

pub fn bit_array_is_at_most_sixteen_bytes_test() {
  let values = sample(pbt.bit_array(), pbt.seed(9), 200)
  assert list.all(values, fn(value) { bit_array.byte_size(value) <= 16 })
  assert list.any(values, fn(value) { bit_array.byte_size(value) == 0 })
  assert list.any(values, fn(value) { bit_array.byte_size(value) == 16 })

  let bytes = list.flat_map(values, byte_values)
  assert list.all(bytes, fn(byte) { byte >= 0 && byte <= 255 })
  assert list.any(bytes, fn(byte) { byte > 200 })
  assert list.any(bytes, fn(byte) { byte < 50 })
}

pub fn list_lengths_stay_within_bounds_test() {
  let values = sample(pbt.list(pbt.small_int()), pbt.seed(11), 300)
  let lengths = list.map(values, list.length)
  assert list.all(lengths, fn(length) { length >= 0 && length <= 10 })
  assert list.contains(lengths, 0)
  assert list.contains(lengths, 10)
  assert list.all(values, fn(value) {
    list.all(value, fn(element) { element >= -100 && element <= 100 })
  })
}

pub fn option_and_result_generate_both_shapes_test() {
  let options = sample(pbt.option(pbt.int(0, 10)), pbt.seed(19), 100)
  assert list.contains(options, None)
  assert list.any(options, fn(value) {
    case value {
      Some(inner) -> inner >= 0 && inner <= 10
      None -> False
    }
  })

  let results =
    sample(pbt.result(pbt.constant(1), pbt.int(0, 10)), pbt.seed(21), 100)
  assert list.contains(results, Ok(1))
  assert list.any(results, fn(value) {
    case value {
      Error(inner) -> inner >= 0 && inner <= 10
      Ok(_) -> False
    }
  })
}

pub fn result_offers_ok_as_a_shrink_candidate_test() {
  let trees =
    sample_trees(pbt.result(pbt.constant(1), pbt.int(0, 10)), pbt.seed(21), 100)
  assert list.all(trees, fn(tree) {
    case pbt.tree_root(tree) {
      Ok(_) -> True
      Error(_) -> list.first(child_roots(tree)) == Ok(Ok(1))
    }
  })
}

pub fn option_offers_none_as_a_shrink_candidate_test() {
  let trees = sample_trees(pbt.option(pbt.int(0, 10)), pbt.seed(19), 100)
  assert list.any(trees, fn(tree) { pbt.tree_root(tree) != None })
  assert list.all(trees, fn(tree) {
    case pbt.tree_root(tree) {
      None -> list.is_empty(pbt.tree_children(tree))
      Some(_) -> list.first(child_roots(tree)) == Ok(None)
    }
  })
}

pub fn tuple2_offers_left_shrinks_before_right_shrinks_test() {
  let trees =
    sample_trees(pbt.tuple2(pbt.int(1, 100), pbt.int(1, 100)), pbt.seed(99), 50)
  let shrinkable =
    list.filter(trees, fn(tree) {
      let #(left, _) = pbt.tree_root(tree)
      left != 1
    })
  assert shrinkable != []
  assert list.all(shrinkable, fn(tree) {
    let #(left, right) = pbt.tree_root(tree)
    case list.first(child_roots(tree)) {
      Ok(#(child_left, child_right)) ->
        child_left != left && child_right == right
      Error(_) -> False
    }
  })
}

pub fn tuple3_generates_every_component_test() {
  let generator = pbt.tuple3(pbt.int(0, 5), pbt.bool(), pbt.constant("x"))
  let values = sample(generator, pbt.seed(17), 60)
  assert list.all(values, fn(value) {
    let #(number, _, text) = value
    number >= 0 && number <= 5 && text == "x"
  })
  let flags = list.map(values, fn(value) { value.1 })
  assert list.contains(flags, True)
  assert list.contains(flags, False)
}

// --- Counterexample search --------------------------------------------------

/// The shrink target is the point of this test: whatever was drawn first, the
/// counterexample collapses to exactly `10`. The two counts beside it are
/// re-pinned for the edge bias, which changed what seed 2026 draws: the first
/// case is now the interesting value `1`, which passes, so the failing case is
/// the second one and it is one halving further from the boundary.
pub fn int_shrinks_to_the_smallest_failing_value_test() {
  let assert Found(shrunk:, original:, cases:, shrinks:) =
    pbt.find_counterexample(pbt.int(0, 100), pbt.seed(2026), 200, 500, fn(x) {
      x < 10
    })
  assert shrunk == 10
  assert original >= 10
  assert cases == 2
  assert shrinks == 4
}

/// A property that only negatives fail still reports a negative.
///
/// The new preference offers `-v` before the smaller magnitudes, and `5` here
/// satisfies `x > -5`: a candidate that passes is not taken, so the answer is
/// unchanged.
pub fn int_shrinks_towards_zero_from_below_test() {
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(pbt.int(-100, 100), pbt.seed(77), 200, 500, fn(x) {
      x > -5
    })
  assert shrunk == -5
}

/// When both signs fail, the answer is the positive one.
///
/// `Score(total: 1, killed: 0, timed_out: -1, ..)` was the measured example:
/// separating `killed + timed_out` from `killed - timed_out` only needs
/// `timed_out != 0`, and at magnitude 1 the search chose `-1`, producing the
/// nonsense expected value `"0% (-1/1)"`. At equal magnitude the non-negative
/// representative is the one a reader can check by eye, so it is offered
/// first.
pub fn int_prefers_the_non_negative_representative_test() {
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(pbt.int(-100, 100), pbt.seed(1), 200, 500, fn(x) {
      x == 0
    })
  assert shrunk == 1
}

/// The mirrored candidate belongs to the range, and comes before the halvings.
pub fn int_offers_the_mirror_of_a_negative_value_test() {
  let trees = sample_trees(pbt.int(-100, 100), pbt.seed(3), 200)
  let negatives = list.filter(trees, fn(tree) { pbt.tree_root(tree) < -1 })
  assert negatives != []
  assert list.all(negatives, fn(tree) {
    child_roots(tree) |> list.take(2) == [0, 0 - pbt.tree_root(tree)]
  })

  // A range that does not hold the mirror never offers it: `-7` mirrors to
  // `7`, which `-100..-3` has no room for.
  let below = sample_trees(pbt.int(-100, -3), pbt.seed(3), 200)
  assert list.all(below, fn(tree) {
    list.all(child_roots(tree), fn(child) { child >= -100 && child <= -3 })
  })
}

/// A float shrinking from below is unchanged: `2.5` satisfies `x >. -2.5`.
pub fn float_prefers_the_non_negative_representative_test() {
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(pbt.float(), pbt.seed(46), 200, 500, fn(x) {
      x == 0.0
    })
  assert shrunk >. 0.0
}

pub fn mapped_generator_keeps_shrinking_test() {
  let generator = pbt.map(pbt.int(0, 100), fn(value) { value * 2 })
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(generator, pbt.seed(31), 200, 500, fn(y) { y < 20 })
  assert shrunk == 20
}

pub fn list_shrinks_to_the_shortest_failing_list_test() {
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(
      pbt.list(pbt.int(0, 100)),
      pbt.seed(2026),
      200,
      500,
      fn(xs) { list.length(xs) < 3 },
    )
  assert shrunk == [0, 0, 0]
}

pub fn string_shrinks_to_the_shortest_failing_string_test() {
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(pbt.string(), pbt.seed(23), 200, 500, fn(s) {
      string.length(s) < 2
    })
  assert shrunk == "aa"
}

pub fn bit_array_shrinks_towards_zero_bytes_test() {
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(pbt.bit_array(), pbt.seed(29), 200, 500, fn(bits) {
      bit_array.byte_size(bits) < 2
    })
  assert shrunk == <<0, 0>>
}

pub fn float_shrinks_towards_zero_test() {
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(pbt.float(), pbt.seed(45), 200, 500, fn(x) {
      x <. 5.0
    })
  assert shrunk == 5.0

  let assert Found(shrunk: from_below, ..) =
    pbt.find_counterexample(pbt.float(), pbt.seed(46), 200, 500, fn(x) {
      x >. 0.0 -. 2.5
    })
  assert from_below == 0.0 -. 2.5
}

pub fn option_shrinks_to_some_of_the_smallest_value_test() {
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(
      pbt.option(pbt.int(0, 100)),
      pbt.seed(37),
      200,
      500,
      fn(value) { value == None },
    )
  assert shrunk == Some(0)
}

pub fn tuple2_shrinks_both_components_test() {
  let generator = pbt.tuple2(pbt.int(0, 100), pbt.int(0, 100))
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(generator, pbt.seed(99), 200, 500, fn(pair) {
      let #(left, right) = pair
      left < 10 || right < 10
    })
  assert shrunk == #(10, 10)
}

pub fn a_property_that_always_holds_is_not_found_test() {
  assert pbt.find_counterexample(pbt.int(0, 100), pbt.seed(8), 37, 10, fn(_) {
      True
    })
    == NotFound(37)
}

pub fn a_zero_shrink_budget_returns_the_original_case_test() {
  let assert Found(shrunk:, original:, cases:, shrinks:) =
    pbt.find_counterexample(pbt.int(0, 100), pbt.seed(8), 50, 0, fn(_) { False })
  assert shrunk == original
  assert cases == 1
  assert shrinks == 0
}

pub fn shrink_budget_is_respected_test() {
  let assert Found(shrunk:, shrinks:, ..) =
    pbt.find_counterexample(pbt.int(0, 100), pbt.seed(2026), 200, 1, fn(x) {
      x < 10
    })
  assert shrinks == 1
  assert shrunk >= 10
}

// --- Hinted generators ------------------------------------------------------
//
// Raising `--max-cases` from 200 to 2000 and changing the seed moved nothing
// on real code: more budget is not the lever, better priors are. A literal the
// function under test writes down is a value the search has to be told about,
// because a uniform draw over `-100..100` or over printable ASCII practically
// never produces it.

/// Every hint is reached inside the first hundred cases, whatever the seed.
///
/// Stated over three seeds and a hundred draws rather than over one seed and
/// forty: `pbt.seed(1)` opens with `48271`, a draw so far below every bucket
/// boundary that a one-seed test of the first few values would keep passing
/// even if the hints had been given a single draw in a million. What is being
/// pinned is the rate, so the test has to be wide enough to measure one.
pub fn int_with_hints_reaches_every_hint_early_test() {
  assert list.filter(seeds(), fn(seed) {
      let values =
        sample(pbt.int_with_hints(-100, 100, [42, -37]), pbt.seed(seed), 100)
      !list.contains(values, 42) || !list.contains(values, -37)
    })
    == []
}

/// Hints are added to the search, not traded against the edges.
///
/// The edges are what separates a boundary mutant, and a function that writes
/// a literal down is exactly the kind that also has one: spending half of the
/// interesting quarter on the hints would have halved the edge coverage of
/// every such function. The built-in quarter is left alone and the hints take
/// a bucket of their own, so the hinted generator draws an edge as often as
/// the plain one does.
pub fn int_with_hints_keeps_the_built_in_interesting_values_test() {
  let edges = [0, -100, 100, -99, 99, 1, -1]
  assert list.filter(seeds(), fn(seed) {
      let hinted =
        sample(pbt.int_with_hints(-100, 100, [42, -37]), pbt.seed(seed), 400)
      let plain = sample(pbt.int(-100, 100), pbt.seed(seed), 400)
      let drawn = fn(values) { list.count(values, list.contains(edges, _)) }
      // A quarter of 400 is 100, and the uniform draws add a handful more.
      drawn(hinted) < 80 || drawn(hinted) > 140 || drawn(plain) < 80
    })
    == []

  let values = sample(pbt.int_with_hints(-100, 100, [42]), pbt.seed(1), 200)
  assert list.filter(edges, fn(edge) { !list.contains(values, edge) }) == []
}

/// A hint the range does not hold is not a value the range can produce.
pub fn int_with_hints_drops_a_hint_outside_the_range_test() {
  let values = sample(pbt.int_with_hints(0, 10, [42, 7, -3]), pbt.seed(1), 200)
  assert list.all(values, fn(value) { value >= 0 && value <= 10 })
  assert list.contains(values, 7)
}

/// An eighth of the draws are spent on the hints, and no more: five draws in
/// eight still cover the range uniformly.
pub fn int_with_hints_spends_an_eighth_of_its_draws_on_the_hints_test() {
  assert list.filter(seeds(), fn(seed) {
      let values =
        sample(pbt.int_with_hints(-100, 100, [42, -37]), pbt.seed(seed), 400)
      let picked = list.count(values, fn(value) { value == 42 || value == -37 })
      // An eighth of 400 is 50, and the uniform draws add a couple more.
      picked < 25 || picked > 90
    })
    == []

  // The rest is the ordinary uniform draw: values nothing named at all still
  // come out, and they cover both signs.
  let values = sample(pbt.int_with_hints(-100, 100, [42]), pbt.seed(9), 400)
  let plain =
    list.filter(values, fn(value) {
      !list.contains([42, 0, -100, 100, -99, 99, 1, -1], value)
    })
  assert list.length(plain) * 2 > 400
  assert list.any(plain, fn(value) { value > 0 })
  assert list.any(plain, fn(value) { value < 0 })
}

pub fn int_with_hints_is_deterministic_test() {
  assert sample(pbt.int_with_hints(-100, 100, [42]), pbt.seed(9), 100)
    == sample(pbt.int_with_hints(-100, 100, [42]), pbt.seed(9), 100)
}

/// A hinted value is not a leaf: it shrinks the way any value of the range
/// does, so a hint that happens to be large still collapses.
pub fn int_with_hints_shrinks_a_hint_with_the_normal_tree_test() {
  let trees = sample_trees(pbt.int_with_hints(0, 100, [42]), pbt.seed(1), 200)
  let hinted = list.filter(trees, fn(tree) { pbt.tree_root(tree) == 42 })
  assert hinted != []
  assert list.all(hinted, fn(tree) { list.first(child_roots(tree)) == Ok(0) })
}

/// A hinted string is reached inside the first hundred cases, at any seed.
pub fn string_with_hints_reaches_every_hint_early_test() {
  assert list.filter(seeds(), fn(seed) {
      let values =
        sample(pbt.string_with_hints(["./", "GET"]), pbt.seed(seed), 100)
      !list.contains(values, "./") || !list.contains(values, "GET")
    })
    == []
}

/// The built-in set carries the shapes a uniform draw never makes: a line
/// ending, a path separator, a backslash.
pub fn string_with_hints_reaches_the_built_in_interesting_strings_test() {
  let values = sample(pbt.string_with_hints([]), pbt.seed(1), 400)
  assert list.filter(pbt.interesting_strings, fn(interesting) {
      !list.contains(values, interesting)
    })
    == []
  assert pbt.interesting_strings
    == ["a", "ab", "hello", "0", " ", "\n", "\r\n", "/", "./", "\\"]
}

/// The built-in strings keep their quarter and the hints take an eighth of
/// their own, exactly as the integers do — and five draws in eight are still
/// the ordinary uniform strings.
pub fn string_with_hints_spends_an_eighth_of_its_draws_on_the_hints_test() {
  assert list.filter(seeds(), fn(seed) {
      // Hints the built-in set does not already hold, so that the two buckets
      // are told apart by the values they produce.
      let values =
        sample(pbt.string_with_hints(["GET", "POST"]), pbt.seed(seed), 400)
      let hinted =
        list.count(values, fn(value) { value == "GET" || value == "POST" })
      let built_in =
        list.count(values, list.contains(pbt.interesting_strings, _))
      // An eighth of 400 is 50 and a quarter is 100; a hinted draw costs one
      // draw where a uniform string costs one per character, so the shares a
      // sample shows are near those figures rather than on them.
      hinted < 20 || hinted > 90 || built_in < 70 || built_in > 140
    })
    == []

  let values = sample(pbt.string_with_hints(["./"]), pbt.seed(9), 400)
  let union = ["./", ..pbt.interesting_strings]
  let plain = list.filter(values, fn(value) { !list.contains(union, value) })
  assert list.length(plain) * 2 > 400
  assert list.any(plain, fn(value) { string.length(value) > 4 })
}

pub fn string_with_hints_is_deterministic_test() {
  assert sample(pbt.string_with_hints(["./"]), pbt.seed(9), 100)
    == sample(pbt.string_with_hints(["./"]), pbt.seed(9), 100)
}

/// A hinted string shrinks the way any drawn string does — length first, then
/// characters towards `"a"` — and never to the empty string.
pub fn string_with_hints_shrinks_a_hint_with_the_normal_tree_test() {
  let trees = sample_trees(pbt.string_with_hints(["./"]), pbt.seed(1), 200)
  let hinted = list.filter(trees, fn(tree) { pbt.tree_root(tree) == "./" })
  assert hinted != []
  assert list.all(hinted, fn(tree) {
    let children = child_roots(tree)
    children != []
    && list.all(children, fn(child) { string.length(child) >= 1 })
  })
}

/// A hinted float is reached inside the first hundred cases, at any seed.
pub fn float_with_hints_reaches_every_hint_early_test() {
  assert list.filter(seeds(), fn(seed) {
      let values =
        sample(pbt.float_with_hints([2.5, -0.125]), pbt.seed(seed), 100)
      !list.contains(values, 2.5) || !list.contains(values, -0.125)
    })
    == []
}

pub fn float_with_hints_is_deterministic_test() {
  assert sample(pbt.float_with_hints([2.5]), pbt.seed(9), 100)
    == sample(pbt.float_with_hints([2.5]), pbt.seed(9), 100)
}

/// A hinted search finds the one input that separates a literal comparison.
///
/// `string.starts_with(s, "./")` is the measured case: with uniform strings
/// the probability of drawing a match is about one in nine thousand, so 200
/// cases never reached it. Told the literal, the search reaches it in a
/// handful.
pub fn string_with_hints_separates_a_literal_prefix_test() {
  let assert Found(shrunk:, ..) =
    pbt.find_counterexample(
      pbt.string_with_hints(["./"]),
      pbt.seed(1),
      200,
      500,
      fn(s) { !string.starts_with(s, "./") },
    )
  assert shrunk == "./"

  assert pbt.find_counterexample(pbt.string(), pbt.seed(1), 200, 500, fn(s) {
      !string.starts_with(s, "./")
    })
    == NotFound(200)
}

// --- Helpers ----------------------------------------------------------------

/// The seeds a rate is measured at.
///
/// A generator's bias is a property of every seed, not of the one a test was
/// written against: measuring it at three tells a real rate apart from an
/// artefact of where a particular MINSTD run happens to start.
fn seeds() -> List(Int) {
  [1, 9, 12_345]
}

fn take_values(seed: pbt.Seed, count: Int) -> List(Int) {
  case count {
    0 -> []
    _ -> {
      let #(value, advanced) = pbt.next(seed)
      [value, ..take_values(advanced, count - 1)]
    }
  }
}

fn stays_in_range(seed: pbt.Seed, remaining: Int) -> Bool {
  case remaining {
    0 -> True
    _ -> {
      let #(value, advanced) = pbt.next(seed)
      case value >= 1 && value <= 2_147_483_646 {
        True -> stays_in_range(advanced, remaining - 1)
        False -> False
      }
    }
  }
}

/// The equal slices of `low..high` that 20_000 draws from seed 1 never
/// reached, out of twenty.
///
/// A slice nothing lands in is a hole in the range, whatever the shape of the
/// distribution over the rest of it: draws spread over the whole range fill
/// every slice hundreds of times over.
fn missing_slices(
  generator: pbt.Generator(Int),
  low: Int,
  high: Int,
) -> List(Int) {
  let width = { high - low + 1 } / slice_count
  let seen = collect_slices(generator, low, width, pbt.seed(1), 20_000, [])
  slice_indices(0)
  |> list.filter(fn(index) { !list.contains(seen, index) })
}

fn slice_indices(index: Int) -> List(Int) {
  case index >= slice_count {
    True -> []
    False -> [index, ..slice_indices(index + 1)]
  }
}

const slice_count = 20

fn collect_slices(
  generator: pbt.Generator(Int),
  low: Int,
  width: Int,
  seed: pbt.Seed,
  draws: Int,
  seen: List(Int),
) -> List(Int) {
  case draws <= 0 {
    True -> seen
    False -> {
      let #(tree, advanced) = pbt.generate(generator, seed)
      let index =
        int.min({ pbt.tree_root(tree) - low } / width, slice_count - 1)
      let seen = case list.contains(seen, index) {
        True -> seen
        False -> [index, ..seen]
      }
      collect_slices(generator, low, width, advanced, draws - 1, seen)
    }
  }
}

fn sample(generator: pbt.Generator(a), seed: pbt.Seed, count: Int) -> List(a) {
  sample_trees(generator, seed, count)
  |> list.map(pbt.tree_root)
}

fn sample_trees(
  generator: pbt.Generator(a),
  seed: pbt.Seed,
  count: Int,
) -> List(pbt.Tree(a)) {
  collect_trees(generator, seed, count, [])
  |> list.reverse
}

fn collect_trees(
  generator: pbt.Generator(a),
  seed: pbt.Seed,
  count: Int,
  acc: List(pbt.Tree(a)),
) -> List(pbt.Tree(a)) {
  case count {
    0 -> acc
    _ -> {
      let #(tree, advanced) = pbt.generate(generator, seed)
      collect_trees(generator, advanced, count - 1, [tree, ..acc])
    }
  }
}

fn leaf(value: a) -> pbt.Tree(a) {
  Tree(value, fn() { [] })
}

fn node(value: a, children: List(a)) -> pbt.Tree(a) {
  Tree(value, fn() { list.map(children, leaf) })
}

fn child_roots(tree: pbt.Tree(a)) -> List(a) {
  pbt.tree_children(tree)
  |> list.map(pbt.tree_root)
}

fn tree_values(tree: pbt.Tree(a)) -> List(a) {
  [pbt.tree_root(tree), ..list.flat_map(pbt.tree_children(tree), tree_values)]
}

/// Every value reachable from `tree` within `depth` shrink steps, root aside.
fn descendant_roots(tree: pbt.Tree(a), depth: Int) -> List(a) {
  case depth <= 0 {
    True -> []
    False ->
      pbt.tree_children(tree)
      |> list.flat_map(fn(child) {
        [pbt.tree_root(child), ..descendant_roots(child, depth - 1)]
      })
  }
}

/// The first seed at or after `from` whose next string draw is empty.
fn first_seed_drawing_empty(from: pbt.Seed, remaining: Int) -> pbt.Seed {
  case remaining <= 0 {
    True -> from
    False -> {
      let #(tree, advanced) = pbt.generate(pbt.string(), from)
      case pbt.tree_root(tree) == "" {
        True -> from
        False -> first_seed_drawing_empty(advanced, remaining - 1)
      }
    }
  }
}

fn character_codes(value: String) -> List(Int) {
  string.to_utf_codepoints(value)
  |> list.map(string.utf_codepoint_to_int)
}

fn byte_values(value: BitArray) -> List(Int) {
  take_bytes(value, 0, bit_array.byte_size(value), [])
}

fn take_bytes(
  value: BitArray,
  index: Int,
  size: Int,
  acc: List(Int),
) -> List(Int) {
  case index >= size {
    True -> list.reverse(acc)
    False -> {
      let byte = case bit_array.slice(value, index, 1) {
        Ok(<<single>>) -> single
        _ -> -1
      }
      take_bytes(value, index + 1, size, [byte, ..acc])
    }
  }
}

fn is_printable_ascii(value: String) -> Bool {
  string.to_utf_codepoints(value)
  |> list.all(fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    code >= 32 && code <= 126
  })
}
