// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// End-to-end smoke for `apply`, driven the way a user drives it: through the
// built command line, on a throwaway copy of the boundary fixture, with
// nothing stubbed.
//
// `apply_test` pins what one plan and one write look like. This one pins the
// promise the whole command makes: that a dry run changes nothing, that
// `--yes` leaves a test module the project's own `gleam test` still passes on,
// that `--verify` then runs the mutation engine over the files it touched and
// reports the mutants those new tests now kill — and that it exits 1 when one
// of them does not.
//
// Several copies are used. The first is applied to and then deliberately
// spoiled, so the failing half of `--verify` is exercised on a real run rather
// than described. The others each hand `apply` a test module that binds a name
// the generated tests need: the module under test under an alias, an option
// constructor under another name, and `gleeunit/should` under another name.
// Every one of them ends with `gleam test`, because a file that binds a name
// the generated source does not use is a file that formats cleanly and does
// not compile. A copy is used rather than the fixture itself because the run
// writes into the workspace's `test/` directory. Run it with
//
//     gleam run -m apply_smoke --target erlang

import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/cache
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile

const fixture = "fixtures/boundary_project"

/// The test module the suggestions for `boundary` belong in.
const target = "test/boundary_test.gleam"

/// The prefix every test generated for `is_positive` is named with.
const boundary_test_prefix = "is_positive_kills_"

/// The assertion the boundary suggestion writes, and one that passes without
/// killing anything: `>` and `>=` answer alike on every input but `0`.
const generated_assertion = "boundary.is_positive(0) == False"

const toothless_assertion = "boundary.is_positive(1) == True"

pub fn main() {
  let root = copy_fixture(None)
  let before = read(root, target)

  let dry = run_cli(["apply", "--root", root])
  let after_dry = read(root, target)

  let boundary_id = boundary_mutant_id(root)

  let applied =
    run_cli(["apply", "--root", root, "--yes", "--verify", "--json"])
  let after = read(root, target)
  let tested = run_gleam_test(root)

  let again = run_cli(["apply", "--root", root, "--yes"])
  let after_again = read(root, target)

  let stored = run_cli(["report", "latest", "--root", root])

  let spoiled = spoil(root)
  let failed = run_cli(["apply", "--root", root, "--yes", "--verify", "--json"])

  let decoded = decode_output(extract_json(applied.stdout))
  let found =
    list.flatten([
      status_problems("apply (dry run)", dry),
      dry_run_problems(dry, before, after_dry),
      status_problems("apply --yes --verify --json", applied),
      case decoded {
        Error(reason) -> [reason]
        Ok(output) ->
          list.flatten([
            plan_problems(output),
            verification_problems(output, boundary_id),
          ])
      },
      written_problems(before, after),
      test_problems(tested),
      reapply_problems(again, after, after_again),
      history_problems(stored),
      spoiled,
      survivor_problems(failed, boundary_id),
    ])

  discard_workspace(root)

  let readers =
    list.flatten([
      aliased_problems(),
      renamed_option_problems(),
      renamed_should_problems(),
      own_constructors_problems(),
      discarded_problems(),
    ])

  list.each(list.append(found, readers), io.println)
  assert list.append(found, readers) == []
  io.println(
    "apply smoke: "
    <> target
    <> " gained a "
    <> boundary_test_prefix
    <> " test that kills mutant "
    <> string.slice(boundary_id, 0, 8)
    <> ", `gleam test` still passes, a spoiled test is reported as a survivor, "
    <> "--verify stored no report of its own, and a module, a constructor and "
    <> "`should` bound under other names, a module the file declares `Some` "
    <> "and `None` for itself, and one it imported as `_` are all applied to "
    <> "and still compile",
  )
}

// --- The checks --------------------------------------------------------------

/// A command that has to succeed, and the output it left when it did not.
fn status_problems(label: String, run: platform.ProcessResult) -> List(String) {
  expect(
    run.status == 0,
    label
      <> " exited "
      <> int.to_string(run.status)
      <> ", expected 0\nstdout:\n"
      <> run.stdout
      <> "\nstderr:\n"
      <> run.stderr,
  )
}

