// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Cover for the differential runner: the parts that decide *whether* a run may
// happen at all — the target gate, the requested sources and the module names
// the probes are generated from — and, on the Erlang target, a handful of real
// runs over throwaway workspaces.
//
// Everything that stays out of a snapshot is pure and runs on both targets. A
// run itself builds the snapshot it made, so the tests that need one are
// Erlang-only and delete every directory they created before they assert.

import glance
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/config
import gleam_mutants/core/catalog
import gleam_mutants/core/operator
import gleam_mutants/core/path
import gleam_mutants/engine
import gleam_mutants/platform
import gleam_mutants/suggest/diff_runner

@target(erlang)
import gleam_mutants/suggest/probe_result

import gleam_mutants/suggest/select
import gleam_mutants/suggest/typederive
import simplifile

// --- fixtures ---------------------------------------------------------------

const plain_toml = "name = \"demo\"
version = \"1.0.0\"
"

const javascript_project_toml = "name = \"demo\"
version = \"1.0.0\"
target = \"javascript\"
"

const erlang_project_toml = "name = \"demo\"
version = \"1.0.0\"
target = \"erlang\"
"

const javascript_test_toml = "name = \"demo\"
version = \"1.0.0\"

[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.test]
target = \"javascript\"
"

const node_runtime_toml = "name = \"demo\"
version = \"1.0.0\"

[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.test]
runtime = \"node\"
"

const erlang_test_of_javascript_project_toml = "name = \"demo\"
version = \"1.0.0\"
target = \"javascript\"

[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.test]
target = \"erlang\"
"

fn target_verdict(gleam_toml: String) -> Result(Nil, String) {
  let assert Ok(configured) = config.decode(gleam_toml, 1)
  diff_runner.check_target(configured, gleam_toml)
}

// --- defaults ---------------------------------------------------------------

pub fn defaults_carry_the_standard_budgets_test() {
  let request = diff_runner.defaults("workspace", ["src/app.gleam"])
  assert request
    == diff_runner.Request(
      workspace: "workspace",
      files: ["src/app.gleam"],
      function_filter: None,
      seed: 1,
      max_cases: 200,
      max_shrinks: 500,
      call_timeout_ms: 1000,
      probe_timeout_ms: 120_000,
      nondeterminism_checks: 3,
      exclude_functions: [],
    )
}

// --- check_target -----------------------------------------------------------

pub fn check_target_accepts_a_workspace_without_a_target_test() {
  assert target_verdict(plain_toml) == Ok(Nil)
}

pub fn check_target_accepts_an_erlang_workspace_test() {
  assert target_verdict(erlang_project_toml) == Ok(Nil)
}

pub fn check_target_rejects_an_explicit_javascript_test_target_test() {
  assert target_verdict(javascript_test_toml)
    == Error("GMU8001: suggest supports the Erlang target only")
}

pub fn check_target_rejects_a_javascript_project_target_test() {
  assert target_verdict(javascript_project_toml)
    == Error("GMU8001: suggest supports the Erlang target only")
}

pub fn check_target_rejects_a_javascript_test_runtime_test() {
  assert target_verdict(node_runtime_toml)
    == Error("GMU8001: suggest supports the Erlang target only")
}

pub fn check_target_accepts_erlang_tests_of_a_javascript_project_test() {
  assert target_verdict(erlang_test_of_javascript_project_toml) == Ok(Nil)
}

// --- distinct_sources -------------------------------------------------------

pub fn distinct_sources_keeps_unrelated_files_in_order_test() {
  assert diff_runner.distinct_sources(["src/one.gleam", "src/app/two.gleam"])
    == Ok(["src/one.gleam", "src/app/two.gleam"])
}

pub fn distinct_sources_drops_a_repeated_file_test() {
  assert diff_runner.distinct_sources([
      "src/app_util.gleam",
      "src/app_util.gleam",
    ])
    == Ok(["src/app_util.gleam"])
}

pub fn distinct_sources_rejects_two_files_sharing_a_probe_module_test() {
  let assert Error(reason) =
    diff_runner.distinct_sources(["src/app_util.gleam", "src/app/util.gleam"])
  assert string.starts_with(reason, "GMU8006: ")
  assert string.contains(reason, "src/app_util.gleam")
  assert string.contains(reason, "src/app/util.gleam")
  assert string.contains(reason, "app_util")
}

// --- check_covered ----------------------------------------------------------

