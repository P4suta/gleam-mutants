// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/result
import gleam/string
import gleam_mutants/cache
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile

pub opaque type WorkspaceLock {
  WorkspaceLock(path: String, token: String, run_id: String)
}

pub fn acquire(workspace: String) -> Result(WorkspaceLock, String) {
  let started = platform.now_milliseconds()
  let run_id = int.to_string(started) <> "-" <> platform.random_nonce()
  let directory =
    platform.cache_directory()
    |> path.join("gleam-mutants/v1/workspaces")
    |> path.join(cache.workspace_id(workspace))
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(simplifile.describe_error),
  )
  let lock_path = path.join(directory, "run.lock")
  let response = platform.acquire_lock(lock_path, run_id, started, 2000)
  case string.starts_with(response, "ok:") {
    True -> Ok(WorkspaceLock(lock_path, string.drop_start(response, 3), run_id))
    False ->
      Error(
        "GMU7001: "
        <> case string.starts_with(response, "error:") {
          True -> string.drop_start(response, 6)
          False -> response
        },
      )
  }
}

pub fn run_id(lock: WorkspaceLock) -> String {
  lock.run_id
}

pub fn release(lock: WorkspaceLock) -> Result(Nil, String) {
  case platform.release_lock(lock.path, lock.token) {
    "" -> Ok(Nil)
    error -> Error(error)
  }
}
