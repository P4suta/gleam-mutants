// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/test_impact
import simplifile

fn manifest() -> test_impact.Manifest {
  test_impact.Manifest(
    schema_version: 1,
    runner: "smartest",
    runtime: "erlang",
    complete: True,
    tests: [
      test_impact.TestDescriptor("leaf-a", "test-a", "smartest-leaf"),
      test_impact.TestDescriptor("legacy-b", "test-b", "legacy-export"),
      test_impact.TestDescriptor("leaf-c", "test-c", "smartest-leaf"),
    ],
    reaches: [
      test_impact.Reach("test-c", ["m1"]),
      test_impact.Reach("test-a", ["m1", "m2"]),
      test_impact.Reach("test-b", []),
    ],
  )
}

pub fn manifest_round_trips_without_losing_order_test() {
  let expected = manifest()
  let assert Ok(decoded) =
    expected |> test_impact.encode_manifest |> test_impact.decode_manifest
  assert decoded == expected
}

pub fn selection_round_trips_test() {
  let expected =
    test_impact.SelectionFile(1, "smartest", "node", ["leaf-b", "leaf-a"])
  let assert Ok(decoded) =
    expected |> test_impact.encode_selection |> test_impact.decode_selection
  assert decoded == expected
}

pub fn selector_order_comes_from_descriptors_not_reach_order_test() {
  assert test_impact.selectors_for(manifest(), "m1") == ["leaf-a", "leaf-c"]
  assert test_impact.selectors_for(manifest(), "unreached") == []
}

pub fn manifest_validation_fails_closed_test() {
  let valid = manifest()
  assert test_impact.validate_manifest(valid, "erlang", ["m1", "m2"]) == Ok(Nil)
  assert test_impact.validate_manifest(
      test_impact.Manifest(..valid, complete: False),
      "erlang",
      ["m1", "m2"],
    )
    == Error("provider reported incomplete impact evidence")
  assert test_impact.validate_manifest(valid, "node", ["m1", "m2"])
    == Error("impact manifest runtime does not match the worker runtime")
  assert test_impact.validate_manifest(valid, "erlang", ["m1"])
    == Error("impact manifest names an unknown mutant")
  assert test_impact.validate_manifest(
      test_impact.Manifest(..valid, reaches: [
        test_impact.Reach("unknown", ["m1"]),
      ]),
      "erlang",
      ["m1", "m2"],
    )
    == Error("impact manifest names an unknown test")
  assert test_impact.validate_manifest(
      test_impact.Manifest(..valid, reaches: [
        test_impact.Reach("test-a", ["m1"]),
        test_impact.Reach("test-a", ["m2"]),
      ]),
      "erlang",
      ["m1", "m2"],
    )
    == Error("impact manifest contains duplicate reach entries")
  assert test_impact.validate_manifest(
      test_impact.Manifest(..valid, reaches: [
        test_impact.Reach("test-a", ["m1", "m1"]),
      ]),
      "erlang",
      ["m1", "m2"],
    )
    == Error("impact manifest contains duplicate mutant reaches")
}

pub fn malformed_and_unknown_schema_documents_are_rejected_test() {
  assert test_impact.decode_manifest("{\"schema_version\":") |> result.is_error
  assert test_impact.decode_manifest(
      "{\"schema_version\":2,\"runner\":\"smartest\",\"runtime\":\"erlang\",\"complete\":true,\"tests\":[],\"reaches\":[]}",
    )
    == Error("unsupported test impact manifest schema")
  assert test_impact.decode_selection(
      "{\"schema_version\":2,\"runner\":\"smartest\",\"runtime\":\"erlang\",\"selectors\":[]}",
    )
    == Error("unsupported test selection schema")
}

pub fn selection_is_atomically_written_below_the_snapshot_test() {
  let root =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-impact-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(target) =
    test_impact.write_selection(root, "erlang", "smartest", ["leaf-a"])
  let assert Ok(source) = simplifile.read(target)
  let assert Ok(decoded) = test_impact.decode_selection(source)
  let assert Ok(entries) =
    simplifile.read_directory(path.join(root, ".gleam_mutants"))
  let assert Ok(Nil) = simplifile.delete(root)

  assert string.starts_with(target, path.join(root, ".gleam_mutants"))
  assert decoded
    == test_impact.SelectionFile(1, "smartest", "erlang", ["leaf-a"])
  assert list.length(entries) == 1
  assert list.all(entries, fn(entry) { !string.contains(entry, ".tmp-") })
}
