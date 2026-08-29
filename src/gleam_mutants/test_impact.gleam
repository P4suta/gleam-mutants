//// Provider-independent adaptive test-selection protocol.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile

pub const schema_version = 1

/// One ordered test the provider can select without exposing command syntax.
pub type TestDescriptor {
  TestDescriptor(selector: String, test_id: String, kind: String)
}

/// Mutation sites reached while one test descriptor was active.
pub type Reach {
  Reach(test_id: String, mutant_ids: List(String))
}

/// Evidence written atomically by a compatible runner after an instrumented
/// baseline. Ordering in `tests` is the provider's execution order.
pub type Manifest {
  Manifest(
    schema_version: Int,
    runner: String,
    runtime: String,
    complete: Bool,
    tests: List(TestDescriptor),
    reaches: List(Reach),
  )
}

/// Opaque selectors lent back to the same provider in a worker snapshot.
pub type SelectionFile {
  SelectionFile(
    schema_version: Int,
    runner: String,
    runtime: String,
    selectors: List(String),
  )
}

/// Ordered selectors indexed once for all mutants in one run.
pub opaque type SelectorIndex {
  SelectorIndex(selectors: dict.Dict(String, List(String)))
}

pub fn encode_manifest(manifest: Manifest) -> String {
  json.object([
    #("schema_version", json.int(manifest.schema_version)),
    #("runner", json.string(manifest.runner)),
    #("runtime", json.string(manifest.runtime)),
    #("complete", json.bool(manifest.complete)),
    #("tests", json.array(manifest.tests, descriptor_json)),
    #("reaches", json.array(manifest.reaches, reach_json)),
  ])
  |> json.to_string
}

pub fn decode_manifest(source: String) -> Result(Manifest, String) {
  use manifest <- result.try(
    json.parse(source, manifest_decoder())
    |> result.map_error(fn(error) {
      "invalid test impact manifest JSON: " <> string.inspect(error)
    }),
  )
  case manifest.schema_version == schema_version {
    True -> Ok(manifest)
    False -> Error("unsupported test impact manifest schema")
  }
}

pub fn encode_selection(selection: SelectionFile) -> String {
  json.object([
    #("schema_version", json.int(selection.schema_version)),
    #("runner", json.string(selection.runner)),
    #("runtime", json.string(selection.runtime)),
    #("selectors", json.array(selection.selectors, json.string)),
  ])
  |> json.to_string
}

pub fn decode_selection(source: String) -> Result(SelectionFile, String) {
  use selection <- result.try(
    json.parse(source, selection_decoder())
    |> result.map_error(fn(error) {
      "invalid test selection JSON: " <> string.inspect(error)
    }),
  )
  case selection.schema_version == schema_version {
    True -> Ok(selection)
    False -> Error("unsupported test selection schema")
  }
}

/// Fails closed on incomplete evidence or identities the engine did not lend
/// to the provider for this run.
pub fn validate_manifest(
  manifest: Manifest,
  runtime: String,
  known_mutants: List(String),
) -> Result(Nil, String) {
  use _ <- result.try(case manifest.complete {
    True -> Ok(Nil)
    False -> Error("provider reported incomplete impact evidence")
  })
  use _ <- result.try(case manifest.runtime == runtime {
    True -> Ok(Nil)
    False -> Error("impact manifest runtime does not match the worker runtime")
  })
  use _ <- result.try(case manifest.runner == "" {
    True -> Error("impact manifest runner is empty")
    False -> Ok(Nil)
  })
  let selectors =
    list.map(manifest.tests, fn(descriptor) { descriptor.selector })
  let test_ids = list.map(manifest.tests, fn(descriptor) { descriptor.test_id })
  use _ <- result.try(
    case
      selectors == []
      || list.any(selectors, fn(selector) { selector == "" })
      || list.any(test_ids, fn(test_id) { test_id == "" })
      || set.size(set.from_list(selectors)) != list.length(selectors)
      || set.size(set.from_list(test_ids)) != list.length(test_ids)
    {
      True -> Error("impact manifest contains invalid or duplicate tests")
      False -> Ok(Nil)
    },
  )
  let known_tests = set.from_list(test_ids)
  let known_mutants = set.from_list(known_mutants)
  use _ <- result.try(
    case
      manifest.reaches
      |> list.map(fn(reach) { reach.test_id })
      |> set.from_list
      |> set.size
      |> fn(size) { size == list.length(manifest.reaches) }
    {
      True -> Ok(Nil)
      False -> Error("impact manifest contains duplicate reach entries")
    },
  )
  use reach <- list.try_each(manifest.reaches)
  case
    set.contains(known_tests, reach.test_id),
    list.all(reach.mutant_ids, set.contains(known_mutants, _)),
    set.size(set.from_list(reach.mutant_ids)) == list.length(reach.mutant_ids)
  {
    True, True, True -> Ok(Nil)
    False, _, _ -> Error("impact manifest names an unknown test")
    _, False, _ -> Error("impact manifest names an unknown mutant")
    _, _, False -> Error("impact manifest contains duplicate mutant reaches")
  }
}

