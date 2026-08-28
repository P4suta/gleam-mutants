// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

@target(erlang)
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
@target(erlang)
import gleam_mutants/core/path
@target(erlang)
import gleam_mutants/platform
import gleam_mutants/suggest/probe_result.{Panicked, Returned, TimedOut}
import gleam_mutants/suggest/render.{AssertKeyword, ShouldEqual, Suggestion}
@target(erlang)
import simplifile

// --- fixtures ---------------------------------------------------------------

/// A boundary the shrunk input `0` tells apart, whose result prints as source.
fn is_positive() -> render.Suggestion {
  Suggestion(
    module_path: "boundary",
    function: "is_positive",
    mutant_id: "ab12cd34ef567890abcd",
    display_id: "ab12cd34ef56",
    operator: "comparison-boundary",
    location: "src/boundary.gleam:12:7",
    original: "value > 0",
    replacement: "value >= 0",
    inputs: ["0"],
    support_modules: [],
    expected: Some("False"),
    expected_inspect: "False",
    expected_outcome: Returned,
    actual_inspect: "True",
    actual_outcome: Returned,
    kills: ["ab12cd34ef567890abcd"],
  )
}

/// The probe line `is_positive` is built from, in the shape the probe writes
/// it: the inspects hold the values the calls answered with.
const probe_line = "{\"function\":\"is_positive\",\"mutant\":\"ab12cd34ef567890abcd\",\"status\":\"distinguished\",\"inputs\":[\"0\"],\"expected\":\"False\",\"expected_inspect\":\"False\",\"expected_outcome\":\"returned\",\"actual_inspect\":\"True\",\"actual_outcome\":\"returned\",\"cases\":4,\"shrinks\":2,\"reason\":\"\",\"kills\":[\"ab12cd34ef567890abcd\"]}"

/// A nested module path, whose qualifier is the last segment, and an argument
/// that names `Some`.
fn maybe_double() -> render.Suggestion {
  Suggestion(
    module_path: "app/util",
    function: "maybe_double",
    mutant_id: "0f9e8d7c6b5a49382716",
    display_id: "0f9e8d7c6b5a",
    operator: "integer-arithmetic",
    location: "src/app/util.gleam:20:5",
    original: "v + v",
    replacement: "v - v",
    inputs: ["Some(1)"],
    support_modules: [],
    expected: Some("Ok(2)"),
    expected_inspect: "Ok(2)",
    expected_outcome: Returned,
    actual_inspect: "Ok(0)",
    actual_outcome: Returned,
    kills: ["0f9e8d7c6b5a49382716"],
  )
}

/// A result that cannot be printed as source, so the test has to fall back to
/// comparing `string.inspect` output. Its argument names `None`.
fn hidden() -> render.Suggestion {
  Suggestion(
    module_path: "app/util",
    function: "hidden",
    mutant_id: "11223344aabbccddeeff",
    display_id: "11223344aabb",
    operator: "boolean-literal",
    location: "src/app/util.gleam:3:3",
    original: "True",
    replacement: "False",
    inputs: ["None"],
    support_modules: [],
    expected: None,
    expected_inspect: "Secret(2)",
    expected_outcome: Returned,
    actual_inspect: "Secret(3)",
    actual_outcome: Returned,
    kills: ["11223344aabbccddeeff", "0f9e8d7c6b5a49382716"],
  )
}

/// No arguments at all, and an inspect rendering that has to be escaped before
/// it can sit inside a Gleam string literal.
fn zero() -> render.Suggestion {
  Suggestion(
    module_path: "app/util",
    function: "zero",
    mutant_id: "55667788ccddeeff0011",
    display_id: "55667788ccdd",
    operator: "integer-literal",
    location: "src/app/util.gleam:9:3",
    original: "0",
    replacement: "1",
    inputs: [],
    support_modules: [],
    expected: None,
    expected_inspect: "Ok(\"a\nb\")",
    expected_outcome: Returned,
    actual_inspect: "Ok(\"c\")",
    actual_outcome: Returned,
    kills: ["55667788ccddeeff0011"],
  )
}

/// Two arguments, one of them a string literal that merely contains the
/// letters of `None`.
fn shout() -> render.Suggestion {
  Suggestion(
    module_path: "boundary",
    function: "shout",
    mutant_id: "99aabbcc00112233ddee",
    display_id: "99aabbcc0011",
    operator: "string-literal",
    location: "src/boundary.gleam:31:10",
    original: "\"!\"",
    replacement: "\"\"",
    inputs: ["1", "\"Nonesuch\""],
    support_modules: [],
    expected: Some("\"Nonesuch!\""),
    expected_inspect: "\"Nonesuch!\"",
    expected_outcome: Returned,
    actual_inspect: "\"Nonesuch\"",
    actual_outcome: Returned,
    kills: ["99aabbcc00112233ddee"],
  )
}

/// A mutant the engine reports over more than one line: `gleam format` wraps a
/// long expression, and the source a mutant replaces is quoted exactly as the
/// module holds it, newlines and indentation and all.
fn wrapped() -> render.Suggestion {
  Suggestion(
    module_path: "boundary",
    function: "wide",
    mutant_id: "b7d2bc6e77889900aabb",
    display_id: "b7d2bc6e7788",
    operator: "integer-arithmetic",
    location: "src/boundary.gleam:14:3",
    original: "alpha_component(alpha)\n  * beta_component(beta)",
    replacement: "alpha_component(alpha)\n  / beta_component(beta)",
    inputs: ["2", "3"],
    support_modules: [],
    expected: Some("15"),
    expected_inspect: "15",
    expected_outcome: Returned,
    actual_inspect: "0",
    actual_outcome: Returned,
    kills: ["b7d2bc6e77889900aabb"],
  )
}

/// An original that panicked on the input that separates the mutant: there is
/// no result for a test to state, however the mutant answered.
fn panicking() -> render.Suggestion {
  Suggestion(
    module_path: "boundary",
    function: "risky",
    mutant_id: "aabbccdd00112233ffee",
    display_id: "aabbccdd0011",
    operator: "integer-literal",
    location: "src/boundary.gleam:40:5",
    original: "1",
    replacement: "2",
    inputs: ["Some(0)"],
    support_modules: [],
    expected: None,
    expected_inspect: "",
    expected_outcome: Panicked,
    actual_inspect: "0",
    actual_outcome: Returned,
    kills: ["aabbccdd00112233ffee"],
  )
}

