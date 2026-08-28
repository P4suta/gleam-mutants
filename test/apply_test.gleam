// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// What `apply` does to a workspace's own test modules, settled on a throwaway
// copy of one rather than on anybody's project.
//
// `plan` answers what would change and `write` changes it, so the two halves
// are pinned apart: a plan is checked against a workspace that is never
// written to, and a write is checked against the bytes it leaves behind. The
// written files are pinned in full rather than described, because the whole
// promise of `apply` is that a reader can open the file afterwards and
// recognise it — the imports in the block they already had, the tests at the
// end, and `gleam format` having been over all of it.
//
// The write half runs `gleam format` in the workspace, so it is Erlang-only;
// planning touches nothing but the file system and runs on both targets.
//
// Attribution is the third half: what `--verify` makes of the two mutation
// runs either side of a write. It is pure over those two outcome maps, so it
// is settled here in microseconds rather than in the minutes a real
// verification costs.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
@target(erlang)
import gleam/result
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/suggest/apply
import gleam_mutants/suggest/probe_result
import gleam_mutants/suggest/render
import simplifile

// --- The suggestions these tests apply ---------------------------------------

/// The boundary case of `is_positive`, as a probe would have found it.
///
/// `expected` is real source, so its test asserts on the value itself.
fn boundary_suggestion() -> render.Suggestion {
  render.Suggestion(
    module_path: "boundary",
    function: "is_positive",
    mutant_id: string.repeat("a", 64),
    display_id: "8E1A6C7E61A90D7463C5",
    operator: "comparison-boundary",
    location: "src/boundary.gleam:17:3",
    original: "value > 0",
    replacement: "value >= 0",
    inputs: ["0"],
    support_modules: [],
    expected: Some("False"),
    expected_inspect: "False",
    expected_outcome: probe_result.Returned,
    actual_inspect: "True",
    actual_outcome: probe_result.Returned,
    kills: [string.repeat("a", 64)],
  )
}

/// A second mutant of the same module whose result has no source form, so its
/// test compares `string.inspect` and its file needs `gleam/string`.
fn abs_suggestion() -> render.Suggestion {
  render.Suggestion(
    module_path: "boundary",
    function: "abs",
    mutant_id: string.repeat("b", 64),
    display_id: "C0A27F78ED058C1CCCD8",
    operator: "comparison-boundary",
    location: "src/boundary.gleam:22:8",
    original: "value < 0",
    replacement: "value <= 0",
    inputs: ["0"],
    support_modules: [],
    expected: None,
    expected_inspect: "0",
    expected_outcome: probe_result.Returned,
    actual_inspect: "1",
    actual_outcome: probe_result.Returned,
    kills: [string.repeat("b", 64)],
  )
}

/// A mutant whose test names a constructor of `gleam/option`.
///
/// Its file needs `None` imported, which is what a module already importing
/// `gleam/option` for `Some` alone does not yet provide.
fn option_suggestion() -> render.Suggestion {
  render.Suggestion(
    module_path: "boundary",
    function: "maybe_double",
    mutant_id: string.repeat("d", 64),
    display_id: "6419CB7B462AB7ED9646",
    operator: "string-neutral",
    location: "src/boundary.gleam:40:19",
    original: "\"missing\"",
    replacement: "\"\"",
    inputs: ["None"],
    support_modules: [],
    expected: Some("Error(\"missing\")"),
    expected_inspect: "Error(\"missing\")",
    expected_outcome: probe_result.Returned,
    actual_inspect: "Error(\"\")",
    actual_outcome: probe_result.Returned,
    kills: [string.repeat("d", 64)],
  )
}

/// A mutant whose input is a value of the module under test's own type.
///
/// The probe prints such a value qualified by the module it belongs to, so the
/// source of this one test names `boundary` twice: once as the callee and once
/// inside the argument. A file that reaches the module under another name has
/// to rename both.
fn shape_suggestion() -> render.Suggestion {
  render.Suggestion(
    module_path: "boundary",
    function: "area",
    mutant_id: string.repeat("e", 64),
    display_id: "5A7B9C0D1E2F30415263",
    operator: "arithmetic-operator",
    location: "src/boundary.gleam:30:5",
    original: "3 * radius * radius",
    replacement: "3 / radius * radius",
    inputs: ["boundary.Circle(-2)"],
    support_modules: [],
    expected: Some("12"),
    expected_inspect: "12",
    expected_outcome: probe_result.Returned,
    actual_inspect: "0",
    actual_outcome: probe_result.Returned,
    kills: [string.repeat("e", 64)],
  )
}

/// The same call in a module named after one of the generated file's imports.
///
/// `gleam/option` takes the name `option`, so a module under test called
/// `option` is imported under another one — and its constructors have to
/// travel with it.
fn shadowing_shape_suggestion() -> render.Suggestion {
  render.Suggestion(
    ..shape_suggestion(),
    module_path: "option",
    location: "src/option.gleam:30:5",
    inputs: ["option.Circle(2)"],
  )
}

/// A mutant whose test hands the module under test a `Some`.
///
/// Its file needs `Some` bound to the constructor of `gleam/option`, which a
/// file that imports that constructor under another name does not bind.
fn some_suggestion() -> render.Suggestion {
  render.Suggestion(
    ..option_suggestion(),
    display_id: "7C1D2E3F40516273849A",
    inputs: ["Some(1)"],
    expected: Some("Ok(2)"),
    expected_inspect: "Ok(2)",
    actual_inspect: "Ok(1)",
  )
}