/// A dry run says what it would write and writes none of it.
fn dry_run_problems(
  run: platform.ProcessResult,
  before: String,
  after: String,
) -> List(String) {
  list.flatten([
    expect(
      before == after,
      "a dry run changed " <> target <> ", which only --yes may do",
    ),
    expect(
      string.contains(output(run), target),
      "the dry run never named " <> target <> ":\n" <> output(run),
    ),
    expect(
      string.contains(output(run), boundary_test_prefix),
      "the dry run never named a "
        <> boundary_test_prefix
        <> " test:\n"
        <> output(run),
    ),
  ])
}

/// The plans of one Apply JSON v1 value.
fn plan_problems(output: ApplyOutput) -> List(String) {
  let planned =
    list.filter(output.plans, fn(plan) { plan.file == target })
    |> list.flat_map(fn(plan) { plan.tests_added })
    |> list.filter(string.starts_with(_, boundary_test_prefix))
  list.flatten([
    expect(
      output.schema_version == 1,
      "schema_version is "
        <> int.to_string(output.schema_version)
        <> ", expected 1",
    ),
    expect(
      planned != [],
      "no plan for "
        <> target
        <> " added a "
        <> boundary_test_prefix
        <> " test; plans were "
        <> string.inspect(output.plans),
    ),
  ])
}

/// What `--verify` found once the generated tests were in place.
///
/// Every mutant a written suggestion named has to be dead now: that is the
/// whole claim `apply --verify` makes, and the boundary mutant of
/// `is_positive` is the one this fixture exists for.
fn verification_problems(
  output: ApplyOutput,
  boundary_id: String,
) -> List(String) {
  case output.verification {
    None -> ["--verify reported no verification at all"]
    Some(entries) ->
      list.flatten([
        expect(entries != [], "--verify verified no mutant at all"),
        expect(
          list.all(entries, fn(entry) { entry.killed }),
          "--verify reports surviving mutants after applying: "
            <> string.inspect(list.filter(entries, fn(entry) { !entry.killed })),
        ),
        expect(
          boundary_id != "",
          "the boundary mutant of is_positive was never discovered, so "
            <> "nothing checked that the generated test kills it",
        ),
        expect(
          list.any(entries, fn(entry) {
            entry.mutant_id == boundary_id
            && entry.killed
            && entry.outcome == "killed"
          }),
          "the boundary mutant of is_positive is not reported killed: "
            <> string.inspect(entries),
        ),
      ])
  }
}

/// The file the run left behind holds the test it said it would write.
fn written_problems(before: String, after: String) -> List(String) {
  list.flatten([
    expect(
      before != after,
      "--yes left " <> target <> " exactly as it found it",
    ),
    expect(
      string.contains(after, boundary_test_prefix),
      target <> " holds no " <> boundary_test_prefix <> " test:\n" <> after,
    ),
  ])
}

/// The project's own suite still passes on what was written into it.
fn test_problems(run: platform.ProcessResult) -> List(String) {
  expect(
    run.status == 0,
    "`gleam test` failed in the applied workspace, exit "
      <> int.to_string(run.status)
      <> "\n"
      <> output(run),
  )
}

/// A second `--yes` over an applied workspace changes nothing and says so.
///
/// Every test is already there, so the file is left untouched — and a report
/// that called that "updated" would send a reader looking for a diff nobody
/// wrote.
fn reapply_problems(
  run: platform.ProcessResult,
  after: String,
  after_again: String,
) -> List(String) {
  list.flatten([
    status_problems("apply --yes (again)", run),
    expect(
      after == after_again,
      "applying twice changed " <> target <> " the second time",
    ),
    expect(
      string.contains(run.stdout, target <> ": unchanged"),
      "a re-apply did not report " <> target <> " as unchanged:\n" <> run.stdout,
    ),
    expect(
      string.contains(run.stdout, "0 test(s) written"),
      "a re-apply claimed to write tests:\n" <> run.stdout,
    ),
  ])
}