/// An original that ran past its timeout instead of answering.
fn timing_out() -> render.Suggestion {
  Suggestion(
    ..panicking(),
    function: "slow",
    display_id: "ddeeff001122",
    expected_outcome: TimedOut,
  )
}

/// The shape `diff_runner` reports for a mutant of a function it could not
/// probe at all: no inputs, no result, and `Returned` standing in for an
/// outcome that was never observed.
fn unobserved() -> render.Suggestion {
  Suggestion(
    ..panicking(),
    function: "unsupported",
    display_id: "102030405060",
    inputs: [],
    expected_outcome: Returned,
    actual_inspect: "",
    kills: [],
  )
}

/// A module under test whose own name is one the generated file's imports
/// take: `app/option` qualifies as `option`, and `import gleam/option` binds
/// that name too, so the file would hold the name twice.
fn shadowing_option() -> render.Suggestion {
  Suggestion(
    module_path: "app/option",
    function: "unwrap_or",
    mutant_id: "6677889900aabbccddee",
    display_id: "6677889900aa",
    operator: "integer-literal",
    location: "src/app/option.gleam:6:13",
    original: "0",
    replacement: "1",
    inputs: ["None"],
    support_modules: [],
    expected: Some("0"),
    expected_inspect: "0",
    expected_outcome: Returned,
    actual_inspect: "1",
    actual_outcome: Returned,
    kills: ["6677889900aabbccddee"],
  )
}

/// The same clash with `gleam/string`, which the inspect fallback imports.
fn shadowing_string() -> render.Suggestion {
  Suggestion(
    ..shadowing_option(),
    module_path: "app/string",
    function: "tagged",
    display_id: "778899aabbcc",
    location: "src/app/string.gleam:5:7",
    inputs: [],
    expected: None,
    expected_inspect: "Tag(0)",
    actual_inspect: "Tag(1)",
  )
}

/// And with `gleeunit/should`, which the `ShouldEqual` style imports.
fn shadowing_should() -> render.Suggestion {
  Suggestion(
    ..shadowing_option(),
    module_path: "app/should",
    function: "count",
    display_id: "8899aabbccdd",
    location: "src/app/should.gleam:2:11",
    inputs: ["2"],
    expected: Some("2"),
    expected_inspect: "2",
    actual_inspect: "3",
  )
}

/// The `gleam/option` clash again, with a value of the module's own type in
/// the call.
///
/// The probe prints such a value qualified by the module it belongs to, so a
/// module the generated file cannot import under its own name has to be
/// renamed inside the argument as well as in front of the call.
fn shadowing_option_shape() -> render.Suggestion {
  Suggestion(
    ..shadowing_option(),
    function: "area",
    mutant_id: "99aabbccddee00112233",
    display_id: "99aabbccddee",
    location: "src/app/option.gleam:13:5",
    original: "3 * radius",
    replacement: "3 / radius",
    inputs: ["option.Circle(2)", "None"],
    expected: Some("6"),
    expected_inspect: "6",
    actual_inspect: "1",
    kills: ["99aabbccddee00112233"],
  )
}

fn cross_opaque() -> render.Suggestion {
  Suggestion(
    module_path: "boundary",
    function: "consume",
    mutant_id: "c0ffee00112233445566",
    display_id: "c0ffee001122",
    operator: "integer-arithmetic",
    location: "src/boundary.gleam:30:3",
    original: "value > 0",
    replacement: "value >= 0",
    inputs: ["token.new(1)"],
    support_modules: ["demo/token"],
    expected: Some("True"),
    expected_inspect: "True",
    expected_outcome: Returned,
    actual_inspect: "False",
    actual_outcome: Returned,
    kills: ["c0ffee00112233445566"],
  )
}

fn lines(values: List(String)) -> String {
  string.join(values, "\n")
}

// --- rendering one file's worth of suggestions -------------------------------

// Rendering is settled per test module: which names the file's own imports
// take is a property of the whole file. These helpers stand for the file a
// test is about, so that each case says what it is about rather than how a
// scope is built.

/// The source of one test, in a file holding that test alone.
fn source(
  suggestion: render.Suggestion,
  style: render.AssertStyle,
) -> Result(String, String) {
  render.test_source(render.scope([suggestion], style), suggestion)
}

/// The whole module one file's worth of suggestions is written as.
fn file_source(
  suggestions: List(render.Suggestion),
  style: render.AssertStyle,
) -> String {
  render.file_source(render.scope(suggestions, style), suggestions)
}

/// The import lines one file's worth of suggestions needs.
fn imports(
  suggestions: List(render.Suggestion),
  style: render.AssertStyle,
) -> List(String) {
  render.imports(render.scope(suggestions, style), suggestions)
}

/// One suggestion summarised the way a terminal shows it.
fn described(suggestion: render.Suggestion) -> String {
  render.describe(render.scope([suggestion], AssertKeyword), suggestion)
}

/// One suggestion with its values named the way its own file names them.
fn shown(suggestion: render.Suggestion) -> render.Suggestion {
  render.rendered(render.scope([suggestion], AssertKeyword), suggestion)
}

// --- the fixtures are the shape the probe reports ----------------------------

pub fn a_probe_result_maps_onto_a_suggestion_test() {
  // The fixtures above are not invented: every value a suggestion carries
  // from the probe is copied across field for field, so a golden here is a
  // golden for what a real run renders.
  let assert Ok(reported) = probe_result.decode_line(probe_line)
  assert Suggestion(
      module_path: "boundary",
      function: reported.function,
      mutant_id: reported.mutant,
      display_id: "ab12cd34ef56",
      operator: "comparison-boundary",
      location: "src/boundary.gleam:12:7",
      original: "value > 0",
      replacement: "value >= 0",
      inputs: reported.inputs,
      support_modules: reported.support_modules,
      expected: reported.expected,
      expected_inspect: reported.expected_inspect,
      expected_outcome: reported.expected_outcome,
      actual_inspect: reported.actual_inspect,
      actual_outcome: reported.actual_outcome,
      kills: reported.kills,
    )
    == is_positive()
}