/// The boundary case again, in a module whose own name is `string`.
///
/// Its test asserts on a value with a source form, so nothing in its file
/// needs `gleam/string` and the module keeps the name its path gives it.
fn string_named_suggestion() -> render.Suggestion {
  render.Suggestion(
    ..boundary_suggestion(),
    module_path: "app/string",
    location: "src/app/string.gleam:17:3",
  )
}

/// The same module, in a file that also falls back to `string.inspect`.
///
/// `gleam/string` takes the name `string` here, so the module under test
/// cannot keep it.
fn inspecting_string_named_suggestion() -> render.Suggestion {
  render.Suggestion(
    ..abs_suggestion(),
    module_path: "app/string",
    location: "src/app/string.gleam:22:8",
  )
}

/// A mutant of a module called `option` whose test names an option
/// constructor.
///
/// The file has to import `gleam/option` for `None`, so the module under test
/// is the one that gives up the name.
fn shadowing_option_suggestion() -> render.Suggestion {
  render.Suggestion(
    ..option_suggestion(),
    module_path: "option",
    location: "src/option.gleam:40:19",
  )
}

/// A mutant of a nested module, whose test module flattens the path.
fn nested_suggestion() -> render.Suggestion {
  render.Suggestion(
    module_path: "app/util",
    function: "join",
    mutant_id: string.repeat("c", 64),
    display_id: "11223344AABBCCDDEEFF",
    operator: "arithmetic-operator",
    location: "src/app/util.gleam:9:5",
    original: "a + b",
    replacement: "a - b",
    inputs: ["1", "2"],
    support_modules: [],
    expected: Some("3"),
    expected_inspect: "3",
    expected_outcome: probe_result.Returned,
    actual_inspect: "-1",
    actual_outcome: probe_result.Returned,
    kills: [string.repeat("c", 64)],
  )
}

// --- The generated tests, as they are written out ----------------------------

/// The test the boundary mutant is killed by, exactly as `render` writes it.
const boundary_test = "/// Generated by gleam_mutants: kills mutant 8E1A6C7E (comparison-boundary at src/boundary.gleam:17:3, `value > 0` -> `value >= 0`).
pub fn is_positive_kills_8e1a6c7e_test() {
  assert boundary.is_positive(0) == False
}
"

@target(erlang)
/// The same test, qualified with the alias the file already imports under.
const aliased_boundary_test = "/// Generated by gleam_mutants: kills mutant 8E1A6C7E (comparison-boundary at src/boundary.gleam:17:3, `value > 0` -> `value >= 0`).
pub fn is_positive_kills_8e1a6c7e_test() {
  assert b.is_positive(0) == False
}
"

@target(erlang)
/// The test whose expectation has no source form, so it inspects instead.
const abs_test = "/// Generated by gleam_mutants: kills mutant C0A27F78 (comparison-boundary at src/boundary.gleam:22:8, `value < 0` -> `value <= 0`).
pub fn abs_kills_c0a27f78_test() {
  assert string.inspect(boundary.abs(0)) == \"0\"
}
"

@target(erlang)
/// The shape test as a file that imports the module under test as `b` holds
/// it: the alias in front of the call and inside the argument alike.
const aliased_shape_test = "/// Generated by gleam_mutants: kills mutant 5A7B9C0D (arithmetic-operator at src/boundary.gleam:30:5, `3 * radius * radius` -> `3 / radius * radius`).
pub fn area_kills_5a7b9c0d_test() {
  assert b.area(b.Circle(-2)) == 12
}
"

