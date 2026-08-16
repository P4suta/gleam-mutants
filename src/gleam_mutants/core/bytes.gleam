// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/result

pub fn slice(source: String, start: Int, end: Int) -> Result(String, Nil) {
  use <- bool.guard(when: start < 0 || end < start, return: Error(Nil))
  use bits <- result.try(
    source
    |> bit_array.from_string
    |> bit_array.slice(at: start, take: end - start),
  )
  bit_array.to_string(bits)
}

pub fn unsafe_slice(source: String, start: Int, end: Int) -> String {
  let assert Ok(value) = slice(source, start, end)
  value
}

pub fn sha256(text: String) -> String {
  sha256_bits(bit_array.from_string(text))
}

pub fn sha256_bits(bits: BitArray) -> String {
  crypto.hash(crypto.Sha256, bits)
  |> bit_array.base16_encode
}
