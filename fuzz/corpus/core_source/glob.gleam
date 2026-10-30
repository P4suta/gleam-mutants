// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/string
import gleam_mutants/core/mutant

pub fn matches(pattern: String, path: String) -> Bool {
  do_match(
    string.to_graphemes(mutant.normalize_path(pattern)),
    string.to_graphemes(mutant.normalize_path(path)),
  )
}

fn do_match(pattern: List(String), path: List(String)) -> Bool {
  case pattern, path {
    [], [] -> True
    [], _ -> False
    ["*", "*", "/", ..rest], _ ->
      do_match(rest, path)
      || case path {
        [] -> False
        [_, ..path_rest] -> do_match(pattern, path_rest)
      }
    ["*", "*", ..rest], _ ->
      do_match(rest, path)
      || case path {
        [] -> False
        [_, ..path_rest] -> do_match(pattern, path_rest)
      }
    ["*", ..rest], _ ->
      do_match(rest, path)
      || case path {
        [segment, ..path_rest] if segment != "/" -> do_match(pattern, path_rest)
        _ -> False
      }
    ["?", ..rest], [segment, ..path_rest] if segment != "/" ->
      do_match(rest, path_rest)
    [expected, ..pattern_rest], [actual, ..path_rest] if expected == actual ->
      do_match(pattern_rest, path_rest)
    _, _ -> False
  }
}

pub fn included(
  path: String,
  includes: List(String),
  excludes: List(String),
) -> Bool {
  list.any(includes, matches(_, path)) && !list.any(excludes, matches(_, path))
}
