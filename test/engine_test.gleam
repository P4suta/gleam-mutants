// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/string
import gleam_mutants/core/operator
import gleam_mutants/core/path
import gleam_mutants/engine
import gleam_mutants/platform
import simplifile

const calc_source = "pub fn add(a: Int, b: Int) -> Int {\n  a + b\n}\n"

const inert_source = "pub fn identity(value: Int) -> Int {\n  value\n}\n"

fn fresh_root(label: String) -> String {
  let root =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-engine-" <> label <> "-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  root
}

fn write_source(root: String, relative: String, contents: String) -> Nil {
  let target = path.join(root, relative)
  let assert Ok(Nil) = simplifile.create_directory_all(path.parent(target))
  let assert Ok(Nil) = simplifile.write(target, contents)
  Nil
}

fn first_meaningful_line(source: String) -> String {
  let remaining =
    source
    |> string.split("\n")
    |> list.drop_while(fn(line) {
      let trimmed = line |> string.replace("\r", "") |> string.trim
      trimmed == "" || string.starts_with(trimmed, "//")
    })
  let assert Ok(line) = list.first(remaining)
  string.replace(line, "\r", "")
}

pub fn instrument_wraps_selected_mutants_and_leaves_other_files_alone_test() {
  let root = fresh_root("instrument")
  write_source(root, "src/calc.gleam", calc_source)
  write_source(root, "src/inert.gleam", inert_source)

  let assert Ok(catalogs) =
    engine.discover_catalogs(root, ["src/calc.gleam", "src/inert.gleam"], [
      operator.IntegerArithmetic,
    ])
  let mutants = list.flat_map(catalogs, fn(entry) { entry.mutants })
  assert list.length(mutants) >= 1

  let assert Ok(Nil) = engine.instrument(root, catalogs, mutants, "rt_mod")

  let assert Ok(instrumented) =
    simplifile.read(path.join(root, "src/calc.gleam"))
  let assert Ok(untouched) = simplifile.read(path.join(root, "src/inert.gleam"))

  assert first_meaningful_line(instrumented) == "import rt_mod"
  assert list.all(mutants, fn(mutant) {
    string.contains(instrumented, "rt_mod.select(\"" <> mutant.id)
  })
  assert string.contains(instrumented, "pub fn add(a: Int, b: Int) -> Int {")
  assert untouched == inert_source

  let assert Ok(Nil) = platform.delete_tree(root)
}

pub fn write_generated_files_creates_parents_and_overwrites_test() {
  let root = fresh_root("generated")

  let assert Ok(Nil) =
    engine.write_generated_files(root, [
      #("test/generated/probe.gleam", "pub fn probe() -> Int {\n  1\n}\n"),
      #("src/x.erl", "-module(x).\n"),
    ])

  assert simplifile.read(path.join(root, "test/generated/probe.gleam"))
    == Ok("pub fn probe() -> Int {\n  1\n}\n")
  assert simplifile.read(path.join(root, "src/x.erl")) == Ok("-module(x).\n")

  let assert Ok(Nil) =
    engine.write_generated_files(root, [
      #("test/generated/probe.gleam", "pub fn probe() -> Int {\n  2\n}\n"),
    ])

  assert simplifile.read(path.join(root, "test/generated/probe.gleam"))
    == Ok("pub fn probe() -> Int {\n  2\n}\n")
  assert simplifile.read(path.join(root, "src/x.erl")) == Ok("-module(x).\n")

  let assert Ok(Nil) = platform.delete_tree(root)
}

pub fn build_targets_without_runtimes_is_a_no_op_test() {
  let root = fresh_root("targets")

  assert engine.build_targets(root, []) == Ok(Nil)

  let assert Ok(Nil) = platform.delete_tree(root)
}

pub fn discover_catalogs_reports_missing_sources_test() {
  let root = fresh_root("missing")

  let result =
    engine.discover_catalogs(root, ["src/absent.gleam"], [
      operator.IntegerArithmetic,
    ])

  assert result == Error(simplifile.describe_error(simplifile.Enoent))

  let assert Ok(Nil) = platform.delete_tree(root)
}