// --- values that only hold on one machine ------------------------------------
//
// Measured on real code: `assert cache.status("") == "cache: empty\nworkspace:
// 5EE2D07D...\npath: /home/yasunobu/.cache/gleam-mutants/..."`. Committed, that
// test fails for every other developer and in CI. A rendered value naming an
// absolute path, or one of this machine's own directories, is refused rather
// than written.

/// A machine with the three directories a test must not name.
fn this_machine() -> render.Machine {
  render.Machine(
    home: "/home/dev",
    cache: "/home/dev/.cache",
    temporary: "/var/tmp/build-7f3a",
  )
}

/// `is_positive` with its inputs and its answer replaced.
fn with_values(
  inputs: List(String),
  expected: Option(String),
  expected_inspect: String,
) -> render.Suggestion {
  Suggestion(
    ..is_positive(),
    inputs: inputs,
    expected: expected,
    expected_inspect: expected_inspect,
  )
}

pub fn machine_specific_refuses_an_absolute_path_in_the_expected_value_test() {
  let paths = [
    "\"/home/dev/.cache/gleam-mutants/v1\"", "\"/Users/dev/Library/Caches\"",
    "\"/root/.config\"", "\"/tmp/gleam-mutants-ab12\"",
    "\"/var/folders/xy/T/probe\"", "\"C:\\\\Users\\\\dev\\\\AppData\"",
  ]
  assert list.filter(paths, fn(path) {
      !render.machine_specific(
        with_values(["0"], Some(path), path),
        render.no_machine(),
      )
    })
    == []
}

pub fn machine_specific_refuses_an_absolute_path_in_an_input_test() {
  assert render.machine_specific(
    with_values(["\"/home/dev/project\"", "0"], Some("True"), "True"),
    render.no_machine(),
  )
}

/// The inspect fallback is the literal a generated test compares against when
/// there is no source form, so it counts as an expected value.
pub fn machine_specific_refuses_a_path_in_the_inspect_fallback_test() {
  assert render.machine_specific(
    with_values(["0"], None, "Config(\"/tmp/gleam-mutants-ab12\")"),
    render.no_machine(),
  )
}

/// This machine's own directories are refused wherever they live, even when
/// they are nowhere near the fixed list of absolute-path shapes.
pub fn machine_specific_refuses_this_machines_own_directories_test() {
  let cases = [
    "\"/home/dev\"", "\"/home/dev/.cache/gleam-mutants\"",
    "\"/var/tmp/build-7f3a/snapshot\"",
  ]
  assert list.filter(cases, fn(value) {
      !render.machine_specific(
        with_values(["0"], Some(value), value),
        this_machine(),
      )
    })
    == []
}

/// A directory this machine does not have is not this machine's.
pub fn machine_specific_accepts_a_value_naming_no_machine_at_all_test() {
  assert !render.machine_specific(is_positive(), this_machine())
  assert !render.machine_specific(
    with_values(["\"src/boundary.gleam\""], Some("\"a/b\""), "\"a/b\""),
    this_machine(),
  )
  // A relative path is portable, and so is a bare separator.
  assert !render.machine_specific(
    with_values(["\"./x\""], Some("\"/\""), "\"/\""),
    this_machine(),
  )
}

/// An unknown directory matches nothing: an empty field is not a prefix of
/// every string in the world.
pub fn machine_specific_ignores_an_unknown_directory_test() {
  assert !render.machine_specific(
    with_values(["\"\""], Some("\"a\""), "\"a\""),
    render.Machine(home: "", cache: "", temporary: ""),
  )
  assert render.no_machine()
    == render.Machine(home: "", cache: "", temporary: "")
}

pub fn machine_specific_reason_is_the_one_the_report_prints_test() {
  assert render.machine_specific_reason
    == "expected value depends on this machine"
}

/// A directory that names nothing below a root is not a fingerprint.
///
/// The three directories come from the environment, and an environment can
/// answer anything: a `HOME` of `/`, of `.` or of an empty string is not a
/// place a value could belong to, and taken as a marker it would refuse every
/// suggestion the tool ever makes — `/` alone is a substring of most rendered
/// paths. Such a directory is ignored, and the fixed list of absolute-path
/// shapes still holds.
pub fn machine_specific_ignores_a_directory_naming_only_a_root_test() {
  let degenerate = render.Machine(home: "/", cache: ".", temporary: "C:\\")
  let cases = ["\"a/b\"", "\"./x\"", "\"src/boundary.gleam\"", "\"/\"", "\"a\""]
  assert list.filter(cases, fn(value) {
      render.machine_specific(
        with_values([value], Some(value), value),
        degenerate,
      )
    })
    == []
  // A relative directory is no marker either: `HOME=dev` must not refuse
  // every value that happens to hold those three letters.
  assert !render.machine_specific(
    with_values(["\"dev/notes\""], Some("\"dev\""), "\"dev\""),
    render.Machine(home: "dev", cache: "", temporary: ""),
  )
}

/// A directory below a root still counts, trailing separator or not.
pub fn machine_specific_reads_a_directory_with_a_trailing_separator_test() {
  let trailing = render.Machine(home: "/data/dev/", cache: "", temporary: "")
  assert render.machine_specific(
    with_values(["0"], Some("\"/data/dev/project\""), "\"/data/dev/project\""),
    trailing,
  )
  // One segment below the root is a real directory: `/root` is a home.
  assert render.machine_specific(
    with_values(["0"], Some("\"/srv/cache\""), "\"/srv/cache\""),
    render.Machine(home: "", cache: "/srv", temporary: ""),
  )
}

// --- test_name ---------------------------------------------------------------

pub fn test_name_cuts_the_display_id_to_eight_test() {
  assert render.test_name(is_positive()) == "is_positive_kills_ab12cd34_test"
  assert render.test_name(maybe_double()) == "maybe_double_kills_0f9e8d7c_test"
}

