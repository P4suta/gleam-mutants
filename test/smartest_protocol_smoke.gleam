// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/test_impact
import simplifile

pub fn main() {
  let runtimes = case platform.arguments() {
    [] -> ["erlang", "node"]
    selected -> selected
  }
  list.each(runtimes, verify_runtime)
}

fn verify_runtime(runtime: String) -> Nil {
  let root = platform.current_directory()
  let private = path.join(root, ".gleam_mutants")
  let impact =
    path.join(
      private,
      "smartest-protocol-"
        <> runtime
        <> "-"
        <> platform.random_nonce()
        <> ".json",
    )
  let baseline =
    run(runtime, [
      #("GLEAM_MUTANTS_ACTIVE", ""),
      #("GLEAM_MUTANTS_RUNTIME", runtime),
      #("GLEAM_MUTANTS_TEST_IMPACT_FILE", impact),
      #("SMARTEST_FILTER", "smartest_native_fixture"),
    ])
  assert baseline.status == 0
  let assert Ok(source) = simplifile.read(impact)
  let assert Ok(manifest) = test_impact.decode_manifest(source)
  assert manifest.runner == "smartest"
  assert manifest.runtime == runtime
  assert manifest.complete
  assert list.map(manifest.tests, fn(descriptor) { descriptor.kind })
    == ["smartest-leaf", "smartest-leaf"]
  let assert [first, _] = manifest.tests

  let assert Ok(selection) =
    test_impact.write_selection(root, runtime, "smartest", [first.selector])
  let narrowed =
    run(runtime, [
      #("GLEAM_MUTANTS_ACTIVE", ""),
      #("GLEAM_MUTANTS_RUNTIME", runtime),
      #("GLEAM_MUTANTS_TEST_SELECTION_FILE", selection),
      #("SMARTEST_FILTER", "smartest_native_fixture"),
    ])
  assert narrowed.status == 0
  assert string.contains(narrowed.stdout, "1 passed, 0 failed")

  let legacy_impact =
    path.join(
      private,
      "smartest-protocol-legacy-"
        <> runtime
        <> "-"
        <> platform.random_nonce()
        <> ".json",
    )
  let legacy_baseline =
    run(runtime, [
      #("GLEAM_MUTANTS_ACTIVE", ""),
      #("GLEAM_MUTANTS_RUNTIME", runtime),
      #("GLEAM_MUTANTS_TEST_IMPACT_FILE", legacy_impact),
      #("SMARTEST_FILTER", "stable_id_is_path_separator_portable"),
    ])
  assert legacy_baseline.status == 0
  let assert Ok(legacy_source) = simplifile.read(legacy_impact)
  let assert Ok(legacy_manifest) = test_impact.decode_manifest(legacy_source)
  let assert [legacy_descriptor] = legacy_manifest.tests
  assert legacy_descriptor.kind == "legacy-export"
  let assert Ok(legacy_selection) =
    test_impact.write_selection(root, runtime, "smartest", [
      legacy_descriptor.selector,
    ])
  let legacy_narrowed =
    run(runtime, [
      #("GLEAM_MUTANTS_ACTIVE", ""),
      #("GLEAM_MUTANTS_RUNTIME", runtime),
      #("GLEAM_MUTANTS_TEST_SELECTION_FILE", legacy_selection),
      #("SMARTEST_FILTER", "stable_id_is_path_separator_portable"),
    ])
  assert legacy_narrowed.status == 0
  assert string.contains(legacy_narrowed.stdout, "1 passed, 0 failed")

  let assert Ok(unknown) =
    test_impact.write_selection(root, runtime, "smartest", ["unknown/test"])
  let rejected =
    run(runtime, [
      #("GLEAM_MUTANTS_ACTIVE", ""),
      #("GLEAM_MUTANTS_RUNTIME", runtime),
      #("GLEAM_MUTANTS_TEST_SELECTION_FILE", unknown),
      #("SMARTEST_FILTER", "smartest_native_fixture"),
    ])
  assert rejected.status != 0
  assert string.contains(
    rejected.stdout <> rejected.stderr,
    "unknown test selector",
  )

  let assert Ok(Nil) = simplifile.delete_file(at: impact)
  let assert Ok(Nil) = simplifile.delete_file(at: selection)
  let assert Ok(Nil) = simplifile.delete_file(at: legacy_impact)
  let assert Ok(Nil) = simplifile.delete_file(at: legacy_selection)
  let assert Ok(Nil) = simplifile.delete_file(at: unknown)
  let assert Ok(entries) = simplifile.read_directory(private)
  assert !list.any(entries, fn(entry) {
    string.contains(entry, "smartest-protocol-")
    && string.contains(entry, ".tmp-")
  })
}

fn run(runtime: String, environment: List(#(String, String))) {
  let arguments = case runtime {
    "erlang" -> ["test", "--target", "erlang"]
    javascript -> [
      "test",
      "--target",
      "javascript",
      "--runtime",
      javascript,
    ]
  }
  platform.run_process(
    "gleam",
    arguments,
    platform.current_directory(),
    environment,
    30_000,
  )
}
