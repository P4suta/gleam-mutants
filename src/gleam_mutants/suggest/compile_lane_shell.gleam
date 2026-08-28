//// Isolated execution shell for content-addressed compile-lane jobs.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/path
import gleam_mutants/platform.{type ProcessResult, ProcessResult}
import gleam_mutants/snapshot.{type Snapshot}
import gleam_mutants/suggest/compile_lane.{type CompileOutcome, type Job}
import simplifile

/// Injectable side effects for one compile worker.
///
/// Keeping worker creation generic lets contract tests prove lifecycle and
/// cache behavior without touching a filesystem or spawning a compiler. The
/// concrete shell below this boundary uses snapshot workers.
pub type Shell(worker) {
  Shell(
    read_cache: fn(String) -> Result(String, Nil),
    write_cache: fn(String, String) -> Result(Nil, String),
    create_worker: fn() -> Result(worker, String),
    write_source: fn(worker, String, String) -> Result(Nil, String),
    build: fn(worker, String) -> ProcessResult,
    dispose: fn(worker) -> Result(Nil, String),
  )
}

/// Executes one job, preferring an exact checksummed cache entry.
///
/// A stale or corrupt entry is merely a miss. Once a worker exists its
/// teardown runs on success, compilation timeout, source-write failure and
/// cache-write failure alike.
pub fn execute_with(
  job: Job,
  source: String,
  target: String,
  shell: Shell(worker),
) -> Result(CompileOutcome, String) {
  case shell.read_cache(job.cache_key) {
    Ok(encoded) ->
      case compile_lane.decode_cache(job, encoded) {
        Ok(cached) -> Ok(cached)
        Error(Nil) -> execute_miss(job, source, target, shell)
      }
    Error(Nil) -> execute_miss(job, source, target, shell)
  }
}

fn execute_miss(
  job: Job,
  source: String,
  target: String,
  shell: Shell(worker),
) -> Result(CompileOutcome, String) {
  use mutated <- result.try(
    compile_lane.apply_source(source, job.mutant)
    |> result.map_error(fn(error) {
      "compile job source validation failed: " <> string.inspect(error)
    }),
  )
  use worker <- result.try(shell.create_worker())
  let operation = {
    use _ <- result.try(shell.write_source(worker, job.mutant.path, mutated))
    let outcome = shell.build(worker, target) |> compile_lane.classify_process
    // A persistent cache is an optimization, never a prerequisite for new
    // evidence. Read-only homes and sandboxes still get the fresh result.
    let _ = case compile_lane.encode_cache(job, outcome) {
      None -> Ok(Nil)
      Some(encoded) -> shell.write_cache(job.cache_key, encoded)
    }
    Ok(outcome)
  }
  finish(operation, shell.dispose(worker))
}

fn finish(
  operation: Result(a, String),
  cleanup: Result(Nil, String),
) -> Result(a, String) {
  case operation, cleanup {
    Ok(value), Ok(Nil) -> Ok(value)
    Error(error), Ok(Nil) -> Error(error)
    Ok(_), Error(error) -> Error("compile worker cleanup failed: " <> error)
    Error(error), Error(cleanup_error) ->
      Error(error <> "; compile worker cleanup failed: " <> cleanup_error)
  }
}

/// The cache filename for an opaque key. Hashing again keeps this storage API
/// path-safe even if a future caller supplies a non-SHA key.
pub fn cache_path(root: String, key: String) -> String {
  path.join(root, bytes.sha256(key) <> ".json")
}

pub fn read_cache_at(root: String, key: String) -> Result(String, Nil) {
  simplifile.read(cache_path(root, key))
  |> result.map_error(fn(_) { Nil })
}

/// Atomically replaces one cache entry, leaving no partial evidence for a
/// concurrent reader to decode.
pub fn write_cache_at(
  root: String,
  key: String,
  encoded: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(root)
    |> result.map_error(simplifile.describe_error),
  )
  let target = cache_path(root, key)
  let staged = target <> ".tmp-" <> platform.random_nonce()
  use _ <- result.try(
    simplifile.write(staged, encoded)
    |> result.map_error(simplifile.describe_error),
  )
  case simplifile.rename(at: staged, to: target) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      let _ = simplifile.delete_file(at: staged)
      Error(simplifile.describe_error(error))
    }
  }
}

/// Executes one job in a disposable copy of the run snapshot.
///
/// The worker receives the raw replacement rather than runtime activation
/// instrumentation, which is what permits constants, guards and patterns to
/// retain compile-time semantics.
pub fn execute(
  base: Snapshot,
  source: String,
  job: Job,
  target: String,
  timeout_ms: Int,
) -> Result(CompileOutcome, String) {
  let cache_root =
    platform.cache_directory()
    |> path.join("smartest/v1/compile")
  let shell: Shell(Snapshot) =
    Shell(
      read_cache: fn(key) { read_cache_at(cache_root, key) },
      write_cache: fn(key, encoded) {
        write_cache_at(cache_root, key, encoded)
        |> result.map_error(fn(error) {
          "could not write compile cache " <> key <> ": " <> error
        })
      },
      create_worker: fn() {
        snapshot.create(snapshot.root(base))
        |> result.map_error(fn(error) {
          "could not create compile worker: " <> error
        })
      },
      write_source: fn(worker, relative, contents) {
        simplifile.write(path.join(snapshot.root(worker), relative), contents)
        |> result.map_error(fn(error) {
          "could not write compile worker source "
          <> relative
          <> ": "
          <> simplifile.describe_error(error)
        })
      },
      build: fn(worker, selected_target) {
        let root = snapshot.root(worker)
        platform.run_process(
          "gleam",
          ["build", "--target", selected_target],
          root,
          [],
          timeout_ms,
        )
        |> normalize_process(root)
      },
      dispose: snapshot.dispose,
    )
  execute_with(job, source, target, shell)
}

fn normalize_process(
  process: ProcessResult,
  worker_root: String,
) -> ProcessResult {
  ProcessResult(
    ..process,
    stdout: string.replace(process.stdout, worker_root, "<compile-worker>"),
    stderr: string.replace(process.stderr, worker_root, "<compile-worker>"),
  )
}