pub fn test_name_keeps_a_short_display_id_whole_test() {
  let short = Suggestion(..is_positive(), display_id: "abc")
  assert render.test_name(short) == "is_positive_kills_abc_test"
}

pub fn test_name_is_a_valid_gleam_identifier_test() {
  // Anything a Gleam name cannot hold is folded to `_`, and capitals are
  // lowered, so the rendered module still compiles.
  let awkward = Suggestion(..is_positive(), display_id: "AB12-CD34.EF")
  assert render.test_name(awkward) == "is_positive_kills_ab12_cd3_test"

  let spaced = Suggestion(..is_positive(), display_id: "a b/c+de9")
  assert render.test_name(spaced) == "is_positive_kills_a_b_c_de_test"
}

// --- test_source -------------------------------------------------------------

pub fn test_source_renders_the_assert_form_test() {
  assert source(is_positive(), AssertKeyword)
    == Ok(
      lines([
        "/// Generated by gleam_mutants: kills mutant ab12cd34 (comparison-boundary at src/boundary.gleam:12:7, `value > 0` -> `value >= 0`).",
        "pub fn is_positive_kills_ab12cd34_test() {",
        "  assert boundary.is_positive(0) == False",
        "}",
      ]),
    )
}

pub fn test_source_renders_the_should_form_test() {
  assert source(is_positive(), ShouldEqual)
    == Ok(
      lines([
        "/// Generated by gleam_mutants: kills mutant ab12cd34 (comparison-boundary at src/boundary.gleam:12:7, `value > 0` -> `value >= 0`).",
        "pub fn is_positive_kills_ab12cd34_test() {",
        "  boundary.is_positive(0) |> should.equal(False)",
        "}",
      ]),
    )
}

pub fn test_source_qualifies_with_the_last_module_segment_test() {
  assert source(maybe_double(), AssertKeyword)
    == Ok(
      lines([
        "/// Generated by gleam_mutants: kills mutant 0f9e8d7c (integer-arithmetic at src/app/util.gleam:20:5, `v + v` -> `v - v`).",
        "pub fn maybe_double_kills_0f9e8d7c_test() {",
        "  assert util.maybe_double(Some(1)) == Ok(2)",
        "}",
      ]),
    )
}

pub fn test_source_falls_back_to_inspect_test() {
  assert source(hidden(), AssertKeyword)
    == Ok(
      lines([
        "/// Generated by gleam_mutants: kills mutant 11223344 (boolean-literal at src/app/util.gleam:3:3, `True` -> `False`).",
        "pub fn hidden_kills_11223344_test() {",
        "  assert string.inspect(util.hidden(None)) == \"Secret(2)\"",
        "}",
      ]),
    )

  assert source(hidden(), ShouldEqual)
    == Ok(
      lines([
        "/// Generated by gleam_mutants: kills mutant 11223344 (boolean-literal at src/app/util.gleam:3:3, `True` -> `False`).",
        "pub fn hidden_kills_11223344_test() {",
        "  string.inspect(util.hidden(None)) |> should.equal(\"Secret(2)\")",
        "}",
      ]),
    )
}

pub fn test_source_escapes_the_inspect_fallback_test() {
  // The quotes and the newline of the inspected value have to survive as
  // escapes inside the string literal the assertion compares against.
  assert source(zero(), AssertKeyword)
    == Ok(
      lines([
        "/// Generated by gleam_mutants: kills mutant 55667788 (integer-literal at src/app/util.gleam:9:3, `0` -> `1`).",
        "pub fn zero_kills_55667788_test() {",
        "  assert string.inspect(util.zero()) == \"Ok(\\\"a\\nb\\\")\"",
        "}",
      ]),
    )
}

pub fn test_source_joins_every_argument_test() {
  let assert Ok(source) = source(shout(), AssertKeyword)
  assert string.contains(
    source,
    "  assert boundary.shout(1, \"Nonesuch\") == \"Nonesuch!\"",
  )
}

pub fn test_source_folds_a_wrapped_mutant_onto_one_line_test() {
  // A documentation comment ends at the newline: the second line of a wrapped
  // expression would land in the file as source, and nothing after it would
  // parse. Folded onto one line it still reads as the code it quotes.
  assert source(wrapped(), AssertKeyword)
    == Ok(
      lines([
        "/// Generated by gleam_mutants: kills mutant b7d2bc6e (integer-arithmetic at src/boundary.gleam:14:3, `alpha_component(alpha) * beta_component(beta)` -> `alpha_component(alpha) / beta_component(beta)`).",
        "pub fn wide_kills_b7d2bc6e_test() {",
        "  assert boundary.wide(2, 3) == 15",
        "}",
      ]),
    )

  let assert Ok(rendered) = source(wrapped(), ShouldEqual)
  assert list.length(string.split(rendered, "\n")) == 4
}

pub fn test_source_folds_a_windows_line_ending_too_test() {
  // A CRLF checkout hands the engine `\r\n`. A lone carriage return ends a
  // line for the compiler as surely as a newline does, so neither half of it
  // may survive into the comment.
  let crlf =
    Suggestion(
      ..wrapped(),
      original: "alpha_component(alpha)\r\n  * beta_component(beta)",
      replacement: "alpha_component(alpha)\r\n  / beta_component(beta)",
    )
  let assert Ok(source) = source(crlf, AssertKeyword)
  assert string.contains(
    source,
    "`alpha_component(alpha) * beta_component(beta)`",
  )
  assert !string.contains(source, "\r")
  assert described(crlf) == described(wrapped())
}

pub fn test_source_refuses_a_call_that_never_answered_test() {
  // A panicking original has no result to compare against: inspecting the
  // call would run the panic, and no literal could match it either way.
  let assert Error(panicked) = source(panicking(), AssertKeyword)
  assert string.contains(panicked, "panicked")
  let assert Error(timed_out) = source(timing_out(), ShouldEqual)
  assert string.contains(timed_out, "timed out")

  assert !render.renderable(panicking())
  assert !render.renderable(timing_out())
  assert list.all(
    [is_positive(), maybe_double(), hidden(), zero(), shout()],
    render.renderable,
  )
}