/// Rewrites one generated test so that it passes without killing anything.
///
/// `>` and `>=` differ on `0` alone, so an assertion about `1` is a test the
/// suite is green on and the mutant walks away from.
fn spoil(root: String) -> List(String) {
  let file = path.join(root, target)
  case simplifile.read(file) {
    Error(_) -> ["could not read " <> target <> " to spoil its generated test"]
    Ok(source) ->
      case string.contains(source, generated_assertion) {
        False -> [
          "the generated test does not assert `"
          <> generated_assertion
          <> "`, so this smoke never spoiled it:\n"
          <> source,
        ]
        True ->
          case
            simplifile.write(
              file,
              string.replace(source, generated_assertion, toothless_assertion),
            )
          {
            Ok(Nil) -> []
            Error(_) -> ["could not write the spoiled " <> target]
          }
      }
  }
}

/// A generated test that no longer kills its mutant is a quality failure.
///
/// The tests are all present, so nothing is written: this is the run that
/// proves `--verify` re-checks the generated tests a module already holds
/// rather than reporting that it had nothing to do.
fn survivor_problems(
  run: platform.ProcessResult,
  boundary_id: String,
) -> List(String) {
  let entries = case decode_output(extract_json(run.stdout)) {
    Error(_) -> []
    Ok(output) -> option.unwrap(output.verification, [])
  }
  list.flatten([
    expect(
      run.status == 1,
      "a spoiled generated test exited "
        <> int.to_string(run.status)
        <> ", expected 1\n"
        <> output(run),
    ),
    expect(
      list.any(entries, fn(entry) {
        entry.mutant_id == boundary_id
        && !entry.killed
        && entry.outcome == "survived"
      }),
      "the spoiled test's mutant was not reported as a survivor: "
        <> string.inspect(entries),
    ),
    expect(
      list.any(entries, fn(entry) { entry.killed }),
      "no mutant at all was reported dead, so the run checked nothing: "
        <> string.inspect(entries),
    ),
  ])
}

/// `--verify` runs the engine over a handful of files, and stores nothing.
///
/// A verification run covers the files one set of suggestions came from and
/// nothing else. Storing it would make it the workspace's latest report, and
/// `report latest`, `report list` and a later `suggest --survivors` would all
/// answer from a narrowed run nobody asked for.
fn history_problems(run: platform.ProcessResult) -> List(String) {
  expect(
    run.status != 0,
    "`apply --verify` stored a run in the report history: `report latest` "
      <> "answered with\n"
      <> output(run),
  )
}

// --- The names the reader's own test module already binds --------------------

/// A workspace whose test module imports the module under test as `b`.
///
/// The file says how it wants to reach `boundary`, and a module it already
/// names cannot be named a second time, so every generated call has to travel
/// through the alias — the values it is given included, since the probe prints a value of
/// the module's own type qualified by the module. `gleam test` is the judge
/// here: source that names a module the file never imported does not build.
fn aliased_problems() -> List(String) {
  let done = apply_copy(aliased_module, [])
  let applied = done.run
  let after = done.source
  let tested = done.tested

  list.flatten([
    status_problems("apply --yes (aliased import)", applied),
    expect(
      string.contains(after, "b." <> boundary_test_prefix)
        || string.contains(after, "assert b.is_positive(0)"),
      "the generated test does not call the module through its alias:\n"
        <> after,
    ),
    expect(
      !string.contains(after, "boundary.Circle")
        && !string.contains(after, "boundary.is_positive("),
      "the applied file still names `boundary` directly, which it never "
        <> "imported:\n"
        <> after,
    ),
    compiles("aliased import", tested),
  ])
}