pub fn check_covered_accepts_a_covered_source_test() {
  assert diff_runner.check_covered(["src/app.gleam"], [
      "src/app.gleam",
      "src/other.gleam",
    ])
    == Ok(Nil)
}

pub fn check_covered_rejects_an_uncovered_source_test() {
  let assert Error(reason) =
    diff_runner.check_covered(["src/nope.gleam"], ["src/app.gleam"])
  assert string.starts_with(reason, "GMU8002: ")
  assert string.contains(reason, "src/nope.gleam")
}

// --- module_name ------------------------------------------------------------

pub fn module_name_trims_the_source_root_and_extension_test() {
  assert diff_runner.module_name("src/boundary.gleam") == "boundary"
}

pub fn module_name_keeps_nested_modules_test() {
  assert diff_runner.module_name("src/app/util.gleam") == "app/util"
}

pub fn module_name_normalises_windows_separators_test() {
  assert diff_runner.module_name("src\\app\\util.gleam") == "app/util"
}

pub fn module_name_leaves_a_path_outside_src_alone_test() {
  assert diff_runner.module_name("vendor/app.gleam") == "vendor/app"
}

// --- filter_targets ---------------------------------------------------------

const two_functions = "pub fn add(a: Int, b: Int) -> Int {
  a + b
}

pub fn multiply(a: Int, b: Int) -> Int {
  a * b
}
"

fn targets(source: String) -> List(select.FunctionTarget) {
  let assert Ok(discovered) =
    catalog.discover("src/demo.gleam", source, operator.all())
  let assert Ok(parsed) = glance.module(source)
  let #(found, _) = select.assign(parsed, discovered.mutants)
  found
}

fn probed_names(found: List(select.FunctionTarget)) -> List(String) {
  list.map(found, fn(target) { target.function.name })
}

pub fn filter_targets_keeps_every_function_without_a_filter_test() {
  assert probed_names(diff_runner.filter_targets(None, targets(two_functions)))
    == ["add", "multiply"]
}

pub fn filter_targets_keeps_only_the_named_function_test() {
  assert probed_names(diff_runner.filter_targets(
      Some("multiply"),
      targets(two_functions),
    ))
    == ["multiply"]
}

pub fn filter_targets_drops_every_function_when_the_name_is_unknown_test() {
  assert diff_runner.filter_targets(Some("missing"), targets(two_functions))
    == []
}

// --- split_excluded ---------------------------------------------------------

pub fn split_excluded_probes_every_target_when_nothing_is_named_test() {
  let #(probed, left_alone) =
    diff_runner.split_excluded([], targets(two_functions))
  assert probed_names(probed) == ["add", "multiply"]
  assert left_alone == []
}

pub fn split_excluded_takes_the_named_function_out_of_the_probe_test() {
  let #(probed, left_alone) =
    diff_runner.split_excluded(["multiply"], targets(two_functions))
  assert probed_names(probed) == ["add"]
  assert probed_names(left_alone) == ["multiply"]
}

pub fn split_excluded_ignores_a_name_the_module_does_not_have_test() {
  let #(probed, left_alone) =
    diff_runner.split_excluded(["missing"], targets(two_functions))
  assert probed_names(probed) == ["add", "multiply"]
  assert left_alone == []
}

// --- classify ---------------------------------------------------------------

const classify_source = "pub fn add(a: Int, b: Int) -> Int {
  a + b
}

fn hidden(x: Int) -> Int {
  x + 1
}

pub fn loose(x) -> Int {
  x + 1
}

pub fn adder(x: Int) -> fn(Int) -> Int {
  fn(y) { x + y }
}
"

/// The name of the plan `classify` made, or the reason it refused to make one.
fn classified(source: String, name: String) -> Result(String, String) {
  let assert Ok(parsed) = glance.module(source)
  let context = typederive.context(parsed)
  let assert Ok(definition) =
    list.find(parsed.functions, fn(definition) {
      definition.definition.name == name
    })
  diff_runner.classify(context, definition.definition)
  |> result.map(fn(plan) { plan.name })
}

pub fn classify_plans_a_public_annotated_function_test() {
  assert classified(classify_source, "add") == Ok("add")
}

pub fn classify_refuses_a_private_function_test() {
  assert classified(classify_source, "hidden") == Error("private function")
}

pub fn classify_refuses_an_unannotated_parameter_test() {
  let assert Error(reason) = classified(classify_source, "loose")
  assert string.contains(reason, "no type annotation")
}

