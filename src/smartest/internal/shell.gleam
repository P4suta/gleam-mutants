// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

@external(erlang, "smartest_shell_ffi", "random_nonce")
@external(javascript, "./smartest_shell_ffi.mjs", "random_nonce")
pub fn random_nonce() -> String

@external(erlang, "smartest_shell_ffi", "arguments")
@external(javascript, "./smartest_shell_ffi.mjs", "arguments")
pub fn arguments() -> List(String)

@external(erlang, "smartest_shell_ffi", "current_directory")
@external(javascript, "./smartest_shell_ffi.mjs", "current_directory")
pub fn current_directory() -> String

@external(erlang, "smartest_shell_ffi", "now_milliseconds")
@external(javascript, "./smartest_shell_ffi.mjs", "now_milliseconds")
pub fn now_milliseconds() -> Int

@external(erlang, "smartest_shell_ffi", "exit")
@external(javascript, "./smartest_shell_ffi.mjs", "exit")
pub fn exit(code: Int) -> Nil