pub fn test_source_refuses_a_call_with_nothing_to_compare_test() {
  // `diff_runner` reports a mutant of a function it could not probe with
  // `Returned` and an empty inspect: nothing was observed at all. Rendered as
  // a test that would read `assert string.inspect(boundary.unsupported()) ==
  // ""`, which no run could satisfy, so it is refused like a call that never
  // answered.
  let assert Error(reason) = source(unobserved(), AssertKeyword)
  assert string.contains(reason, "no result")

  assert !render.renderable(unobserved())
  assert file_source([unobserved()], AssertKeyword) == ""
  assert imports([unobserved()], ShouldEqual) == []
}

pub fn test_source_names_a_shadowing_module_one_way_test() {
  // The call is qualified by the name the file imports the module under, and
  // so is every value of that module's own type the call is given: a test
  // that says `option_under_test.area(option.Circle(2))` names a module the
  // generated file never imported and would not compile.
  let assert Ok(source) = source(shadowing_option_shape(), AssertKeyword)
  assert string.contains(
    source,
    "assert option_under_test.area(option_under_test.Circle(2), None) == 6",
  )
  assert !string.contains(source, "option.Circle")
  assert string.contains(
    described(shadowing_option_shape()),
    "option_under_test.area(option_under_test.Circle(2), None)",
  )

  // Every report of a suggestion's source answers from one normalisation, and
  // running it twice changes nothing.
  let normalised = shown(shadowing_option_shape())
  assert normalised.inputs == ["option_under_test.Circle(2)", "None"]
  assert shown(normalised) == normalised
  assert shown(is_positive()) == is_positive()
}

pub fn test_source_keeps_a_module_no_import_shadows_test() {
  // Nothing in this file names an option constructor, so `gleam/option` is
  // never imported and the name `option` is the module under test's to keep.
  // Standing aside for an import nobody writes would leave the reader with an
  // alias they cannot paste into a file that already imports the module.
  let plain =
    Suggestion(..shadowing_option_shape(), inputs: ["option.Circle(2)"])
  let assert Ok(source) = source(plain, AssertKeyword)
  assert string.contains(source, "assert option.area(option.Circle(2)) == 6")
  assert !string.contains(source, "option_under_test")
  assert imports([plain], AssertKeyword) == ["import app/option"]
}

// --- bind --------------------------------------------------------------------

pub fn bind_renames_the_call_and_the_values_together_test() {
  // A file that already imports the module under test under an alias says how
  // it wants to reach it, and one module cannot be named twice.
  // Renaming the call alone would leave the argument naming a module the file
  // never imported.
  let shaped =
    Suggestion(
      ..is_positive(),
      function: "area",
      inputs: ["boundary.Circle(2)", "1"],
      expected: Some("boundary.Square(4)"),
    )
  let scope =
    render.bind(render.scope([shaped], AssertKeyword), "boundary", "b")
  let assert Ok(source) = render.test_source(scope, shaped)
  assert string.contains(source, "assert b.area(b.Circle(2), 1) == b.Square(4)")
  assert !string.contains(source, "boundary.Circle")
  assert !string.contains(source, "boundary.Square")
  assert render.imports(scope, [shaped]) == ["import boundary as b"]
}

pub fn bind_renames_a_qualifier_and_nothing_else_test() {
  // Only the module qualifier is renamed: a longer name that merely ends in
  // it, a field of another qualified name, and the letters inside a string
  // literal are all the reader's own text.
  let awkward =
    Suggestion(
      ..is_positive(),
      function: "label",
      inputs: [
        "my_boundary.Circle(1)", "\"boundary.Circle(2)\"", "other.boundary.x",
        "boundary.Circle(3)",
      ],
      expected: Some("\"boundary.\""),
    )
  let renamed =
    render.rendered(
      render.bind(render.scope([awkward], AssertKeyword), "boundary", "b"),
      awkward,
    )
  assert renamed.inputs
    == [
      "my_boundary.Circle(1)", "\"boundary.Circle(2)\"", "other.boundary.x",
      "b.Circle(3)",
    ]
  assert renamed.expected == Some("\"boundary.\"")
}

pub fn bind_leaves_the_name_a_module_already_has_alone_test() {
  let scope = render.scope([is_positive()], AssertKeyword)
  assert render.rendered(
      render.bind(scope, "boundary", "boundary"),
      is_positive(),
    )
    == is_positive()
  assert shown(maybe_double()) == maybe_double()
}

pub fn bind_names_a_support_module_the_way_the_file_does_test() {
  // `gleam/string as str` and `gleeunit/should as expect` are names a reader's
  // own test module can already have bound, and a generated assertion has to
  // be stated through them: a second name for either would not compile.
  let inspecting =
    render.bind(render.scope([hidden()], AssertKeyword), "gleam/string", "str")
  let assert Ok(inspected) = render.test_source(inspecting, hidden())
  assert string.contains(inspected, "assert str.inspect(util.hidden(None))")
  assert !string.contains(inspected, "string.inspect")
  assert render.imports(inspecting, [hidden()])
    == [
      "import app/util", "import gleam/option.{None}",
      "import gleam/string as str",
    ]

  let expecting =
    render.bind(
      render.scope([is_positive()], ShouldEqual),
      "gleeunit/should",
      "expect",
    )
  let assert Ok(expected) = render.test_source(expecting, is_positive())
  assert string.contains(expected, "|> expect.equal(False)")
  assert render.imports(expecting, [is_positive()])
    == ["import boundary", "import gleeunit/should as expect"]
}

pub fn bind_frees_the_name_a_support_import_would_have_taken_test() {
  // The name `string` is only spoken for while `gleam/string` answers to it.
  // A file that imports it as `str` leaves the module under test the name its
  // own path gives it.
  let scope =
    render.bind(
      render.scope([shadowing_string()], AssertKeyword),
      "gleam/string",
      "str",
    )
  assert render.imports(scope, [shadowing_string()])
    == ["import app/string", "import gleam/string as str"]
  let assert Ok(source) = render.test_source(scope, shadowing_string())
  assert string.contains(source, "assert str.inspect(string.tagged())")
}

