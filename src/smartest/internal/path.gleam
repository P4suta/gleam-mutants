// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/result
import gleam/string

pub fn join(left: String, right: String) -> String {
  let left = left |> normalize |> string.trim_end
  let right = right |> normalize |> string.trim_start
  case left, right {
    "", _ -> right
    _, "" -> left
    _, _ -> left <> "/" <> right
  }
}

pub fn parent(value: String) -> String {
  value
  |> normalize
  |> string.split("/")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join("/")
}

pub fn base_name(value: String) -> String {
  value
  |> normalize
  |> string.split("/")
  |> list.last
  |> result.unwrap("")
}

fn normalize(value: String) -> String {
  string.replace(value, "\\", "/")
}
