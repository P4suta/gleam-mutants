// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/runtime
import simplifile

@target(erlang)
@external(erlang, "runtime_test_ffi", "load_generated")
fn load_generated(path: String) -> Result(String, String)

@target(erlang)
@external(erlang, "runtime_test_ffi", "active")
fn active(module: String) -> String

@target(erlang)
@external(erlang, "runtime_test_ffi", "active_in_new_process")
fn active_in_new_process(module: String) -> String

@target(erlang)
@external(erlang, "runtime_test_ffi", "set_process_active")
fn set_process_active(id: String) -> Nil

@target(erlang)
@external(erlang, "runtime_test_ffi", "erase_process_active")
fn erase_process_active() -> Nil

@target(erlang)
@external(erlang, "runtime_test_ffi", "set_persistent_active")
fn set_persistent_active(id: String) -> Nil

@target(erlang)
@external(erlang, "runtime_test_ffi", "erase_persistent_active")
fn erase_persistent_active() -> Nil

fn fresh_snapshot_root() -> String {
  let root =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-runtime-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  root
}

fn generated_source_path(
  root: String,
  module: String,
  extension: String,
) -> String {
  path.join(path.join(root, "src"), module <> "_ffi" <> extension)
}

@target(erlang)
pub fn generated_runtime_resolves_the_active_mutant_per_process_test() {
  let root = fresh_snapshot_root()
  let assert Ok(generated) = runtime.generate(root, platform.random_nonce())
  let assert Ok(module) =
    load_generated(generated_source_path(root, runtime.name(generated), ".erl"))

  // (a) neither the process dictionary nor the persistent term is set.
  let unset = active(module)

  // (b) the process dictionary of the calling process wins.
  set_process_active("m1")
  let with_dictionary = active(module)
  erase_process_active()

  // (c) the persistent term is used when no process dictionary entry exists.
  set_persistent_active("m2")
  let with_persistent_term = active(module)

  // (d) the process dictionary still wins over the persistent term.
  set_process_active("m1")
  let with_both = active(module)

  // (e) a freshly spawned process inherits only the persistent term.
  let in_spawned_process = active_in_new_process(module)

  erase_process_active()
  erase_persistent_active()
  let after_cleanup = active(module)
  let assert Ok(Nil) = simplifile.delete(root)

  let from_environment = platform.env("GLEAM_MUTANTS_ACTIVE")
  assert unset == from_environment
  assert with_dictionary == "m1"
  assert with_persistent_term == "m2"
  assert with_both == "m1"
  assert in_spawned_process == "m2"
  assert after_cleanup == from_environment
}

pub fn generated_javascript_runtime_uses_process_context_without_a_global_override_test() {
  let root = fresh_snapshot_root()
  let assert Ok(generated) = runtime.generate(root, platform.random_nonce())
  let assert Ok(source) =
    simplifile.read(generated_source_path(root, runtime.name(generated), ".mjs"))
  let assert Ok(Nil) = simplifile.delete(root)

  assert !string.contains(source, "let override")
  assert !string.contains(source, "set_active")
  assert string.contains(source, "globalThis.process?.env")
  assert string.contains(source, "globalThis.Deno.env.get")
  assert string.contains(source, "GLEAM_MUTANTS_ACTIVE")
}

pub fn generated_javascript_runtime_isolates_parallel_process_contexts_test() {
  let root = fresh_snapshot_root()
  let assert Ok(generated) = runtime.generate(root, platform.random_nonce())
  let module = "./src/" <> runtime.name(generated) <> "_ffi.mjs"
  let script =
    "import { active } from '"
    <> module
    <> "'; setTimeout(() => process.stdout.write(active()), 100)"
  let requests =
    ["mutant-one", "mutant-two"]
    |> list.map(fn(id) {
      platform.ProcessRequest(
        "node",
        ["--input-type=module", "-e", script],
        root,
        [#("GLEAM_MUTANTS_ACTIVE", id)],
        5000,
      )
    })
  let results = platform.run_process_batch(requests, 2)
  let assert Ok(Nil) = simplifile.delete(root)

  let observed =
    list.map(results, fn(result) {
      #(
        result.process.status,
        result.process.stdout,
        result.process.stderr,
        result.process.timed_out,
      )
    })
  let expected = [
    #(0, "mutant-one", "", False),
    #(0, "mutant-two", "", False),
  ]
  case observed == expected {
    True -> Nil
    False -> panic as string.inspect(observed)
  }
}