@target(erlang)
/// The test of a module whose own name the generated file needs for an import.
const shadowing_option_test = "/// Generated by gleam_mutants: kills mutant 6419CB7B (string-neutral at src/option.gleam:40:19, `\"missing\"` -> `\"\"`).
pub fn maybe_double_kills_6419cb7b_test() {
  assert option_under_test.maybe_double(None) == Error(\"missing\")
}
"

@target(erlang)
/// The `Some` test, in a file that binds `Some` to a name of its own.
const some_test = "/// Generated by gleam_mutants: kills mutant 7C1D2E3F (string-neutral at src/boundary.gleam:40:19, `\"missing\"` -> `\"\"`).
pub fn maybe_double_kills_7c1d2e3f_test() {
  assert boundary.maybe_double(Some(1)) == Ok(2)
}
"

@target(erlang)
/// The boundary test stated the way `gleeunit/should` states it, through the
/// name the file gives that module.
const aliased_should_test = "/// Generated by gleam_mutants: kills mutant 8E1A6C7E (comparison-boundary at src/boundary.gleam:17:3, `value > 0` -> `value >= 0`).
pub fn is_positive_kills_8e1a6c7e_test() {
  boundary.is_positive(0) |> expect.equal(False)
}
"

@target(erlang)
/// The inspect fallback written through the name the file gives `gleam/string`.
const aliased_inspect_test = "/// Generated by gleam_mutants: kills mutant C0A27F78 (comparison-boundary at src/boundary.gleam:22:8, `value < 0` -> `value <= 0`).
pub fn abs_kills_c0a27f78_test() {
  assert str.inspect(boundary.abs(0)) == \"0\"
}
"

@target(erlang)
/// The boundary test of a module called `string` that keeps its own name.
const string_named_test = "/// Generated by gleam_mutants: kills mutant 8E1A6C7E (comparison-boundary at src/app/string.gleam:17:3, `value > 0` -> `value >= 0`).
pub fn is_positive_kills_8e1a6c7e_test() {
  assert string.is_positive(0) == False
}
"

@target(erlang)
/// The shape test of a module called `option` that keeps its own name.
const plain_shadowing_shape_test = "/// Generated by gleam_mutants: kills mutant 5A7B9C0D (arithmetic-operator at src/option.gleam:30:5, `3 * radius * radius` -> `3 / radius * radius`).
pub fn area_kills_5a7b9c0d_test() {
  assert option.area(option.Circle(2)) == 12
}
"

@target(erlang)
/// The `Some` test in a file that binds `Some` to something of its own, so the
/// constructor travels through its module rather than through a name.
const qualified_some_test = "/// Generated by gleam_mutants: kills mutant 7C1D2E3F (string-neutral at src/boundary.gleam:40:19, `\"missing\"` -> `\"\"`).
pub fn maybe_double_kills_7c1d2e3f_test() {
  assert boundary.maybe_double(option.Some(1)) == Ok(2)
}
"

@target(erlang)
/// The `None` test of the same file, qualified for the same reason.
const qualified_none_test = "/// Generated by gleam_mutants: kills mutant 6419CB7B (string-neutral at src/boundary.gleam:40:19, `\"missing\"` -> `\"\"`).
pub fn maybe_double_kills_6419cb7b_test() {
  assert boundary.maybe_double(option.None) == Error(\"missing\")
}
"

/// The header every hand-written module in these fixtures carries.
const header = "// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0
"

// --- Where a verified kill came from -----------------------------------------

/// `--verify` has to say which of the two runs around the write did the
/// killing.
///
/// Verification re-runs the whole suite, so a mutant the reader's own tests
/// were already killing comes back dead whether or not the generated test
/// that claims it kills anything at all. Attribution is what separates them,
/// and it is settled from the two outcome maps alone — no engine, no
/// workspace, no clock — so every case is pinned here rather than inferred
/// from a run that takes minutes.
pub fn attribution_tells_a_new_kill_from_an_old_one_test() {
  let before =
    dict.from_list([
      #("survived-then-killed", False),
      #("killed-all-along", True),
      #("killed-then-broken", True),
      #("survived-throughout", False),
    ])
  let after =
    dict.from_list([
      #("survived-then-killed", True),
      #("killed-all-along", True),
      #("killed-then-broken", False),
      #("survived-throughout", False),
      #("unseen-before", True),
    ])

  assert apply.attribute(
      [
        "survived-then-killed", "killed-all-along", "killed-then-broken",
        "survived-throughout", "unseen-before", "unseen-by-either",
      ],
      before,
      after,
    )
    == [
      // The generated test did this one, and nothing else had.
      #("survived-then-killed", apply.NewlyKilled),
      // Dead before anybody generated anything: the test added nothing.
      #("killed-all-along", apply.AlreadyKilled),
      // Dead before and alive now — a regression is still a failure.
      #("killed-then-broken", apply.StillSurviving),
      #("survived-throughout", apply.StillSurviving),
      // A mutant the first run never discovered was not dead: it was unseen,
      // which is the same standing as alive.
      #("unseen-before", apply.NewlyKilled),
      // A mutant neither run discovered cannot be called dead.
      #("unseen-by-either", apply.StillSurviving),
    ]
}

/// The names Apply JSON v1 carries for the three attributions.
///
/// A consumer reads these strings and nothing else, so they are part of the
/// schema rather than of the prose.
pub fn every_attribution_carries_the_name_the_json_uses_test() {
  assert apply.attribution_name(apply.NewlyKilled) == "new"
  assert apply.attribution_name(apply.AlreadyKilled) == "already_killed"
  assert apply.attribution_name(apply.StillSurviving) == "surviving"
}

// --- Planning ----------------------------------------------------------------

/// A module with no test file of its own is planned as one to create.
pub fn plan_creates_a_test_module_that_does_not_exist_test() {
  let root = workspace([])
  let planned = apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/boundary_test.gleam",
        create: True,
        imports_added: ["import boundary"],
        tests_added: ["is_positive_kills_8e1a6c7e_test"],
        tests_skipped: [],
      ),
    ])
}

/// One plan per module under test, named after the module and sorted by file.
///
/// `app/util` is tested by `test/app_util_test.gleam`: a test module lives in
/// one flat directory, so the separators of a nested module path become
/// underscores rather than directories nobody asked for.
pub fn plan_names_one_flat_test_module_per_module_under_test_test() {
  let root = workspace([])
  let planned =
    apply.plan(
      root,
      [boundary_suggestion(), nested_suggestion()],
      render.AssertKeyword,
    )
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/app_util_test.gleam",
        create: True,
        imports_added: ["import app/util"],
        tests_added: ["join_kills_11223344_test"],
        tests_skipped: [],
      ),
      apply.Plan(
        file: "test/boundary_test.gleam",
        create: True,
        imports_added: ["import boundary"],
        tests_added: ["is_positive_kills_8e1a6c7e_test"],
        tests_skipped: [],
      ),
    ])
}

/// A test the file already defines is skipped, and only the missing imports
/// are named.
///
/// `apply` run twice must not write the same test twice, and the module import
/// the file already carries must not be added beside itself.
pub fn plan_skips_a_test_the_module_already_defines_test() {
  let root = workspace([#("test/boundary_test.gleam", existing_module())])
  let planned =
    apply.plan(
      root,
      [boundary_suggestion(), abs_suggestion()],
      render.AssertKeyword,
    )
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/boundary_test.gleam",
        create: False,
        imports_added: ["import gleam/string"],
        tests_added: ["abs_kills_c0a27f78_test"],
        tests_skipped: ["is_positive_kills_8e1a6c7e_test"],
      ),
    ])
}

