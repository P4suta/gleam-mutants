// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/core/mutant

pub fn join(left: String, right: String) -> String {
  let left = left |> mutant.normalize_path |> string.trim_end
  let right = right |> mutant.normalize_path |> string.trim_start
  case left, right {
    "", _ -> right
    _, "" -> left
    _, _ -> left <> "/" <> right
  }
}

pub fn parent(path: String) -> String {
  let parts = path |> mutant.normalize_path |> string.split("/")
  parts |> list.reverse |> list.drop(1) |> list.reverse |> string.join("/")
}

pub fn base_name(path: String) -> String {
  path
  |> mutant.normalize_path
  |> string.split("/")
  |> list.last
  |> result.unwrap("")
}
