// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Choosing the fewest suggestions that still kill every mutant the whole set
// kills: a greedy set cover over the kill sets the probe reports.
//
// Pure: no file system, no processes, no ordering beyond the one the caller
// supplied.

import gleam/list
import gleam/set.{type Set}

/// Greedily covers every id any candidate covers, and answers with the
/// candidates it kept in the order it picked them.
///
/// Each candidate pairs a key of the caller's choosing with the ids it covers.
/// The candidate covering the most still-uncovered ids is picked first; ties
/// go to the earliest candidate in the list. Duplicate ids inside one
/// candidate count once, and a candidate that would add nothing is dropped, so
/// the answer never holds a key that earns its place.
///
/// A real run hands this one candidate per distinguished mutant, so the
/// covered ids are held in a set and a candidate is dropped from the search as
/// soon as it has nothing left to add: a few thousand candidates are a pass or
/// two of set lookups rather than a rescan of every id already covered.
pub fn cover(candidates: List(#(key, List(String)))) -> List(key) {
  candidates
  |> list.map(fn(candidate) { #(candidate.0, list.unique(candidate.1)) })
  |> pick(set.new(), [])
}

/// Picks candidates until nothing is left to add.
fn pick(
  candidates: List(#(key, List(String))),
  covered: Set(String),
  picked: List(key),
) -> List(key) {
  case best(candidates, covered) {
    Error(Nil) -> list.reverse(picked)
    Ok(#(_, key, added)) -> {
      let covered = list.fold(added, covered, set.insert)
      candidates
      |> list.filter(fn(candidate) { adds(candidate.1, covered) != [] })
      |> pick(covered, [key, ..picked])
    }
  }
}

/// The candidate adding the most uncovered ids, with its gain and those ids.
///
/// Ties go to the earliest candidate, and a candidate adding nothing is never
/// answered with, so the search stops once every coverable id is covered.
fn best(
  candidates: List(#(key, List(String))),
  covered: Set(String),
) -> Result(#(Int, key, List(String)), Nil) {
  candidates
  |> list.fold(Error(Nil), fn(chosen, candidate) {
    let #(key, ids) = candidate
    let added = adds(ids, covered)
    let gain = list.length(added)
    let best_gain = case chosen {
      Error(Nil) -> 0
      Ok(#(best_gain, _, _)) -> best_gain
    }
    case gain > best_gain {
      True -> Ok(#(gain, key, added))
      False -> chosen
    }
  })
}

/// The ids of one candidate that `covered` does not hold yet.
fn adds(ids: List(String), covered: Set(String)) -> List(String) {
  list.filter(ids, fn(id) { !set.contains(covered, id) })
}
