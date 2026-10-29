// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/result
import gleam/string

pub fn from_native(value: String, windows: Bool) -> String {
  case windows {
    True -> string.replace(value, "\\", "/")
    False -> value
  }
}

pub fn normalize_absolute(value: String, windows: Bool) -> String {
  let #(root, segments) = case
    string.split(from_native(value, windows), "/"),
    windows
  {
    ["", "", server, share, ..rest], True -> #(
      "//" <> server <> "/" <> share <> "/",
      rest,
    )
    ["", ..rest], _ -> #("/", rest)
    [drive, ..rest], True -> #(drive <> "/", rest)
    parts, _ -> #("", parts)
  }
  let reversed =
    list.fold(segments, [], fn(reversed, segment) {
      case segment {
        "" | "." -> reversed
        ".." -> list.drop(reversed, 1)
        _ -> [segment, ..reversed]
      }
    })
  root <> string.join(list.reverse(reversed), "/")
}

pub fn join(left: String, right: String) -> String {
  case left, right {
    "", _ -> right
    _, "" -> left
    _, _ -> left <> "/" <> right
  }
}

pub fn parent(path: String) -> String {
  let parts = string.split(path, "/")
  parts |> list.reverse |> list.drop(1) |> list.reverse |> string.join("/")
}

pub fn base_name(path: String) -> String {
  path
  |> string.split("/")
  |> list.last
  |> result.unwrap("")
}
