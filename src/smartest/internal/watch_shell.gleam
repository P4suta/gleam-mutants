//// Side-effecting primitives for the explicit foreground watch command.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

const default_poll_ms = 100

const cancellation_grace_ms = 250

pub type Spec {
  Spec(
    root: String,
    command: String,
    arguments: List(String),
    poll_ms: Int,
    cancellation_grace_ms: Int,
  )
}

pub fn spec(root: String, arguments: List(String)) -> Spec {
  Spec(
    root: root,
    command: "gleam",
    arguments: ["test", ..arguments],
    poll_ms: default_poll_ms,
    cancellation_grace_ms: cancellation_grace_ms,
  )
}

@external(erlang, "smartest_shell_ffi", "workspace_fingerprint")
@external(javascript, "./smartest_shell_ffi.mjs", "workspace_fingerprint")
fn workspace_fingerprint_ffi(root: String) -> #(Bool, String)

/// Returns a content-addressed revision of compiler and test inputs.
///
/// Build output is deliberately outside this digest, so a test execution
/// cannot cause watch mode to trigger itself.
pub fn workspace_fingerprint(root: String) -> Result(String, String) {
  case workspace_fingerprint_ffi(root) {
    #(True, fingerprint) -> Ok(fingerprint)
    #(False, reason) -> Error(reason)
  }
}

@external(erlang, "smartest_shell_ffi", "run_foreground_watch")
@external(javascript, "./smartest_shell_ffi.mjs", "run_foreground_watch")
fn run_foreground_watch_ffi(
  root: String,
  command: String,
  arguments: List(String),
  poll_ms: Int,
  cancellation_grace_ms: Int,
) -> Nil

/// Owns the explicit foreground watcher until it is interrupted.
///
/// `SMARTEST_WATCH_MAX_REVISIONS` is an internal smoke-test seam. It is unset
/// in normal use, where this function runs until the foreground process is
/// interrupted and never installs a daemon or service.
pub fn run(spec: Spec) -> Nil {
  run_foreground_watch_ffi(
    spec.root,
    spec.command,
    spec.arguments,
    spec.poll_ms,
    spec.cancellation_grace_ms,
  )
}
