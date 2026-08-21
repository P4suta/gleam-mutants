// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/result
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/glob
import gleam_mutants/core/span
import gleam_mutants/platform

pub fn main() {
  let #(cases, seed) = case platform.arguments() {
    [cases, seed] -> #(
      int.parse(cases) |> result.unwrap(10_000),
      int.parse(seed) |> result.unwrap(0x5EED),
    )
    _ -> #(10_000, 0x5EED)
  }
  loop(cases, seed)
}

fn loop(remaining: Int, state: Int) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let next =
        int.modulo(state * 1_103_515_245 + 12_345, 2_147_483_647)
        |> result.unwrap(1)
      let width = int.modulo(next, 64) |> result.unwrap(0)
      let prefix = string.repeat("x", width) <> "\r\n日本語😀"
      let source = prefix <> " mutation-target " <> string.repeat("y", width)
      let start = string.byte_size(prefix)
      let end = start + string.byte_size(" mutation-target ")
      assert bytes.slice(source, start, end) == Ok(" mutation-target ")
      let assert Ok(value_span) = span.new(start, end)
      assert span.length(value_span) == end - start
      let path = "src/dir " <> int.to_string(width) <> "/file.gleam"
      assert glob.matches("src/**/*.gleam", path)
      assert !glob.matches("test/**/*.gleam", path)
      loop(remaining - 1, next)
    }
  }
}
