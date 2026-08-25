// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam_mutants/suggest/minimize

// --- the greedy choice -------------------------------------------------------

pub fn cover_picks_the_candidate_that_covers_the_most_test() {
  // The classic shape: four candidates, two of which cover everything.
  assert minimize.cover([
      #("a", ["1", "2", "3"]),
      #("b", ["1", "2"]),
      #("c", ["3", "4"]),
      #("d", ["4"]),
    ])
    == ["a", "c"]
}

pub fn cover_drops_a_candidate_that_adds_nothing_test() {
  assert minimize.cover([
      #("wide", ["1", "2", "3"]),
      #("inside", ["2"]),
      #("outside", ["4"]),
    ])
    == ["wide", "outside"]
}

pub fn cover_keeps_the_keys_it_was_given_test() {
  // Nothing about a key is inspected, so anything comparable will do.
  assert minimize.cover([#(1, ["x"]), #(2, ["y"]), #(3, ["x", "y"])]) == [3]
}

// --- ties --------------------------------------------------------------------

pub fn cover_breaks_a_tie_by_position_test() {
  assert minimize.cover([#("first", ["1"]), #("second", ["1"])]) == ["first"]

  // `a` and `c` cover as much as each other, so the earlier one wins; `b` is
  // then the only candidate left that still adds anything.
  assert minimize.cover([
      #("a", ["1", "2"]),
      #("b", ["2", "3"]),
      #("c", ["1", "2"]),
    ])
    == ["a", "b"]
}

// --- nothing to cover --------------------------------------------------------

pub fn cover_of_nothing_is_nothing_test() {
  let none: List(#(String, List(String))) = []
  assert minimize.cover(none) == []
  assert minimize.cover([#("a", []), #("b", [])]) == []
}

// --- duplicates --------------------------------------------------------------

pub fn cover_counts_a_repeated_id_once_test() {
  // `a` looks like three ids and is worth one, so `b` is picked first.
  assert minimize.cover([#("a", ["1", "1", "1"]), #("b", ["2", "3"])])
    == ["b", "a"]
}

pub fn cover_keeps_one_of_two_identical_candidates_test() {
  assert minimize.cover([#("a", ["1", "2"]), #("b", ["2", "1"])]) == ["a"]
}

// --- scale -------------------------------------------------------------------

pub fn cover_handles_a_project_sized_candidate_list_test() {
  // A real run hands `cover` one candidate per distinguished mutant, and a
  // project has thousands. A pass that keeps its covered ids in a list rescans
  // them for every id of every candidate on every pick, so this grows with the
  // cube of the candidate count and stalls; a set-backed one does not.
  let ids = numbers(1500)
  let candidates = list.map(ids, fn(index) { #(index, [int.to_string(index)]) })

  assert minimize.cover(candidates) == ids
}

/// `1` up to `count`, in order.
fn numbers(count: Int) -> List(Int) {
  int.range(from: 1, to: count + 1, with: [], run: list.prepend)
  |> list.reverse
}