// --- imports -----------------------------------------------------------------

pub fn imports_names_the_module_under_test_test() {
  assert imports([is_positive()], AssertKeyword) == ["import boundary"]
}

pub fn imports_are_sorted_and_unique_test() {
  assert imports([maybe_double(), is_positive(), maybe_double()], AssertKeyword)
    == ["import app/util", "import boundary", "import gleam/option.{Some}"]
}

pub fn imports_add_option_only_for_a_real_token_test() {
  // `Some(` and `None` in a rendered value need the import.
  assert list.contains(
    imports([maybe_double()], AssertKeyword),
    "import gleam/option.{Some}",
  )
  assert list.contains(
    imports([hidden()], AssertKeyword),
    "import gleam/option.{None}",
  )

  // The same letters inside a longer word do not, nor does a constructor of
  // the module under test that happens to share the name.
  assert imports([shout()], AssertKeyword) == ["import boundary"]
  let qualified =
    Suggestion(
      ..is_positive(),
      inputs: ["boundary.None"],
      expected: Some("boundary.Some(1)"),
    )
  assert imports([qualified], AssertKeyword) == ["import boundary"]

  // Neither does a string literal that spells one out.
  let quoted =
    Suggestion(
      ..is_positive(),
      inputs: ["\"None\""],
      expected: Some("\"Some(1)\""),
    )
  assert imports([quoted], AssertKeyword) == ["import boundary"]
}

pub fn imports_name_only_the_option_constructors_used_test() {
  // An unqualified constructor nothing names is a warning in the project the
  // generated file lands in, and this project builds with warnings as errors.
  assert list.contains(
    imports([maybe_double(), hidden()], AssertKeyword),
    "import gleam/option.{None, Some}",
  )
  assert list.contains(
    imports([maybe_double()], AssertKeyword),
    "import gleam/option.{Some}",
  )
  assert list.contains(
    imports([hidden()], AssertKeyword),
    "import gleam/option.{None}",
  )
}

pub fn imports_ignore_what_no_test_is_written_for_test() {
  // The `Some(0)` of a suggestion nothing can assert never reaches the file,
  // so importing for it would leave an unused constructor behind.
  assert imports([is_positive(), panicking()], AssertKeyword)
    == ["import boundary"]
}

pub fn imports_do_not_let_a_module_shadow_what_a_test_needs_test() {
  // `import app/option` binds the name `import gleam/option` binds, and a
  // file holding both would not compile. The module under test is imported
  // under another name, and every call it makes is qualified by that name.
  assert imports([shadowing_option()], AssertKeyword)
    == ["import app/option as option_under_test", "import gleam/option.{None}"]
  let assert Ok(source) = source(shadowing_option(), AssertKeyword)
  assert string.contains(
    source,
    "assert option_under_test.unwrap_or(None) == 0",
  )
  assert string.contains(
    described(shadowing_option()),
    "option_under_test.unwrap_or(None)",
  )

  assert imports([shadowing_string()], AssertKeyword)
    == ["import app/string as string_under_test", "import gleam/string"]
  assert imports([shadowing_should()], ShouldEqual)
    == ["import app/should as should_under_test", "import gleeunit/should"]

  // Only the three names the generated file takes are stepped around.
  assert imports([maybe_double()], AssertKeyword)
    == ["import app/util", "import gleam/option.{Some}"]
}

pub fn imports_add_string_for_the_inspect_fallback_test() {
  assert imports([hidden(), zero()], AssertKeyword)
    == ["import app/util", "import gleam/option.{None}", "import gleam/string"]

  // The fallback is what needs it: a suggestion no test is written for
  // imports nothing at all.
  assert imports([panicking()], AssertKeyword) == []
  assert imports([timing_out()], ShouldEqual) == []
}

pub fn imports_add_should_for_the_gleeunit_style_test() {
  assert imports([is_positive()], ShouldEqual)
    == ["import boundary", "import gleeunit/should"]
  assert imports([maybe_double(), is_positive()], ShouldEqual)
    == [
      "import app/util", "import boundary", "import gleam/option.{Some}",
      "import gleeunit/should",
    ]
}

// --- qualify_option ----------------------------------------------------------

// A test module that binds `Some` or `None` to something of its own leaves a
// generated test no way to write those names plainly, and a second binding of
// one name is a name defined twice. Reaching the constructors through their
// module needs no name of the file's at all, so the file is adapted rather
// than refused.

pub fn qualify_option_imports_the_module_rather_than_its_constructors_test() {
  let scope =
    render.scope([maybe_double(), hidden()], AssertKeyword)
    |> render.qualify_option
  assert render.imports(scope, [maybe_double(), hidden()])
    == ["import app/util", "import gleam/option", "import gleam/string"]
}

pub fn qualify_option_writes_the_constructors_through_the_module_test() {
  let scope =
    render.scope([maybe_double(), hidden()], AssertKeyword)
    |> render.qualify_option
  let assert Ok(some) = render.test_source(scope, maybe_double())
  assert string.contains(some, "util.maybe_double(option.Some(1))")
  let assert Ok(none) = render.test_source(scope, hidden())
  assert string.contains(none, "util.hidden(option.None)")

  // The terminal summary names them the same way the test does.
  assert string.contains(
    render.describe(scope, hidden()),
    "util.hidden(option.None)",
  )
}

pub fn qualify_option_writes_through_the_name_the_file_binds_test() {
  let scope =
    render.scope([maybe_double()], AssertKeyword)
    |> render.qualify_option
    |> render.bind("gleam/option", "opt")
  assert render.imports(scope, [maybe_double()])
    == ["import app/util", "import gleam/option as opt"]
  let assert Ok(source) = render.test_source(scope, maybe_double())
  assert string.contains(source, "opt.Some(1)")
}

pub fn qualify_option_leaves_every_other_name_alone_test() {
  // A constructor of the module under test that merely shares the name, a
  // longer word that merely contains it, and a string literal that spells it
  // out are all the reader's own text.
  let own =
    Suggestion(
      ..is_positive(),
      inputs: ["boundary.None", "\"Nonesuch\""],
      expected: Some("boundary.Some(1)"),
    )
  let scope = render.qualify_option(render.scope([own], AssertKeyword))
  let assert Ok(source) = render.test_source(scope, own)
  assert string.contains(
    source,
    "boundary.is_positive(boundary.None, \"Nonesuch\") == boundary.Some(1)",
  )
  assert !string.contains(source, "option.")
}

