//// Runtime-specific discovery of public zero-arity `*_test` exports.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

@external(erlang, "smartest_discovery_ffi", "main")
@external(javascript, "./smartest_discovery_ffi.mjs", "main")
pub fn main() -> Nil