/// Provider selectors that reached `mutant_id`, in descriptor order.
pub fn selectors_for(manifest: Manifest, mutant_id: String) -> List(String) {
  selectors(selector_index(manifest), mutant_id)
}

pub fn selector_index(manifest: Manifest) -> SelectorIndex {
  let reached =
    manifest.reaches
    |> list.map(fn(reach) { #(reach.test_id, reach.mutant_ids) })
    |> dict.from_list
  let selectors =
    list.fold(manifest.tests, dict.new(), fn(index, descriptor) {
      let mutants = dict.get(reached, descriptor.test_id) |> result.unwrap([])
      list.fold(mutants, index, fn(index, mutant_id) {
        let existing = dict.get(index, mutant_id) |> result.unwrap([])
        dict.insert(index, mutant_id, [descriptor.selector, ..existing])
      })
    })
  SelectorIndex(selectors)
}

pub fn selectors(index: SelectorIndex, mutant_id: String) -> List(String) {
  dict.get(index.selectors, mutant_id)
  |> result.map(list.reverse)
  |> result.unwrap([])
}

/// Writes a selector document below the snapshot's private tool directory.
pub fn write_selection(
  snapshot_root: String,
  runtime: String,
  runner: String,
  selectors: List(String),
) -> Result(String, String) {
  let directory = path.join(snapshot_root, ".gleam_mutants")
  let target =
    path.join(
      directory,
      "test-selection-" <> runtime <> "-" <> platform.random_nonce() <> ".json",
    )
  let temporary = target <> ".tmp-" <> platform.random_nonce()
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(simplifile.describe_error),
  )
  let source =
    encode_selection(SelectionFile(schema_version, runner, runtime, selectors))
  case simplifile.write(temporary, source) {
    Error(error) -> {
      let _ = simplifile.delete_file(at: temporary)
      Error(simplifile.describe_error(error))
    }
    Ok(Nil) ->
      case simplifile.rename(at: temporary, to: target) {
        Ok(Nil) -> Ok(target)
        Error(error) -> {
          let _ = simplifile.delete_file(at: temporary)
          Error(simplifile.describe_error(error))
        }
      }
  }
}

fn descriptor_json(descriptor: TestDescriptor) -> json.Json {
  json.object([
    #("selector", json.string(descriptor.selector)),
    #("test_id", json.string(descriptor.test_id)),
    #("kind", json.string(descriptor.kind)),
  ])
}

fn reach_json(reach: Reach) -> json.Json {
  json.object([
    #("test_id", json.string(reach.test_id)),
    #("mutant_ids", json.array(reach.mutant_ids, json.string)),
  ])
}

fn manifest_decoder() -> decode.Decoder(Manifest) {
  use version <- decode.field("schema_version", decode.int)
  use runner <- decode.field("runner", decode.string)
  use runtime <- decode.field("runtime", decode.string)
  use complete <- decode.field("complete", decode.bool)
  use tests <- decode.field("tests", decode.list(descriptor_decoder()))
  use reaches <- decode.field("reaches", decode.list(reach_decoder()))
  decode.success(Manifest(version, runner, runtime, complete, tests, reaches))
}

fn descriptor_decoder() -> decode.Decoder(TestDescriptor) {
  use selector <- decode.field("selector", decode.string)
  use test_id <- decode.field("test_id", decode.string)
  use kind <- decode.field("kind", decode.string)
  decode.success(TestDescriptor(selector, test_id, kind))
}

fn reach_decoder() -> decode.Decoder(Reach) {
  use test_id <- decode.field("test_id", decode.string)
  use mutants <- decode.field("mutant_ids", decode.list(decode.string))
  decode.success(Reach(test_id, mutants))
}

fn selection_decoder() -> decode.Decoder(SelectionFile) {
  use version <- decode.field("schema_version", decode.int)
  use runner <- decode.field("runner", decode.string)
  use runtime <- decode.field("runtime", decode.string)
  use selectors <- decode.field("selectors", decode.list(decode.string))
  decode.success(SelectionFile(version, runner, runtime, selectors))
}