/// A workspace whose test module binds an option constructor to another name.
///
/// `import gleam/option.{Some as Just}` binds `Just` and leaves `Some`
/// unbound, so a generated test that writes `Some(1)` needs the constructor
/// imported under its own name beside it. `gleam format` is happy either way;
/// the compiler is the judge here.
fn renamed_option_problems() -> List(String) {
  let done = apply_copy(renamed_option_module, [])
  list.flatten([
    status_problems("apply --yes (renamed constructor)", done.run),
    expect(
      string.contains(done.source, "Some as Just"),
      "the reader's own `Some as Just` import was rewritten away:\n"
        <> done.source,
    ),
    expect(
      !string.contains(done.source, "Some(")
        || string.contains(done.source, "{None, Some as Just, Some}")
        || string.contains(done.source, "{Some as Just, Some}"),
      "a generated test writes `Some(` but the import was never grown to "
        <> "bind it:\n"
        <> done.source,
    ),
    compiles("renamed constructor", done.tested),
  ])
}

/// A workspace whose test module binds `gleeunit/should` to another name.
///
/// A second name for one module does not compile, so the generated
/// assertions have to be stated through the name the file bound it under.
fn renamed_should_problems() -> List(String) {
  let done = apply_copy(renamed_should_module, ["--style", "should"])
  list.flatten([
    status_problems("apply --yes --style should (renamed should)", done.run),
    expect(
      string.contains(done.source, "|> expect.equal("),
      "no generated test states its expectation through `expect`:\n"
        <> done.source,
    ),
    expect(
      !string.contains(done.source, "should.equal("),
      "a generated test calls `should`, which this file never bound:\n"
        <> done.source,
    ),
    compiles("renamed should", done.tested),
  ])
}

/// A workspace whose test module declares `Some` and `None` of its own.
///
/// Nothing in its imports says so, so a tool that reads only imports writes
/// `import gleam/option.{None, Some}` beside a type that already binds both
/// names. `gleam format` accepts the result and the compiler does not, which
/// is why this copy ends in `gleam test`.
fn own_constructors_problems() -> List(String) {
  let done = apply_copy(own_constructors_module, [])
  list.flatten([
    status_problems("apply --yes (own constructors)", done.run),
    expect(
      !string.contains(done.source, "import gleam/option.{"),
      "the generated imports take names this file already binds:\n"
        <> done.source,
    ),
    expect(
      string.contains(done.source, "option.Some(")
        || string.contains(done.source, "option.None"),
      "no generated test reaches an option constructor through its module:\n"
        <> done.source,
    ),
    compiles("own constructors", done.tested),
  ])
}

/// A workspace whose test module imports the module under test as `_`.
///
/// That line binds the names it lists and no name for the module itself, and
/// Gleam is content to hold a plain `import boundary` beside it — so the
/// generated tests get a name to call rather than a refusal.
fn discarded_problems() -> List(String) {
  let done = apply_copy(discarded_module, [])
  list.flatten([
    status_problems("apply --yes (discarded import)", done.run),
    expect(
      string.contains(done.source, "\nimport boundary\n"),
      "the module the file imported as `_` was never imported under a name:\n"
        <> done.source,
    ),
    expect(
      string.contains(done.source, "as _"),
      "the reader's own `as _` import was rewritten away:\n" <> done.source,
    ),
    compiles("discarded import", done.tested),
  ])
}

/// The project's own suite, run over what was written into one copy.
fn compiles(label: String, tested: platform.ProcessResult) -> List(String) {
  expect(
    tested.status == 0,
    "`gleam test` failed in the "
      <> label
      <> " workspace, exit "
      <> int.to_string(tested.status)
      <> "\n"
      <> output(tested),
  )
}

/// One copy of the fixture, applied to and then handed to `gleam test`.
type Applied {
  Applied(
    run: platform.ProcessResult,
    source: String,
    tested: platform.ProcessResult,
  )
}

fn apply_copy(test_module: String, arguments: List(String)) -> Applied {
  let root = copy_fixture(Some(test_module))
  let run =
    run_cli(list.flatten([["apply", "--root", root], arguments, ["--yes"]]))
  let source = read(root, target)
  let tested = run_gleam_test(root)
  discard_workspace(root)
  Applied(run: run, source: source, tested: tested)
}

