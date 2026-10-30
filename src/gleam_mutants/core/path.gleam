// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/result
import gleam/string

type RootedParts {
  RootedParts(root: String, segments: List(String))
}

pub fn from_native(value: String, windows: Bool) -> String {
  case windows {
    True -> string.replace(value, "\\", "/")
    False -> value
  }
}

pub fn normalize_absolute(value: String, windows: Bool) -> String {
  let RootedParts(root, segments) =
    split_root(string.split(from_native(value, windows), "/"), windows)
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

fn split_root(parts: List(String), windows: Bool) -> RootedParts {
  case parts, windows {
    ["", "", server, share, ..rest], True ->
      RootedParts("//" <> server <> "/" <> share <> "/", rest)
    ["", ..rest], _ -> RootedParts("/", rest)
    [drive, ..rest], True -> RootedParts(drive <> "/", rest)
    parts, _ -> RootedParts("", parts)
  }
}

pub fn join(left: String, right: String) -> String {
  case left, right {
    "", _ -> right
    _, "" -> left
    _, _ -> left <> "/" <> right
  }
}

pub fn parent(path: String) -> String {
  case path {
    "" -> ""
    _ -> parent_nonempty(path)
  }
}

fn parent_nonempty(path: String) -> String {
  let parts = string.split(path, "/")
  let RootedParts(root, segments) = split_root(parts, has_windows_root(parts))
  let parent_segments =
    segments
    |> list.reverse
    |> list.drop_while(fn(segment) { segment == "" })
    |> list.drop(1)
    |> list.reverse
  root <> string.join(parent_segments, "/")
}

fn has_windows_root(parts: List(String)) -> Bool {
  case parts {
    ["", "", server, share, ..] -> server != "" && share != ""
    [drive, _, ..] -> is_drive(drive)
    _ -> False
  }
}

fn is_drive(value: String) -> Bool {
  case string.to_graphemes(value) {
    [letter, ":"] ->
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
        letter,
      )
    _ -> False
  }
}

pub fn base_name(path: String) -> String {
  path
  |> string.split("/")
  |> list.last
  |> result.unwrap("")
}
