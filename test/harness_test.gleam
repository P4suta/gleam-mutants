// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import glance
@target(erlang)
import gleam/int
@target(erlang)
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
@target(erlang)
import gleam_mutants/core/path
@target(erlang)
import gleam_mutants/platform
@target(erlang)
import gleam_mutants/runtime
import gleam_mutants/suggest/genspec.{
  BitArraySpec, BoolSpec, CustomSpec, FieldSpec, FloatSpec, IntSpec, ListSpec,
  NilSpec, OptionSpec, RecursiveRef, ResultSpec, StringSpec, TupleSpec,
  VariantSpec,
}
import gleam_mutants/suggest/harness.{ProbeFunction, ProbeSpec}
import gleam_mutants/suggest/hints
@target(erlang)
import gleam_mutants/suggest/pbt_source
@target(erlang)
import gleam_mutants/suggest/probe_result
import gleam_mutants/suggest/typederive
@target(erlang)
import simplifile

// --- the module under test ---------------------------------------------------

/// A stand-in for the user's module: every shape the probe has to handle.
const target_source = "import gleam/option.{type Option}

pub type Shape {
  Circle(radius: Int)
  Square(side: Int)
}

pub fn is_positive(value: Int) -> Bool {
  value > 0
}

pub fn area(shape: Shape) -> Int {
  case shape {
    Circle(radius) -> 3 * radius * radius
    Square(side) -> side * side
  }
}

pub fn maybe_double(value: Option(Int)) -> Result(Int, String) {
  todo
}

pub fn pair(a: Int, b: String) -> #(Int, String) {
  #(a, b)
}

pub fn triple(a: Int, b: Int, c: Bool) -> Int {
  todo
}

pub fn quad(a: Int, b: Int, c: Int, d: Int) -> Int {
  todo
}

pub fn now() -> Int {
  todo
}

pub fn measure(values: List(Float), tag: BitArray) -> Float {
  todo
}

pub fn opaque_out(value: Int) -> Mystery {
  todo
}
"

// --- helpers -----------------------------------------------------------------

fn plan(name: String) -> typederive.FunctionPlan {
  plan_in(target_source, name)
}

fn plan_in(source: String, name: String) -> typederive.FunctionPlan {
  let assert Ok(module) = glance.module(source)
  let assert Ok(found) =
    list.find(module.functions, fn(definition) {
      definition.definition.name == name
    })
  let assert Ok(planned) =
    typederive.derive_function(typederive.context(module), found.definition)
  planned
}

/// The parsed function `name`, which is what a probe harvests literals from.
fn function_in(source: String, name: String) -> glance.Function {
  let assert Ok(module) = glance.module(source)
  let assert Ok(found) =
    list.find(module.functions, fn(definition) {
      definition.definition.name == name
    })
  found.definition
}

fn probe_function(
  name: String,
  mutant_ids: List(String),
) -> harness.ProbeFunction {
  ProbeFunction(
    plan: plan(name),
    mutant_ids: mutant_ids,
    hints: hints.harvest(function_in(target_source, name)),
  )
}

/// The file the spec under test has its probe append its results to.
const results_path = "/tmp/gleam-mutants-ab12cd34ef56/probe_boundary.jsonl"

fn spec_for(functions: List(harness.ProbeFunction)) -> harness.ProbeSpec {
  ProbeSpec(
    target_module: "boundary",
    probe_module: "gleam_mutants_probe_ab12cd34ef56_boundary",
    pbt_module: "gleam_mutants_pbt_ab12cd34ef56",
    ffi_module: "gleam_mutants_probe_ab12cd34ef56_ffi",
    results_path: results_path,
    functions: functions,
    seed: 424_242,
    max_cases: 137,
    max_shrinks: 43,
    call_timeout_ms: 2500,
    nondeterminism_checks: 5,
  )
}

fn mutant_ids() -> List(String) {
  [
    "boundary.gleam:9:3:comparison", "boundary.gleam:9:11:int_literal",
    "boundary.gleam:14:5:arithmetic", "boundary.gleam:22:3:result_ok",
    "boundary.gleam:26:3:string_literal",
  ]
}

/// The four functions named by the milestone, carrying five mutants.
fn full_spec() -> harness.ProbeSpec {
  let assert [first, second, third, fourth, fifth] = mutant_ids()
  spec_for([
    probe_function("is_positive", [first, second]),
    probe_function("area", [third]),
    probe_function("maybe_double", [fourth]),
    probe_function("pair", [fifth]),
  ])
}

/// The source of a Gleam string literal holding `text`, as the probe writes
/// it: only ids without quotes or backslashes are used here.
fn literal(text: String) -> String {
  "\"" <> text <> "\""
}

/// The needles that are absent from `source`, so failures name them.
fn missing(source: String, needles: List(String)) -> List(String) {
  list.filter(needles, fn(needle) { !string.contains(source, needle) })
}

/// The needles that are present in `source` but should not be.
fn present(source: String, needles: List(String)) -> List(String) {
  list.filter(needles, fn(needle) { string.contains(source, needle) })
}

fn occurrences(source: String, needle: String) -> Int {
  list.length(string.split(source, needle)) - 1
}

fn imported_modules(source: String) -> List(String) {
  let assert Ok(module) = glance.module(source)
  list.map(module.imports, fn(definition) { definition.definition.module })
}

/// The expression the probe prints a value of `spec` with.
fn printer(spec: genspec.GenSpec) -> String {
  harness.render_value_printer(spec, "value")
}

// --- the rendered probe module ----------------------------------------------

pub fn rendered_probe_parses_as_a_gleam_module_test() {
  let rendered = harness.render_probe(full_spec())
  assert result.is_ok(glance.module(rendered))
  assert missing(rendered, ["pub fn main() -> Nil"]) == []
}

pub fn rendered_probe_imports_only_snapshot_modules_test() {
  let spec = full_spec()
  let rendered = harness.render_probe(spec)
  let allowed = [
    "gleam/int", "gleam/float", "gleam/list", "gleam/string", "gleam/io",
    "gleam/option", "gleam/bit_array", spec.pbt_module, spec.target_module,
  ]
  assert list.filter(imported_modules(rendered), fn(module) {
      !list.contains(allowed, module)
    })
    == []
  assert missing(rendered, [
      "import gleam_mutants_pbt_ab12cd34ef56 as pbt",
      "import boundary as target",
    ])
    == []
}

pub fn rendered_probe_omits_imports_it_does_not_need_test() {
  let integers =
    harness.render_probe(
      spec_for([
        probe_function("is_positive", ["boundary.gleam:9:3:comparison"]),
      ]),
    )
  assert present(integers, ["gleam/float", "gleam/bit_array"]) == []

  let floats =
    harness.render_probe(
      spec_for([
        probe_function("measure", ["boundary.gleam:40:3:arithmetic"]),
      ]),
    )
  assert missing(floats, [
      "import gleam/float", "import gleam/bit_array", "pbt.float()",
      "pbt.bit_array()", "pbt.list(",
    ])
    == []
}

pub fn rendered_probe_searches_once_per_mutant_test() {
  let rendered = harness.render_probe(full_spec())
  assert occurrences(rendered, "pbt.find_counterexample(")
    == list.length(mutant_ids())
  assert missing(
      rendered,
      list.map(mutant_ids(), fn(id) { "\"" <> id <> "\"" }),
    )
    == []
}

pub fn rendered_probe_bakes_in_the_seed_and_budgets_test() {
  let rendered = harness.render_probe(full_spec())
  assert missing(rendered, [
      "pbt.seed(", "424242", "137", "43", "2500",
      "gleam_mutants_probe_ab12cd34ef56_boundary",
    ])
    == []
}

pub fn rendered_probe_declares_the_isolating_external_test() {
  let rendered = harness.render_probe(full_spec())
  assert missing(rendered, [
      "@external(erlang, \"gleam_mutants_probe_ab12cd34ef56_ffi\", \"isolated\")",
      "fn isolated(", "Value(a)", "Panic(String)", "Timeout",
    ])
    == []
}

pub fn rendered_probe_generates_one_helper_per_function_test() {
  let rendered = harness.render_probe(full_spec())
  assert missing(rendered, [
      "fn gen_is_positive()", "fn show_args_is_positive(",
      "fn show_result_is_positive(", "fn gen_area()", "fn show_args_area(",
      "fn gen_maybe_double()", "fn gen_pair()", "target.is_positive(",
      "target.area(", "target.maybe_double(", "target.pair(",
    ])
    == []
}

pub fn rendered_probe_omits_a_result_printer_without_a_return_spec_test() {
  let rendered =
    harness.render_probe(
      spec_for([
        probe_function("opaque_out", ["boundary.gleam:44:3:int_literal"]),
      ]),
    )
  assert present(rendered, ["show_result_opaque_out"]) == []
  assert missing(rendered, ["fn show_args_opaque_out("]) == []
  assert result.is_ok(glance.module(rendered))
}

pub fn rendered_probe_builds_a_generator_for_every_arity_test() {
  let rendered =
    harness.render_probe(
      spec_for([
        probe_function("now", ["boundary.gleam:36:3:int_literal"]),
        probe_function("is_positive", ["boundary.gleam:9:3:comparison"]),
        probe_function("pair", ["boundary.gleam:26:3:string_literal"]),
        probe_function("triple", ["boundary.gleam:30:3:arithmetic"]),
        probe_function("quad", ["boundary.gleam:33:3:arithmetic"]),
      ]),
    )
  assert missing(rendered, [
      "pbt.constant(Nil)", "pbt.small_int()", "pbt.string()", "pbt.bool()",
      "pbt.tuple2(", "pbt.tuple3(", "fn gen_now()", "fn gen_quad()",
    ])
    == []
  assert result.is_ok(glance.module(rendered))
}

/// The literals a function writes down are drawn on purpose.
///
/// Measured on real code, no seed and no budget reached the inputs the
/// separating cases needed: `normalize_path` needs a path starting `"./"`,
/// and a boundary at `x > 10` needs `10`. Both are in the source of the
/// function itself, so the generator of each parameter is told about them.
pub fn rendered_probe_seeds_a_generator_with_the_functions_literals_test() {
  let rendered =
    harness.render_probe(
      spec_in(hint_source, [
        #("big", ["m_big"]),
        #("is_path", ["m_path"]),
        #("joined", ["m_join"]),
        #("plain", ["m_plain"]),
      ]),
    )

  assert missing(function_source(rendered, "gen_big"), [
      "pbt.int_with_hints(-100, 100, [10, 9, 11])",
    ])
    == []
  assert missing(function_source(rendered, "gen_is_path"), [
      "pbt.string_with_hints([\"./\"])",
    ])
    == []
  // A hint reaches every value of that kind inside the parameter, list
  // elements included: `join(parts, "; ")` is separated by a list holding the
  // separator, not by a `List(String)` shaped like anything else.
  assert missing(function_source(rendered, "gen_joined"), [
      "pbt.list(pbt.string_with_hints([\"; \"]))",
    ])
    == []
  assert result.is_ok(glance.module(rendered))
}

