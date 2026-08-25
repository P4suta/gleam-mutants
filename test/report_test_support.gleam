// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam_mutants/core/path
import simplifile

pub fn cleanup(workspace: String) -> Nil {
  let directory = path.join(workspace, "reports/mutation")
  let _ = simplifile.delete_file(at: path.join(directory, "mutation.json"))
  let _ = simplifile.delete_file(at: path.join(directory, "mutation.html"))
  Nil
}

// --- Moving the cache directory somewhere a test owns ------------------------

@target(erlang)
/// Points `platform.cache_directory` at `directory` for the rest of this VM.
///
/// The report history is written under the cache directory, and a test that
/// wants to watch that write fail has to own the place it fails in. There is
/// no other seam: the path is read out of the environment on every call, so
/// the environment is what a test moves. Erlang-only, because that is where
/// the report history tests run, and paired with `restore_cache_directory`
/// because everything else in this VM reads the same variable.
pub fn set_cache_directory(directory: String) -> Nil {
  let _ = putenv(charlist(cache_variable), charlist(directory))
  Nil
}

@target(erlang)
/// Puts the cache directory back to what the environment said before.
///
/// `previous` is whatever `platform.env(cache_variable)` answered before the
/// move, and `""` means the variable was not set at all — which is not the
/// same as being set to the empty string, so it is unset rather than blanked.
pub fn restore_cache_directory(previous: String) -> Nil {
  let _ = case previous {
    "" -> unsetenv(charlist(cache_variable))
    value -> putenv(charlist(cache_variable), charlist(value))
  }
  Nil
}

/// The environment variable the cache directory is read from.
pub const cache_variable = "XDG_CACHE_HOME"

@target(erlang)
type Charlist

@target(erlang)
@external(erlang, "erlang", "binary_to_list")
fn charlist(value: String) -> Charlist

@target(erlang)
@external(erlang, "os", "putenv")
fn putenv(name: Charlist, value: Charlist) -> Bool

@target(erlang)
@external(erlang, "os", "unsetenv")
fn unsetenv(name: Charlist) -> Bool
