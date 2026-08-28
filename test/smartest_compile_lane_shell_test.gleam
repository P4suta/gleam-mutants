// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import glance
import gleam/option.{Some}
import gleam/string
import gleam_mutants/core/catalog
import gleam_mutants/core/operator
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/suggest/compile_lane
import gleam_mutants/suggest/compile_lane_shell
import gleam_mutants/suggest/select

const source = "const limit = 10\n\npub fn over(value: Int) -> Bool { value > limit }\n"

fn job() -> compile_lane.Job {
  let assert Ok(module) = glance.module(source)
  let assert Ok(discovered) =
    catalog.discover("src/demo.gleam", source, operator.all())
  let #(_, outside) = select.assign(module, discovered.mutants)
  let assert [job, ..] =
    compile_lane.plan(module, outside, "erlang", "gleam-1.18.0", "workspace-a").jobs
  job
}

fn forbidden() -> a {
  panic as "a cache hit crossed the process boundary"
}

pub fn smartest_compile_shell_returns_a_cache_hit_without_making_a_worker_test() {
  let job = job()
  let assert Some(cached) =
    compile_lane.encode_cache(job, compile_lane.Compiled(False))
  let shell =
    compile_lane_shell.Shell(
      read_cache: fn(key) {
        assert key == job.cache_key
        Ok(cached)
      },
      write_cache: fn(_, _) { forbidden() },
      create_worker: fn() { forbidden() },
      write_source: fn(_, _, _) { forbidden() },
      build: fn(_, _) { forbidden() },
      dispose: fn(_) { forbidden() },
    )

  assert compile_lane_shell.execute_with(job, source, "erlang", shell)
    == Ok(compile_lane.Compiled(True))
}

pub fn smartest_compile_shell_mutates_builds_caches_and_disposes_a_miss_test() {
  let job = job()
  let assert Ok(expected_source) = compile_lane.apply_source(source, job.mutant)
  let shell =
    compile_lane_shell.Shell(
      read_cache: fn(_) { Error(Nil) },
      write_cache: fn(key, encoded) {
        assert key == job.cache_key
        assert compile_lane.decode_cache(job, encoded)
          == Ok(compile_lane.Compiled(True))
        Ok(Nil)
      },
      create_worker: fn() { Ok("/worker") },
      write_source: fn(worker, path, written) {
        assert worker == "/worker"
        assert path == "src/demo.gleam"
        assert written == expected_source
        Ok(Nil)
      },
      build: fn(worker, target) {
        assert worker == "/worker"
        assert target == "erlang"
        platform.ProcessResult(0, "", "", False)
      },
      dispose: fn(worker) {
        assert worker == "/worker"
        Ok(Nil)
      },
    )

  assert compile_lane_shell.execute_with(job, source, "erlang", shell)
    == Ok(compile_lane.Compiled(False))
}

pub fn smartest_compile_shell_does_not_cache_a_timeout_test() {
  let job = job()
  let shell =
    compile_lane_shell.Shell(
      read_cache: fn(_) { Error(Nil) },
      write_cache: fn(_, _) { forbidden() },
      create_worker: fn() { Ok("/worker") },
      write_source: fn(_, _, _) { Ok(Nil) },
      build: fn(_, _) { platform.ProcessResult(-1, "", "", True) },
      dispose: fn(_) { Ok(Nil) },
    )

  assert compile_lane_shell.execute_with(job, source, "erlang", shell)
    == Ok(compile_lane.CompileTimedOut)
}

pub fn smartest_compile_shell_treats_an_unwritable_cache_as_an_optimization_miss_test() {
  let job = job()
  let shell =
    compile_lane_shell.Shell(
      read_cache: fn(_) { Error(Nil) },
      write_cache: fn(_, _) { Error("read-only cache") },
      create_worker: fn() { Ok("/worker") },
      write_source: fn(_, _, _) { Ok(Nil) },
      build: fn(_, _) { platform.ProcessResult(0, "", "", False) },
      dispose: fn(_) { Ok(Nil) },
    )

  assert compile_lane_shell.execute_with(job, source, "erlang", shell)
    == Ok(compile_lane.Compiled(False))
}

pub fn smartest_compile_shell_disposes_after_a_write_failure_test() {
  let job = job()
  let shell =
    compile_lane_shell.Shell(
      read_cache: fn(_) { Error(Nil) },
      write_cache: fn(_, _) { forbidden() },
      create_worker: fn() { Ok("/worker") },
      write_source: fn(_, _, _) { Error("write failed") },
      build: fn(_, _) { forbidden() },
      dispose: fn(_) { Error("cleanup failed") },
    )

  assert compile_lane_shell.execute_with(job, source, "erlang", shell)
    == Error("write failed; compile worker cleanup failed: cleanup failed")
}

pub fn smartest_compile_cache_writes_atomically_below_its_root_test() {
  let root =
    path.join(
      platform.temporary_directory(),
      "smartest-compile-cache-test-" <> platform.random_nonce(),
    )
  let key = "../must-not-escape"
  let cache_file = compile_lane_shell.cache_path(root, key)

  assert string.starts_with(cache_file, root <> "/")
  assert !string.contains(cache_file, "must-not-escape")
  assert compile_lane_shell.write_cache_at(root, key, "cached evidence")
    == Ok(Nil)
  assert compile_lane_shell.read_cache_at(root, key) == Ok("cached evidence")
  assert platform.delete_tree(root) == Ok(Nil)
}
