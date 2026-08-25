// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Turning one distinguishing input into the Gleam test that kills the mutant
// it came from.
//
// Only a `Distinguished` probe result has an input that tells a mutant apart,
// so only one of those is worth building a `Suggestion` from; a result of any
// other status carries placeholder fields the probe never observed. Rather
// than trust the caller to filter, `renderable` refuses a suggestion with no
// observation behind it and `test_source` says why.
//
// Pure string building: no file system, no processes. Long arguments are
// rendered on one line on purpose — the CLI runs `gleam format` over the files
// it writes.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/suggest/probe_result.{
  type Outcome, Panicked, Returned, TimedOut,
}

/// The characters a Gleam identifier is written with, once it is lowercased.
const identifier_characters = "abcdefghijklmnopqrstuvwxyz0123456789_"

/// The characters that continue a name, so a token has to end before them.
const name_characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"

/// The characters a name can follow: `name_characters` and the dot of a
/// qualified name, since `mod.None` names a constructor of `mod` rather than
/// the one `gleam/option` would have to be imported for.
const qualified_characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_."

/// The option constructors a rendered value can name, with the text that
/// names each one.
const option_constructors = [#("None", "None"), #("Some", "Some(")]

/// The module whose constructors a rendered value can name.
const option_module = "gleam/option"

/// The module the inspect fallback calls.
const string_module = "gleam/string"

/// The module the `should` assertion style calls.
const should_module = "gleeunit/should"

/// What a module under test is imported as when a support import of the same
/// file has already taken the name its own path gives it.
const alias_suffix = "_under_test"

/// How a generated test states its expectation.
pub type AssertStyle {
  /// The `assert <call> == <expected>` keyword form.
  AssertKeyword
  /// The `<call> |> should.equal(<expected>)` gleeunit form.
  ShouldEqual
}

/// Everything one generated test needs to know about the mutant it kills.
///
/// `module_path` is the Gleam module path of the module under test, whose last
/// segment qualifies the call. `inputs` and `expected` hold rendered Gleam
/// source; when `expected` is `None` the test falls back to comparing
/// `string.inspect` against `expected_inspect`, which holds the value the
/// original answered with. The two outcomes say whether there was a value at
/// all: nothing can be asserted about a call that panicked or ran out of time.
/// `kills` names every mutant the same input separates from the original.
pub type Suggestion {
  Suggestion(
    module_path: String,
    function: String,
    mutant_id: String,
    display_id: String,
    operator: String,
    location: String,
    original: String,
    replacement: String,
    inputs: List(String),
    expected: Option(String),
    expected_inspect: String,
    expected_outcome: Outcome,
    actual_inspect: String,
    actual_outcome: Outcome,
    kills: List(String),
  )
}

/// Whether a test can be written for `suggestion` at all.
///
/// Only a call that returned has a result to state. An original that panicked
/// or ran past its timeout is worth telling the reader about — `describe` says
/// so — but no assertion can name what it answers, and comparing
/// `string.inspect` of the call against a literal would only run the panic
/// again. Neither can a suggestion that carries no observation at all: a
/// probe result of any status other than `Distinguished` reports an empty
/// inspect, which as a test would read `== ""` and never pass.
pub fn renderable(suggestion: Suggestion) -> Bool {
  suggestion.expected_outcome == Returned && observed(suggestion)
}

/// Whether the original's answer was seen: as source, as an inspect, or both.
fn observed(suggestion: Suggestion) -> Bool {
  suggestion.expected != None || suggestion.expected_inspect != ""
}

/// The directories of the machine a probe ran on.
///
/// A generated test travels: it is committed, and then run on someone else's
/// laptop and in CI. A value naming one of these directories only holds where
/// it was found, so a suggestion carrying one is refused rather than written.
/// A field naming no place below a root — an empty one, `/`, or a relative
/// path — matches nothing, because it says nothing about this machine that is
/// not equally true of every other.
pub type Machine {
  Machine(home: String, cache: String, temporary: String)
}

/// A machine whose directories are unknown, which nothing is measured against.
pub fn no_machine() -> Machine {
  Machine(home: "", cache: "", temporary: "")
}

/// Why a suggestion that names a directory of this machine has no test.
pub const machine_specific_reason = "expected value depends on this machine"

/// The absolute-path shapes a rendered value must not hold, whatever machine
/// this is: the roots every common platform puts a home, a temporary file or a
/// drive under.
const absolute_markers = [
  "/home/",
  "/Users/",
  "/root/",
  "/tmp/",
  "/var/folders/",
  "C:\\",
]

/// Whether a suggestion's values only mean anything on the machine that found
/// them.
///
/// Both the inputs and the answer are read: an input naming an absolute path
/// makes the call itself unportable, and an expected value naming one makes
/// the assertion fail everywhere else. The inspect fallback counts as an
/// expected value, because that is the literal the generated test compares
/// against when there is no source form.
pub fn machine_specific(suggestion: Suggestion, machine: Machine) -> Bool {
  let values = [
    option.unwrap(suggestion.expected, ""),
    suggestion.expected_inspect,
    ..suggestion.inputs
  ]
  let markers =
    [machine.home, machine.cache, machine.temporary]
    |> list.map(without_trailing_separator)
    |> list.filter(fingerprint)
    |> list.append(absolute_markers)
  list.any(values, fn(value) {
    list.any(markers, fn(marker) { string.contains(value, marker) })
  })
}

/// Whether a directory names a place of this machine's, rather than a root.
///
/// The three directories come out of the environment, and an environment can
/// answer anything: a `HOME` of `/` taken as a marker would refuse every
/// rendered path in the world, an empty one would refuse every value at all,
/// and a relative one — `HOME=dev` — would refuse every value holding those
/// three letters anywhere. A directory earns its place only when it is
/// absolute *and* names something below its root; the roots themselves are
/// what `absolute_markers` is for, and it holds them whatever the environment
/// says.
fn fingerprint(directory: String) -> Bool {
  case directory {
    "/" <> below -> below != ""
    other ->
      case string.split(other, ":\\") {
        [drive, below] -> string.length(drive) <= 2 && below != ""
        _ -> False
      }
  }
}

/// `directory` without the separators it ends in, so that a `HOME` written
/// with a trailing slash is the same marker as one written without.
fn without_trailing_separator(directory: String) -> String {
  case string.ends_with(directory, "/") || string.ends_with(directory, "\\") {
    True -> without_trailing_separator(string.drop_end(directory, 1))
    False -> directory
  }
}

/// The name of the generated test: `<function>_kills_<display id>_test`.
///
/// The display id is cut to its first eight characters and everything that
/// cannot appear in a Gleam identifier is folded to `_`, so the name always
/// compiles.
pub fn test_name(suggestion: Suggestion) -> String {
  suggestion.function
  <> "_kills_"
  <> identifier(short_id(suggestion))
  <> "_test"
}

/// The context one generated test module is rendered in.
///
/// A generated file imports more than the modules its tests call:
/// `gleam/option` for the constructors its values name, `gleam/string` for the
/// inspect fallback, `gleeunit/should` for that assertion style. Each of those
/// takes a name in the file, and which names are taken is a property of the
/// whole file rather than of any one test — as is the name the reader's own
/// module already gave a module it imports. Both live here, so that every
/// fragment naming one module was named from the same scope and they agree.
pub opaque type Scope {
  Scope(
    style: AssertStyle,
    support: List(String),
    bindings: List(#(String, String)),
    qualify_option: Bool,
  )
}

/// The scope the tests of one test module are rendered in.
pub fn scope(suggestions: List(Suggestion), style: AssertStyle) -> Scope {
  Scope(
    style: style,
    support: support(suggestions, style),
    bindings: [],
    qualify_option: False,
  )
}

/// `scope` with the option constructors written through their own module.
///
/// A file that already binds `Some` or `None` — an import of another module's
/// constructor, or a type it declares itself — leaves a generated test no way
/// to write those names plainly: a second binding of one name is a name
/// defined twice, which `gleam format` accepts and the compiler does not.
/// Reaching the constructors through `gleam/option` instead takes no name of
/// the reader's at all, so such a file is adapted rather than refused. The
/// import that comes with it stops naming constructors for the same reason.
pub fn qualify_option(scope: Scope) -> Scope {
  Scope(..scope, qualify_option: True)
}

/// `scope` with `module` called by `name` wherever a rendered test names it.
///
/// The reader's own test module is the caller this exists for: one module
/// cannot be imported twice under a name, so a module the file already names
/// has to be called by the name that file bound it under — `gleam/string as
/// str` as much as the module under test.
pub fn bind(scope: Scope, module: String, name: String) -> Scope {
  Scope(..scope, bindings: [
    #(module, name),
    ..list.filter(scope.bindings, fn(binding) { binding.0 != module })
  ])
}

/// The name the tests of `scope` call `module` by.
///
/// Whatever it was bound to, or the last segment of its path — unless a
/// support import of the same file has taken that name, in which case the
/// module under test is the one that gives it up and is imported as
/// `<name>_under_test`.
pub fn qualifier(scope: Scope, module: String) -> String {
  case list.key_find(scope.bindings, module) {
    Ok(name) -> name
    Error(Nil) -> {
      let segment = last_segment(module)
      case
        list.contains(scope.support, module)
        || !list.any(scope.support, fn(other) { bound(scope, other) == segment })
      {
        True -> segment
        False -> segment <> alias_suffix
      }
    }
  }
}

/// The name one of the file's own support imports binds.
fn bound(scope: Scope, module: String) -> String {
  case list.key_find(scope.bindings, module) {
    Ok(name) -> name
    Error(Nil) -> last_segment(module)
  }
}

/// The modules a generated file imports besides the modules under test.
fn support(suggestions: List(Suggestion), style: AssertStyle) -> List(String) {
  let written = list.filter(suggestions, renderable)
  list.flatten([
    when(option_names(written) != [], option_module),
    when(list.any(written, inspects), string_module),
    when(written != [] && style == ShouldEqual, should_module),
  ])
}

/// One module a generated test module imports, and what its tests need of it.
///
/// `qualifier` is the name the tests write in front of a `.`, and `names` the
/// unqualified names they write on their own. A caller adding these to a file
/// the reader already wrote needs both halves: an import that binds the module
/// under another name, or one of these names to another constructor, does not
/// provide what a glance at its module path suggests it does.
pub type Requirement {
  Requirement(module: String, qualifier: Option(String), names: List(String))
}

/// Every module the tests of `suggestions` import, as `scope` names them.
///
/// Nothing the tests do not use is required: an unused import is a warning in
/// the project the generated file lands in, and `gleam/option` is required
/// with exactly the constructors the rendered values name.
pub fn requirements(
  scope: Scope,
  suggestions: List(Suggestion),
) -> List(Requirement) {
  let written = list.filter(suggestions, renderable)
  list.flatten([
    list.map(written, fn(suggestion) { needed(scope, suggestion.module_path) }),
    case option_names(written), scope.qualify_option {
      [], _ -> []
      _, True -> [needed(scope, option_module)]
      names, False -> [Requirement(option_module, None, names)]
    },
    list.map(when(list.any(written, inspects), string_module), needed(scope, _)),
    list.map(
      when(written != [] && scope.style == ShouldEqual, should_module),
      needed(scope, _),
    ),
  ])
  |> list.unique
}

/// One module the tests reach through a name of its own.
fn needed(scope: Scope, module: String) -> Requirement {
  Requirement(
    module: module,
    qualifier: Some(qualifier(scope, module)),
    names: [],
  )
}

/// The Gleam line one requirement is written as.
///
/// The names are sorted the way `gleam format` sorts them, and the module is
/// aliased only when the name its tests call it by is not the one its path
/// already gives it.
pub fn import_line(requirement: Requirement) -> String {
  "import "
  <> requirement.module
  <> case requirement.names {
    [] -> ""
    names -> ".{" <> string.join(list.sort(names, string.compare), ", ") <> "}"
  }
  <> case requirement.qualifier {
    None -> ""
    Some(name) ->
      case name == last_segment(requirement.module) {
        True -> ""
        False -> " as " <> name
      }
  }
}

/// The sorted, unique import lines the given suggestions need in `scope`.
pub fn imports(scope: Scope, suggestions: List(Suggestion)) -> List(String) {
  requirements(scope, suggestions)
  |> list.map(import_line)
  |> list.unique
  |> list.sort(string.compare)
}

/// Renders one generated test, documentation comment included.
///
/// The comment names the mutant, its operator, its location and the source it
/// replaces. The body asserts in the scope's style, falling back to comparing
/// `string.inspect` output when the original's result cannot be printed as
/// source. A suggestion whose original never returned is refused with the
/// reason, since no assertion could state what it answers.
pub fn test_source(
  scope: Scope,
  suggestion: Suggestion,
) -> Result(String, String) {
  case suggestion.expected_outcome {
    Returned ->
      case observed(suggestion) {
        True -> {
          let shown = rendered(scope, suggestion)
          Ok(
            documentation(shown)
            <> "\npub fn "
            <> test_name(shown)
            <> "() {\n  "
            <> assertion(scope, shown)
            <> "\n}",
          )
        }
        False ->
          Error(
            "the probe recorded no result for this mutant, so there is "
            <> "nothing a test could compare against",
          )
      }
    ended ->
      Error(
        "the original "
        <> ended_as(ended)
        <> " on this input, so no test can state what it answers",
      )
  }
}

/// Renders a whole test module: imports, a blank line, then the tests.
///
/// No `main` is emitted — the project's own test module owns that. Suggestions
/// no test can be written for are left out, imports and all, and a module with
/// nothing to say is rendered as nothing at all.
pub fn file_source(scope: Scope, suggestions: List(Suggestion)) -> String {
  case list.filter_map(suggestions, test_source(scope, _)) {
    [] -> ""
    tests ->
      string.join(imports(scope, suggestions), "\n")
      <> "\n\n"
      <> string.join(list.map(tests, fn(rendered) { rendered <> "\n" }), "\n")
  }
}

/// `suggestion` with the values it carries named the way its call is named.
///
/// The probe prints a value of the module's own type qualified by the last
/// segment of the module path, which is not always the name the file calls
/// that module by: a file that already imports it under an alias, and a file
/// whose own support imports have taken the name, both reach it another way.
/// Rendering is the moment the two have to agree, so everything that reports a
/// suggestion's source — the JSON documents included — reports it from here
/// and names one module one way.
///
/// Applying it twice changes nothing: the values name the qualifier already.
pub fn rendered(scope: Scope, suggestion: Suggestion) -> Suggestion {
  suggestion
  |> renamed_values(
    last_segment(suggestion.module_path),
    qualifier(scope, suggestion.module_path),
  )
  |> qualified_options(scope)
}

/// `suggestion` with every option constructor it names written through the
/// module, when `scope` asks for that.
///
/// The module under test is renamed first, so a value of its own type that
/// happens to name a `Some` of its own is already qualified by the time this
/// runs and is left exactly as it was.
///
/// Applying it twice changes nothing: a constructor that already follows a
/// `.` is somebody else's.
fn qualified_options(suggestion: Suggestion, scope: Scope) -> Suggestion {
  case scope.qualify_option {
    False -> suggestion
    True -> {
      let name = qualifier(scope, option_module)
      Suggestion(
        ..suggestion,
        inputs: list.map(suggestion.inputs, qualified_constructors(_, name)),
        expected: option.map(suggestion.expected, qualified_constructors(
          _,
          name,
        )),
      )
    }
  }
}

/// `text` with every bare option constructor qualified by `name`.
fn qualified_constructors(text: String, name: String) -> String {
  list.fold(option_constructors, text, fn(current, constructor) {
    rename(current, "", constructor.1, name <> "." <> constructor.1)
  })
}

/// `suggestion` with the module qualifier `from` renamed to `to` in the source
/// it carries.
fn renamed_values(
  suggestion: Suggestion,
  from: String,
  to: String,
) -> Suggestion {
  case from == to {
    True -> suggestion
    False ->
      Suggestion(
        ..suggestion,
        inputs: list.map(suggestion.inputs, renamed_qualifier(_, from, to)),
        expected: option.map(suggestion.expected, renamed_qualifier(_, from, to)),
      )
  }
}

/// `text` with every mention of the module qualifier `from` renamed to `to`.
///
/// Only a qualifier is renamed. A longer name that merely ends in `from`, a
/// field reached through another qualified name, and everything inside a
/// string literal are the reader's own text and are left exactly as they are.
/// A name a longer one merely opens with — `Nonesuch` for `None` — is left
/// alone too, which is what lets the same walk rename a bare constructor.
fn renamed_qualifier(text: String, from: String, to: String) -> String {
  rename(text, "", from <> ".", to <> ".")
}

fn rename(
  rest: String,
  seen: String,
  needle: String,
  replacement: String,
) -> String {
  case string.split_once(rest, needle) {
    Error(Nil) -> seen <> rest
    Ok(#(before, after)) -> {
      let head = seen <> before
      case
        follows_name(head) || in_literal(head) || starts_name(needle, after)
      {
        True -> rename(after, head <> needle, needle, replacement)
        False -> rename(after, head <> replacement, needle, replacement)
      }
    }
  }
}

/// Whether `text` ends inside a Gleam string literal it never closed.
fn in_literal(text: String) -> Bool {
  literal_state(string.to_graphemes(text), False)
}

fn literal_state(graphemes: List(String), inside: Bool) -> Bool {
  case graphemes, inside {
    [], _ -> inside
    ["\\", _, ..rest], True -> literal_state(rest, True)
    ["\"", ..rest], _ -> literal_state(rest, !inside)
    [_, ..rest], _ -> literal_state(rest, inside)
  }
}

/// A one-suggestion summary for terminal output.
///
/// One line: the mutant, where it lives, the source it replaces, the call that
/// separates it, and what the original and the mutant each answered. A call
/// that never answered is reported as the panic or the timeout it was, not as
/// the wrapper the probe carried it home in.
pub fn describe(scope: Scope, suggestion: Suggestion) -> String {
  let suggestion = rendered(scope, suggestion)
  short_id(suggestion)
  <> " "
  <> suggestion.operator
  <> " at "
  <> suggestion.location
  <> ": `"
  <> one_line_source(suggestion.original)
  <> "` -> `"
  <> one_line_source(suggestion.replacement)
  <> "`; "
  <> call_source(scope, suggestion)
  <> " "
  <> answered(suggestion.expected_outcome, "is", suggestion.expected_inspect)
  <> ", the mutant "
  <> answered(suggestion.actual_outcome, "answers", suggestion.actual_inspect)
}

/// What one side of the comparison did, as a reader reads it.
fn answered(outcome: Outcome, verb: String, inspect: String) -> String {
  case outcome {
    Returned -> verb <> " " <> one_line(inspect)
    Panicked -> "panics"
    TimedOut -> "times out"
  }
}

/// How a call that did not return ended.
fn ended_as(outcome: Outcome) -> String {
  case outcome {
    Returned -> "returned"
    Panicked -> "panicked"
    TimedOut -> "timed out"
  }
}

/// `text` with the whitespace that would break a terminal item escaped.
fn one_line(text: String) -> String {
  text
  |> string.replace("\\", "\\\\")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

/// A quoted fragment of Gleam source folded onto one line.
///
/// `gleam format` wraps a long expression, so the source a mutant replaces
/// arrives over several indented lines. A `///` comment ends at the first
/// newline and a terminal item is one line, so the wrapping is undone rather
/// than escaped: the fragment is quoted as code, and `a\n  * b` reads as
/// `a * b` either way.
fn one_line_source(source: String) -> String {
  source
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
}

/// The first eight characters of the display id, as the reader sees it.
fn short_id(suggestion: Suggestion) -> String {
  string.slice(suggestion.display_id, 0, 8)
}

/// `text` folded to something a Gleam identifier can hold.
fn identifier(text: String) -> String {
  text
  |> string.lowercase
  |> string.to_graphemes
  |> list.map(fn(grapheme) {
    case string.contains(identifier_characters, grapheme) {
      True -> grapheme
      False -> "_"
    }
  })
  |> string.concat
}

/// The documentation comment above a generated test.
fn documentation(suggestion: Suggestion) -> String {
  "/// Generated by gleam_mutants: kills mutant "
  <> short_id(suggestion)
  <> " ("
  <> suggestion.operator
  <> " at "
  <> suggestion.location
  <> ", `"
  <> one_line_source(suggestion.original)
  <> "` -> `"
  <> one_line_source(suggestion.replacement)
  <> "`)."
}

/// The single statement a generated test is made of.
///
/// The support modules are named through the scope like every other module:
/// a file that imports `gleam/string as str` inspects through `str`, and one
/// that imports `gleeunit/should as expect` expects through `expect`.
fn assertion(scope: Scope, suggestion: Suggestion) -> String {
  let call = call_source(scope, suggestion)
  let #(left, right) = case suggestion.expected {
    Some(expected) -> #(call, expected)
    None -> #(
      qualifier(scope, string_module) <> ".inspect(" <> call <> ")",
      quoted(suggestion.expected_inspect),
    )
  }
  case scope.style {
    AssertKeyword -> "assert " <> left <> " == " <> right
    ShouldEqual ->
      left
      <> " |> "
      <> qualifier(scope, should_module)
      <> ".equal("
      <> right
      <> ")"
  }
}

/// The qualified call the test makes, arguments and all.
fn call_source(scope: Scope, suggestion: Suggestion) -> String {
  qualifier(scope, suggestion.module_path)
  <> "."
  <> suggestion.function
  <> "("
  <> string.join(suggestion.inputs, ", ")
  <> ")"
}

/// The last segment of a module path.
fn last_segment(module_path: String) -> String {
  module_path
  |> string.split("/")
  |> list.last
  |> result.unwrap(module_path)
}

/// Whether the test of `suggestion` compares `string.inspect` output.
fn inspects(suggestion: Suggestion) -> Bool {
  suggestion.expected == None
}

/// The `gleam/option` constructors the given suggestions name, if any.
///
/// Only the constructors a rendered value actually names are imported: a
/// generated file that names `None` and nothing else must not carry `Some`,
/// which the compiler would report as an unused imported constructor. Which
/// name a module under test is called by never moves a constructor in or out
/// of the answer, so this is settled before any scope exists.
fn option_names(suggestions: List(Suggestion)) -> List(String) {
  let rendered =
    suggestions
    |> list.flat_map(rendered_values)
    |> list.map(without_literals)
  option_constructors
  |> list.filter(fn(constructor) { list.any(rendered, token(_, constructor.1)) })
  |> list.map(fn(constructor) { constructor.0 })
}

/// The Gleam source a suggestion's test writes out as values.
fn rendered_values(suggestion: Suggestion) -> List(String) {
  case suggestion.expected {
    Some(expected) -> [expected, ..suggestion.inputs]
    None -> suggestion.inputs
  }
}

/// `text` with every Gleam string literal removed.
///
/// The letters inside a literal are data, not names: `Error("None")` needs no
/// import, and a literal holding a quote of its own must not end the scan
/// early.
fn without_literals(text: String) -> String {
  outside_literal(string.to_graphemes(text), [])
}

fn outside_literal(graphemes: List(String), kept: List(String)) -> String {
  case graphemes {
    [] -> string.concat(list.reverse(kept))
    ["\"", ..rest] -> inside_literal(rest, kept)
    [grapheme, ..rest] -> outside_literal(rest, [grapheme, ..kept])
  }
}

fn inside_literal(graphemes: List(String), kept: List(String)) -> String {
  case graphemes {
    [] -> string.concat(list.reverse(kept))
    ["\\", _, ..rest] -> inside_literal(rest, kept)
    ["\"", ..rest] -> outside_literal(rest, kept)
    [_, ..rest] -> inside_literal(rest, kept)
  }
}

/// Whether `needle` appears in `text` as a token rather than inside a name.
fn token(text: String, needle: String) -> Bool {
  case string.split_once(text, needle) {
    Error(Nil) -> False
    Ok(#(before, after)) ->
      case follows_name(before) || starts_name(needle, after) {
        False -> True
        True -> token(after, needle)
      }
  }
}

/// Whether `text` ends in a character a name continues through.
fn ends_name(text: String) -> Bool {
  case string.last(text) {
    Ok(character) -> string.contains(name_characters, character)
    Error(Nil) -> False
  }
}

/// Whether `text` ends in a character a name can follow, the dot of a
/// qualified name included.
fn follows_name(text: String) -> Bool {
  case string.last(text) {
    Ok(character) -> string.contains(qualified_characters, character)
    Error(Nil) -> False
  }
}

/// Whether `after` continues the name `needle` ended with.
fn starts_name(needle: String, after: String) -> Bool {
  ends_name(needle) && ends_name(string.slice(after, 0, 1))
}

/// Wraps `text` in a Gleam string literal, escaping what a literal cannot
/// hold.
fn quoted(text: String) -> String {
  "\"" <> string.concat(list.map(string.to_graphemes(text), escaped)) <> "\""
}

fn escaped(grapheme: String) -> String {
  case grapheme {
    "\\" -> "\\\\"
    "\"" -> "\\\""
    "\n" -> "\\n"
    "\r" -> "\\r"
    "\t" -> "\\t"
    _ -> grapheme
  }
}

/// The single-element list holding `line` when `needed`, or nothing.
fn when(needed: Bool, line: String) -> List(String) {
  case needed {
    True -> [line]
    False -> []
  }
}