/// A function with nothing to harvest keeps the plain generators: a hint list
/// that is always empty would be noise in every probe the tool writes.
pub fn rendered_probe_keeps_the_plain_generators_without_hints_test() {
  let rendered =
    harness.render_probe(spec_in(hint_source, [#("plain", ["m_plain"])]))
  assert missing(function_source(rendered, "gen_plain"), [
      "pbt.small_int()", "pbt.string()",
    ])
    == []
  assert present(function_source(rendered, "gen_plain"), ["_with_hints"]) == []
}

/// Functions whose bodies name the values their mutants hide behind.
const hint_source = "import gleam/string

pub fn big(x: Int) -> Bool {
  x > 10
}

pub fn is_path(s: String) -> Bool {
  string.starts_with(s, \"./\")
}

pub fn joined(parts: List(String)) -> String {
  string.join(parts, \"; \")
}

pub fn plain(x: Int, s: String) -> Int {
  string.length(s) + x
}
"

pub fn rendered_probe_generates_custom_type_generators_test() {
  let rendered = harness.render_probe(full_spec())
  assert missing(rendered, [
      "fn gen_type_shape(depth: Int)", "gen_type_shape(3)", "pbt.one_of(",
      "target.Circle(", "target.Square(",
    ])
    == []
}

pub fn rendered_probe_uses_the_probe_result_field_names_test() {
  let rendered = harness.render_probe(full_spec())
  assert missing(rendered, [
      "\"function\"", "\"mutant\"", "\"status\"", "\"inputs\"", "\"expected\"",
      "\"expected_inspect\"", "\"actual_inspect\"", "\"cases\"", "\"shrinks\"",
      "\"reason\"", "\"distinguished\"", "\"indistinguishable\"",
      "append_result(",
    ])
    == []
}

pub fn rendered_probe_writes_its_results_to_the_baked_in_file_test() {
  let rendered = harness.render_probe(full_spec())
  assert missing(rendered, [
      "const results_path = \"" <> results_path <> "\"",
      "@external(erlang, \"gleam_mutants_probe_ab12cd34ef56_ffi\", \"append_result\")",
      "fn append_result(path: String, line: String) -> Nil",
      "append_result(\n    results_path,\n    json_object([",
      "io.println(\"5 results written\")",
    ])
    == []

  // A result line runs to kilobytes and a host reads a child's stdout through
  // a bounded window: nothing but the closing count is printed.
  assert occurrences(rendered, "io.println(") == 1
}

pub fn rendered_probe_reports_the_mutants_one_input_kills_test() {
  let rendered = harness.render_probe(full_spec())
  let assert [first, second, ..] = mutant_ids()

  // Every result line carries a kill set, and the search of a function knows
  // the whole list of that function's mutants to play the shrunk input
  // against — `is_positive` carries two.
  assert missing(rendered, [
      "\"kills\"",
      "[" <> literal(first) <> ", " <> literal(second) <> "]",
    ])
    == []
}

pub fn rendered_probe_checks_the_original_for_nondeterminism_test() {
  let rendered = harness.render_probe(full_spec())
  assert missing(rendered, [
      "\"nondeterministic\"", "7919",
      "original produced different results for the same input",
      "original timed out",
    ])
    == []
}

// --- the rendered Erlang FFI -------------------------------------------------

pub fn rendered_ffi_isolates_the_call_in_a_spawned_process_test() {
  let rendered = harness.render_ffi(full_spec())
  assert missing(rendered, [
      "-module(gleam_mutants_probe_ab12cd34ef56_ffi).",
      "-export([isolated/3, append_result/2]).", "spawn_monitor",
      "gleam_mutants_active", "{value,", "{panic,", "timeout", "'DOWN'",
      "make_ref()", "kill", "~p",
    ])
    == []
}

pub fn rendered_ffi_pins_the_active_mutant_in_the_child_test() {
  let rendered = harness.render_ffi(full_spec())
  // The original runs with an empty id rather than with no id at all, so a
  // stray persistent term or environment variable cannot select a mutant.
  assert missing(rendered, ["put(gleam_mutants_active, Mutant)"]) == []
  assert present(rendered, ["case Mutant of"]) == []
}

pub fn rendered_ffi_appends_one_result_line_to_the_file_test() {
  let rendered = harness.render_ffi(full_spec())
  assert missing(rendered, [
      "append_result(Path, Line) ->", "file:write_file(Path,", "[append]",
    ])
    == []
}

pub fn rendered_ffi_is_named_after_the_spec_test() {
  let renamed =
    ProbeSpec(..spec_for([]), ffi_module: "gleam_mutants_probe_99_ffi")
  assert missing(harness.render_ffi(renamed), [
      "-module(gleam_mutants_probe_99_ffi).",
    ])
    == []
  assert present(harness.render_ffi(renamed), [
      "gleam_mutants_probe_ab12cd34ef56_ffi",
    ])
    == []
}

// --- printing values as Gleam source -----------------------------------------
//
// These check the expressions the probe actually ships, so a change to the
// printers has to change these too.

pub fn value_printer_renders_scalars_test() {
  assert printer(IntSpec) == "int.to_string(value)"
  assert printer(FloatSpec) == "float.to_string(value)"
  assert printer(BoolSpec) == "show_bool(value)"
  assert printer(StringSpec) == "show_string(value)"
  assert printer(NilSpec) == "show_nil(value)"
  assert printer(BitArraySpec) == "show_bit_array(value)"
}

pub fn value_printer_renders_containers_test() {
  assert printer(ListSpec(IntSpec))
    == "show_list(value, fn(v0) { int.to_string(v0) })"
  assert printer(OptionSpec(ListSpec(StringSpec)))
    == "show_option(value, fn(v0) { show_list(v0, fn(v1) { show_string(v1) }) })"
  assert printer(ResultSpec(IntSpec, StringSpec))
    == "show_result(value, fn(v0) { int.to_string(v0) }, fn(v1) { show_string(v1) })"
  assert printer(TupleSpec([IntSpec, StringSpec]))
    == "\"#(\" <> int.to_string(value.0) <> \", \" <> show_string(value.1) <> \")\""
  assert printer(TupleSpec([])) == "\"#()\""
}

pub fn value_printer_names_the_printer_of_a_custom_type_test() {
  assert printer(CustomSpec("Shape", [], [])) == "show_type_shape(value)"
  assert printer(CustomSpec("MyShape", [], [])) == "show_type_my_shape(value)"
  assert printer(RecursiveRef("Shape")) == "show_type_shape(value)"
}

/// One instantiation of `pub type Box(a) { Box(inner: a) }`.
fn box_spec(inner: genspec.GenSpec) -> genspec.GenSpec {
  CustomSpec("Box", [inner], [
    VariantSpec("Box", [FieldSpec(Some("inner"), inner)]),
  ])
}

pub fn value_printer_separates_two_instantiations_of_one_type_test() {
  // `Box(Int)` and `Box(String)` hold different values, so one printer
  // cannot serve both.
  assert printer(box_spec(IntSpec)) != printer(box_spec(StringSpec))
}

pub fn printer_helpers_carry_one_printer_per_instantiation_test() {
  let helpers =
    harness.render_printer_helpers("app/util", [
      box_spec(IntSpec),
      box_spec(StringSpec),
    ])
  assert list.length(helpers_named(helpers, "show_type_")) == 2
  assert missing(helpers, [
      "value: target.Box(Int)", "value: target.Box(String)",
    ])
    == []
  assert present(helpers, ["value: target.Box)"]) == []
}

pub fn value_printer_discards_a_binding_it_never_reads_test() {
  // Printing an empty tuple never reads the value, and Gleam rejects a
  // closure parameter nothing uses.
  assert printer(ListSpec(TupleSpec([])))
    == "show_list(value, fn(_v0) { \"#()\" })"
}

pub fn printer_helpers_carry_only_what_the_specs_need_test() {
  assert harness.render_printer_helpers("boundary", [IntSpec, FloatSpec]) == ""

  let texts = harness.render_printer_helpers("boundary", [ListSpec(StringSpec)])
  assert missing(texts, [
      "fn show_string(value: String) -> String {", "fn escape_source(",
      "fn show_list(",
    ])
    == []
  assert present(texts, [
      "fn show_bool(", "fn show_nil(", "fn show_bit_array(", "fn show_option(",
      "fn show_result(",
    ])
    == []
}

pub fn printer_helpers_qualify_constructors_with_the_module_test() {
  let variants = [
    VariantSpec("Ctor", [FieldSpec(None, IntSpec), FieldSpec(None, BoolSpec)]),
    VariantSpec("Empty", []),
  ]
  let helpers =
    harness.render_printer_helpers("app/util", [
      CustomSpec("Ctor", [], variants),
    ])
  assert missing(helpers, [
      "fn show_type_ctor(value: target.Ctor) -> String {",
      "target.Ctor(f0, f1) ->", "\"util.Ctor(\"",
      "target.Empty -> \"util.Empty\"", "fn show_bool(",
    ])
    == []
}

/// A record with labelled fields prints with its labels.
///
/// `score.Score(1, 0, -1, 0, 0, 0.0)` is a value a reviewer cannot read: six
/// positional fields, and no way to tell which is which without opening the
/// type. `gleam format` cannot recover the intent, so the printer has to write
/// it down.
pub fn printer_helpers_render_labelled_fields_with_their_labels_test() {
  let helpers =
    harness.render_printer_helpers("app/score", [
      CustomSpec("Score", [], [
        VariantSpec("Score", [
          FieldSpec(Some("total"), IntSpec),
          FieldSpec(Some("killed"), IntSpec),
        ]),
        VariantSpec("Mixed", [
          FieldSpec(Some("first"), IntSpec),
          FieldSpec(None, BoolSpec),
        ]),
        VariantSpec("Bare", [FieldSpec(None, IntSpec)]),
      ]),
    ])
  assert missing(helpers, [
      "\"score.Score(\"", "\"total: \"", "\"killed: \"", "\"first: \"",
      "\"score.Bare(\"",
    ])
    == []
}

/// An unlabelled field keeps its position and gains no label.
pub fn printer_helpers_leave_an_unlabelled_field_positional_test() {
  let helpers =
    harness.render_printer_helpers("app/util", [
      CustomSpec("Ctor", [], [
        VariantSpec("Ctor", [
          FieldSpec(None, IntSpec),
          FieldSpec(None, BoolSpec),
        ]),
      ]),
    ])
  assert present(helpers, [": \" <>"]) == []
}

pub fn printer_helpers_render_the_bits_a_byte_does_not_hold_test() {
  // A bit array that is not a whole number of bytes still has to print as
  // source that rebuilds it, which needs a sized final segment.
  //
  // What the helper *answers* for `<<>>`, `<<7, 8>>`, `<<0:4>>` and
  // `<<255, 1:1>>` is pinned by `printer_cases` below, which runs this very
  // helper inside the live snapshot: it is generated Gleam source, so only a
  // compiler can say what it prints, and restating its rules here would pin a
  // second implementation rather than the shipped one. What is left to check
  // on the text is that it has a case for the empty array and one per width a
  // byte does not hold.
  let helpers = harness.render_printer_helpers("boundary", [BitArraySpec])
  assert missing(helpers, ["0 -> \"<<>>\"", ":size("]) == []
  assert list.filter(["1", "2", "3", "4", "5", "6", "7"], fn(size) {
      !string.contains(helpers, "<<bits:size(" <> size <> ")>>")
    })
    == []
}

pub fn printer_helpers_escape_the_source_they_render_test() {
  // The escaping rules live in the generated `escape_source`, so the check is
  // on the source of that function.
  let escapes =
    function_source(
      harness.render_printer_helpers("boundary", [StringSpec]),
      "escape_source",
    )
  assert missing(escapes, [
      "\"\\\\\" -> \"\\\\\\\\\"", "\"\\\"\" -> \"\\\\\\\"\"",
      "\"\\n\" -> \"\\\\n\"", "\"\\r\" -> \"\\\\r\"", "\"\\t\" -> \"\\\\t\"",
    ])
    == []
}

// --- more modules under test -------------------------------------------------

/// Mutually recursive public types: the depth budget has to survive the hop.
const mutual_source = "pub type Expr {
  Num(value: Int)
  Block(body: Stmt)
}

pub type Stmt {
  Nop
  Print(value: Expr)
}

pub fn evaluate(expr: Expr) -> Int {
  todo
}

pub fn describe(statement: Stmt) -> Int {
  todo
}

pub fn both(expr: Expr, statement: Stmt) -> Int {
  todo
}

pub fn convert(expr: Expr) -> Stmt {
  todo
}
"

/// A custom type that is only ever printed, never generated.
const return_only_source = "pub type Shape {
  Circle(radius: Int)
  Square(side: Int)
}

pub fn make(n: Int) -> Shape {
  todo
}
"

/// A module whose every public function returns an unprintable value.
const all_none_source = "pub opaque type Secret {
  Secret(n: Int)
}

pub fn hidden(n: Int) -> Secret {
  todo
}
"

/// A parameter with no components at all.
const empty_tuple_source = "pub fn unit0(x: #()) -> Int {
  todo
}
"

/// Variant fields with no components at all: the printer binds one name per
/// field, and a field that prints without being read has to be discarded.
const unit_field_source = "pub type Box {
  Box(u: #())
}

pub type Pair {
  Pair(a: Int, u: #())
}

pub fn open(b: Box) -> Int {
  todo
}

pub fn split(p: Pair) -> Int {
  todo
}
"

/// A parameterised type used at two instantiations, a recursive parameterised
/// type, one that is only ever returned, one whose recursion runs through
/// another parameterised type, a pair of parameterised types that recurse
/// through each other at one instantiation, a phantom parameter that only an
/// annotation ever mentions, and two instantiations inside one variant.
const generic_source = "pub type Box(a) {
  Box(inner: a)
}

pub type Tree(a) {
  Leaf
  Node(Tree(a), a, Tree(a))
}

pub type Nest(a) {
  Tip
  Fork(Box(Nest(a)), a)
}

pub type Tagged(a) {
  Tagged(n: Int)
}

pub type Both {
  Both(Box(Int), Box(String))
}

pub type Chain(a) {
  ChainEnd
  ChainMore(Link(a))
}

pub type Link(a) {
  Link(a, Chain(a))
}

pub fn walk(c: Chain(Int)) -> Int {
  todo
}

pub fn pairup(x: Box(Int), y: Box(String)) -> Int {
  todo
}

pub fn wrap(x: Int) -> Box(Int) {
  todo
}

pub fn total(t: Tree(Int)) -> Int {
  todo
}

pub fn nested(x: Nest(Int), y: Nest(String)) -> Int {
  todo
}

pub fn use_tag(t: Tagged(Option(Int))) -> Int {
  todo
}

pub fn unpack(b: Both) -> Int {
  todo
}
"

fn spec_in(
  source: String,
  functions: List(#(String, List(String))),
) -> harness.ProbeSpec {
  spec_for(
    list.map(functions, fn(entry) {
      ProbeFunction(
        plan: plan_in(source, entry.0),
        mutant_ids: entry.1,
        hints: hints.harvest(function_in(source, entry.0)),
      )
    }),
  )
}

// --- what the Gleam compiler would reject ------------------------------------

/// The source with its import lines removed, so a qualifier that only appears
/// in an import does not count as a use of that import.
fn body_without_imports(source: String) -> String {
  source
  |> string.split("\n")
  |> list.filter(fn(line) { !string.starts_with(line, "import ") })
  |> string.join("\n")
}

/// The top-level chunk of `source` that defines `name`.
fn function_source(source: String, name: String) -> String {
  let assert Ok(found) =
    list.find(string.split(source, "\n\n"), fn(chunk) {
      string.starts_with(chunk, "fn " <> name <> "(")
      || string.starts_with(chunk, "pub fn " <> name <> "(")
    })
  found
}

/// The names of the functions `source` defines, in source order.
fn defined_functions(source: String) -> List(String) {
  let assert Ok(module) = glance.module(source)
  list.map(module.functions, fn(definition) { definition.definition.name })
}

/// The distinct names `source` defines that start with `prefix`.
fn helpers_named(source: String, prefix: String) -> List(String) {
  source
  |> defined_functions
  |> list.filter(string.starts_with(_, prefix))
  |> list.unique
}

/// Private functions the module declares but never mentions again, each of
/// which the compiler reports as an unused private function.
fn unused_private_functions(source: String) -> List(String) {
  let assert Ok(module) = glance.module(source)
  module.functions
  |> list.map(fn(definition) { definition.definition })
  |> list.filter(fn(function) { function.publicity == glance.Private })
  |> list.map(fn(function) { function.name })
  |> list.filter(fn(name) { occurrences(source, name) < 2 })
}

/// Constructors the module declares but never builds or matches on.
fn unused_constructors(source: String) -> List(String) {
  let assert Ok(module) = glance.module(source)
  module.custom_types
  |> list.flat_map(fn(definition) { definition.definition.variants })
  |> list.map(fn(variant) { variant.name })
  |> list.filter(fn(name) { occurrences(source, name) < 2 })
}

/// Imports whose qualifier and unqualified names are never used.
fn unused_imports(source: String) -> List(String) {
  let body = body_without_imports(source)
  let assert Ok(module) = glance.module(source)
  module.imports
  |> list.map(fn(definition) { definition.definition })
  |> list.filter(fn(imported) { !import_used(body, imported) })
  |> list.map(fn(imported) { imported.module })
}

fn import_used(body: String, imported: glance.Import) -> Bool {
  let qualifier = case imported.alias {
    Some(glance.Named(alias)) -> alias
    _ ->
      case list.last(string.split(imported.module, "/")) {
        Ok(segment) -> segment
        Error(_) -> imported.module
      }
  }
  let unqualified =
    imported.unqualified_types
    |> list.append(imported.unqualified_values)
    |> list.map(fn(item) { option.unwrap(item.alias, item.name) })
  occurrences(body, qualifier <> ".") > 0
  || list.any(unqualified, fn(name) { occurrences(body, name) > 0 })
}

/// Constructor pattern variables whose clause body never reads them, each of
/// which the compiler reports as an unused variable.
///
/// Every such pattern the renderer writes sits on its own line, ending in
/// `) ->`, with the clause body on the line below it.
fn unused_pattern_variables(source: String) -> List(String) {
  let lines = string.split(source, "\n")
  list.zip(lines, list.drop(lines, 1))
  |> list.flat_map(fn(pair) {
    let #(pattern, body) = pair
    let trimmed = string.trim(pattern)
    case
      string.starts_with(trimmed, "target."),
      string.ends_with(trimmed, ") ->")
    {
      True, True ->
        trimmed
        |> pattern_variables
        |> list.filter(fn(name) { !string.starts_with(name, "_") })
        |> list.filter(fn(name) { !string.contains(body, name) })
      _, _ -> []
    }
  })
}

fn pattern_variables(pattern: String) -> List(String) {
  case string.split_once(pattern, "(") {
    Ok(#(_, arguments)) ->
      case string.split_once(arguments, ")") {
        Ok(#(inside, _)) -> string.split(inside, ", ")
        Error(_) -> []
      }
    Error(_) -> []
  }
}

/// Every probe of the milestone, so one check can sweep them all.
fn every_probe_spec() -> List(#(String, harness.ProbeSpec)) {
  [
    #("mixed", full_spec()),
    #("mutual", spec_in(mutual_source, [#("evaluate", ["m1"])])),
    #(
      "mutual pair",
      spec_in(mutual_source, [#("evaluate", ["m1"]), #("describe", ["m2"])]),
    ),
    #("mutual both", spec_in(mutual_source, [#("both", ["m1"])])),
    #("mutual convert", spec_in(mutual_source, [#("convert", ["m1"])])),
    #("return only", spec_in(return_only_source, [#("make", ["m1"])])),
    #("all none", spec_in(all_none_source, [#("hidden", ["m1"])])),
    #("empty tuple", spec_in(empty_tuple_source, [#("unit0", ["m1"])])),
    #(
      "unit field",
      spec_in(unit_field_source, [#("open", ["m1"]), #("split", ["m2"])]),
    ),
    #("generic pair", spec_in(generic_source, [#("pairup", ["m1"])])),
    #("generic return", spec_in(generic_source, [#("wrap", ["m1"])])),
    #("generic tree", spec_in(generic_source, [#("total", ["m1"])])),
    #("generic nest", spec_in(generic_source, [#("nested", ["m1"])])),
    #("generic tagged", spec_in(generic_source, [#("use_tag", ["m1"])])),
    #("generic variant", spec_in(generic_source, [#("unpack", ["m1"])])),
    #("generic cycle", spec_in(generic_source, [#("walk", ["m1"])])),
    #(
      "generic all",
      spec_in(generic_source, [
        #("pairup", ["m1"]),
        #("wrap", ["m2"]),
        #("total", ["m3"]),
        #("nested", ["m4"]),
        #("use_tag", ["m5"]),
        #("unpack", ["m6"]),
        #("walk", ["m7"]),
      ]),
    ),
  ]
}

fn every_rendered_probe() -> List(#(String, String)) {
  list.map(every_probe_spec(), fn(entry) {
    #(entry.0, harness.render_probe(entry.1))
  })
}

pub fn rendered_probe_never_declares_a_helper_it_does_not_use_test() {
  assert list.filter_map(every_rendered_probe(), fn(entry) {
      case unused_private_functions(entry.1) {
        [] -> Error(Nil)
        unused -> Ok(#(entry.0, unused))
      }
    })
    == []
}

pub fn rendered_probe_never_declares_a_constructor_it_does_not_use_test() {
  assert list.filter_map(every_rendered_probe(), fn(entry) {
      case unused_constructors(entry.1) {
        [] -> Error(Nil)
        unused -> Ok(#(entry.0, unused))
      }
    })
    == []
}

pub fn rendered_probe_never_declares_an_import_it_does_not_use_test() {
  assert list.filter_map(every_rendered_probe(), fn(entry) {
      case unused_imports(entry.1) {
        [] -> Error(Nil)
        unused -> Ok(#(entry.0, unused))
      }
    })
    == []
}

pub fn rendered_probe_never_binds_a_pattern_variable_it_does_not_read_test() {
  assert list.filter_map(every_rendered_probe(), fn(entry) {
      case unused_pattern_variables(entry.1) {
        [] -> Error(Nil)
        unused -> Ok(#(entry.0, unused))
      }
    })
    == []
}

pub fn rendered_probe_discards_a_variant_field_it_never_prints_test() {
  let rendered =
    harness.render_probe(
      spec_in(unit_field_source, [#("open", ["m1"]), #("split", ["m2"])]),
    )
  assert missing(function_source(rendered, "show_type_box"), [
      "target.Box(_f0) ->",
    ])
    == []
  assert missing(function_source(rendered, "show_type_pair"), [
      "target.Pair(f0, _f1) ->",
    ])
    == []
}

pub fn every_rendered_probe_parses_test() {
  assert list.filter(every_rendered_probe(), fn(entry) {
      !result.is_ok(glance.module(entry.1))
    })
    == []
}

// --- recursion is bounded ----------------------------------------------------

pub fn rendered_probe_spends_depth_on_every_custom_type_hop_test() {
  let rendered =
    harness.render_probe(spec_in(mutual_source, [#("evaluate", ["m1"])]))

  // The search enters the type at the initial depth ...
  assert missing(function_source(rendered, "gen_evaluate"), ["gen_type_expr(3)"])
    == []

  // ... and every hop from there on spends one unit of it, so that a cycle
  // between two types cannot reset the budget and generate for ever.
  assert present(function_source(rendered, "gen_type_expr"), [
      "gen_type_expr(3)", "gen_type_stmt(3)",
    ])
    == []
  assert missing(function_source(rendered, "gen_type_expr"), [
      "gen_type_stmt(depth - 1)",
    ])
    == []
  assert present(function_source(rendered, "gen_type_stmt"), [
      "gen_type_expr(3)", "gen_type_stmt(3)",
    ])
    == []
  assert missing(function_source(rendered, "gen_type_stmt"), [
      "gen_type_expr(depth - 1)",
    ])
    == []
}

pub fn rendered_probe_omits_a_generator_for_a_type_it_only_prints_test() {
  let rendered =
    harness.render_probe(spec_in(return_only_source, [#("make", ["m1"])]))
  assert present(rendered, ["fn gen_type_shape("]) == []
  assert missing(rendered, [
      "fn show_type_shape(", "fn show_result_make(", "target.Circle(",
    ])
    == []
}

pub fn rendered_probe_normalises_every_observation_test() {
  let rendered =
    harness.render_probe(spec_in(all_none_source, [#("hidden", ["m1"])]))
  assert missing(function_source(rendered, "normalise"), [
      "Value(", "Panic(_) -> Panic(\"\")", "Timeout",
    ])
    == []
}

pub fn rendered_probe_refuses_a_type_with_no_finite_values_test() {
  // `typederive` rejects such a type before it reaches the renderer, so this
  // plan is built by hand; the generator still has to type check.
  let plan =
    typederive.FunctionPlan(
      name: "spin",
      parameters: [
        typederive.ParameterPlan(
          name: "value",
          label: None,
          spec: CustomSpec("Loop", [], [
            VariantSpec("Loop", [FieldSpec(None, RecursiveRef("Loop"))]),
          ]),
        ),
      ],
      return_spec: None,
    )
  let rendered =
    harness.render_probe(spec_for([ProbeFunction(plan, ["m1"], hints.none())]))
  assert result.is_ok(glance.module(rendered))
  assert missing(rendered, [
      "panic as \"gleam_mutants: Loop has no values to generate\"",
    ])
    == []
  assert present(rendered, ["pbt.nil()"]) == []
}

pub fn rendered_probe_prints_the_empty_tuple_test() {
  let rendered =
    harness.render_probe(spec_in(empty_tuple_source, [#("unit0", ["m1"])]))
  assert missing(function_source(rendered, "show_args_unit0"), ["\"#()\""])
    == []
  assert present(function_source(rendered, "show_args_unit0"), [
      "\"#(\" <>  <>",
    ])
    == []
}

// --- parameterised custom types ---------------------------------------------

pub fn rendered_probe_separates_two_instantiations_of_one_type_test() {
  let rendered =
    harness.render_probe(spec_in(generic_source, [#("pairup", ["m1"])]))

  // `Box(Int)` and `Box(String)` are two types, so they need two generators
  // and two printers rather than one keyed by the name they share.
  assert list.length(helpers_named(rendered, "gen_type_")) == 2
  assert list.length(helpers_named(rendered, "show_type_")) == 2

  // A parameterised type is annotated with its arguments; the bare name is
  // not a type the compiler accepts.
  assert missing(rendered, ["target.Box(Int)", "target.Box(String)"]) == []
  assert present(rendered, ["target.Box)", "target.Box,", "target.Box "]) == []
}

pub fn rendered_probe_annotates_a_parameterised_return_type_test() {
  let rendered =
    harness.render_probe(spec_in(generic_source, [#("wrap", ["m1"])]))
  assert missing(rendered, [
      "fn show_result_wrap(value: target.Box(Int)) -> String",
    ])
    == []
  // Only ever returned, so it is printed and never generated.
  assert present(rendered, ["fn gen_type_box"]) == []
  assert result.is_ok(glance.module(rendered))
}

pub fn rendered_probe_annotates_a_recursive_parameterised_type_test() {
  let rendered =
    harness.render_probe(spec_in(generic_source, [#("total", ["m1"])]))
  assert missing(rendered, ["target.Tree(Int)"]) == []
  assert present(rendered, ["target.Tree)", "target.Tree,", "target.Tree "])
    == []

  // The recursive hop names the very helper it sits in, at one less depth.
  let assert [generator] = helpers_named(rendered, "gen_type_")
  assert missing(function_source(rendered, generator), [
      generator <> "(depth - 1)",
    ])
    == []
  let assert [shown] = helpers_named(rendered, "show_type_")
  assert occurrences(function_source(rendered, shown), shown <> "(") >= 2
}

pub fn rendered_probe_keeps_one_helper_per_instantiation_of_a_shared_type_test() {
  let rendered =
    harness.render_probe(
      spec_in(generic_source, [
        #("pairup", ["m1"]),
        #("wrap", ["m2"]),
        #("total", ["m3"]),
      ]),
    )
  // Box(Int), Box(String) and Tree(Int) are three types: one printer and one
  // generator each, with `wrap`'s return sharing `pairup`'s `Box(Int)`.
  assert list.length(helpers_named(rendered, "show_type_")) == 3
  assert list.length(helpers_named(rendered, "gen_type_")) == 3
  assert result.is_ok(glance.module(rendered))
}

pub fn rendered_probe_separates_a_type_reached_through_a_recursive_hop_test() {
  // `Nest(a)` holds a `Box(Nest(a))`, so the argument of that box is the
  // reference back at the enclosing instantiation: `Box(Nest(Int))` inside
  // `Nest(Int)` and `Box(Nest(String))` inside `Nest(String)` are two types.
  let spec = spec_in(generic_source, [#("nested", ["m1"])])
  assert harness.check_spec(spec) == Ok(Nil)
  let rendered = harness.render_probe(spec)
  assert list.length(helpers_named(rendered, "gen_type_")) == 4
  assert list.length(helpers_named(rendered, "show_type_")) == 4
  assert missing(rendered, [
      "target.Box(target.Nest(Int))", "target.Box(target.Nest(String))",
    ])
    == []
}

pub fn rendered_probe_keeps_two_instantiations_inside_one_variant_apart_test() {
  // `Both(Box(Int), Box(String))` reaches one type at two instantiations
  // through a single variant.
  let rendered =
    harness.render_probe(spec_in(generic_source, [#("unpack", ["m1"])]))
  assert list.length(helpers_named(rendered, "gen_type_")) == 3
  assert missing(rendered, [
      "value: target.Box(Int)", "value: target.Box(String)",
    ])
    == []
}

pub fn rendered_probe_imports_a_type_only_an_annotation_mentions_test() {
  // The phantom parameter of `Tagged(a)` reaches no variant, so nothing
  // generates or prints an `Option` here — but the annotations still name the
  // type, and a name the probe writes has to be a name it imports.
  let rendered =
    harness.render_probe(spec_in(generic_source, [#("use_tag", ["m1"])]))
  assert missing(rendered, [
      "import gleam/option.{type Option}", "target.Tagged(Option(Int))",
    ])
    == []
  // Importing `Some` and `None` where no printer matches on them would itself
  // be a warning.
  assert present(rendered, ["import gleam/option.{type Option, None, Some}"])
    == []
  assert unused_imports(rendered) == []
}

// --- names that could clash --------------------------------------------------

/// Two functions whose helpers land on names the probe already uses: one on a
/// type generator, one on a baked-in constant.
const clashing_source = "pub type Shape {
  Circle(radius: Int)
}

pub fn type_shape(shape: Shape) -> Int {
  todo
}

pub fn seed(n: Int) -> Int {
  todo
}
"

/// A function taking two types whose names differ only in where the case
/// changes, which a plain lower-casing would map onto one helper.
fn case_clash_spec() -> harness.ProbeSpec {
  let plan =
    typederive.FunctionPlan(
      name: "both",
      parameters: [
        typederive.ParameterPlan(
          name: "first",
          label: None,
          spec: CustomSpec("ABc", [], [
            VariantSpec("MakeA", [FieldSpec(None, IntSpec)]),
          ]),
        ),
        typederive.ParameterPlan(
          name: "second",
          label: None,
          spec: CustomSpec("Abc", [], [
            VariantSpec("MakeB", [FieldSpec(None, IntSpec)]),
          ]),
        ),
      ],
      return_spec: None,
    )
  spec_for([ProbeFunction(plan, ["m1"], hints.none())])
}

pub fn check_spec_accepts_a_probe_whose_helpers_are_unique_test() {
  assert harness.check_spec(full_spec()) == Ok(Nil)
  assert list.filter_map(every_probe_spec(), fn(entry) {
      case harness.check_spec(entry.1) {
        Ok(Nil) -> Error(Nil)
        Error(message) -> Ok(#(entry.0, message))
      }
    })
    == []
}

pub fn check_spec_accepts_two_ways_into_one_recursion_cycle_test() {
  // Two mutually recursive types are one cycle with two entrances, and each
  // entrance unrolls it differently: `Expr` holds a `Stmt` that points back at
  // `Expr`, while `Stmt` holds an `Expr` that points back at `Stmt`. Both
  // unrollings describe the same pair of types, so the name guard has to
  // compare the instantiation rather than the shape it was reached through.
  let ways = [
    spec_in(mutual_source, [#("evaluate", ["m1"]), #("describe", ["m2"])]),
    spec_in(mutual_source, [#("both", ["m1"])]),
    spec_in(mutual_source, [#("convert", ["m1"])]),
  ]
  assert list.filter_map(ways, fn(spec) {
      case harness.check_spec(spec) {
        Ok(Nil) -> Error(Nil)
        Error(message) -> Ok(message)
      }
    })
    == []

  // ... and one helper per type, however many ways in there are.
  let rendered =
    harness.render_probe(
      spec_in(mutual_source, [#("evaluate", ["m1"]), #("describe", ["m2"])]),
    )
  assert list.length(helpers_named(rendered, "gen_type_")) == 2
  assert list.length(helpers_named(rendered, "show_type_")) == 2
}

pub fn check_spec_reports_a_helper_named_after_a_type_generator_test() {
  let assert Error(message) =
    harness.check_spec(spec_in(clashing_source, [#("type_shape", ["m1"])]))
  // Every other wall a suggest run can hit is reported with a code, and this
  // one is no different: a user who reads it can look it up.
  assert string.starts_with(message, "GMU8007: ")
  assert string.contains(message, "gen_type_shape")
}

pub fn check_spec_reports_a_helper_that_shadows_a_constant_test() {
  let assert Error(message) =
    harness.check_spec(spec_in(clashing_source, [#("seed", ["m1"])]))
  assert string.starts_with(message, "GMU8007: ")
  assert string.contains(message, "probe_seed")
}

pub fn check_spec_reports_two_instantiations_that_share_a_helper_name_test() {
  // A helper is named after its type and a readable fingerprint of the type's
  // arguments, so `Box(Int)` and a type called `BoxInt` both ask for
  // `show_type_box_int` — and one helper cannot serve two types.
  let plan =
    typederive.FunctionPlan(
      name: "both",
      parameters: [
        typederive.ParameterPlan(
          name: "first",
          label: None,
          spec: box_spec(IntSpec),
        ),
        typederive.ParameterPlan(
          name: "second",
          label: None,
          spec: CustomSpec("BoxInt", [], [
            VariantSpec("BoxInt", [FieldSpec(None, IntSpec)]),
          ]),
        ),
      ],
      return_spec: None,
    )
  let assert Error(message) =
    harness.check_spec(spec_for([ProbeFunction(plan, ["m1"], hints.none())]))
  assert string.starts_with(message, "GMU8008: ")
  assert string.contains(message, "box_int")
  // Naming the key alone leaves the reader hunting for the pair that asked
  // for it, so the message writes both types the way the probe would.
  assert string.contains(message, "target.Box(Int)")
  assert string.contains(message, "target.BoxInt")
}

pub fn type_helpers_stay_distinct_when_names_differ_only_in_case_test() {
  let spec = case_clash_spec()
  assert harness.check_spec(spec) == Ok(Nil)
  assert missing(harness.render_probe(spec), [
      "fn gen_type_abc(", "fn gen_type_a_bc(", "fn show_type_abc(",
      "fn show_type_a_bc(",
    ])
    == []
}

// --- the rendered probe inside a real snapshot -------------------------------
//
// Everything above asserts on text. This last check writes a snapshot-shaped
// project, compiles it with `--warnings-as-errors` and runs every probe, which
// is the only way to catch a rendered module that does not type check, warns,
// or never terminates. It also runs the printers the probe ships over values
// picked here, which is the only way to check what they print rather than
// what they are made of.
//
// Nothing between creating the project and deleting it asserts: a red run
// would otherwise leave a build tree behind on every retry.

@target(erlang)
type LiveProbe {
  LiveProbe(spec: harness.ProbeSpec, source: String)
}

@target(erlang)
/// One value the shipped printers have to render: the Gleam source that
/// builds it, and the source the printer must answer with.
type PrinterCase {
  PrinterCase(spec: genspec.GenSpec, value: String, expected: String)
}

@target(erlang)
/// What one `gleam run -m <module>` answered.
type ProbeRun {
  ProbeRun(
    module: String,
    status: Int,
    timed_out: Bool,
    stdout: String,
    stderr: String,
    results: List(probe_result.ProbeResult),
    failures: List(String),
  )
}

@target(erlang)
/// Everything the live check collects before it deletes the project.
type LiveRun {
  LiveRun(
    build_status: Int,
    build_output: String,
    shapes: ProbeRun,
    returns: ProbeRun,
    secrets: ProbeRun,
    mutual: ProbeRun,
    captured: ProbeRun,
    paths: ProbeRun,
    printer: ProbeRun,
    cases: List(PrinterCase),
  )
}

@target(erlang)
/// True when `rendered` is a Gleam float literal: it parses and has a point.
fn is_float_literal(rendered: String) -> Bool {
  let source = "pub fn probe() -> Float {\n  " <> rendered <> "\n}\n"
  case glance.module(source) {
    Ok(_) -> string.contains(rendered, ".")
    Error(_) -> False
  }
}

@target(erlang)
fn live_root() -> String {
  let root =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-probe-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(path.join(root, "src"))
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
fn project_toml() -> String {
  string.join(
    [
      "name = \"gleam_mutants_probe_check\"", "version = \"0.0.0\"", "",
      "[dependencies]", "gleam_stdlib = \">= 0.44.0 and < 2.0.0\"",
    ],
    "\n",
  )
  <> "\n"
}

@target(erlang)
/// One mutation site in the shape the instrumenter writes it.
fn select(
  runtime_module: String,
  mutant: String,
  original: String,
  replacement: String,
) -> String {
  runtime_module
  <> ".select(\""
  <> mutant
  <> "\", fn() { "
  <> original
  <> " }, fn() { "
  <> replacement
  <> " })"
}

@target(erlang)
/// Arity 0 to 5, a custom-type parameter, a variant field with no components,
/// a panicking mutant, a hanging mutant, an equivalent mutant and a
/// nondeterministic original.
fn shapes_target(rt: String) -> String {
  string.join(
    [
      "import gleam/float",
      "import gleam/int",
      "import gleam/list",
      "import gleam/string",
      "import " <> rt,
      "",
      "pub type Shape {",
      "  Circle(radius: Int)",
      "  Square(side: Int)",
      "}",
      "",
      "pub type Box {",
      "  Box(u: #())",
      "}",
      "",
      "pub type Pair {",
      "  Pair(a: Int, u: #())",
      "}",
      "",
      "pub fn is_positive(value: Int) -> Bool {",
      "  " <> select(rt, "m_positive", "value > 0", "value < 0"),
      "}",
      "",
      "pub fn area(shape: Shape) -> Int {",
      "  case shape {",
      "    Circle(radius) -> "
        <> select(rt, "m_area", "3 * radius", "4 * radius"),
      "    Square(side) -> side * side",
      "  }",
      "}",
      "",
      "pub fn zero() -> Int {",
      "  " <> select(rt, "m_zero", "0", "1"),
      "}",
      "",
      "pub fn quad(a: Int, b: Int, c: Int, d: Int) -> Int {",
      "  " <> select(rt, "m_quad", "a + b + c + d", "a + b + c - d"),
      "}",
      "",
      "pub fn five(a: Int, b: Int, c: Bool, d: String, e: Float) -> Int {",
      "  let extra = case c {",
      "    True -> string.length(d)",
      "    False -> float.round(e)",
      "  }",
      "  " <> select(rt, "m_five", "a - b + extra", "b - a + extra"),
      "}",
      "",
      "pub fn boom(value: Int) -> Int {",
      "  " <> select(rt, "m_boom", "value", "panic as \"boom\""),
      "}",
      "",
      // The other way around: the original panics for every input, so there
      // is no result for a generated test to state.
      "pub fn always_boom(value: Int) -> Int {",
      "  " <> select(rt, "m_always", "panic as \"always\"", "value"),
      "}",
      "",
      "pub fn steady(value: Int) -> Int {",
      "  " <> select(rt, "m_hang", "value", "spin(value)"),
      "}",
      "",
      "fn spin(value: Int) -> Int {",
      "  case value > 1_000_000_000 {",
      "    True -> value",
      "    False -> spin(value)",
      "  }",
      "}",
      "",
      "pub fn quiet(value: Int) -> Int {",
      "  " <> select(rt, "m_quiet", "value + 0", "value - 0"),
      "}",
      "",
      "pub fn dice(value: Int) -> Int {",
      "  " <> select(rt, "m_dice", "value + int.random(1000)", "value"),
      "}",
      "",
      "pub fn unit0(_x: #()) -> Int {",
      "  " <> select(rt, "m_unit", "0", "1"),
      "}",
      "",
      "pub fn tally(items: List(#())) -> Int {",
      "  list.length(items) + " <> select(rt, "m_tally", "0", "1"),
      "}",
      "",
      "pub fn open(b: Box) -> Int {",
      "  case b {",
      "    Box(_) -> " <> select(rt, "m_open", "0", "1"),
      "  }",
      "}",
      "",
      "pub fn split(p: Pair) -> Int {",
      "  case p {",
      "    Pair(a, _) -> " <> select(rt, "m_split", "a", "a + 1"),
      "  }",
      "}",
      "",
      // Two mutants in one function, each of which every input tells apart:
      // whichever input the search settles on kills both of them.
      "pub fn twins(value: Int) -> Int {",
      "  "
        <> select(rt, "m_twin_a", "value", "value + 1")
        <> " + "
        <> select(rt, "m_twin_b", "0", "1"),
      "}",
    ],
    "\n",
  )
  <> "\n"
}

@target(erlang)
/// The functions of the shapes module the probe plays, in the order it
/// reports them.
fn shapes_functions() -> List(#(String, List(String))) {
  [
    #("is_positive", ["m_positive"]),
    #("area", ["m_area"]),
    #("zero", ["m_zero"]),
    #("quad", ["m_quad"]),
    #("five", ["m_five"]),
    #("boom", ["m_boom"]),
    #("always_boom", ["m_always"]),
    #("steady", ["m_hang"]),
    #("quiet", ["m_quiet"]),
    #("dice", ["m_dice"]),
    #("unit0", ["m_unit"]),
    #("tally", ["m_tally"]),
    #("open", ["m_open"]),
    #("split", ["m_split"]),
    #("twins", ["m_twin_a", "m_twin_b"]),
  ]
}

@target(erlang)
fn shapes_expected() -> List(#(String, String)) {
  [
    #("m_positive", "distinguished"),
    #("m_area", "distinguished"),
    #("m_zero", "distinguished"),
    #("m_quad", "distinguished"),
    #("m_five", "distinguished"),
    #("m_boom", "distinguished"),
    #("m_always", "distinguished"),
    #("m_hang", "distinguished"),
    #("m_quiet", "indistinguishable"),
    #("m_dice", "nondeterministic"),
    #("m_unit", "distinguished"),
    #("m_tally", "distinguished"),
    #("m_open", "distinguished"),
    #("m_split", "distinguished"),
    #("m_twin_a", "distinguished"),
    #("m_twin_b", "distinguished"),
  ]
}

@target(erlang)
/// A custom type reachable only through a result.
fn return_only_target(rt: String) -> String {
  string.join(
    [
      "import " <> rt,
      "",
      "pub type Shape {",
      "  Circle(radius: Int)",
      "  Square(side: Int)",
      "}",
      "",
      "pub fn make(n: Int) -> Shape {",
      "  case " <> select(rt, "m_make", "n > 0", "n < 0") <> " {",
      "    True -> Circle(n)",
      "    False -> Square(n)",
      "  }",
      "}",
    ],
    "\n",
  )
  <> "\n"
}

@target(erlang)
/// A module whose only public function returns an opaque value.
fn opaque_target(rt: String) -> String {
  string.join(
    [
      "import " <> rt,
      "",
      "pub opaque type Secret {",
      "  Secret(n: Int)",
      "}",
      "",
      "pub fn hidden(n: Int) -> Secret {",
      "  Secret(" <> select(rt, "m_hidden", "n", "n + 1") <> ")",
      "}",
    ],
    "\n",
  )
  <> "\n"
}

@target(erlang)
/// Two public types that point at each other.
fn mutual_target(rt: String) -> String {
  string.join(
    [
      "import " <> rt,
      "",
      "pub type Expr {",
      "  Num(value: Int)",
      "  Block(body: Stmt)",
      "}",
      "",
      "pub type Stmt {",
      "  Nop",
      "  Print(value: Expr)",
      "}",
      "",
      "pub fn evaluate(expr: Expr) -> Int {",
      "  case expr {",
      "    Num(value) -> " <> select(rt, "m_eval", "value", "value + 1"),
      "    Block(body) -> describe(body)",
      "  }",
      "}",
      "",
      "pub fn describe(statement: Stmt) -> Int {",
      "  case statement {",
      "    Nop -> " <> select(rt, "m_describe", "0", "1"),
      "    Print(value) -> evaluate(value)",
      "  }",
      "}",
      "",
      "pub fn both(expr: Expr, statement: Stmt) -> Int {",
      "  evaluate(expr) + describe(statement) + "
        <> select(rt, "m_both", "0", "1"),
      "}",
      "",
      "pub fn convert(expr: Expr) -> Stmt {",
      "  Print(Num("
        <> select(rt, "m_convert", "evaluate(expr)", "evaluate(expr) + 1")
        <> "))",
      "}",
    ],
    "\n",
  )
  <> "\n"
}

@target(erlang)
/// A module whose result carries a function value.
///
/// `Wrapper` is a plain named type, so the return is comparable as far as the
/// annotation goes — and at run time it holds a closure. Both mutants change a
/// value the closure captures rather than any code it runs, so the original and
/// the mutant answer with funs that are structurally unequal (Erlang compares a
/// fun by its environment) and that `string.inspect` renders identically. A
/// test written from that separation passes with the mutant in place, so there
/// is no test to write and the probe has to say so.
fn functional_target(rt: String) -> String {
  string.join(
    [
      "import " <> rt,
      "",
      "pub type Wrapper {",
      "  Wrapper(f: fn(Int) -> Int)",
      "}",
      "",
      "pub fn make(x: Int) -> Wrapper {",
      "  let base = " <> select(rt, "m_capture", "x + 1", "x - 1"),
      "  let scale = " <> select(rt, "m_scale", "2", "3"),
      "  Wrapper(fn(y) { base + scale * y })",
      "}",
    ],
    "\n",
  )
  <> "\n"
}

@target(erlang)
/// A module whose mutant is separated by a literal it writes down itself.
///
/// `strip` answers differently only for a string starting `"./"`, and a
/// uniform draw over 0 to 20 printable ASCII characters produces one about
/// once in nine thousand: 25 cases never reach it, and neither did 2000 on
/// real code. The literal is right there in the source, so the generator of
/// `s` is told about it and the search finds `"./"` in a handful of draws.
fn paths_target(rt: String) -> String {
  string.join(
    [
      "import gleam/string",
      "import " <> rt,
      "",
      "pub fn strip(s: String) -> String {",
      "  case string.starts_with(s, \"./\") {",
      "    True -> string.drop_start(s, "
        <> select(rt, "m_strip", "2", "1")
        <> ")",
      "    False -> s",
      "  }",
      "}",
      "",
      // The literal lives in a pattern and nowhere else, which is where most
      // Gleam code writes one: nothing in an expression names `"GET"`.
      "pub fn method(m: String) -> Int {",
      "  case m {",
      "    \"GET\" -> " <> select(rt, "m_method", "1", "2"),
      "    _ -> 0",
      "  }",
      "}",
    ],
    "\n",
  )
  <> "\n"
}

@target(erlang)
/// The file the probe of `module` reports through, inside the project.
fn live_results(root: String, module: String) -> String {
  path.join(root, module <> ".jsonl")
}

@target(erlang)
fn live_spec(
  root: String,
  module: String,
  source: String,
  pbt_module: String,
  functions: List(#(String, List(String))),
) -> harness.ProbeSpec {
  ProbeSpec(
    target_module: module,
    probe_module: module <> "_probe",
    pbt_module: pbt_module,
    ffi_module: module <> "_probe_ffi",
    results_path: live_results(root, module <> "_probe"),
    functions: list.map(functions, fn(entry) {
      ProbeFunction(
        plan: plan_in(source, entry.0),
        mutant_ids: entry.1,
        hints: hints.harvest(function_in(source, entry.0)),
      )
    }),
    seed: 20_260_825,
    max_cases: 25,
    max_shrinks: 3,
    call_timeout_ms: 250,
    nondeterminism_checks: 2,
  )
}

@target(erlang)
fn install(root: String, probe: LiveProbe) -> Nil {
  let spec = probe.spec
  write_file(root, "src/" <> spec.target_module <> ".gleam", probe.source)
  write_file(
    root,
    "src/" <> spec.probe_module <> ".gleam",
    harness.render_probe(spec),
  )
  write_file(
    root,
    "src/" <> spec.ffi_module <> ".erl",
    harness.render_ffi(spec),
  )
}

// --- the shipped printers, over values chosen here ---------------------------

@target(erlang)
fn parameter_spec(source: String, function: String) -> genspec.GenSpec {
  let assert [parameter, ..] = plan_in(source, function).parameters
  parameter.spec
}

@target(erlang)
/// Every shape a printer can meet, with the source it has to answer with.
fn printer_cases(source: String) -> List(PrinterCase) {
  // A string prints as the literal that rebuilds it, so the source of the
  // value and the expected output are the same text: `say "hi"` followed by a
  // newline, a tab, `tab\end` and a carriage return.
  let escapes = "\"say \\\"hi\\\"\\n\\ttab\\\\end\\r\""
  [
    PrinterCase(IntSpec, "-5", "-5"),
    PrinterCase(IntSpec, "0", "0"),
    PrinterCase(FloatSpec, "0.5", "0.5"),
    PrinterCase(FloatSpec, "0.0", "0.0"),
    // Erlang picks the shortest rendering, which is exponent notation here;
    // it is still a float literal a test can paste back in.
    PrinterCase(FloatSpec, "-1000.0", "-1.0e3"),
    PrinterCase(BoolSpec, "True", "True"),
    PrinterCase(BoolSpec, "False", "False"),
    PrinterCase(NilSpec, "Nil", "Nil"),
    PrinterCase(StringSpec, "\"\"", "\"\""),
    PrinterCase(StringSpec, "\"plain\"", "\"plain\""),
    PrinterCase(StringSpec, escapes, escapes),
    PrinterCase(BitArraySpec, "<<>>", "<<>>"),
    PrinterCase(BitArraySpec, "<<7>>", "<<7>>"),
    PrinterCase(BitArraySpec, "<<1, 2, 3>>", "<<1, 2, 3>>"),
    PrinterCase(BitArraySpec, "<<0, 255>>", "<<0, 255>>"),
    PrinterCase(BitArraySpec, "<<7, 8>>", "<<7, 8>>"),
    // Bit arrays that are not a whole number of bytes: the trailing bits are
    // a sized segment, not something to drop.
    PrinterCase(BitArraySpec, "<<0:size(4)>>", "<<0:size(4)>>"),
    PrinterCase(BitArraySpec, "<<255, 1:size(1)>>", "<<255, 1:size(1)>>"),
    PrinterCase(ListSpec(IntSpec), "[]", "[]"),
    PrinterCase(ListSpec(IntSpec), "[1, -2]", "[1, -2]"),
    PrinterCase(
      ListSpec(OptionSpec(IntSpec)),
      "[Some(1), None]",
      "[Some(1), None]",
    ),
    PrinterCase(ResultSpec(IntSpec, StringSpec), "Ok(1)", "Ok(1)"),
    PrinterCase(
      ResultSpec(IntSpec, StringSpec),
      "Error(\"boom\")",
      "Error(\"boom\")",
    ),
    PrinterCase(TupleSpec([IntSpec, StringSpec]), "#(1, \"a\")", "#(1, \"a\")"),
    PrinterCase(TupleSpec([]), "#()", "#()"),
    // A record with labelled fields prints with its labels: this milestone's
    // rendering change, and the difference between a value a reviewer can read
    // and six positional numbers.
    PrinterCase(
      parameter_spec(source, "area"),
      "target.Circle(1)",
      "probe_shapes.Circle(radius: 1)",
    ),
    PrinterCase(
      parameter_spec(source, "area"),
      "target.Square(-2)",
      "probe_shapes.Square(side: -2)",
    ),
    // A variant field with no components: printed, never read.
    PrinterCase(
      parameter_spec(source, "open"),
      "target.Box(#())",
      "probe_shapes.Box(u: #())",
    ),
    PrinterCase(
      parameter_spec(source, "split"),
      "target.Pair(2, #())",
      "probe_shapes.Pair(a: 2, u: #())",
    ),
  ]
}

@target(erlang)
/// A snapshot module that prints every case with the probe's own printers.
///
/// Each line is marked so that compiler chatter cannot be mistaken for
/// printer output.
fn printer_check_module(
  target_module: String,
  cases: List(PrinterCase),
) -> String {
  let lines =
    list.index_map(cases, fn(printed, index) {
      let name = "arg" <> int.to_string(index)
      let expression = harness.render_value_printer(printed.spec, name)
      // The empty tuple prints without the printer reading the value, and
      // Gleam rejects a binding nothing uses.
      let binding = case string.contains(expression, name) {
        True -> name
        False -> "_" <> name
      }
      "  let "
      <> binding
      <> " = "
      <> printed.value
      <> "\n  io.println(\"P|\" <> "
      <> expression
      <> ")"
    })
  string.join(
    [
      "import gleam/bit_array",
      "import gleam/float",
      "import gleam/int",
      "import gleam/io",
      "import gleam/list",
      "import gleam/option.{type Option, None, Some}",
      "import gleam/string",
      "import " <> target_module <> " as target",
      "",
      "pub fn main() -> Nil {",
      string.join(list.append(lines, ["  Nil"]), "\n"),
      "}",
      "",
      harness.render_printer_helpers(
        target_module,
        list.map(cases, fn(printed) { printed.spec }),
      ),
    ],
    "\n",
  )
  <> "\n"
}

@target(erlang)
/// The lines the printer check module marked as printer output.
fn printed_lines(run: ProbeRun) -> List(String) {
  run.stdout
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(string.starts_with(_, "P|"))
  |> list.map(string.drop_start(_, 2))
}

// --- running the project ------------------------------------------------------

@target(erlang)
/// Runs one module and decodes whatever it wrote to its results file.
///
/// A module that reports nothing — the printer check, which prints its own
/// lines instead — writes no file, and reads back as no results at all.
fn run_probe(root: String, module: String) -> ProbeRun {
  let outcome =
    platform.run_process(
      "gleam",
      ["run", "-m", module, "--target", "erlang"],
      root,
      [],
      90_000,
    )
  let written = result.unwrap(simplifile.read(live_results(root, module)), "")
  let #(results, failures) = probe_result.decode_output(written)
  ProbeRun(
    module: module,
    status: outcome.status,
    timed_out: outcome.timed_out,
    stdout: outcome.stdout,
    stderr: outcome.stderr,
    results: results,
    failures: failures,
  )
}

@target(erlang)
fn statuses(
  results: List(probe_result.ProbeResult),
) -> List(#(String, String)) {
  list.map(results, fn(result) {
    #(result.mutant, probe_result.status_name(result.status))
  })
}

@target(erlang)
/// The result the probe reported for one mutant.
fn reported(run: ProbeRun, mutant: String) -> probe_result.ProbeResult {
  let assert Ok(found) =
    list.find(run.results, fn(result) { result.mutant == mutant })
  found
}

@target(erlang)
/// The kill set the probe reported for one mutant.
fn killed(run: ProbeRun, mutant: String) -> List(String) {
  reported(run, mutant).kills
}

@target(erlang)
fn probe_runs(run: LiveRun) -> List(ProbeRun) {
  [
    run.shapes,
    run.returns,
    run.secrets,
    run.mutual,
    run.captured,
    run.paths,
    run.printer,
  ]
}

@target(erlang)
/// Writes the project, builds it and runs every module, asserting nothing.
fn live_run(root: String) -> LiveRun {
  let assert Ok(generated) = runtime.generate(root, "e2eprobe0001")
  let rt = runtime.name(generated)
  let pbt_module = "gleam_mutants_pbt_e2e"
  write_file(root, "gleam.toml", project_toml())
  write_file(root, "src/" <> pbt_module <> ".gleam", pbt_source.source())

  let shapes_source = shapes_target(rt)
  let return_only_source = return_only_target(rt)
  let opaque_source = opaque_target(rt)
  let mutual_source = mutual_target(rt)
  let functional_source = functional_target(rt)
  let paths_source = paths_target(rt)
  let probes = [
    LiveProbe(
      spec: live_spec(
        root,
        "probe_shapes",
        shapes_source,
        pbt_module,
        shapes_functions(),
      ),
      source: shapes_source,
    ),
    LiveProbe(
      spec: live_spec(
        root,
        "probe_return_only",
        return_only_source,
        pbt_module,
        [
          #("make", ["m_make"]),
        ],
      ),
      source: return_only_source,
    ),
    LiveProbe(
      spec: live_spec(root, "probe_opaque", opaque_source, pbt_module, [
        #("hidden", ["m_hidden"]),
      ]),
      source: opaque_source,
    ),
    LiveProbe(
      spec: live_spec(root, "probe_mutual", mutual_source, pbt_module, [
        #("evaluate", ["m_eval"]),
        #("describe", ["m_describe"]),
        #("both", ["m_both"]),
        #("convert", ["m_convert"]),
      ]),
      source: mutual_source,
    ),
    LiveProbe(
      spec: live_spec(root, "probe_functional", functional_source, pbt_module, [
        #("make", ["m_capture", "m_scale"]),
      ]),
      source: functional_source,
    ),
    LiveProbe(
      spec: live_spec(root, "probe_paths", paths_source, pbt_module, [
        #("strip", ["m_strip"]),
        #("method", ["m_method"]),
      ]),
      source: paths_source,
    ),
  ]
  list.each(probes, fn(probe) { install(root, probe) })

  let cases = printer_cases(shapes_source)
  write_file(
    root,
    "src/printer_check.gleam",
    printer_check_module("probe_shapes", cases),
  )

  let build =
    platform.run_process(
      "gleam",
      ["build", "--target", "erlang", "--warnings-as-errors"],
      root,
      [],
      180_000,
    )
  LiveRun(
    build_status: build.status,
    build_output: build.stdout <> build.stderr,
    shapes: run_probe(root, "probe_shapes_probe"),
    returns: run_probe(root, "probe_return_only_probe"),
    secrets: run_probe(root, "probe_opaque_probe"),
    mutual: run_probe(root, "probe_mutual_probe"),
    captured: run_probe(root, "probe_functional_probe"),
    paths: run_probe(root, "probe_paths_probe"),
    printer: run_probe(root, "printer_check"),
    cases: cases,
  )
}

@target(erlang)
/// Prints what went wrong, so a red assertion has something to read.
fn report(run: LiveRun) -> Nil {
  case run.build_status == 0 {
    True -> Nil
    False -> io.println("probe build failed:\n" <> run.build_output)
  }
  list.each(probe_runs(run), fn(probe) {
    case probe.status == 0 && !probe.timed_out && probe.failures == [] {
      True -> Nil
      False ->
        io.println(
          probe.module
          <> " exited "
          <> int.to_string(probe.status)
          <> "\n"
          <> probe.stdout
          <> probe.stderr,
        )
    }
  })
}

@target(erlang)
pub fn rendered_probe_compiles_and_answers_inside_a_snapshot_test() {
  let root = live_root()
  let run = live_run(root)
  let assert Ok(Nil) = platform.delete_tree(root)
  report(run)

  assert run.build_status == 0
  let broken =
    probe_runs(run)
    |> list.filter(fn(probe) {
      probe.status != 0 || probe.timed_out || probe.failures != []
    })
    |> list.map(fn(probe) { probe.module })
  assert broken == []

  assert statuses(run.shapes.results) == shapes_expected()

  // A value with no components prints as the literal `#()`.
  let assert Ok(unit) =
    list.find(run.shapes.results, fn(result) { result.mutant == "m_unit" })
  assert unit.inputs == ["#()"]

  // So does a variant field with no components, inside its constructor —
  // under the label the type gave it.
  let assert Ok(boxed) =
    list.find(run.shapes.results, fn(result) { result.mutant == "m_open" })
  assert boxed.inputs == ["probe_shapes.Box(u: #())"]

  // A distinguished result names every mutant of its function that the same
  // input kills, in the order the probe was given them, its own included.
  assert killed(run.shapes, "m_positive") == ["m_positive"]
  assert killed(run.shapes, "m_twin_a") == ["m_twin_a", "m_twin_b"]
  assert killed(run.shapes, "m_twin_b") == ["m_twin_a", "m_twin_b"]

  // A mutant no input separates, and one whose original disagrees with
  // itself, kill nothing at all.
  assert killed(run.shapes, "m_quiet") == []
  assert killed(run.shapes, "m_dice") == []

  // The probe reports the value the call answered with, not the wrapper it
  // travelled home in: an inspect a generated test can compare against.
  let positive = reported(run.shapes, "m_positive")
  assert list.contains(["True", "False"], positive.expected_inspect)
  assert positive.expected_outcome == probe_result.Returned
  assert positive.actual_outcome == probe_result.Returned

  // A call that never answered has no value to inspect, and says so: a
  // mutant that panics, one that hangs, and an original that panics for
  // every input.
  let boom = reported(run.shapes, "m_boom")
  assert boom.expected_outcome == probe_result.Returned
  assert boom.actual_outcome == probe_result.Panicked
  assert boom.actual_inspect == ""

  let hang = reported(run.shapes, "m_hang")
  assert hang.expected_outcome == probe_result.Returned
  assert hang.actual_outcome == probe_result.TimedOut
  assert hang.actual_inspect == ""

  let always = reported(run.shapes, "m_always")
  assert always.expected_outcome == probe_result.Panicked
  assert always.expected_inspect == ""
  assert always.expected == None
  assert always.actual_outcome == probe_result.Returned

  // A printable result is rendered as source a test could paste back in.
  let assert [made] = run.returns.results
  assert statuses([made]) == [#("m_make", "distinguished")]
  assert made.inputs != []
  assert string.starts_with(
    option.unwrap(made.expected, ""),
    "probe_return_only.",
  )

  // An unprintable result leaves `expected` empty but still reports. The
  // generated test falls back to comparing `string.inspect` output, so what
  // is reported has to be that output — the value itself, not the wrapper.
  let assert [hidden] = run.secrets.results
  assert statuses([hidden]) == [#("m_hidden", "distinguished")]
  assert hidden.expected == None
  assert hidden.expected_outcome == probe_result.Returned
  assert string.starts_with(hidden.expected_inspect, "Secret(")
  assert string.starts_with(hidden.actual_inspect, "Secret(")

  // Mutually recursive generators terminate, and every way into the cycle —
  // one function per type, one function over both, one that converts between
  // them — names the same pair of types.
  assert statuses(run.mutual.results)
    == [
      #("m_eval", "distinguished"),
      #("m_describe", "distinguished"),
      #("m_both", "distinguished"),
      #("m_convert", "distinguished"),
    ]

  // The converted result is printed by the helper of the type it returns.
  let assert Ok(converted) =
    list.find(run.mutual.results, fn(result) { result.mutant == "m_convert" })
  assert string.starts_with(
    option.unwrap(converted.expected, ""),
    "probe_mutual.Print(",
  )

  // A separation nothing can be written down is not a separation.
  //
  // Both mutants change a value the returned closure captures, so the original
  // and the mutant are structurally unequal and render identically. Calling
  // that `distinguished` produces a test that passes with the mutant in place;
  // the probe has to report the wall instead, and claim no kill at all.
  assert statuses(run.captured.results)
    == [#("m_capture", "unsupported"), #("m_scale", "unsupported")]
  let captured = reported(run.captured, "m_capture")
  assert string.contains(captured.reason, "function values")
  assert captured.expected_inspect == captured.actual_inspect
  assert killed(run.captured, "m_capture") == []
  assert killed(run.captured, "m_scale") == []

  // A mutant nothing but the function's own literal separates.
  //
  // With uniform strings this was `indistinguishable` after every budget
  // tried; harvested, `"./"` is drawn on purpose and the search reports the
  // shortest input that tells the two apart.
  assert statuses(run.paths.results)
    == [#("m_strip", "distinguished"), #("m_method", "distinguished")]
  let stripped = reported(run.paths, "m_strip")
  assert stripped.inputs == ["\"./\""]
  assert stripped.expected == Some("\"\"")

  // The same, for a literal written in a pattern rather than in an expression:
  // `case m { "GET" -> .. }` is the only place the function names the string
  // that separates its mutant, and 95^3 uniform draws never reach it.
  let matched = reported(run.paths, "m_method")
  assert matched.inputs == ["\"GET\""]
  assert matched.expected == Some("1")

  // The printers the probe ships, over values picked here.
  let printed = printed_lines(run.printer)
  assert printed == list.map(run.cases, fn(printed) { printed.expected })

  // However the runtime chooses to render a float, the result is source a
  // generated test could paste back in.
  let floats =
    list.zip(run.cases, printed)
    |> list.filter(fn(pair) {
      let #(printed, _) = pair
      printed.spec == FloatSpec
    })
    |> list.map(fn(pair) { pair.1 })
  assert list.length(floats) == 3
  assert list.filter(floats, fn(text) { !is_float_literal(text) }) == []
}

// --- parameterised types inside a real snapshot ------------------------------
//
// A type the module under test declares with parameters is a different type at
// every instantiation: `Box(Int)` and `Box(String)` share a name and nothing
// else. Only a compiler can say whether the probe named them apart, so this
// check builds a second snapshot and runs it.

@target(erlang)
/// What one `gleam build` plus its probe runs answered.
type GenericRun {
  GenericRun(
    build_status: Int,
    build_output: String,
    generic: ProbeRun,
    wrapped: ProbeRun,
  )
}

@target(erlang)
/// One parameterised type at two instantiations, a recursive one, one whose
/// recursion runs through another parameterised type, a pair that recurses
/// through each other at one instantiation, a phantom parameter and two
/// instantiations inside one variant.
fn generic_target(rt: String) -> String {
  string.join(
    [
      "import gleam/option.{type Option}",
      "import gleam/string",
      "import " <> rt,
      "",
      "pub type Box(a) {",
      "  Box(inner: a)",
      "}",
      "",
      "pub type Tree(a) {",
      "  Leaf",
      "  Node(Tree(a), a, Tree(a))",
      "}",
      "",
      "pub type Nest(a) {",
      "  Tip",
      "  Fork(Box(Nest(a)), a)",
      "}",
      "",
      "pub type Tagged(a) {",
      "  Tagged(n: Int)",
      "}",
      "",
      "pub type Both {",
      "  Both(Box(Int), Box(String))",
      "}",
      "",
      "pub type Chain(a) {",
      "  ChainEnd",
      "  ChainMore(Link(a))",
      "}",
      "",
      "pub type Link(a) {",
      "  Link(a, Chain(a))",
      "}",
      "",
      "pub fn pairup(x: Box(Int), y: Box(String)) -> Int {",
      "  case x, y {",
      "    Box(n), Box(s) ->",
      "      n + string.length(s) + " <> select(rt, "m_pair", "1", "2"),
      "  }",
      "}",
      "",
      "pub fn total(t: Tree(Int)) -> Int {",
      "  case t {",
      "    Leaf -> " <> select(rt, "m_total", "0", "1"),
      "    Node(left, value, right) -> total(left) + value + total(right)",
      "  }",
      "}",
      "",
      "pub fn nested(x: Nest(Int), y: Nest(String)) -> Int {",
      "  hops(x) + hops(y) + " <> select(rt, "m_nest", "0", "1"),
      "}",
      "",
      "fn hops(nest: Nest(a)) -> Int {",
      "  case nest {",
      "    Tip -> 0",
      "    Fork(Box(inner), _) -> 1 + hops(inner)",
      "  }",
      "}",
      "",
      "pub fn use_tag(t: Tagged(Option(Int))) -> Int {",
      "  case t {",
      "    Tagged(n) -> " <> select(rt, "m_tag", "n", "n + 1"),
      "  }",
      "}",
      "",
      "pub fn unpack(b: Both) -> Int {",
      "  case b {",
      "    Both(Box(n), Box(s)) ->",
      "      n + string.length(s) + " <> select(rt, "m_unpack", "0", "1"),
      "  }",
      "}",
      "",
      "pub fn walk(c: Chain(Int)) -> Int {",
      "  case c {",
      "    ChainEnd -> " <> select(rt, "m_walk", "0", "1"),
      "    ChainMore(Link(value, rest)) -> value + walk(rest)",
      "  }",
      "}",
    ],
    "\n",
  )
  <> "\n"
}

@target(erlang)
/// A parameterised type that is only ever returned, never taken.
fn wrap_target(rt: String) -> String {
  string.join(
    [
      "import " <> rt,
      "",
      "pub type Box(a) {",
      "  Box(inner: a)",
      "}",
      "",
      "pub fn wrap(x: Int) -> Box(Int) {",
      "  Box(" <> select(rt, "m_wrap", "x", "x + 1") <> ")",
      "}",
    ],
    "\n",
  )
  <> "\n"
}

@target(erlang)
/// Writes the project, builds it and runs both probes, asserting nothing.
fn generic_live_run(root: String) -> GenericRun {
  let assert Ok(generated) = runtime.generate(root, "e2egeneric01")
  let rt = runtime.name(generated)
  let pbt_module = "gleam_mutants_pbt_generic"
  write_file(root, "gleam.toml", project_toml())
  write_file(root, "src/" <> pbt_module <> ".gleam", pbt_source.source())

  let generic_source = generic_target(rt)
  let wrap_source = wrap_target(rt)
  let probes = [
    LiveProbe(
      spec: live_spec(root, "probe_generic", generic_source, pbt_module, [
        #("pairup", ["m_pair"]),
        #("total", ["m_total"]),
        #("nested", ["m_nest"]),
        #("use_tag", ["m_tag"]),
        #("unpack", ["m_unpack"]),
        #("walk", ["m_walk"]),
      ]),
      source: generic_source,
    ),
    LiveProbe(
      spec: live_spec(root, "probe_wrap", wrap_source, pbt_module, [
        #("wrap", ["m_wrap"]),
      ]),
      source: wrap_source,
    ),
  ]
  list.each(probes, fn(probe) { install(root, probe) })

  let build =
    platform.run_process(
      "gleam",
      ["build", "--target", "erlang", "--warnings-as-errors"],
      root,
      [],
      180_000,
    )
  GenericRun(
    build_status: build.status,
    build_output: build.stdout <> build.stderr,
    generic: run_probe(root, "probe_generic_probe"),
    wrapped: run_probe(root, "probe_wrap_probe"),
  )
}

@target(erlang)
/// Prints what went wrong, so a red assertion has something to read.
fn report_generic(run: GenericRun) -> Nil {
  case run.build_status == 0 {
    True -> Nil
    False -> io.println("generic probe build failed:\n" <> run.build_output)
  }
  list.each([run.generic, run.wrapped], fn(probe) {
    case probe.status == 0 && !probe.timed_out && probe.failures == [] {
      True -> Nil
      False ->
        io.println(
          probe.module
          <> " exited "
          <> int.to_string(probe.status)
          <> "\n"
          <> probe.stdout
          <> probe.stderr,
        )
    }
  })
}

@target(erlang)
pub fn rendered_probe_compiles_parameterised_types_inside_a_snapshot_test() {
  let root = live_root()
  let run = generic_live_run(root)
  let assert Ok(Nil) = platform.delete_tree(root)
  report_generic(run)

  assert run.build_status == 0
  let broken =
    [run.generic, run.wrapped]
    |> list.filter(fn(probe) {
      probe.status != 0 || probe.timed_out || probe.failures != []
    })
    |> list.map(fn(probe) { probe.module })
  assert broken == []

  assert statuses(run.generic.results)
    == [
      #("m_pair", "distinguished"),
      #("m_total", "distinguished"),
      #("m_nest", "distinguished"),
      #("m_tag", "distinguished"),
      #("m_unpack", "distinguished"),
      #("m_walk", "distinguished"),
    ]
  assert statuses(run.wrapped.results) == [#("m_wrap", "distinguished")]

  // Each instantiation is printed by a helper of its own: an integer box
  // holds an integer, a string box a string literal.
  let assert Ok(paired) =
    list.find(run.generic.results, fn(result) { result.mutant == "m_pair" })
  let assert [boxed_int, boxed_string] = paired.inputs
  assert string.starts_with(boxed_int, "probe_generic.Box(inner: ")
  assert !string.contains(boxed_int, "\"")
  assert string.starts_with(boxed_string, "probe_generic.Box(inner: \"")

  // A recursive parameterised type generates and prints.
  let assert Ok(totalled) =
    list.find(run.generic.results, fn(result) { result.mutant == "m_total" })
  let assert [tree] = totalled.inputs
  assert string.starts_with(tree, "probe_generic.")

  // A type whose recursion runs through another parameterised type is one
  // type per instantiation all the way down: an integer nest holds boxes of
  // integer nests, a string nest boxes of string nests.
  let assert Ok(nested) =
    list.find(run.generic.results, fn(result) { result.mutant == "m_nest" })
  let assert [nest_int, nest_string] = nested.inputs
  assert string.starts_with(nest_int, "probe_generic.")
  assert !string.contains(nest_int, "\"")
  assert string.starts_with(nest_string, "probe_generic.")

  // Two instantiations inside one variant stay apart: the integer box prints
  // a number, the string box a string literal.
  let assert Ok(unpacked) =
    list.find(run.generic.results, fn(result) { result.mutant == "m_unpack" })
  let assert [both] = unpacked.inputs
  assert string.starts_with(
    both,
    "probe_generic.Both(probe_generic.Box(inner: ",
  )
  assert string.contains(both, "probe_generic.Box(inner: \"")

  // A parameter whose type argument no variant uses is still annotated with
  // that argument, and the probe prints what the variants hold.
  let assert Ok(tagged) =
    list.find(run.generic.results, fn(result) { result.mutant == "m_tag" })
  let assert [tag] = tagged.inputs
  assert string.starts_with(tag, "probe_generic.Tagged(")

  // A pair of parameterised types that recurse through each other stays one
  // type per instantiation: the chain of integers prints its own links.
  let assert Ok(walked) =
    list.find(run.generic.results, fn(result) { result.mutant == "m_walk" })
  let assert [chain] = walked.inputs
  assert string.starts_with(chain, "probe_generic.Chain")
    || string.starts_with(chain, "probe_generic.ChainEnd")
    || string.starts_with(chain, "probe_generic.ChainMore")

  // A parameterised type that is only ever returned still prints as source a
  // generated test could paste back in.
  let assert [wrapped] = run.wrapped.results
  assert string.starts_with(
    option.unwrap(wrapped.expected, ""),
    "probe_wrap.Box(",
  )
}
