// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/result
import gleam/string
import simplifile

const pure_modules = [
  "src/smartest/evidence.gleam",
  "src/smartest/corpus.gleam",
  "src/smartest/gen.gleam",
  "src/smartest/concurrency.gleam",
  "src/smartest/differential.gleam",
  "src/smartest/doctest.gleam",
  "src/smartest/exhaustive.gleam",
  "src/smartest/fault.gleam",
  "src/smartest/fuzz.gleam",
  "src/smartest/hyperproperty.gleam",
  "src/smartest/impact.gleam",
  "src/smartest/legacy.gleam",
  "src/smartest/metamorphic.gleam",
  "src/smartest/observe.gleam",
  "src/smartest/performance.gleam",
  "src/smartest/reference.gleam",
  "src/smartest/testing.gleam",
  "src/smartest/property.gleam",
  "src/smartest/model.gleam",
  "src/smartest/scenario.gleam",
  "src/smartest/solver.gleam",
  "src/smartest/snapshot.gleam",
  "src/smartest/transcript.gleam",
  "src/smartest/watch.gleam",
  "src/smartest/internal/plan.gleam",
]

const pure_smartest_imports = [
  "smartest/evidence",
  "smartest/corpus",
  "smartest/gen",
  "smartest/concurrency",
  "smartest/differential",
  "smartest/doctest",
  "smartest/exhaustive",
  "smartest/fault",
  "smartest/fuzz",
  "smartest/hyperproperty",
  "smartest/impact",
  "smartest/legacy",
  "smartest/metamorphic",
  "smartest/observe",
  "smartest/performance",
  "smartest/reference",
  "smartest/scenario",
  "smartest/solver",
  "smartest/snapshot",
  "smartest/transcript",
  "smartest/testing",
  "smartest/property",
  "smartest/internal/plan",
]

pub fn smartest_core_is_stdlib_only_and_ffi_free_test() {
  pure_modules
  |> list.each(fn(path) {
    let source = simplifile.read(path) |> result.unwrap("")
    assert source != ""
    assert !string.contains(source, "@external(")
    source
    |> string.split("\n")
    |> list.filter_map(import_name)
    |> list.each(fn(imported) {
      assert string.starts_with(imported, "gleam/")
        || list.contains(pure_smartest_imports, imported)
    })
  })
}

pub fn mutation_engine_never_depends_back_on_smartest_core_test() {
  let assert Ok(files) = simplifile.read_directory("src/gleam_mutants")
  files
  |> list.filter(fn(file) { string.ends_with(file, ".gleam") })
  |> list.each(fn(file) {
    let source =
      simplifile.read("src/gleam_mutants/" <> file) |> result.unwrap("")
    assert !string.contains(source, "import smartest/")
  })
}

pub fn smartest_runtime_shell_is_not_part_of_the_public_package_api_test() {
  let config = simplifile.read("gleam.toml") |> result.unwrap("")
  assert string.contains(config, "\"smartest/internal/*\"")
}

fn import_name(line: String) -> Result(String, Nil) {
  let line = string.trim(line)
  case string.starts_with(line, "import ") {
    False -> Error(Nil)
    True -> {
      let name =
        line
        |> string.drop_start(7)
        |> string.split(".")
        |> list.first
        |> result.unwrap("")
        |> string.split(" ")
        |> list.first
        |> result.unwrap("")
      Ok(name)
    }
  }
}