pub fn classify_refuses_a_function_typed_return_test() {
  assert classified(classify_source, "adder")
    == Error("return type contains a function")
}

/// A type that recurses at an instantiation other than its own is not one the
/// probe can name, and a whole run must not fail over it: the function it
/// annotates is given up on, one function at a time, like any other wall.
const non_uniform_source = "pub type W(a) {
  Stop
  Go(W(Int))
}

pub fn walk(w: W(String)) -> Int {
  case w {
    Stop -> 0
    Go(_) -> 1
  }
}

pub fn size(w: W(Int)) -> Int {
  case w {
    Stop -> 0
    Go(inner) -> 1 + size(inner)
  }
}
"

pub fn classify_refuses_a_type_recursing_at_another_instantiation_test() {
  let assert Error(reason) = classified(non_uniform_source, "walk")
  assert string.contains(reason, "another instantiation")
}

// --- planning one module ----------------------------------------------------

/// A function whose probe helper would be named `gen_type_shape`, beside a
/// type whose generator asks for that very name.
const clashing_source = "pub type Shape {
  Circle(radius: Int)
}

pub fn type_shape(shape: Shape) -> Int {
  case shape {
    Circle(radius) -> radius + 1
  }
}
"

fn planned(source: String) -> Result(Nil, String) {
  let assert Ok(discovered) =
    catalog.discover("src/demo.gleam", source, operator.all())
  diff_runner.check_plan(
    diff_runner.defaults("/workspace", ["src/demo.gleam"]),
    engine.SourceCatalog(
      "src/demo.gleam",
      source,
      discovered.mutants,
      discovered.rejected,
    ),
    "t01",
    "gleam_mutants_pbt_t01",
  )
}

pub fn plan_module_plans_a_probe_whose_helpers_are_unique_test() {
  assert planned(two_functions) == Ok(Nil)
}

/// The name guard is only worth having if it reaches the caller: a probe that
/// would define one name twice has to be reported here, not left to fail as a
/// snapshot that does not compile.
pub fn plan_module_reports_a_probe_that_would_define_a_name_twice_test() {
  let assert Error(reason) = planned(clashing_source)
  assert string.starts_with(reason, "GMU8007: ")
  assert string.contains(reason, "gen_type_shape")
}

/// A wall one function runs into is that function's alone: the module still
/// plans, and the run reports on everything else it holds. `size` takes the
/// very type `walk` does, at the instantiation it recurses at.
pub fn plan_module_keeps_planning_around_a_function_it_cannot_probe_test() {
  assert classified(non_uniform_source, "size") == Ok("size")
  assert planned(non_uniform_source) == Ok(Nil)
}

// --- the runtime decides before the target ----------------------------------

const erlang_runtime_of_javascript_test_toml = "name = \"demo\"
version = \"1.0.0\"

[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.test]
target = \"javascript\"
runtime = \"erlang\"
"

const node_runtime_of_erlang_test_toml = "name = \"demo\"
version = \"1.0.0\"

[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.test]
target = \"erlang\"
runtime = \"node\"
"

const deno_runtime_of_erlang_test_toml = "name = \"demo\"
version = \"1.0.0\"

[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.test]
target = \"erlang\"
runtime = \"deno\"
"

const erlang_runtime_of_javascript_project_toml = "name = \"demo\"
version = \"1.0.0\"
target = \"javascript\"

[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.test]
runtime = \"erlang\"
"

/// A configured runtime settles the question on its own, exactly as
/// `engine.detect_runtime` settles it: the target is only consulted when the
/// runtime is left on `auto`. Tests that say `runtime = "erlang"` run on the
/// BEAM whatever target is written beside them, so the probe can run too.
pub fn check_target_lets_an_erlang_runtime_outrank_a_javascript_target_test() {
  assert target_verdict(erlang_runtime_of_javascript_test_toml) == Ok(Nil)
  assert target_verdict(erlang_runtime_of_javascript_project_toml) == Ok(Nil)
}

/// ... and the other way round: a JavaScript runtime is where the tests run
/// even when `target = "erlang"` is written beside it, and there the probe's
/// Erlang FFI does not exist.
pub fn check_target_lets_a_javascript_runtime_outrank_an_erlang_target_test() {
  assert target_verdict(node_runtime_of_erlang_test_toml)
    == Error("GMU8001: suggest supports the Erlang target only")
  assert target_verdict(deno_runtime_of_erlang_test_toml)
    == Error("GMU8001: suggest supports the Erlang target only")
}

// --- describe ---------------------------------------------------------------

