// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/core/path
import simplifile

pub type ProcessRequest {
  ProcessRequest(
    executable: String,
    arguments: List(String),
    working_directory: String,
    environment: List(#(String, String)),
    timeout_ms: Int,
  )
}

pub type TimedProcessResult {
  TimedProcessResult(process: ProcessResult, duration_ms: Int)
}

pub type ProcessResult {
  ProcessResult(status: Int, stdout: String, stderr: String, timed_out: Bool)
}

@external(erlang, "gleam_mutants_platform_ffi", "arguments")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "arguments")
pub fn arguments() -> List(String)

@external(erlang, "gleam_mutants_platform_ffi", "env")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "env")
pub fn env(name: String) -> String

pub fn optional_env(name: String) -> Option(String) {
  case env(name) {
    "" -> None
    value -> Some(value)
  }
}

@external(erlang, "gleam_mutants_platform_ffi", "current_directory")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "current_directory")
pub fn current_directory() -> String

@external(erlang, "gleam_mutants_platform_ffi", "temporary_directory")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "temporary_directory")
pub fn temporary_directory() -> String

@external(erlang, "gleam_mutants_platform_ffi", "cache_directory")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "cache_directory")
pub fn cache_directory() -> String

@external(erlang, "gleam_mutants_platform_ffi", "cpu_count")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "cpu_count")
pub fn cpu_count() -> Int

@external(erlang, "gleam_mutants_platform_ffi", "now_milliseconds")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "now_milliseconds")
pub fn now_milliseconds() -> Int

@external(erlang, "gleam_mutants_platform_ffi", "monotonic_milliseconds")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "monotonic_milliseconds")
pub fn monotonic_milliseconds() -> Int

@external(erlang, "gleam_mutants_platform_ffi", "resolve_path")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "resolve_path")
fn do_resolve_path(path: String) -> String

pub fn resolve_path(value: String) -> String {
  path.from_native(do_resolve_path(value), os_name() == "windows")
}

@external(erlang, "gleam_mutants_platform_ffi", "architecture")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "architecture")
pub fn architecture() -> String

@external(erlang, "gleam_mutants_platform_ffi", "environment")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "environment")
pub fn environment() -> String

@external(erlang, "gleam_mutants_platform_ffi", "random_nonce")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "random_nonce")
pub fn random_nonce() -> String

pub const private_directory_mode = 0o700

pub fn ensure_private_directory(directory: String) -> Result(Nil, String) {
  case simplifile.create_directory(directory) {
    Ok(Nil) | Error(simplifile.Eexist) -> protect_directory(directory)
    Error(error) -> Error(simplifile.describe_error(error))
  }
}

pub fn protect_directory(directory: String) -> Result(Nil, String) {
  use info <- result.try(
    simplifile.link_info(directory)
    |> result.map_error(simplifile.describe_error),
  )
  case simplifile.file_info_type(info), is_reparse_point(directory) {
    simplifile.Directory, False ->
      case os_name() {
        "windows" -> Ok(Nil)
        _ ->
          simplifile.set_permissions_octal(directory, private_directory_mode)
          |> result.map_error(simplifile.describe_error)
      }
    _, _ ->
      Error("private directory is linked or not a directory: " <> directory)
  }
}

pub fn create_private_directory(directory: String) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory(directory)
    |> result.map_error(simplifile.describe_error),
  )
  let protected = {
    use _ <- result.try(protect_directory(directory))
    use names <- result.try(
      simplifile.read_directory(directory)
      |> result.map_error(simplifile.describe_error),
    )
    case names {
      [] -> Ok(Nil)
      _ ->
        Error("private directory was populated during creation: " <> directory)
    }
  }
  case protected {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      case delete_tree(directory) {
        Ok(Nil) -> Error(error)
        Error(cleanup) ->
          Error(error <> "; directory cleanup failed: " <> cleanup)
      }
  }
}

@external(erlang, "gleam_mutants_platform_ffi", "delete_tree")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "delete_tree")
fn do_delete_tree(path: String) -> String

pub fn delete_tree(path: String) -> Result(Nil, String) {
  case do_delete_tree(path) {
    "" -> Ok(Nil)
    error -> Error(error)
  }
}

@external(erlang, "gleam_mutants_platform_ffi", "acquire_lock")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "acquire_lock")
pub fn acquire_lock(
  path: String,
  run_id: String,
  started_ms: Int,
  wait_ms: Int,
) -> String

@external(erlang, "gleam_mutants_platform_ffi", "release_lock")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "release_lock")
pub fn release_lock(path: String, token: String) -> String

@external(erlang, "gleam_mutants_platform_ffi", "process_id")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "process_id")
pub fn process_id() -> Int

@external(erlang, "gleam_mutants_platform_ffi", "os_name")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "os_name")
pub fn os_name() -> String

@external(erlang, "gleam_mutants_platform_ffi", "is_tty")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "is_tty")
pub fn is_tty() -> Bool

@external(erlang, "gleam_mutants_platform_ffi", "is_reparse_point")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "is_reparse_point")
pub fn is_reparse_point(path: String) -> Bool

@external(erlang, "gleam_mutants_platform_ffi", "exit")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "exit")
pub fn exit(code: Int) -> Nil

@external(erlang, "gleam_mutants_platform_ffi", "run_process")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "run_process")
fn do_run_process(
  executable: String,
  arguments: List(String),
  working_directory: String,
  environment: List(#(String, String)),
  timeout_ms: Int,
) -> #(Int, String, String, Bool)

pub fn run_process(
  executable: String,
  arguments: List(String),
  working_directory: String,
  environment: List(#(String, String)),
  timeout_ms: Int,
) -> ProcessResult {
  let #(status, stdout, stderr, timed_out) =
    do_run_process(
      executable,
      arguments,
      working_directory,
      environment,
      timeout_ms,
    )
  ProcessResult(status, stdout, stderr, timed_out)
}

@external(erlang, "gleam_mutants_platform_ffi", "run_process_batch")
@external(javascript, "./gleam_mutants_platform_ffi.mjs", "run_process_batch")
fn do_run_process_batch(
  requests: List(#(String, List(String), String, List(#(String, String)), Int)),
  jobs: Int,
) -> List(#(Int, String, String, Bool, Int))

pub fn run_process_batch(
  requests: List(ProcessRequest),
  jobs: Int,
) -> List(TimedProcessResult) {
  requests
  |> list.map(fn(request) {
    #(
      request.executable,
      request.arguments,
      request.working_directory,
      request.environment,
      request.timeout_ms,
    )
  })
  |> do_run_process_batch(int.max(1, jobs))
  |> list.map(fn(result) {
    let #(status, stdout, stderr, timed_out, duration_ms) = result
    TimedProcessResult(
      ProcessResult(status, stdout, stderr, timed_out),
      duration_ms,
    )
  })
}

pub fn is_ci() -> Bool {
  ["CI", "GITHUB_ACTIONS", "BUILD_BUILDID", "TF_BUILD"]
  |> list.any(fn(name) {
    case env(name) |> string.lowercase {
      "" | "0" | "false" -> False
      _ -> True
    }
  })
}