/// The fixture's own test module, rewritten to reach `boundary` as `b`.
///
/// Written out as one literal rather than assembled line by line, so that the
/// licence header it carries is a line of this file too and the repository's
/// own REUSE lint can read it.
const aliased_module = "// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import boundary as b
import gleam/option.{Some}
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn is_positive_test() {
  assert b.is_positive(5)
}

pub fn area_test() {
  assert b.area(b.Circle(2)) == 12
}

pub fn maybe_double_test() {
  assert b.maybe_double(Some(2)) == Ok(4)
}
"

/// The fixture's own test module, binding `Some` under a name of its own.
const renamed_option_module = "// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import boundary
import gleam/option.{Some as Just}
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn is_positive_test() {
  assert boundary.is_positive(5)
}

pub fn maybe_double_test() {
  assert boundary.maybe_double(Just(2)) == Ok(4)
}
"

/// The same module, reaching `gleeunit/should` under a name of its own.
const renamed_should_module = "// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import boundary
import gleeunit
import gleeunit/should as expect

pub fn main() {
  gleeunit.main()
}

pub fn is_positive_test() {
  boundary.is_positive(5) |> expect.equal(True)
}
"

/// The fixture's own test module, declaring `Some` and `None` of its own.
const own_constructors_module = "// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import boundary
import gleeunit

pub type Maybe {
  Some(Int)
  None
}

pub fn main() {
  gleeunit.main()
}

pub fn is_positive_test() {
  assert boundary.is_positive(5)
}

pub fn maybe_test() {
  assert Some(1) != None
}
"

/// The fixture's own test module, importing the module under test as `_`.
const discarded_module = "// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import boundary.{Circle, area, is_positive, maybe_double} as _
import gleam/option.{Some}
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn is_positive_test() {
  assert is_positive(5)
}

pub fn area_test() {
  assert area(Circle(2)) == 12
}

pub fn maybe_double_test() {
  assert maybe_double(Some(2)) == Ok(4)
}
"

// --- The mutant this fixture exists for --------------------------------------

/// The id of the `>` boundary mutant of `is_positive`, as `list` discovers it.
///
/// The verification names mutants by id, and a smoke that only counted them
/// would pass on a run that verified something else entirely.
fn boundary_mutant_id(root: String) -> String {
  let listed = run_cli(["list", "--root", root, "--json"])
  case json.parse(extract_json(listed.stdout), catalogue_decoder()) {
    Error(_) -> ""
    Ok(mutants) ->
      mutants
      |> list.filter(fn(entry) {
        entry.operator == "comparison-boundary" && entry.original == "value > 0"
      })
      |> list.first
      |> result.map(fn(entry) { entry.id })
      |> result.unwrap("")
  }
}

// --- A workspace of one's own ------------------------------------------------

/// The files a copy of the fixture is made of.
const fixture_files = [
  "gleam.toml", "src/boundary.gleam", "test/boundary_test.gleam",
  "test/boundary_fixture_test.gleam",
]

/// A throwaway copy of the fixture, which this smoke writes into.
///
/// `test_module` replaces the fixture's own test module when it is given, so
/// that one copy can be applied to as the fixture's author wrote it and
/// another as a reader who imports it under an alias would have it.
fn copy_fixture(test_module: Option(String)) -> String {
  let root =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-apply-" <> platform.random_nonce(),
    )
  list.each(fixture_files, fn(relative) {
    let assert Ok(contents) = simplifile.read(path.join(fixture, relative))
    let file = path.join(root, relative)
    let assert Ok(Nil) = simplifile.create_directory_all(path.parent(file))
    let assert Ok(Nil) = case relative == target, test_module {
      True, Some(replacement) -> simplifile.write(file, replacement)
      _, _ -> simplifile.write(file, contents)
    }
  })
  root
}

/// Deletes a throwaway workspace and the run history it stored.
fn discard_workspace(root: String) -> Nil {
  let _ = platform.delete_tree(root)
  let _ =
    platform.delete_tree(
      platform.cache_directory()
      |> path.join("gleam-mutants/v1/workspaces")
      |> path.join(cache.workspace_id(root)),
    )
  Nil
}