/// A failure is printed the way it always was: the code, a colon, the message.
pub fn describe_prints_the_code_before_the_message_test() {
  assert diff_runner.describe(diff_runner.RunError(
      code: "GMU8001",
      message: "suggest supports the Erlang target only",
      snapshot_root: None,
    ))
    == "GMU8001: suggest supports the Erlang target only"
}

/// A snapshot the run left behind is named on its own line, so whoever reads
/// the message knows where the generated probe is — and what to delete.
pub fn describe_names_the_snapshot_it_left_behind_test() {
  assert diff_runner.describe(diff_runner.RunError(
      code: "GMU8003",
      message: "the instrumented snapshot did not compile:\nboom",
      snapshot_root: Some("/tmp/gleam-mutants-abc"),
    ))
    == "GMU8003: the instrumented snapshot did not compile:\nboom\n"
    <> "the snapshot was left at /tmp/gleam-mutants-abc"
}

// --- running a workspace ----------------------------------------------------

/// A throwaway workspace on disk: the manifest, and the sources under it.
fn workspace(gleam_toml: String, sources: List(#(String, String))) -> String {
  let root =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-diff-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(path.join(root, "src"))
  let assert Ok(Nil) =
    simplifile.write(path.join(root, "gleam.toml"), gleam_toml)
  list.each(sources, fn(source) {
    let #(relative, contents) = source
    let target = path.join(root, relative)
    let assert Ok(Nil) = simplifile.create_directory_all(path.parent(target))
    let assert Ok(Nil) = simplifile.write(target, contents)
  })
  root
}

/// Deletes a directory, there or not, and says nothing about it.
fn discard(root: String) -> Nil {
  let _ = platform.delete_tree(root)
  Nil
}

/// Deletes the snapshot a failure names, answering whether it was really
/// there: a caller that is told about a snapshot has to be able to delete it.
fn discard_snapshot(root: Option(String)) -> Bool {
  case root {
    None -> False
    Some(directory) -> {
      let existed = simplifile.is_directory(directory) == Ok(True)
      discard(directory)
      existed
    }
  }
}

/// The target gate runs before anything is copied: a JavaScript workspace
/// costs one file read and leaves nothing behind.
pub fn run_rejects_a_javascript_workspace_test() {
  let root =
    workspace(javascript_project_toml, [#("src/demo.gleam", two_functions)])
  let outcome = diff_runner.run(diff_runner.defaults(root, ["src/demo.gleam"]))
  discard(root)

  let assert Error(error) = outcome
  let leftover = discard_snapshot(error.snapshot_root)
  assert error.code == "GMU8001"
  assert leftover == False
  assert diff_runner.describe(error)
    == "GMU8001: suggest supports the Erlang target only"
}

/// A path the mutation includes do not cover is rejected by name, and the
/// copy the runner had already made goes with it: a mistyped path must not
/// leave a workspace behind.
///
/// A `snapshot_root` of `None` says only that the caller was handed nothing to
/// delete, which a runner that quietly leaked its copy would say just as
/// loudly. So the directory snapshots are made in is read either side of the
/// run: the only thing that may leave it is the workspace this test made, and
/// nothing may be added to it.
pub fn run_rejects_a_file_outside_the_mutation_includes_test() {
  let root = workspace(plain_toml, [#("src/demo.gleam", two_functions)])
  let before = snapshot_siblings()
  let outcome =
    diff_runner.run(diff_runner.defaults(root, ["src/missing.gleam"]))
  discard(root)
  let added =
    list.filter(snapshot_siblings(), fn(entry) { !list.contains(before, entry) })

  let assert Error(error) = outcome
  let leftover = discard_snapshot(error.snapshot_root)
  // The listing really does see what the runner writes: the workspace above
  // is in it, so an empty `added` is evidence rather than an empty reading.
  assert list.contains(before, path.base_name(root))
  assert added == []
  assert error.code == "GMU8002"
  assert leftover == False
  assert string.contains(error.message, "src/missing.gleam")
  assert string.starts_with(
    diff_runner.describe(error),
    "GMU8002: src/missing.gleam",
  )
}

/// The directories a snapshot could be sitting in: everything in the temporary
/// directory that a snapshot, or a workspace one of these tests made, is named
/// like. Anything else there belongs to the machine, not to this run.
fn snapshot_siblings() -> List(String) {
  let assert Ok(entries) =
    simplifile.read_directory(platform.temporary_directory())
  list.filter(entries, fn(entry) { string.starts_with(entry, "gleam-mutants-") })
}

// --- running a workspace, for real ------------------------------------------

@target(erlang)
/// A manifest holding the one dependency a generated probe imports.
const stdlib_toml = "name = \"diff_demo\"
version = \"1.0.0\"

[dependencies]
gleam_stdlib = \">= 0.44.0 and < 2.0.0\"
"

@target(erlang)
/// Two public functions, a private one, and a caller keeping it alive.
const nested_source = "pub fn add(a: Int, b: Int) -> Int {
  a + b
}

fn bump(value: Int) -> Int {
  value + 1
}

pub fn bumped(value: Int) -> Int {
  bump(value)
}
"

@target(erlang)
/// A source that parses but does not type check.
///
/// Reaching GMU8003 needs a snapshot that is instrumented and generated
/// without complaint and then fails to build, and a type error is the
/// cheapest way there that never leaves the machine: a dependency on a
/// package that does not exist would have to be fetched to be found missing.
const uncompilable_source = "pub fn broken(value: Int) -> Int {
  value + \"one\"
}
"

@target(erlang)
/// A run with the budgets cut down to what a two-line module needs.
fn quick(root: String, files: List(String)) -> diff_runner.Request {
  diff_runner.Request(
    ..diff_runner.defaults(root, files),
    max_cases: 20,
    max_shrinks: 50,
    nondeterminism_checks: 1,
  )
}

@target(erlang)
/// Deletes whatever a finished run is holding, so an assertion below it can
/// fail without leaving a build tree behind.
fn discard_run(
  outcome: Result(diff_runner.RunOutput, diff_runner.RunError),
) -> Nil {
  case outcome {
    Ok(output) -> discard(output.snapshot_root)
    Error(error) -> {
      let _ = discard_snapshot(error.snapshot_root)
      Nil
    }
  }
}

@target(erlang)
/// One real run of a nested module asked for twice, which is the evidence for
/// three things at once: a repeated path is probed once rather than twice,
/// `src/app/util.gleam` is the module `app/util`, and a private function is
/// skipped under that module's name.
pub fn run_probes_a_repeated_nested_source_once_test() {
  let root = workspace(stdlib_toml, [#("src/app/util.gleam", nested_source)])
  let outcome =
    diff_runner.run(
      quick(root, [
        "src/app/util.gleam",
        "src/app/util.gleam",
      ]),
    )
  discard(root)
  discard_run(outcome)

  let assert Ok(output) = outcome
  let reported = list.map(output.results, fn(probe) { probe.mutant })
  assert reported != []
  assert list.unique(reported) == reported
  assert output.unassigned_mutants == 0
  assert list.any(output.results, fn(probe) {
    probe.function == "add" && probe.status == probe_result.Distinguished
  })
  assert list.map(output.skipped, fn(entry) { #(entry.module, entry.function) })
    == [#("app/util", "bump")]
}

@target(erlang)
/// A run narrowed to one function reports that function and nothing else.
pub fn run_narrows_to_the_named_function_test() {
  let root = workspace(stdlib_toml, [#("src/pair.gleam", two_functions)])
  let request =
    diff_runner.Request(
      ..quick(root, ["src/pair.gleam"]),
      function_filter: Some("multiply"),
    )
  let outcome = diff_runner.run(request)
  discard(root)
  discard_run(outcome)

  let assert Ok(output) = outcome
  assert output.results != []
  assert list.unique(list.map(output.results, fn(probe) { probe.function }))
    == ["multiply"]
  assert output.skipped == []
}

@target(erlang)
/// A snapshot that does not compile is the one failure worth keeping: the
/// generated probe and the compiler output are in it, so the error names it
/// and hands it to the caller rather than deleting it.
pub fn run_hands_back_the_snapshot_that_did_not_compile_test() {
  let root =
    workspace(stdlib_toml, [#("src/broken.gleam", uncompilable_source)])
  let outcome = diff_runner.run(quick(root, ["src/broken.gleam"]))
  discard(root)

  let assert Error(error) = outcome
  let named = option.unwrap(error.snapshot_root, "")
  let leftover = discard_snapshot(error.snapshot_root)
  assert error.code == "GMU8003"
  assert leftover
  assert string.ends_with(
    diff_runner.describe(error),
    "\nthe snapshot was left at " <> named,
  )
}

@target(erlang)
/// A module whose first function records on disk that it was called.
///
/// `file:write_file/2` is reached directly rather than through simplifile, so
/// the throwaway workspace needs no dependency beyond the one a generated
/// probe already imports. `add` is there to give the run something to do once
/// `shout` has been taken away from it.
fn shouting_source(witness: String) -> String {
  "@external(erlang, \"file\", \"write_file\")
fn write_file(path: String, data: String) -> Nil

pub fn shout(value: Int) -> Int {
  let _ = write_file(\"" <> witness <> "\", \"called\")
  value + 1
}

pub fn add(a: Int, b: Int) -> Int {
  a + b
}
"
}

@target(erlang)
/// A file nothing has written yet, beside the throwaway workspaces.
fn witness_path() -> String {
  path.join(
    platform.temporary_directory(),
    "gleam-mutants-probe-called-" <> platform.random_nonce(),
  )
  |> string.replace("\\", "/")
}

@target(erlang)
/// The probe really does call the functions it is given, which is what makes
/// the silence of the excluded run below evidence rather than an empty
/// reading.
pub fn run_calls_a_function_no_exclusion_names_test() {
  let witness = witness_path()
  let root =
    workspace(stdlib_toml, [#("src/shout.gleam", shouting_source(witness))])
  let outcome = diff_runner.run(quick(root, ["src/shout.gleam"]))
  let called = simplifile.is_file(witness) == Ok(True)
  discard(root)
  discard_run(outcome)
  let _ = simplifile.delete(witness)

  let assert Ok(output) = outcome
  assert called
  assert list.any(output.results, fn(probe) { probe.function == "shout" })
  assert output.skipped == []
}

@target(erlang)
/// An excluded function is never compiled into the probe, never called and
/// never timed — and its mutants still reach the caller.
///
/// The point of excluding a function is that calling it is unsafe or slow, so
/// a run that calls it anyway and only relabels the verdict afterwards buys
/// the reader nothing. The witness file is the proof: it exists only if the
/// probe called `shout`.
pub fn run_never_calls_a_function_the_request_excludes_test() {
  let witness = witness_path()
  let root =
    workspace(stdlib_toml, [#("src/shout.gleam", shouting_source(witness))])
  let outcome =
    diff_runner.run(
      diff_runner.Request(
        ..quick(root, ["src/shout.gleam"]),
        exclude_functions: [
          "shout",
        ],
      ),
    )
  let called = simplifile.is_file(witness) == Ok(True)
  discard(root)
  discard_run(outcome)
  let _ = simplifile.delete(witness)

  let assert Ok(output) = outcome
  assert called == False
  assert list.map(output.skipped, fn(entry) { #(entry.function, entry.reason) })
    == [#("shout", diff_runner.excluded_reason)]
  let left_alone =
    list.filter(output.results, fn(probe) { probe.function == "shout" })
  assert left_alone != []
  assert list.all(left_alone, fn(probe) {
    probe.status == probe_result.Unsupported
    && probe.reason == diff_runner.excluded_reason
  })
  assert list.any(output.results, fn(probe) {
    probe.function == "add" && probe.status == probe_result.Distinguished
  })
}

@target(erlang)
/// A module with nothing left to probe is never compiled at all.
///
/// `snapshot.create` leaves `build` behind when it copies, so a `build`
/// directory inside the snapshot exists only if the runner compiled there.
/// That is the other half of what excluding a function buys: a workspace whose
/// probeable functions are all excluded costs a copy and nothing else, and its
/// mutants still come back.
pub fn run_excluding_every_function_compiles_nothing_test() {
  let witness = witness_path()
  let root =
    workspace(stdlib_toml, [#("src/shout.gleam", shouting_source(witness))])
  let outcome =
    diff_runner.run(
      diff_runner.Request(
        ..quick(root, ["src/shout.gleam"]),
        exclude_functions: [
          "shout",
          "add",
        ],
      ),
    )
  let called = simplifile.is_file(witness) == Ok(True)
  let compiled = case outcome {
    Ok(output) ->
      simplifile.is_directory(path.join(output.snapshot_root, "build"))
      == Ok(True)
    Error(_) -> False
  }
  discard(root)
  discard_run(outcome)
  let _ = simplifile.delete(witness)

  let assert Ok(output) = outcome
  assert called == False
  assert compiled == False
  assert output.results != []
  assert list.all(output.results, fn(probe) {
    probe.status == probe_result.Unsupported
    && probe.reason == diff_runner.excluded_reason
  })
  assert list.map(output.skipped, fn(entry) { entry.function })
    == ["shout", "add"]
}