pub fn qualify_option_steps_around_a_module_named_after_it_test() {
  // The module under test is called `option`, so it gives the name up and the
  // constructors it is handed still travel through `gleam/option`.
  let scope =
    render.qualify_option(render.scope([shadowing_option()], AssertKeyword))
  assert render.imports(scope, [shadowing_option()])
    == ["import app/option as option_under_test", "import gleam/option"]
  let assert Ok(source) = render.test_source(scope, shadowing_option())
  assert string.contains(source, "option_under_test.unwrap_or(option.None)")
}

// --- file_source -------------------------------------------------------------

pub fn file_source_puts_the_imports_above_the_tests_test() {
  assert file_source([is_positive(), maybe_double()], AssertKeyword)
    == lines([
      "import app/util",
      "import boundary",
      "import gleam/option.{Some}",
      "",
      "/// Generated by gleam_mutants: kills mutant ab12cd34 (comparison-boundary at src/boundary.gleam:12:7, `value > 0` -> `value >= 0`).",
      "pub fn is_positive_kills_ab12cd34_test() {",
      "  assert boundary.is_positive(0) == False",
      "}",
      "",
      "/// Generated by gleam_mutants: kills mutant 0f9e8d7c (integer-arithmetic at src/app/util.gleam:20:5, `v + v` -> `v - v`).",
      "pub fn maybe_double_kills_0f9e8d7c_test() {",
      "  assert util.maybe_double(Some(1)) == Ok(2)",
      "}",
      "",
    ])
}

pub fn file_source_leaves_out_what_cannot_be_asserted_test() {
  // Nothing to say at all is an empty file, not a file of imports.
  assert file_source([panicking(), timing_out()], AssertKeyword) == ""

  let source = file_source([is_positive(), panicking()], AssertKeyword)
  assert string.contains(source, "is_positive_kills_ab12cd34_test")
  assert !string.contains(source, "risky")
  assert !string.contains(source, "import gleam/option")
}

pub fn file_source_never_writes_a_main_test() {
  let source = file_source([is_positive()], ShouldEqual)
  assert !string.contains(source, "pub fn main")
  assert string.contains(source, "import gleeunit/should")
}

// --- describe ----------------------------------------------------------------

pub fn describe_names_everything_a_reader_needs_test() {
  let described = described(hidden())
  let expected = [
    "11223344", "boolean-literal", "src/app/util.gleam:3:3", "True", "False",
    "None", "Secret(2)", "Secret(3)",
  ]
  assert list.filter(expected, fn(needle) {
      !string.contains(described, needle)
    })
    == []

  // A summary is one terminal item, not a paragraph.
  assert !string.contains(described, "\n")
}

pub fn describe_folds_a_wrapped_mutant_onto_one_line_test() {
  // The source a mutant replaces reaches `describe` with the newlines the
  // module had. A terminal item is one line: every summary is, whatever the
  // engine quoted.
  assert list.filter(list.map(every_suggestion(), described), fn(summary) {
      string.contains(summary, "\n")
    })
    == []

  let described = described(wrapped())
  assert string.contains(
    described,
    "`alpha_component(alpha) * beta_component(beta)`",
  )
  assert string.contains(
    described,
    "`alpha_component(alpha) / beta_component(beta)`",
  )
}

pub fn describe_says_when_a_call_never_answered_test() {
  let panicked = described(panicking())
  assert string.contains(panicked, "boundary.risky(Some(0)) panics")
  assert string.contains(panicked, "the mutant answers 0")
  assert string.contains(described(timing_out()), "times out")

  let mutant_panicked =
    described(
      Suggestion(..is_positive(), actual_outcome: Panicked, actual_inspect: ""),
    )
  assert string.contains(mutant_panicked, "is False, the mutant panics")

  // The wrapper the probe carries observations home in is never printed: a
  // reader is told about values, panics and timeouts.
  let every =
    list.map([is_positive(), hidden(), panicking(), timing_out()], described)
  assert list.filter(every, fn(line) {
      string.contains(line, "Value(")
      || string.contains(line, "Panic(")
      || string.contains(line, "Timeout")
    })
    == []
}

// --- what the Gleam compiler accepts -----------------------------------------
//
// The CLI runs `gleam format` over the files it writes, so a rendered module
// has to be source the formatter leaves alone — which is also the only way to
// know it parses at all. And since a generated file lands in a project that
// may build with warnings as errors, it also has to compile without one.

fn every_suggestion() -> List(render.Suggestion) {
  [
    is_positive(),
    maybe_double(),
    hidden(),
    zero(),
    shout(),
    wrapped(),
    shadowing_option(),
    shadowing_option_shape(),
    shadowing_string(),
    shadowing_should(),
    panicking(),
    timing_out(),
    unobserved(),
    cross_opaque(),
  ]
}

@target(erlang)
fn temporary_root(prefix: String) -> String {
  let root =
    path.join(platform.temporary_directory(), prefix <> platform.random_nonce())
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  root
}

@target(erlang)
fn write_file(root: String, relative: String, contents: String) -> Nil {
  let target = path.join(root, relative)
  let assert Ok(Nil) = simplifile.create_directory_all(path.parent(target))
  let assert Ok(Nil) = simplifile.write(target, contents)
  Nil
}

@target(erlang)
fn format_check(root: String, name: String, source: String) -> Int {
  write_file(root, name, source)
  let outcome =
    platform.run_process("gleam", ["format", "--check", name], root, [], 60_000)
  outcome.status
}