fn read(root: String, relative: String) -> String {
  simplifile.read(path.join(root, relative)) |> result.unwrap("")
}

// --- Running the command line ------------------------------------------------

fn run_cli(arguments: List(String)) -> platform.ProcessResult {
  platform.run_process(
    "gleam",
    list.append(
      ["run", "-m", "gleam_mutants", "--target", "erlang", "--"],
      arguments,
    ),
    ".",
    [],
    900_000,
  )
}

/// The applied workspace's own test suite, run the way its author would.
fn run_gleam_test(root: String) -> platform.ProcessResult {
  platform.run_process("gleam", ["test"], root, [], 900_000)
}

/// Everything a command wrote, whichever stream it chose.
fn output(run: platform.ProcessResult) -> String {
  run.stdout <> "\n" <> run.stderr
}

/// The one JSON value a `--json` run prints, picked out of the build chatter.
fn extract_json(stdout: String) -> String {
  stdout
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(string.starts_with(_, "{"))
  |> list.last
  |> result.unwrap("")
}

// --- The subset of Apply JSON v1 this smoke reads -----------------------------

type ApplyOutput {
  ApplyOutput(
    schema_version: Int,
    plans: List(Plan),
    verification: Option(List(Verified)),
  )
}

type Plan {
  Plan(
    file: String,
    create: Bool,
    imports_added: List(String),
    tests_added: List(String),
    tests_skipped: List(String),
  )
}

type Verified {
  Verified(mutant_id: String, display_id: String, outcome: String, killed: Bool)
}

type Candidate {
  Candidate(id: String, operator: String, original: String)
}

fn decode_output(text: String) -> Result(ApplyOutput, String) {
  case json.parse(text, output_decoder()) {
    Ok(decoded) -> Ok(decoded)
    Error(error) ->
      Error(
        "the --json output is not Apply JSON v1: "
        <> string.inspect(error)
        <> "\n"
        <> text,
      )
  }
}

fn output_decoder() -> decode.Decoder(ApplyOutput) {
  use schema_version <- decode.field("schema_version", decode.int)
  use plans <- decode.field("plans", decode.list(plan_decoder()))
  use verification <- decode.field(
    "verification",
    decode.optional(decode.list(verified_decoder())),
  )
  decode.success(ApplyOutput(
    schema_version: schema_version,
    plans: plans,
    verification: verification,
  ))
}

fn plan_decoder() -> decode.Decoder(Plan) {
  use file <- decode.field("file", decode.string)
  use create <- decode.field("create", decode.bool)
  use imports_added <- decode.field("imports_added", decode.list(decode.string))
  use tests_added <- decode.field("tests_added", decode.list(decode.string))
  use tests_skipped <- decode.field("tests_skipped", decode.list(decode.string))
  decode.success(Plan(
    file: file,
    create: create,
    imports_added: imports_added,
    tests_added: tests_added,
    tests_skipped: tests_skipped,
  ))
}

fn verified_decoder() -> decode.Decoder(Verified) {
  use mutant_id <- decode.field("mutant_id", decode.string)
  use display_id <- decode.field("display_id", decode.string)
  use outcome <- decode.field("outcome", decode.string)
  use killed <- decode.field("killed", decode.bool)
  decode.success(Verified(
    mutant_id: mutant_id,
    display_id: display_id,
    outcome: outcome,
    killed: killed,
  ))
}

fn catalogue_decoder() -> decode.Decoder(List(Candidate)) {
  decode.at(
    ["mutants"],
    decode.list({
      use id <- decode.field("id", decode.string)
      use operator <- decode.field("operator", decode.string)
      use original <- decode.field("original", decode.string)
      decode.success(Candidate(id: id, operator: operator, original: original))
    }),
  )
}

fn expect(holds: Bool, message: String) -> List(String) {
  case holds {
    True -> []
    False -> [message]
  }
}