/// A module already imported under an alias is left exactly as it is.
///
/// The file says how it wants to call the module under test, and a module it
/// already names cannot be imported a second time under another.
pub fn plan_keeps_the_alias_the_module_is_already_imported_under_test() {
  let root = workspace([#("test/boundary_test.gleam", aliased_module())])
  let planned = apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/boundary_test.gleam",
        create: False,
        imports_added: [],
        tests_added: ["is_positive_kills_8e1a6c7e_test"],
        tests_skipped: [],
      ),
    ])
}

/// A test module that is not Gleam is refused rather than overwritten.
///
/// Nothing can be said about which tests it already defines, and appending to
/// it would bury the reader's own broken file under generated code.
pub fn plan_refuses_a_test_module_it_cannot_parse_test() {
  let root =
    workspace([#("test/boundary_test.gleam", "pub fn broken( {\n  Nil\n")])
  let planned = apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
  discard(root)

  let assert Error(message) = planned
  assert string.starts_with(message, "GMU8013:")
  assert string.contains(message, "test/boundary_test.gleam")
}

/// An import the generated tests outgrow is grown, not written out twice.
///
/// Gleam refuses a second name for a module it already names, so a file that
/// imports `gleam/option` for `Some` alone has to gain `None` on the line it
/// has.
pub fn plan_grows_an_import_the_generated_tests_outgrow_test() {
  let root = workspace([#("test/boundary_test.gleam", partial_option_module())])
  let planned = apply.plan(root, [option_suggestion()], render.AssertKeyword)
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/boundary_test.gleam",
        create: False,
        imports_added: ["import gleam/option.{None, Some}"],
        tests_added: ["maybe_double_kills_6419cb7b_test"],
        tests_skipped: [],
      ),
    ])
}

/// A module imported as `_` gains the qualified import its tests need.
///
/// `import boundary.{is_positive} as _` binds the names it lists and no name
/// for the module itself, which is a line Gleam is happy to hold beside a
/// plain `import boundary`. The reader's own import is left exactly as they
/// wrote it and the generated tests reach the module through the new one.
pub fn plan_imports_a_module_the_file_gave_no_name_test() {
  let root = workspace([#("test/boundary_test.gleam", discarded_module())])
  let planned = apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/boundary_test.gleam",
        create: False,
        imports_added: ["import boundary"],
        tests_added: ["is_positive_kills_8e1a6c7e_test"],
        tests_skipped: [],
      ),
    ])
}