@target(erlang)
pub fn file_source_is_already_formatted_test() {
  let root = temporary_root("gleam-mutants-render-")

  let with_assert = file_source(every_suggestion(), AssertKeyword)
  let with_should = file_source(every_suggestion(), ShouldEqual)
  let assert_status =
    format_check(root, "generated_assert_test.gleam", with_assert)
  let should_status =
    format_check(root, "generated_should_test.gleam", with_should)
  let assert Ok(Nil) = platform.delete_tree(root)

  // Every test the suggestions describe is in the file, so an empty or
  // half-rendered module cannot pass the formatter by having nothing in it.
  let names =
    every_suggestion()
    |> list.filter(render.renderable)
    |> list.map(render.test_name)
  assert list.length(names) == 11
  assert list.filter(names, fn(name) { !string.contains(with_assert, name) })
    == []
  assert list.filter(names, fn(name) { !string.contains(with_should, name) })
    == []

  assert assert_status == 0
  assert should_status == 0
}

@target(erlang)
/// The modules the fixtures above call into, as a project would hold them.
fn subject_project(root: String) -> Nil {
  write_file(
    root,
    "gleam.toml",
    lines([
      "name = \"render_check\"",
      "version = \"0.0.0\"",
      "",
      "[dependencies]",
      "gleam_stdlib = \">= 0.44.0 and < 2.0.0\"",
      "gleeunit = \">= 1.9.0 and < 2.0.0\"",
    ])
      <> "\n",
  )
  write_file(
    root,
    "src/boundary.gleam",
    lines([
      "import demo/token",
      "",
      "pub fn is_positive(value: Int) -> Bool {",
      "  value > 0",
      "}",
      "",
      "pub fn shout(times: Int, word: String) -> String {",
      "  case times > 0 {",
      "    True -> word <> \"!\"",
      "    False -> word",
      "  }",
      "}",
      "",
      "fn alpha_component(alpha: Int) -> Int {",
      "  alpha + 1",
      "}",
      "",
      "fn beta_component(beta: Int) -> Int {",
      "  beta + 2",
      "}",
      "",
      "pub fn wide(alpha: Int, beta: Int) -> Int {",
      "  alpha_component(alpha) * beta_component(beta)",
      "}",
      "",
      "pub fn consume(value: token.Token) -> Bool {",
      "  token.value(value) > 0",
      "}",
    ])
      <> "\n",
  )
  write_file(
    root,
    "src/demo/token.gleam",
    lines([
      "pub opaque type Token {",
      "  Token(Int)",
      "}",
      "",
      "pub fn new(value: Int) -> Token {",
      "  Token(value)",
      "}",
      "",
      "pub fn value(token: Token) -> Int {",
      "  let Token(value) = token",
      "  value",
      "}",
    ])
      <> "\n",
  )
  write_file(
    root,
    "src/app/util.gleam",
    lines([
      "import gleam/option.{type Option, None, Some}",
      "",
      "pub opaque type Secret {",
      "  Secret(n: Int)",
      "}",
      "",
      "pub fn maybe_double(value: Option(Int)) -> Result(Int, String) {",
      "  case value {",
      "    Some(v) -> Ok(v + v)",
      "    None -> Error(\"missing\")",
      "  }",
      "}",
      "",
      "pub fn hidden(value: Option(Int)) -> Secret {",
      "  case value {",
      "    Some(v) -> Secret(v)",
      "    None -> Secret(2)",
      "  }",
      "}",
      "",
      "pub fn zero() -> Result(String, Nil) {",
      "  Ok(\"a\\nb\")",
      "}",
    ])
      <> "\n",
  )
  write_file(
    root,
    "src/app/option.gleam",
    lines([
      "import gleam/option.{type Option, None, Some}",
      "",
      "pub type Shape {",
      "  Circle(radius: Int)",
      "  Square(side: Int)",
      "}",
      "",
      "pub fn unwrap_or(value: Option(Int)) -> Int {",
      "  case value {",
      "    Some(v) -> v",
      "    None -> 0",
      "  }",
      "}",
      "",
      "pub fn area(shape: Shape, fallback: Option(Int)) -> Int {",
      "  case shape {",
      "    Circle(radius) -> 3 * radius",
      "    Square(side) -> side * side + unwrap_or(fallback)",
      "  }",
      "}",
    ])
      <> "\n",
  )
  write_file(
    root,
    "src/app/string.gleam",
    lines([
      "pub opaque type Tag {",
      "  Tag(n: Int)",
      "}",
      "",
      "pub fn tagged() -> Tag {",
      "  Tag(0)",
      "}",
    ])
      <> "\n",
  )
  write_file(
    root,
    "src/app/should.gleam",
    lines([
      "pub fn count(value: Int) -> Int {",
      "  value",
      "}",
    ])
      <> "\n",
  )
}

@target(erlang)
pub fn file_source_compiles_without_a_warning_test() {
  // An import the tests do not use is a warning, and a project that builds
  // with warnings as errors would refuse the file gleam_mutants wrote for it.
  let root = temporary_root("gleam-mutants-render-build-")
  subject_project(root)
  write_file(
    root,
    "src/generated_assert_test.gleam",
    file_source(every_suggestion(), AssertKeyword),
  )
  write_file(
    root,
    "src/generated_should_test.gleam",
    file_source(every_suggestion(), ShouldEqual),
  )
  // One file per option constructor on its own: a file that names only `Some`
  // must not import `None`, and the other way around.
  write_file(
    root,
    "src/generated_some_test.gleam",
    file_source([maybe_double()], AssertKeyword),
  )
  write_file(
    root,
    "src/generated_none_test.gleam",
    file_source([hidden()], AssertKeyword),
  )
  let outcome =
    platform.run_process(
      "gleam",
      ["build", "--target", "erlang", "--warnings-as-errors"],
      root,
      [],
      180_000,
    )
  let assert Ok(Nil) = platform.delete_tree(root)

  case outcome.status == 0 {
    True -> Nil
    False -> io.println("generated build failed:\n" <> outcome.stderr)
  }
  assert outcome.status == 0
}

pub fn cross_module_opaque_inputs_require_their_provider_module_test() {
  let suggestion = cross_opaque()
  let scope = render.scope([suggestion], AssertKeyword)

  assert list.contains(render.imports(scope, [suggestion]), "import demo/token")
  let assert Ok(source) = render.test_source(scope, suggestion)
  assert string.contains(source, "token.new(1)")
}