/// A file that already binds the name a generated test needs is refused.
///
/// `gleam/option` has to be imported as `option` for the constructors these
/// tests name, and a file that already imports the module under test under
/// that name leaves them nowhere to stand. Refusing says so before anything is
/// written — and says which import wants the name and how to give it up.
pub fn plan_refuses_a_module_named_after_an_import_it_needs_test() {
  let root = workspace([#("test/option_test.gleam", option_named_module())])
  let planned =
    apply.plan(root, [shadowing_option_suggestion()], render.AssertKeyword)
  discard(root)

  let assert Error(message) = planned
  assert string.starts_with(message, "GMU8014:")
  assert string.contains(message, "test/option_test.gleam")
  assert string.contains(message, "gleam/option")
  assert string.contains(message, "alias")
}

/// A module named after an import the generated tests never need keeps its
/// name.
///
/// Nothing in these tests mentions `Some` or `None`, so no `gleam/option` is
/// written and the name `option` is the module under test's to keep. Refusing
/// here would leave a reader with a file they cannot apply to and no edit that
/// would help.
pub fn plan_keeps_a_module_named_after_an_import_no_test_needs_test() {
  let root = workspace([#("test/option_test.gleam", option_named_module())])
  let planned =
    apply.plan(root, [shadowing_shape_suggestion()], render.AssertKeyword)
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/option_test.gleam",
        create: False,
        imports_added: [],
        tests_added: ["area_kills_5a7b9c0d_test"],
        tests_skipped: [],
      ),
    ])
}

/// A module whose own name a generated file needs is refused by name.
///
/// The reader's file imports `app/string` as `string`, which is the name the
/// inspect fallback needs for `gleam/string`. The message has to name both
/// modules and the edit that resolves them, or it reads as a refusal of a
/// module the file plainly can call.
pub fn plan_refuses_a_module_whose_name_an_import_needs_test() {
  let root = workspace([#("test/app_string_test.gleam", string_named_module())])
  let planned =
    apply.plan(
      root,
      [string_named_suggestion(), inspecting_string_named_suggestion()],
      render.AssertKeyword,
    )
  discard(root)

  let assert Error(message) = planned
  assert string.starts_with(message, "GMU8014:")
  assert string.contains(message, "test/app_string_test.gleam")
  assert string.contains(message, "app/string")
  assert string.contains(message, "gleam/string")
  assert string.contains(message, "alias")
}

/// The same module, with nothing in the file that wants its name.
///
/// `app/string` is only unreachable when a generated test really writes
/// `gleam/string` beside it; on its own it is imported and called as `string`
/// like any other module.
pub fn plan_keeps_a_module_whose_name_no_import_needs_test() {
  let root = workspace([#("test/app_string_test.gleam", string_named_module())])
  let planned =
    apply.plan(root, [string_named_suggestion()], render.AssertKeyword)
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/app_string_test.gleam",
        create: False,
        imports_added: [],
        tests_added: ["is_positive_kills_8e1a6c7e_test"],
        tests_skipped: [],
      ),
    ])
}

/// A name another import already answers to is refused, whoever wants it.
///
/// The file reaches some other module as `boundary`, so the import the
/// generated tests need cannot be added: Gleam binds one name to one module.
/// The message names the import the reader can edit.
pub fn plan_refuses_a_name_another_import_answers_to_test() {
  let root = workspace([#("test/boundary_test.gleam", occupied_module())])
  let planned = apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
  discard(root)

  let assert Error(message) = planned
  assert string.starts_with(message, "GMU8014:")
  assert string.contains(message, "app/thing")
  assert string.contains(message, "alias")
}

/// A constructor the file binds from elsewhere is stepped around, not taken.
///
/// `import app/thing.{Some}` binds `Some`, and a second unqualified `Some`
/// would be a name defined twice — which `gleam format` accepts and the
/// compiler does not. The generated tests reach the constructor through its
/// own module instead, which needs no name of the reader's at all.
pub fn plan_qualifies_a_constructor_the_file_binds_elsewhere_test() {
  let root = workspace([#("test/boundary_test.gleam", borrowed_name_module())])
  let planned = apply.plan(root, [some_suggestion()], render.AssertKeyword)
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/boundary_test.gleam",
        create: False,
        imports_added: ["import gleam/option"],
        tests_added: ["maybe_double_kills_7c1d2e3f_test"],
        tests_skipped: [],
      ),
    ])
}

/// A constructor the file declares itself is stepped around the same way.
///
/// A test module holding `pub type Maybe { Some(Int) None }` binds both names
/// to constructors of its own. Nothing in its imports says so, so a tool that
/// only reads imports writes `import gleam/option.{None, Some}` into a file
/// that then does not type-check — and `gleam format` reports nothing.
pub fn plan_qualifies_a_constructor_the_module_defines_itself_test() {
  let root =
    workspace([#("test/boundary_test.gleam", own_constructors_module())])
  let planned =
    apply.plan(
      root,
      [some_suggestion(), option_suggestion()],
      render.AssertKeyword,
    )
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/boundary_test.gleam",
        create: False,
        imports_added: ["import gleam/option"],
        tests_added: [
          "maybe_double_kills_7c1d2e3f_test",
          "maybe_double_kills_6419cb7b_test",
        ],
        tests_skipped: [],
      ),
    ])
}

/// A name the file binds to something else is not a name the tests can use.
///
/// `import gleam/option.{Some as Just}` binds `Just`, not `Some`, so a
/// generated test that writes `Some(1)` needs the constructor imported under
/// its own name as well — which is a line Gleam accepts and the compiler
/// needs.
pub fn plan_grows_an_import_that_binds_a_name_elsewhere_test() {
  let root = workspace([#("test/boundary_test.gleam", renamed_option_module())])
  let planned = apply.plan(root, [some_suggestion()], render.AssertKeyword)
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/boundary_test.gleam",
        create: False,
        imports_added: ["import gleam/option.{Some as Just, Some}"],
        tests_added: ["maybe_double_kills_7c1d2e3f_test"],
        tests_skipped: [],
      ),
    ])
}

/// A support module the file already imports under a name is called by it.
///
/// A second name for `gleeunit/should` would not compile, so the generated
/// assertion has to be stated through the name the file bound it under.
pub fn plan_calls_a_support_module_by_the_name_the_file_binds_test() {
  let root = workspace([#("test/boundary_test.gleam", renamed_should_module())])
  let planned = apply.plan(root, [boundary_suggestion()], render.ShouldEqual)
  discard(root)

  assert planned
    == Ok([
      apply.Plan(
        file: "test/boundary_test.gleam",
        create: False,
        imports_added: [],
        tests_added: ["is_positive_kills_8e1a6c7e_test"],
        tests_skipped: [],
      ),
    ])
}

// --- Writing -----------------------------------------------------------------

@target(erlang)
/// A created module holds the imports, the tests, and no `main` of its own.
///
/// The project already has a test module with a `main` in it; a second one
/// would give `gleeunit` two entry points to argue over.
pub fn write_creates_the_module_a_plan_asked_for_test() {
  let root = workspace([])
  let plans =
    apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
    |> unwrap_plans
  let written =
    apply.write(root, plans, [boundary_suggestion()], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents == "import boundary\n\n" <> boundary_test
}

@target(erlang)
/// Imports land in the block the module already has, and tests at the end.
///
/// The test the module already defines is not written a second time, and the
/// file comes back in the order `gleam format` puts it in.
pub fn write_inserts_imports_into_the_existing_block_test() {
  let root = workspace([#("test/boundary_test.gleam", existing_module())])
  let suggestions = [boundary_suggestion(), abs_suggestion()]
  let plans =
    apply.plan(root, suggestions, render.AssertKeyword) |> unwrap_plans
  let written = apply.write(root, plans, suggestions, render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents
    == header
    <> "\nimport boundary\nimport gleam/string\nimport gleeunit\n"
    <> "\npub fn main() {\n  gleeunit.main()\n}\n"
    <> "\n"
    <> boundary_test
    <> "\n"
    <> abs_test
}

@target(erlang)
/// A module imported under an alias is called through that alias.
pub fn write_qualifies_its_calls_with_the_existing_alias_test() {
  let root = workspace([#("test/boundary_test.gleam", aliased_module())])
  let plans =
    apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
    |> unwrap_plans
  let written =
    apply.write(root, plans, [boundary_suggestion()], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents
    == header
    <> "\nimport boundary as b\nimport gleeunit\n"
    <> "\npub fn main() {\n  gleeunit.main()\n}\n"
    <> "\n"
    <> aliased_boundary_test
}

@target(erlang)
/// The alias reaches the values a generated call is given, not just the call.
///
/// A test that reads `b.area(boundary.Circle(-2))` names a module the file
/// never imported, and `apply` would have left the reader's suite refusing to
/// compile.
pub fn write_qualifies_the_values_it_passes_with_the_alias_too_test() {
  let root = workspace([#("test/boundary_test.gleam", aliased_module())])
  let plans =
    apply.plan(root, [shape_suggestion()], render.AssertKeyword) |> unwrap_plans
  let written =
    apply.write(root, plans, [shape_suggestion()], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents
    == header
    <> "\nimport boundary as b\nimport gleeunit\n"
    <> "\npub fn main() {\n  gleeunit.main()\n}\n"
    <> "\n"
    <> aliased_shape_test
  assert !string.contains(contents, "boundary.Circle")
}

@target(erlang)
/// A module named after one of the generated file's own imports is named one
/// way throughout.
///
/// This file writes `None`, so `gleam/option` binds `option` and the module
/// under test is imported as `option_under_test` — in front of the call and,
/// were its own type in the arguments, inside them too.
pub fn write_names_a_shadowing_module_one_way_test() {
  let root = workspace([])
  let suggestions = [shadowing_option_suggestion()]
  let plans =
    apply.plan(root, suggestions, render.AssertKeyword) |> unwrap_plans
  let written = apply.write(root, plans, suggestions, render.AssertKeyword)
  let contents = read(root, "test/option_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents
    == "import gleam/option.{None}\nimport option as option_under_test\n\n"
    <> shadowing_option_test
}

@target(erlang)
/// The same module, in a file with no import that wants its name.
///
/// Nothing here writes `Some` or `None`, so `gleam/option` is never imported
/// and the module under test is imported and called as `option`. An alias
/// nothing asked for would only be a name the reader has to learn.
pub fn write_keeps_a_module_no_import_shadows_test() {
  let root = workspace([])
  let suggestions = [shadowing_shape_suggestion()]
  let plans =
    apply.plan(root, suggestions, render.AssertKeyword) |> unwrap_plans
  let written = apply.write(root, plans, suggestions, render.AssertKeyword)
  let contents = read(root, "test/option_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents == "import option\n\n" <> plain_shadowing_shape_test
  assert !string.contains(contents, "option_under_test")
}

@target(erlang)
/// A constructor the file binds to another name is imported beside it.
///
/// `import gleam/option.{Some as Just}` leaves `Some` unbound, and a generated
/// test that writes `Some(1)` needs it: the line grows rather than the file
/// gaining source that names something it never imported.
pub fn write_grows_an_import_that_binds_a_name_elsewhere_test() {
  let root = workspace([#("test/boundary_test.gleam", renamed_option_module())])
  let plans =
    apply.plan(root, [some_suggestion()], render.AssertKeyword) |> unwrap_plans
  let written =
    apply.write(root, plans, [some_suggestion()], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents
    == header
    <> "\nimport boundary\nimport gleam/option.{Some as Just, Some}\nimport gleeunit\n"
    <> "\npub fn main() {\n  gleeunit.main()\n}\n"
    <> "\npub fn holds_test() {\n  assert Just(1) != Just(2)\n}\n"
    <> "\n"
    <> some_test
}

@target(erlang)
/// `gleeunit/should` is called by the name the file already gave it.
pub fn write_states_should_through_the_name_the_file_binds_test() {
  let root = workspace([#("test/boundary_test.gleam", renamed_should_module())])
  let plans =
    apply.plan(root, [boundary_suggestion()], render.ShouldEqual)
    |> unwrap_plans
  let written =
    apply.write(root, plans, [boundary_suggestion()], render.ShouldEqual)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents
    == header
    <> "\nimport boundary\nimport gleeunit\nimport gleeunit/should as expect\n"
    <> "\npub fn main() {\n  gleeunit.main()\n}\n"
    <> "\n"
    <> aliased_should_test
  assert !string.contains(contents, "should.equal")
}

@target(erlang)
/// So is `gleam/string`, when a test falls back to inspecting.
pub fn write_inspects_through_the_name_the_file_binds_test() {
  let root = workspace([#("test/boundary_test.gleam", renamed_string_module())])
  let plans =
    apply.plan(root, [abs_suggestion()], render.AssertKeyword) |> unwrap_plans
  let written =
    apply.write(root, plans, [abs_suggestion()], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents
    == header
    <> "\nimport boundary\nimport gleam/string as str\nimport gleeunit\n"
    <> "\npub fn main() {\n  gleeunit.main()\n}\n"
    <> "\n"
    <> aliased_inspect_test
}

@target(erlang)
/// A module called `string` that nothing shadows keeps its own name.
pub fn write_keeps_a_module_whose_name_no_import_needs_test() {
  let root = workspace([#("test/app_string_test.gleam", string_named_module())])
  let suggestions = [string_named_suggestion()]
  let plans =
    apply.plan(root, suggestions, render.AssertKeyword) |> unwrap_plans
  let written = apply.write(root, plans, suggestions, render.AssertKeyword)
  let contents = read(root, "test/app_string_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents
    == header
    <> "\nimport app/string\nimport gleeunit\n"
    <> "\npub fn main() {\n  gleeunit.main()\n}\n"
    <> "\n"
    <> string_named_test
}

@target(erlang)
/// A created module carries the licence header the module under test carries.
///
/// A project that lints its own copyright — this one does — would report a
/// generated file with none as a violation the reader never made.
pub fn write_carries_the_licence_of_the_module_under_test_test() {
  let root =
    workspace([
      #(
        "src/boundary.gleam",
        header
          <> "\n// A module with prose in its header as well.\n"
          <> "\npub fn is_positive(value: Int) -> Bool {\n  value > 0\n}\n",
      ),
    ])
  let plans =
    apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
    |> unwrap_plans
  let _ =
    apply.write(root, plans, [boundary_suggestion()], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  // The tags, and only the tags: the prose above belongs to that module.
  assert contents == header <> "\nimport boundary\n\n" <> boundary_test
}

@target(erlang)
/// A module with no imports at all takes them under its header comment.
///
/// The header is the reader's, licence lines included, and generated code
/// belongs after it rather than in front of it.
pub fn write_puts_the_first_import_under_the_header_test() {
  let root = workspace([#("test/boundary_test.gleam", importless_module())])
  let plans =
    apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
    |> unwrap_plans
  let _ =
    apply.write(root, plans, [boundary_suggestion()], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert contents
    == header
    <> "\nimport boundary\n"
    <> "\npub fn placeholder_test() {\n  Nil\n}\n"
    <> "\n"
    <> boundary_test
}

@target(erlang)
/// `gleam format` is run over the file that was written, whatever state the
/// reader left it in.
///
/// The seeded module is valid Gleam written on one line; nothing but the
/// formatter could have expanded it, so a formatted file is the evidence that
/// the formatter ran.
pub fn write_formats_the_file_it_wrote_test() {
  let root = workspace([#("test/boundary_test.gleam", unformatted_module())])
  let plans =
    apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
    |> unwrap_plans
  let _ =
    apply.write(root, plans, [boundary_suggestion()], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert contents
    == "import boundary\nimport gleeunit\n"
    <> "\npub fn main() {\n  gleeunit.main()\n}\n"
    <> "\n"
    <> boundary_test
}

@target(erlang)
/// A file the formatter refuses is reported, and left where the reader can
/// read it.
///
/// The probe renders the values it observed, and nothing downstream parses
/// them: source that does not compile has to be reported rather than quietly
/// called applied.
pub fn write_reports_a_file_the_formatter_refuses_test() {
  let root = workspace([])
  let broken =
    render.Suggestion(..boundary_suggestion(), expected: Some("Circle("))
  let plans = apply.plan(root, [broken], render.AssertKeyword) |> unwrap_plans
  let written = apply.write(root, plans, [broken], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  let assert Error(message) = written
  assert string.starts_with(message, "GMU8016:")
  assert string.contains(message, "test/boundary_test.gleam")
  assert string.contains(contents, "Circle(")
}

@target(erlang)
/// A file that binds `Some` and `None` itself gets them through their module.
///
/// The reader's own `Maybe` is left alone, `gleam/option` arrives with no
/// constructors on it, and the generated tests name `option.Some` and
/// `option.None`. Written unqualified this file would format cleanly and then
/// refuse to type-check, which is the failure this pins.
pub fn write_qualifies_the_constructors_the_module_defines_itself_test() {
  let root =
    workspace([#("test/boundary_test.gleam", own_constructors_module())])
  let suggestions = [some_suggestion(), option_suggestion()]
  let plans =
    apply.plan(root, suggestions, render.AssertKeyword) |> unwrap_plans
  let written = apply.write(root, plans, suggestions, render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents
    == header
    <> "\nimport boundary\nimport gleam/option\nimport gleeunit\n"
    <> "\npub type Maybe {\n  Some(Int)\n  None\n}\n"
    <> "\npub fn main() {\n  gleeunit.main()\n}\n"
    <> "\npub fn holds_test() {\n  assert Some(1) != None\n}\n"
    <> "\n"
    <> qualified_some_test
    <> "\n"
    <> qualified_none_test
  assert !string.contains(contents, "import gleam/option.{")
}

@target(erlang)
/// A module the file imported under no name gains one of its own.
///
/// The reader's `as _` line is theirs and is left where it was: it binds the
/// names it lists and nothing else, so a plain import beside it is what gives
/// the generated tests something to call.
pub fn write_imports_a_module_the_file_gave_no_name_test() {
  let root = workspace([#("test/boundary_test.gleam", discarded_module())])
  let plans =
    apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
    |> unwrap_plans
  let written =
    apply.write(root, plans, [boundary_suggestion()], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert written == Ok(plans)
  assert contents
    == header
    <> "\nimport boundary.{is_positive} as _\nimport boundary\nimport gleeunit\n"
    <> "\npub fn main() {\n  gleeunit.main()\n}\n"
    <> "\npub fn holds_test() {\n  assert is_positive(1)\n}\n"
    <> "\n"
    <> boundary_test
}

@target(erlang)
/// A header of two comment blocks is one header, blank line and all.
///
/// The licence block and the file comment under it are both the reader's, so
/// the first generated import belongs beneath the pair rather than wedged
/// between them.
pub fn write_puts_the_first_import_under_a_spaced_header_test() {
  let root = workspace([#("test/boundary_test.gleam", spaced_header_module())])
  let plans =
    apply.plan(root, [boundary_suggestion()], render.AssertKeyword)
    |> unwrap_plans
  let _ =
    apply.write(root, plans, [boundary_suggestion()], render.AssertKeyword)
  let contents = read(root, "test/boundary_test.gleam")
  discard(root)

  assert contents
    == header
    <> "\n// A module with a header and no imports at all.\n"
    <> "\nimport boundary\n"
    <> "\npub fn placeholder_test() {\n  Nil\n}\n"
    <> "\n"
    <> boundary_test
}

// --- The modules these tests seed --------------------------------------------

/// A test module with an import block, a `main`, and one generated test.
fn existing_module() -> String {
  header
  <> "\nimport boundary\nimport gleeunit\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
  <> "\n"
  <> boundary_test
}

/// A test module that imports the module under test under another name.
fn aliased_module() -> String {
  header
  <> "\nimport boundary as b\nimport gleeunit\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
}

/// A test module that imports `gleam/option` for one constructor of two.
fn partial_option_module() -> String {
  header
  <> "\nimport boundary\nimport gleam/option.{Some}\nimport gleeunit\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
}

/// A test module that binds a constructor of `gleam/option` to another name.
fn renamed_option_module() -> String {
  header
  <> "\nimport boundary\nimport gleam/option.{Some as Just}\nimport gleeunit\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
  <> "\npub fn holds_test() {\n  assert Just(1) != Just(2)\n}\n"
}

/// A test module that imports `gleeunit/should` under a name of its own.
fn renamed_should_module() -> String {
  header
  <> "\nimport boundary\nimport gleeunit\nimport gleeunit/should as expect\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
}

@target(erlang)
/// A test module that imports `gleam/string` under a name of its own.
fn renamed_string_module() -> String {
  header
  <> "\nimport boundary\nimport gleam/string as str\nimport gleeunit\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
}

/// A test module that imports a module under test called `app/string`.
fn string_named_module() -> String {
  header
  <> "\nimport app/string\nimport gleeunit\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
}

/// A test module that imports a module under test called `option` plainly.
fn option_named_module() -> String {
  header
  <> "\nimport gleeunit\nimport option\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
}

/// A test module that reaches another module by the name of the one under
/// test.
fn occupied_module() -> String {
  header
  <> "\nimport app/thing as boundary\nimport gleeunit\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
}

/// A test module that binds `Some` to a constructor of its own.
fn borrowed_name_module() -> String {
  header
  <> "\nimport app/thing.{Some}\nimport boundary\nimport gleeunit\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
  <> "\npub fn holds_test() {\n  assert Some(1) != Some(2)\n}\n"
}

/// A test module that imports the module under test without naming it.
fn discarded_module() -> String {
  header
  <> "\nimport boundary.{is_positive} as _\nimport gleeunit\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
  <> "\npub fn holds_test() {\n  assert is_positive(1)\n}\n"
}

/// A test module that declares constructors of its own called `Some` and
/// `None`.
fn own_constructors_module() -> String {
  header
  <> "\nimport boundary\nimport gleeunit\n"
  <> "\npub type Maybe {\n  Some(Int)\n  None\n}\n"
  <> "\npub fn main() {\n  gleeunit.main()\n}\n"
  <> "\npub fn holds_test() {\n  assert Some(1) != None\n}\n"
}

@target(erlang)
/// A test module whose header is two comment blocks with a blank line between.
fn spaced_header_module() -> String {
  header
  <> "\n// A module with a header and no imports at all.\n"
  <> "\npub fn placeholder_test() {\n  Nil\n}\n"
}

@target(erlang)
/// A test module with a header and no import at all.
fn importless_module() -> String {
  header <> "\npub fn placeholder_test() {\n  Nil\n}\n"
}

@target(erlang)
/// Valid Gleam nobody has run the formatter over.
fn unformatted_module() -> String {
  "import gleeunit\npub fn main() { gleeunit.main() }\n"
}

// --- A workspace of one's own ------------------------------------------------

/// A throwaway workspace holding a manifest and the given files.
fn workspace(files: List(#(String, String))) -> String {
  let root =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-apply-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(
      path.join(root, "gleam.toml"),
      "name = \"boundary_fixture\"\nversion = \"0.0.0\"\n",
    )
  list.each(files, fn(file) {
    let target = path.join(root, file.0)
    let assert Ok(Nil) = simplifile.create_directory_all(path.parent(target))
    let assert Ok(Nil) = simplifile.write(target, file.1)
  })
  root
}

/// Deletes a throwaway workspace, there or not, and says nothing about it.
fn discard(root: String) -> Nil {
  let _ = platform.delete_tree(root)
  Nil
}

@target(erlang)
/// The plans a planning step answered with, or none.
///
/// A planning step that failed is reported by the assertion below rather than
/// here: a panic in the middle of a write test would leave the throwaway
/// workspace on disk.
fn unwrap_plans(planned: Result(List(apply.Plan), String)) -> List(apply.Plan) {
  result.unwrap(planned, [])
}

@target(erlang)
/// What one file of the workspace holds now, or nothing when it holds nothing.
fn read(root: String, relative: String) -> String {
  simplifile.read(path.join(root, relative)) |> result.unwrap("")
}
