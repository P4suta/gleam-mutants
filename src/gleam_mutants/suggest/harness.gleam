// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Renders the differential probe: one Gleam module that plays every mutant of
// a target module against its original inside a single BEAM VM, plus the
// Erlang FFI that runs each call in a throw-away process.
//
// Everything in here is pure string building — no file system, no processes —
// so the rendered text can be asserted on directly.

import glance
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam_mutants/suggest/genspec.{
  type GenSpec, type VariantSpec, BitArraySpec, BoolSpec, CustomSpec, FloatSpec,
  IntSpec, ListSpec, NilSpec, OptionSpec, RecursiveRef, ResultSpec, StringSpec,
  TupleSpec,
}
import gleam_mutants/suggest/typederive

/// The depth a custom-type generator starts at, which bounds its recursion.
const initial_depth = 3

/// Added to the seed for the nondeterminism pre-check, keeping it clear of the
/// per-mutant searches.
const determinism_offset = 7919

// --- The specification -------------------------------------------------------

/// One function to probe together with the mutants that live inside it.
pub type ProbeFunction {
  ProbeFunction(plan: typederive.FunctionPlan, mutant_ids: List(String))
}

/// Everything the renderer needs to emit a probe module and its Erlang FFI.
///
/// `target_module` is the Gleam module path of the module under test, while
/// `probe_module`, `pbt_module` and `ffi_module` are the names the generated
/// files take inside the snapshot.
pub type ProbeSpec {
  ProbeSpec(
    target_module: String,
    probe_module: String,
    pbt_module: String,
    ffi_module: String,
    functions: List(ProbeFunction),
    seed: Int,
    max_cases: Int,
    max_shrinks: Int,
    call_timeout_ms: Int,
    nondeterminism_checks: Int,
  )
}

// --- Printing values as Gleam source ----------------------------------------

/// The Gleam expression that prints `variable` as the source rebuilding it.
///
/// This is the very expression the probe writes into `show_args_*` and
/// `show_result_*`, so it names the helpers `render_printer_helpers` emits:
/// `int.to_string(value)` for an integer, `show_string(value)` for a string,
/// `show_type_shape(value)` for a custom type called `Shape`, and
/// `show_type_box_int(value)` for the `Box(Int)` instantiation of `Box(a)`.
pub fn render_value_printer(spec: GenSpec, variable: String) -> String {
  let #(rendered, _) = show_expression(spec, variable, 0, no_scope)
  rendered
}

/// The Gleam source of every printer helper `specs` need, in one block.
///
/// The shared shape printers come first, then one `show_type_*` per custom
/// type reached. Constructors are matched as `target.Name`, so the module
/// holding these helpers has to import the module under test as `target`,
/// and are printed with the last segment of `target_module` as their
/// qualifier — the name a generated test would call them by.
pub fn render_printer_helpers(
  target_module: String,
  specs: List(GenSpec),
) -> String {
  let helpers =
    list.fold(specs, no_helpers(), fn(seen, spec) {
      collect(spec, no_scope, seen)
    })
  string.join(
    list.flatten([
      printers(helpers),
      custom_printers(qualifier(target_module), helpers),
    ]),
    "\n\n",
  )
}

/// The module qualifier a generated test would use, e.g. `util` for `app/util`.
fn qualifier(module: String) -> String {
  case list.last(string.split(module, "/")) {
    Ok(segment) -> segment
    Error(_) -> module
  }
}

/// Lowercases an upper-camel type name into a legal Gleam function-name part.
///
/// Gleam function names hold only `a-z`, `0-9` and `_`, so a helper named
/// after a type has to carry it in snake case: `MyShape` becomes `my_shape`.
///
/// The mapping is injective: every upper-case letter becomes `_` plus its
/// lower case and every underscore doubles, so two type names that differ
/// only in where the case changes — `ABc` beside `Abc` — still name two
/// different helpers rather than defining one helper twice.
fn snake_case(name: String) -> String {
  let text =
    name
    |> string.to_graphemes
    |> list.map(snake_grapheme)
    |> string.concat
  case string.starts_with(text, "_") {
    True -> string.drop_start(text, 1)
    False -> text
  }
}

fn snake_grapheme(grapheme: String) -> String {
  let lowered = string.lowercase(grapheme)
  case grapheme == "_", lowered != grapheme {
    True, _ -> "__"
    False, True -> "_" <> lowered
    False, False -> grapheme
  }
}

/// Wraps `text` in a Gleam string literal, escaping what a literal cannot hold.
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
    other -> other
  }
}

// --- Which helpers the rendered probe needs ----------------------------------

/// One instantiation of a custom type, with the helpers it needs.
///
/// `key` is the name part of `gen_type_*` and `show_type_*`, and `scope` maps
/// every type whose definition encloses this one — this one included — to the
/// instantiation it is being defined at, which is what a `RecursiveRef` inside
/// `variants` points back at.
type Custom {
  Custom(
    key: String,
    name: String,
    arguments: List(GenSpec),
    variants: List(VariantSpec),
    scope: Scope,
  )
}

/// The instantiation each enclosing custom type is being defined at.
type Scope =
  List(#(String, GenSpec))

/// The scope of a specification that no custom type encloses.
const no_scope: Scope = []

/// The printers and imports a probe needs, plus every custom type it touches.
type Helpers {
  Helpers(
    bools: Bool,
    strings: Bool,
    nils: Bool,
    bit_arrays: Bool,
    floats: Bool,
    lists: Bool,
    options: Bool,
    results: Bool,
    // True when an annotation names `Option` though no helper needs it.
    option_types: Bool,
    customs: List(#(String, Custom)),
  )
}

fn no_helpers() -> Helpers {
  Helpers(False, False, False, False, False, False, False, False, False, [])
}

/// Every type one probed function mentions: its parameters and its result.
fn plan_specs(plan: typederive.FunctionPlan) -> List(GenSpec) {
  let parameters = list.map(plan.parameters, fn(parameter) { parameter.spec })
  case plan.return_spec {
    Some(spec) -> list.append(parameters, [spec])
    None -> parameters
  }
}

fn collect_plan(plan: typederive.FunctionPlan, acc: Helpers) -> Helpers {
  list.fold(plan_specs(plan), acc, fn(seen, spec) {
    collect(spec, no_scope, seen)
  })
}

fn collect(spec: GenSpec, scope: Scope, acc: Helpers) -> Helpers {
  case spec {
    IntSpec -> acc
    FloatSpec -> Helpers(..acc, floats: True)
    BoolSpec -> Helpers(..acc, bools: True)
    StringSpec -> Helpers(..acc, strings: True)
    NilSpec -> Helpers(..acc, nils: True)
    BitArraySpec -> Helpers(..acc, bit_arrays: True)
    ListSpec(element) -> collect(element, scope, Helpers(..acc, lists: True))
    OptionSpec(inner) -> collect(inner, scope, Helpers(..acc, options: True))
    ResultSpec(ok, error) ->
      collect(error, scope, collect(ok, scope, Helpers(..acc, results: True)))
    TupleSpec(elements) ->
      list.fold(elements, acc, fn(seen, element) {
        collect(element, scope, seen)
      })
    // A type argument is only reached through the variants it was substituted
    // into, so a parameter no variant uses needs no helpers of its own — but
    // every annotation still writes it out, which is what `annotated` walks.
    CustomSpec(name, arguments, variants) -> {
      let key = custom_key(name, arguments, scope)
      let named = list.fold(arguments, acc, annotated)
      case list.key_find(named.customs, key) {
        Ok(_) -> named
        Error(_) -> {
          let inner = [#(name, CustomSpec(name, arguments, variants)), ..scope]
          let entry = Custom(key, name, arguments, variants, inner)
          list.fold(
            variants,
            Helpers(..named, customs: [#(key, entry), ..named.customs]),
            fn(seen, variant) {
              list.fold(variant.fields, seen, fn(deeper, field) {
                collect(field.spec, inner, deeper)
              })
            },
          )
        }
      }
    }
    RecursiveRef(_) -> acc
  }
}

/// Notes the imports one *annotation* needs, without asking for any helper.
///
/// A type argument no variant uses is never generated and never printed, so it
/// needs no helper — but `type_source` still writes it into every annotation
/// of the instantiation it parameterises, and `Option` is the one name the
/// renderer writes that the prelude does not hold. A reference back at an
/// enclosing type carries no arguments of its own: it stands for an
/// instantiation this walk has already reached.
fn annotated(acc: Helpers, spec: GenSpec) -> Helpers {
  case spec {
    ListSpec(element) -> annotated(acc, element)
    OptionSpec(inner) -> annotated(Helpers(..acc, option_types: True), inner)
    ResultSpec(ok, error) -> annotated(annotated(acc, ok), error)
    TupleSpec(elements) -> list.fold(elements, acc, annotated)
    CustomSpec(_, arguments, _) -> list.fold(arguments, acc, annotated)
    _ -> acc
  }
}

/// The helper keys of the custom types `spec` reaches, without repeats.
fn custom_keys(spec: GenSpec, scope: Scope, acc: List(String)) -> List(String) {
  case spec {
    ListSpec(element) -> custom_keys(element, scope, acc)
    OptionSpec(inner) -> custom_keys(inner, scope, acc)
    ResultSpec(ok, error) ->
      custom_keys(error, scope, custom_keys(ok, scope, acc))
    TupleSpec(elements) ->
      list.fold(elements, acc, fn(seen, element) {
        custom_keys(element, scope, seen)
      })
    CustomSpec(name, arguments, variants) -> {
      let key = custom_key(name, arguments, scope)
      case list.contains(acc, key) {
        True -> acc
        False -> {
          let inner = [#(name, CustomSpec(name, arguments, variants)), ..scope]
          list.fold(variants, [key, ..acc], fn(seen, variant) {
            list.fold(variant.fields, seen, fn(deeper, field) {
              custom_keys(field.spec, inner, deeper)
            })
          })
        }
      }
    }
    _ -> acc
  }
}

/// The custom types the probe has to generate values of.
///
/// Only a type reachable from a *parameter* is generated, while every type the
/// probe touches is printed, so the two sets are collected apart: a type that
/// is only ever returned would otherwise get a generator nothing calls, which
/// the compiler rejects under `--warnings-as-errors`.
fn generated_types(functions: List(ProbeFunction)) -> List(String) {
  list.fold(functions, [], fn(keys, probe) {
    list.fold(probe.plan.parameters, keys, fn(seen, parameter) {
      custom_keys(parameter.spec, no_scope, seen)
    })
  })
}

// --- Naming one instantiation ------------------------------------------------

/// The name part of the helpers serving one instantiation of a custom type.
///
/// `Box(Int)` and `Box(String)` are two types that share a name, so one
/// `show_type_box` cannot serve both: the arguments are folded into the key,
/// giving `box_int` and `box_string`. A type that takes no parameters keeps
/// its plain snake-cased name.
/// An argument can itself be a reference back at a type that is still being
/// defined, and such a reference names an instantiation only `scope` knows:
/// the `Box(Nest(a))` inside `Nest(Int)` is `Box(Nest(Int))`, and the one
/// inside `Nest(String)` is another type entirely.
fn custom_key(name: String, arguments: List(GenSpec), scope: Scope) -> String {
  case arguments {
    [] -> snake_case(name)
    _ ->
      snake_case(name)
      <> "_"
      <> string.join(list.map(arguments, fingerprint(_, scope)), "_")
  }
}

/// One type argument written in the alphabet a Gleam function name allows.
///
/// A custom type is marked with a leading `t_`, which keeps `Box(List(String))`
/// and `Box(ListString)` from folding onto one key. The encoding is readable
/// rather than injective, and `check_spec` reports the pairs it cannot tell
/// apart.
fn fingerprint(spec: GenSpec, scope: Scope) -> String {
  case spec {
    IntSpec -> "int"
    FloatSpec -> "float"
    BoolSpec -> "bool"
    StringSpec -> "string"
    NilSpec -> "nil"
    BitArraySpec -> "bit_array"
    ListSpec(element) -> "list_" <> fingerprint(element, scope)
    OptionSpec(inner) -> "option_" <> fingerprint(inner, scope)
    ResultSpec(ok, error) ->
      "result_" <> fingerprint(ok, scope) <> "_" <> fingerprint(error, scope)
    TupleSpec([]) -> "unit"
    TupleSpec(elements) ->
      "tuple"
      <> int.to_string(list.length(elements))
      <> "_"
      <> string.join(list.map(elements, fingerprint(_, scope)), "_")
    CustomSpec(name, arguments, _) -> "t_" <> custom_key(name, arguments, scope)
    RecursiveRef(name) -> "t_" <> recursive_key(name, scope)
  }
}

/// The helper key a recursive reference resolves to inside `scope`.
///
/// A `RecursiveRef` names a type without its arguments, so only the enclosing
/// instantiation can say which helper it means: `Tree(a)` inside `Tree(Int)`
/// is `Tree(Int)` again, and so `gen_type_tree_int`.
///
/// The reference is dropped from the scope its arguments resolve in, so a
/// pair of types that name each other cannot chase each other for ever.
fn recursive_key(name: String, scope: Scope) -> String {
  case list.key_find(scope, name) {
    Ok(CustomSpec(found, arguments, _)) ->
      custom_key(found, arguments, without(scope, name))
    _ -> snake_case(name)
  }
}

/// `scope` with the binding of `name` removed.
fn without(scope: Scope, name: String) -> Scope {
  list.filter(scope, fn(entry) { entry.0 != name })
}

/// True when `spec` mentions the type called `name` recursively.
fn references(spec: GenSpec, name: String) -> Bool {
  case spec {
    RecursiveRef(reference) -> reference == name
    ListSpec(element) -> references(element, name)
    OptionSpec(inner) -> references(inner, name)
    ResultSpec(ok, error) -> references(ok, name) || references(error, name)
    TupleSpec(elements) -> list.any(elements, references(_, name))
    CustomSpec(_, _, variants) ->
      list.any(variants, variant_references(_, name))
    _ -> False
  }
}

fn variant_references(variant: VariantSpec, name: String) -> Bool {
  list.any(variant.fields, fn(field) { references(field.spec, name) })
}

// --- Rendering the probe module ---------------------------------------------

/// Renders the Gleam source of the probe module described by `spec`.
///
/// The module imports nothing beyond `gleam_stdlib`, the copied property
/// testing core and the module under test, so it compiles inside any snapshot.
/// Functions without mutants are skipped.
pub fn render_probe(spec: ProbeSpec) -> String {
  let functions =
    list.filter(spec.functions, fn(probe) { probe.mutant_ids != [] })
  case functions {
    [] -> block([header(spec), "pub fn main() -> Nil {\n  Nil\n}"])
    _ -> {
      let helpers =
        list.fold(functions, no_helpers(), fn(seen, probe) {
          collect_plan(probe.plan, seen)
        })
      block(
        list.flatten([
          [
            header(spec),
            imports(spec, helpers),
            constants(spec),
            observation(spec),
            main_function(functions),
            runtime_source,
          ],
          printers(helpers),
          customs(spec, helpers, generated_types(functions)),
          function_blocks(functions),
        ]),
      )
    }
  }
}

/// Checks that the probe of `spec` would define every name exactly once.
///
/// Every helper is named after something in the module under test, so an
/// unlucky pair can land on one name: a function called `type_shape` beside a
/// type called `Shape`, or a function called `seed` beside the probe's own
/// `probe_seed` constant. Gleam would answer with a duplicate-definition
/// error inside a module the user never wrote, so the clash is named here
/// instead — the renderer itself stays total.
///
/// A failure is coded like every other wall a suggest run can hit: `GMU8007`
/// for two definitions of one name, `GMU8008` for two types asking for one
/// helper, and `GMU8009` for a probe that is not Gleam at all.
pub fn check_spec(spec: ProbeSpec) -> Result(Nil, String) {
  use _ <- result.try(check_instantiations(spec))
  check_definitions(spec)
}

/// Checks that no two custom-type instantiations share one helper key.
///
/// A key is the type's name plus a readable fingerprint of its arguments, and
/// readable is not injective: `Box(Int)` and a type called `BoxInt` both come
/// out as `box_int`. One helper cannot serve two types, so the pair is named
/// here rather than left to fail inside the snapshot.
///
/// Two instantiations are the same type when they annotate the same way, which
/// is what the probe's helpers are typed by. Comparing the *shape* each was
/// reached through would answer differently: a cycle of mutually recursive
/// types unrolls one way from each of its entrances, and those unrollings are
/// still the same two types.
fn check_instantiations(spec: ProbeSpec) -> Result(Nil, String) {
  let keyed =
    spec.functions
    |> list.flat_map(fn(probe) { plan_specs(probe.plan) })
    |> list.fold([], fn(seen, mentioned) {
      instantiations(mentioned, no_scope, seen)
    })
  case
    list.find_map(keyed, fn(entry) {
      keyed
      |> list.find(fn(other) { other.0 == entry.0 && other.1 != entry.1 })
      |> result.map(fn(other) { #(entry.0, entry.1, other.1) })
    })
  {
    Error(_) -> Ok(Nil)
    // Both types are named the way the probe would write them: the key alone
    // would leave the reader hunting for the pair that asked for it.
    Ok(#(key, one, other)) ->
      Error(
        "GMU8008: the probe of `"
        <> spec.target_module
        <> "` would name both `"
        <> one
        <> "` and `"
        <> other
        <> "` `"
        <> key
        <> "`; rename one of them",
      )
  }
}

/// Every distinct custom-type instantiation `spec` reaches: the helper key it
/// asks for, beside the type that key would serve.
fn instantiations(
  spec: GenSpec,
  scope: Scope,
  acc: List(#(String, String)),
) -> List(#(String, String)) {
  case spec {
    ListSpec(element) -> instantiations(element, scope, acc)
    OptionSpec(inner) -> instantiations(inner, scope, acc)
    ResultSpec(ok, error) ->
      instantiations(error, scope, instantiations(ok, scope, acc))
    TupleSpec(elements) ->
      list.fold(elements, acc, fn(seen, element) {
        instantiations(element, scope, seen)
      })
    CustomSpec(name, arguments, variants) -> {
      let entry = #(
        custom_key(name, arguments, scope),
        type_source(spec, scope),
      )
      case list.contains(acc, entry) {
        True -> acc
        False -> {
          let inner = [#(name, spec), ..scope]
          list.fold(variants, [entry, ..acc], fn(seen, variant) {
            list.fold(variant.fields, seen, fn(deeper, field) {
              instantiations(field.spec, inner, deeper)
            })
          })
        }
      }
    }
    _ -> acc
  }
}

fn check_definitions(spec: ProbeSpec) -> Result(Nil, String) {
  case glance.module(render_probe(spec)) {
    Error(_) ->
      Error(
        "GMU8009: the probe of `"
        <> spec.target_module
        <> "` is not valid Gleam; please report this as a bug",
      )
    Ok(module) -> {
      let names =
        list.append(
          list.map(module.constants, fn(definition) {
            definition.definition.name
          }),
          list.map(module.functions, fn(definition) {
            definition.definition.name
          }),
        )
      case list.filter(list.unique(names), fn(name) { defines(names, name) }) {
        [] -> Ok(Nil)
        [name, ..] ->
          Error(
            "GMU8007: the probe of `"
            <> spec.target_module
            <> "` would define `"
            <> name
            <> "` twice; rename the function or type it is built from",
          )
      }
    }
  }
}

/// True when `names` holds `name` more than once.
fn defines(names: List(String), name: String) -> Bool {
  list.count(names, fn(other) { other == name }) > 1
}

fn block(sections: List(String)) -> String {
  string.join(list.filter(sections, fn(section) { section != "" }), "\n\n")
  <> "\n"
}

fn header(spec: ProbeSpec) -> String {
  "// Generated by gleam_mutants. Do not edit.\n// Probe module: "
  <> spec.probe_module
}

/// The single-element list holding `line` when `needed`, or nothing.
fn when(needed: Bool, line: String) -> List(String) {
  case needed {
    True -> [line]
    False -> []
  }
}

fn imports(spec: ProbeSpec, helpers: Helpers) -> String {
  string.join(
    list.flatten([
      when(helpers.bit_arrays, "import gleam/bit_array"),
      when(helpers.floats, "import gleam/float"),
      ["import gleam/int", "import gleam/io", "import gleam/list"],
      // `show_option` matches on `Some` and `None`, while an annotation names
      // only the type — and importing a name nothing uses is itself a warning.
      when(helpers.options, "import gleam/option.{type Option, None, Some}"),
      when(
        !helpers.options && helpers.option_types,
        "import gleam/option.{type Option}",
      ),
      [
        "import gleam/string",
        "import " <> spec.pbt_module <> " as pbt",
        "import " <> spec.target_module <> " as target",
      ],
    ]),
    "\n",
  )
}

fn constants(spec: ProbeSpec) -> String {
  string.join(
    [
      "const probe_seed = " <> int.to_string(spec.seed),
      "const max_cases = " <> int.to_string(spec.max_cases),
      "const max_shrinks = " <> int.to_string(spec.max_shrinks),
      "const call_timeout_ms = " <> int.to_string(spec.call_timeout_ms),
      "const nondeterminism_checks = "
        <> int.to_string(spec.nondeterminism_checks),
    ],
    "\n\n",
  )
}

fn observation(spec: ProbeSpec) -> String {
  "type Observation(a) {
  Value(a)
  Panic(String)
  Timeout
}

@external(erlang, \"" <> spec.ffi_module <> "\", \"isolated\")
fn isolated(run: fn() -> a, mutant: String, timeout_ms: Int) -> Observation(a)"
}

fn main_function(functions: List(ProbeFunction)) -> String {
  let calls =
    list.map(functions, fn(probe) { "  probe_" <> probe.plan.name <> "()" })
  "pub fn main() -> Nil {\n"
  <> string.join(list.append(calls, ["  Nil"]), "\n")
  <> "\n}"
}

/// The parts of the probe that do not depend on the module under test.
const runtime_source = "fn normalise(observation: Observation(a)) -> Observation(a) {
  case observation {
    Value(value) -> Value(value)
    Panic(_) -> Panic(\"\")
    Timeout -> Timeout
  }
}

fn determinism(
  generator: pbt.Generator(a),
  s: pbt.Seed,
  remaining: Int,
  checked: Int,
  timeouts: Int,
  run: fn(a) -> Observation(b),
) -> String {
  case remaining <= 0 {
    True ->
      case checked > 0 && checked == timeouts {
        True -> \"original timed out\"
        False -> \"\"
      }
    False -> {
      let #(tree, advanced) = pbt.generate(generator, s)
      let args = pbt.tree_root(tree)
      let first = normalise(run(args))
      let second = normalise(run(args))
      case first == second {
        False -> \"original produced different results for the same input\"
        True -> {
          let timed_out = case first {
            Timeout -> 1
            _ -> 0
          }
          determinism(
            generator,
            advanced,
            remaining - 1,
            checked + 1,
            timeouts + timed_out,
            run,
          )
        }
      }
    }
  }
}

fn emit(
  function: String,
  mutant: String,
  status: String,
  inputs: List(String),
  expected: String,
  expected_inspect: String,
  actual_inspect: String,
  cases: Int,
  shrinks: Int,
  reason: String,
) -> Nil {
  io.println(
    json_object([
      #(\"function\", json_string(function)),
      #(\"mutant\", json_string(mutant)),
      #(\"status\", json_string(status)),
      #(\"inputs\", json_array(inputs)),
      #(\"expected\", expected),
      #(\"expected_inspect\", json_string(expected_inspect)),
      #(\"actual_inspect\", json_string(actual_inspect)),
      #(\"cases\", int.to_string(cases)),
      #(\"shrinks\", int.to_string(shrinks)),
      #(\"reason\", json_string(reason)),
    ]),
  )
}

fn json_object(fields: List(#(String, String))) -> String {
  let rendered =
    list.map(fields, fn(field) { json_string(field.0) <> \":\" <> field.1 })
  \"{\" <> string.join(rendered, \",\") <> \"}\"
}

fn json_array(values: List(String)) -> String {
  \"[\" <> string.join(list.map(values, json_string), \",\") <> \"]\"
}

fn json_string(value: String) -> String {
  let escaped = list.map(string.to_utf_codepoints(value), json_escape)
  \"\\\"\" <> string.concat(escaped) <> \"\\\"\"
}

fn json_escape(point: UtfCodepoint) -> String {
  let code = string.utf_codepoint_to_int(point)
  case code {
    34 -> \"\\\\\\\"\"
    92 -> \"\\\\\\\\\"
    10 -> \"\\\\n\"
    13 -> \"\\\\r\"
    9 -> \"\\\\t\"
    _ ->
      case code < 32 {
        True ->
          \"\\\\u\"
          <> hex_digit(code / 4096)
          <> hex_digit(code / 256 % 16)
          <> hex_digit(code / 16 % 16)
          <> hex_digit(code % 16)
        False -> string.from_utf_codepoints([point])
      }
  }
}

fn hex_digit(value: Int) -> String {
  case value {
    0 -> \"0\"
    1 -> \"1\"
    2 -> \"2\"
    3 -> \"3\"
    4 -> \"4\"
    5 -> \"5\"
    6 -> \"6\"
    7 -> \"7\"
    8 -> \"8\"
    9 -> \"9\"
    10 -> \"a\"
    11 -> \"b\"
    12 -> \"c\"
    13 -> \"d\"
    14 -> \"e\"
    _ -> \"f\"
  }
}"

fn printers(helpers: Helpers) -> List(String) {
  list.flatten([
    when(
      helpers.bools,
      "fn show_bool(value: Bool) -> String {
  case value {
    True -> \"True\"
    False -> \"False\"
  }
}",
    ),
    when(
      helpers.nils,
      "fn show_nil(_value: Nil) -> String {
  \"Nil\"
}",
    ),
    when(
      helpers.strings,
      "fn show_string(value: String) -> String {
  let escaped = list.map(string.to_graphemes(value), escape_source)
  \"\\\"\" <> string.concat(escaped) <> \"\\\"\"
}

fn escape_source(grapheme: String) -> String {
  case grapheme {
    \"\\\\\" -> \"\\\\\\\\\"
    \"\\\"\" -> \"\\\\\\\"\"
    \"\\n\" -> \"\\\\n\"
    \"\\r\" -> \"\\\\r\"
    \"\\t\" -> \"\\\\t\"
    other -> other
  }
}",
    ),
    when(
      helpers.bit_arrays,
      "fn show_bit_array(value: BitArray) -> String {
  case bit_array.bit_size(value) {
    0 -> \"<<>>\"
    _ -> \"<<\" <> string.join(bit_array_segments(value), \", \") <> \">>\"
  }
}

fn bit_array_segments(value: BitArray) -> List(String) {
  case value {
    <<byte:8, rest:bits>> -> [int.to_string(byte), ..bit_array_segments(rest)]
    _ -> bit_array_tail(value)
  }
}

fn bit_array_tail(value: BitArray) -> List(String) {
  case value {
    <<bits:size(1)>> -> [sized_bits(bits, 1)]
    <<bits:size(2)>> -> [sized_bits(bits, 2)]
    <<bits:size(3)>> -> [sized_bits(bits, 3)]
    <<bits:size(4)>> -> [sized_bits(bits, 4)]
    <<bits:size(5)>> -> [sized_bits(bits, 5)]
    <<bits:size(6)>> -> [sized_bits(bits, 6)]
    <<bits:size(7)>> -> [sized_bits(bits, 7)]
    _ -> []
  }
}

fn sized_bits(bits: Int, size: Int) -> String {
  int.to_string(bits) <> \":size(\" <> int.to_string(size) <> \")\"
}",
    ),
    when(
      helpers.lists,
      "fn show_list(values: List(a), show: fn(a) -> String) -> String {
  \"[\" <> string.join(list.map(values, show), \", \") <> \"]\"
}",
    ),
    when(
      helpers.options,
      "fn show_option(value: Option(a), show: fn(a) -> String) -> String {
  case value {
    Some(inner) -> \"Some(\" <> show(inner) <> \")\"
    None -> \"None\"
  }
}",
    ),
    when(
      helpers.results,
      "fn show_result(
  value: Result(a, e),
  show_ok: fn(a) -> String,
  show_error: fn(e) -> String,
) -> String {
  case value {
    Ok(inner) -> \"Ok(\" <> show_ok(inner) <> \")\"
    Error(inner) -> \"Error(\" <> show_error(inner) <> \")\"
  }
}",
    ),
  ])
}

// --- Custom types ------------------------------------------------------------

fn customs(
  spec: ProbeSpec,
  helpers: Helpers,
  generated: List(String),
) -> List(String) {
  helpers.customs
  |> list.reverse
  |> list.map(fn(found) {
    let entry = found.1
    let printer = custom_printer(qualifier(spec.target_module), entry)
    case list.contains(generated, entry.key) {
      True -> custom_generator(entry) <> "\n\n" <> printer
      False -> printer
    }
  })
}

/// One printer per custom type the helpers reached, in the order they appear.
fn custom_printers(module: String, helpers: Helpers) -> List(String) {
  helpers.customs
  |> list.reverse
  |> list.map(fn(found) { custom_printer(module, found.1) })
}

/// The type the helpers of `entry` take and produce, e.g. `target.Box(Int)`.
fn instantiation(entry: Custom) -> String {
  custom_type_source(entry.name, entry.arguments, entry.scope)
}

fn custom_generator(entry: Custom) -> String {
  let of_variants = fn(recursive) {
    entry.variants
    |> list.filter(fn(variant) {
      variant_references(variant, entry.name) == recursive
    })
    |> list.map(variant_generator(_, entry.scope))
  }
  let base = of_variants(False)
  let deeper = of_variants(True)
  "fn gen_type_"
  <> entry.key
  <> "(depth: Int) -> pbt.Generator("
  <> instantiation(entry)
  <> ") {\n  case depth <= 0 {\n    True -> "
  <> one_of_expression(base, entry.name)
  <> "\n    False -> "
  <> one_of_expression(list.append(base, deeper), entry.name)
  <> "\n  }\n}"
}

/// Offers one of the given generators, preferring the first while shrinking.
///
/// A type whose every variant points back at itself holds no finite value, so
/// there is nothing to offer: the generator says so instead of returning a
/// value of the wrong type. `typederive` rejects such a type before it ever
/// reaches here.
fn one_of_expression(options: List(String), name: String) -> String {
  case options {
    [] -> "panic as \"gleam_mutants: " <> name <> " has no values to generate\""
    [only] -> only
    [first, ..rest] ->
      "pbt.one_of(" <> first <> ", [" <> string.join(rest, ", ") <> "])"
  }
}

fn variant_generator(variant: VariantSpec, scope: Scope) -> String {
  let generators =
    list.map(variant.fields, fn(field) {
      generator_expression(field.spec, spent_depth, scope)
    })
  case generators {
    [] -> "pbt.constant(target." <> variant.name <> ")"
    [only] ->
      "pbt.map(" <> only <> ", fn(f0) { target." <> variant.name <> "(f0) })"
    [first, second] ->
      "pbt.map2("
      <> first
      <> ", "
      <> second
      <> ", fn(f0, f1) { target."
      <> variant.name
      <> "(f0, f1) })"
    many -> {
      let arguments =
        list.map(indices(list.length(many)), fn(index) {
          "fields." <> int.to_string(index)
        })
      "pbt.map("
      <> tuple_generator(many)
      <> ", fn(fields) { target."
      <> variant.name
      <> "("
      <> string.join(arguments, ", ")
      <> ") })"
    }
  }
}

fn custom_printer(module: String, entry: Custom) -> String {
  let clauses =
    list.map(entry.variants, fn(variant) {
      let label = module <> "." <> variant.name
      case variant.fields {
        [] -> "    target." <> variant.name <> " -> " <> quoted(label)
        fields -> {
          let names =
            list.map(indices(list.length(fields)), fn(index) {
              "f" <> int.to_string(index)
            })
          let pairs =
            list.zip(list.map(fields, fn(field) { field.spec }), names)
          let #(rendered, _) = show_expressions(pairs, 0, entry.scope)
          // A field with no components — the empty tuple — prints without the
          // pattern reading it, and a binding nothing reads has to be
          // discarded or the compiler warns.
          let bindings =
            list.map(list.zip(names, rendered), fn(pair) {
              bound(pair.0, pair.1)
            })
          "    target."
          <> variant.name
          <> "("
          <> string.join(bindings, ", ")
          <> ") ->\n      "
          <> quoted(label <> "(")
          <> " <> "
          <> string.join(rendered, " <> \", \" <> ")
          <> " <> "
          <> quoted(")")
        }
      }
    })
  "fn show_type_"
  <> entry.key
  <> "(value: "
  <> instantiation(entry)
  <> ") -> String {\n  case value {\n"
  <> string.join(clauses, "\n")
  <> "\n  }\n}"
}

// --- Expressions -------------------------------------------------------------

/// The generator expression that produces values matching `spec`.
///
/// `depth` is the expression each custom-type generator is entered with. A
/// search enters at `initial_depth`, while a generator that is already inside
/// a `gen_type_*` body spends one unit of the budget on every hop — including
/// the hop into a *different* type, which is what keeps two mutually recursive
/// types from resetting each other's budget and generating for ever.
fn generator_expression(spec: GenSpec, depth: String, scope: Scope) -> String {
  case spec {
    IntSpec -> "pbt.small_int()"
    FloatSpec -> "pbt.float()"
    BoolSpec -> "pbt.bool()"
    StringSpec -> "pbt.string()"
    NilSpec -> "pbt.nil()"
    BitArraySpec -> "pbt.bit_array()"
    ListSpec(element) ->
      "pbt.list(" <> generator_expression(element, depth, scope) <> ")"
    OptionSpec(inner) ->
      "pbt.option(" <> generator_expression(inner, depth, scope) <> ")"
    ResultSpec(ok, error) ->
      "pbt.result("
      <> generator_expression(ok, depth, scope)
      <> ", "
      <> generator_expression(error, depth, scope)
      <> ")"
    TupleSpec(elements) ->
      tuple_generator(list.map(elements, generator_expression(_, depth, scope)))
    CustomSpec(name, arguments, _) ->
      "gen_type_" <> custom_key(name, arguments, scope) <> "(" <> depth <> ")"
    RecursiveRef(name) ->
      "gen_type_" <> recursive_key(name, scope) <> "(" <> spent_depth <> ")"
  }
}

/// The depth a search enters a custom-type generator with.
fn entry_depth() -> String {
  int.to_string(initial_depth)
}

/// The depth one hop inside a custom-type generator passes on.
const spent_depth = "depth - 1"

/// A generator of the flat tuple holding one value per given generator.
fn tuple_generator(generators: List(String)) -> String {
  case generators {
    [] -> "pbt.constant(#())"
    [only] -> "pbt.map(" <> only <> ", fn(v) { #(v) })"
    [first, second] -> "pbt.tuple2(" <> first <> ", " <> second <> ")"
    [first, second, third] ->
      "pbt.tuple3(" <> first <> ", " <> second <> ", " <> third <> ")"
    many -> {
      let count = list.length(many)
      let head = list.take(many, count - 1)
      let tail = case list.last(many) {
        Ok(generator) -> generator
        Error(_) -> "pbt.nil()"
      }
      let fields =
        list.map(indices(count - 1), fn(index) {
          "rest." <> int.to_string(index)
        })
      "pbt.map2("
      <> tuple_generator(head)
      <> ", "
      <> tail
      <> ", fn(rest, last) { #("
      <> string.join(list.append(fields, ["last"]), ", ")
      <> ") })"
    }
  }
}

/// The Gleam type of a value matching `spec`, as the probe would write it.
///
/// A parameterised custom type is written with its arguments — `target.Box`
/// alone is not a type the compiler accepts — and a `RecursiveRef` takes the
/// arguments of the enclosing instantiation `scope` holds.
fn type_source(spec: GenSpec, scope: Scope) -> String {
  case spec {
    IntSpec -> "Int"
    FloatSpec -> "Float"
    BoolSpec -> "Bool"
    StringSpec -> "String"
    NilSpec -> "Nil"
    BitArraySpec -> "BitArray"
    ListSpec(element) -> "List(" <> type_source(element, scope) <> ")"
    OptionSpec(inner) -> "Option(" <> type_source(inner, scope) <> ")"
    ResultSpec(ok, error) ->
      "Result("
      <> type_source(ok, scope)
      <> ", "
      <> type_source(error, scope)
      <> ")"
    TupleSpec(elements) ->
      "#("
      <> string.join(list.map(elements, type_source(_, scope)), ", ")
      <> ")"
    CustomSpec(name, arguments, _) -> custom_type_source(name, arguments, scope)
    RecursiveRef(name) ->
      case list.key_find(scope, name) {
        // The reference is dropped from the scope it resolves in, so a pair of
        // types that name each other cannot chase each other for ever.
        Ok(CustomSpec(found, arguments, _)) ->
          custom_type_source(found, arguments, without(scope, name))
        _ -> "target." <> name
      }
  }
}

fn custom_type_source(
  name: String,
  arguments: List(GenSpec),
  scope: Scope,
) -> String {
  case arguments {
    [] -> "target." <> name
    _ ->
      "target."
      <> name
      <> "("
      <> string.join(list.map(arguments, type_source(_, scope)), ", ")
      <> ")"
  }
}

/// True when `body` reads the variable called `name`.
///
/// A generated expression always follows a name with one of a few characters,
/// which keeps `v1` from matching `v10`.
fn mentions(body: String, name: String) -> Bool {
  list.any([")", ",", ".", " "], fn(suffix) {
    string.contains(body, name <> suffix)
  })
}

/// Names a binding, discarding it when the body never reads it.
///
/// Gleam rejects an argument nothing uses under `--warnings-as-errors`, and a
/// printer for a value with no components — the empty tuple — never reads it.
fn bound(name: String, body: String) -> String {
  case mentions(body, name) {
    True -> name
    False -> "_" <> name
  }
}

/// The expression printing `variable` as Gleam source, plus the next free name.
fn show_expression(
  spec: GenSpec,
  variable: String,
  fresh: Int,
  scope: Scope,
) -> #(String, Int) {
  case spec {
    IntSpec -> #("int.to_string(" <> variable <> ")", fresh)
    FloatSpec -> #("float.to_string(" <> variable <> ")", fresh)
    BoolSpec -> #("show_bool(" <> variable <> ")", fresh)
    StringSpec -> #("show_string(" <> variable <> ")", fresh)
    NilSpec -> #("show_nil(" <> variable <> ")", fresh)
    BitArraySpec -> #("show_bit_array(" <> variable <> ")", fresh)
    ListSpec(element) -> {
      let name = "v" <> int.to_string(fresh)
      let #(inner, next) = show_expression(element, name, fresh + 1, scope)
      #(
        "show_list("
          <> variable
          <> ", fn("
          <> bound(name, inner)
          <> ") { "
          <> inner
          <> " })",
        next,
      )
    }
    OptionSpec(inner_spec) -> {
      let name = "v" <> int.to_string(fresh)
      let #(inner, next) = show_expression(inner_spec, name, fresh + 1, scope)
      #(
        "show_option("
          <> variable
          <> ", fn("
          <> bound(name, inner)
          <> ") { "
          <> inner
          <> " })",
        next,
      )
    }
    ResultSpec(ok, error) -> {
      let ok_name = "v" <> int.to_string(fresh)
      let #(ok_inner, after_ok) = show_expression(ok, ok_name, fresh + 1, scope)
      let error_name = "v" <> int.to_string(after_ok)
      let #(error_inner, next) =
        show_expression(error, error_name, after_ok + 1, scope)
      #(
        "show_result("
          <> variable
          <> ", fn("
          <> bound(ok_name, ok_inner)
          <> ") { "
          <> ok_inner
          <> " }, fn("
          <> bound(error_name, error_inner)
          <> ") { "
          <> error_inner
          <> " })",
        next,
      )
    }
    TupleSpec([]) -> #("\"#()\"", fresh)
    TupleSpec(elements) -> {
      let pairs =
        list.zip(
          elements,
          list.map(indices(list.length(elements)), fn(index) {
            variable <> "." <> int.to_string(index)
          }),
        )
      let #(rendered, next) = show_expressions(pairs, fresh, scope)
      #(
        "\"#(\" <> " <> string.join(rendered, " <> \", \" <> ") <> " <> \")\"",
        next,
      )
    }
    CustomSpec(name, arguments, _) -> #(
      "show_type_"
        <> custom_key(name, arguments, scope)
        <> "("
        <> variable
        <> ")",
      fresh,
    )
    RecursiveRef(name) -> #(
      "show_type_" <> recursive_key(name, scope) <> "(" <> variable <> ")",
      fresh,
    )
  }
}

fn show_expressions(
  pairs: List(#(GenSpec, String)),
  fresh: Int,
  scope: Scope,
) -> #(List(String), Int) {
  let #(reversed, next) =
    list.fold(pairs, #([], fresh), fn(acc, pair) {
      let #(rendered, counter) = acc
      let #(spec, variable) = pair
      let #(text, advanced) = show_expression(spec, variable, counter, scope)
      #([text, ..rendered], advanced)
    })
  #(list.reverse(reversed), next)
}

fn indices(count: Int) -> List(Int) {
  counted(0, count)
}

fn counted(from: Int, to: Int) -> List(Int) {
  case from >= to {
    True -> []
    False -> [from, ..counted(from + 1, to)]
  }
}

// --- Per-function code -------------------------------------------------------

fn function_blocks(functions: List(ProbeFunction)) -> List(String) {
  let #(blocks, _) =
    list.fold(functions, #([], 0), fn(acc, probe) {
      let #(blocks, index) = acc
      let #(rendered, next) = one_function(probe, index)
      #(list.append(blocks, rendered), next)
    })
  blocks
}

fn one_function(probe: ProbeFunction, index: Int) -> #(List(String), Int) {
  let plan = probe.plan
  let searches =
    list.index_map(probe.mutant_ids, fn(mutant, offset) {
      search_function(probe, mutant, offset, index + offset)
    })
  let result_printer = case plan.return_spec {
    Some(spec) -> [result_printer_source(plan.name, spec)]
    None -> []
  }
  let blocks =
    list.flatten([
      [
        probe_function(probe),
        check_function(plan),
        generator_function(plan),
        args_printer(plan),
      ],
      result_printer,
      [runner_function(plan), agrees_function(plan)],
      searches,
    ])
  #(blocks, index + list.length(probe.mutant_ids))
}

fn probe_function(probe: ProbeFunction) -> String {
  let name = probe.plan.name
  let searches =
    list.index_map(probe.mutant_ids, fn(_, offset) {
      "      search_" <> name <> "_" <> int.to_string(offset) <> "()"
    })
  let skipped =
    list.map(probe.mutant_ids, fn(mutant) {
      emit_call("      ", [
        quoted(name),
        quoted(mutant),
        "\"nondeterministic\"",
        "[]",
        "\"null\"",
        "\"\"",
        "\"\"",
        "0",
        "0",
        "reason",
      ])
    })
  "fn probe_"
  <> name
  <> "() -> Nil {\n  case check_"
  <> name
  <> "() {\n    \"\" -> {\n"
  <> string.join(list.append(searches, ["      Nil"]), "\n")
  <> "\n    }\n    reason -> {\n"
  <> string.join(list.append(skipped, ["      Nil"]), "\n")
  <> "\n    }\n  }\n}"
}

fn check_function(plan: typederive.FunctionPlan) -> String {
  "fn check_"
  <> plan.name
  <> "() -> String {\n  determinism(\n    gen_"
  <> plan.name
  <> "(),\n    pbt.seed(probe_seed + "
  <> int.to_string(determinism_offset)
  <> "),\n    nondeterminism_checks,\n    0,\n    0,\n    fn(args) { run_"
  <> plan.name
  <> "(args, \"\") },\n  )\n}"
}

fn generator_function(plan: typederive.FunctionPlan) -> String {
  let generators =
    list.map(plan.parameters, fn(parameter) {
      generator_expression(parameter.spec, entry_depth(), no_scope)
    })
  let body = case generators {
    [] -> "pbt.constant(Nil)"
    [only] -> only
    many -> tuple_generator(many)
  }
  "fn gen_"
  <> plan.name
  <> "() -> pbt.Generator("
  <> args_type(plan)
  <> ") {\n  "
  <> body
  <> "\n}"
}

fn args_type(plan: typederive.FunctionPlan) -> String {
  case plan.parameters {
    [] -> "Nil"
    [only] -> type_source(only.spec, no_scope)
    many ->
      "#("
      <> string.join(
        list.map(many, fn(parameter) { type_source(parameter.spec, no_scope) }),
        ", ",
      )
      <> ")"
  }
}

/// The names the probe reads each argument out of the generated value with.
fn argument_variables(plan: typederive.FunctionPlan) -> List(String) {
  case plan.parameters {
    [] -> []
    [_] -> ["args"]
    many ->
      list.map(indices(list.length(many)), fn(index) {
        "args." <> int.to_string(index)
      })
  }
}

fn args_printer(plan: typederive.FunctionPlan) -> String {
  case plan.parameters {
    [] ->
      "fn show_args_" <> plan.name <> "(_args: Nil) -> List(String) {\n  []\n}"
    parameters -> {
      let pairs =
        list.zip(
          list.map(parameters, fn(parameter) { parameter.spec }),
          argument_variables(plan),
        )
      let #(rendered, _) = show_expressions(pairs, 0, no_scope)
      let printed = string.join(rendered, ", ")
      // A parameter list of nothing but empty tuples prints without reading
      // the value, and an argument a function never reads has to be discarded.
      "fn show_args_"
      <> plan.name
      <> "("
      <> bound("args", printed)
      <> ": "
      <> args_type(plan)
      <> ") -> List(String) {\n  ["
      <> printed
      <> "]\n}"
    }
  }
}

fn result_printer_source(name: String, spec: GenSpec) -> String {
  let #(rendered, _) = show_expression(spec, "value", 0, no_scope)
  "fn show_result_"
  <> name
  <> "("
  <> bound("value", rendered)
  <> ": "
  <> type_source(spec, no_scope)
  <> ") -> String {\n  "
  <> rendered
  <> "\n}"
}

fn runner_function(plan: typederive.FunctionPlan) -> String {
  let binding = case plan.parameters {
    [] -> "_args: Nil"
    _ -> "args: " <> args_type(plan)
  }
  "fn run_"
  <> plan.name
  <> "("
  <> binding
  <> ", mutant: String) {\n  isolated(fn() { target."
  <> plan.name
  <> "("
  <> string.join(argument_variables(plan), ", ")
  <> ") }, mutant, call_timeout_ms)\n}"
}

fn agrees_function(plan: typederive.FunctionPlan) -> String {
  "fn agrees_"
  <> plan.name
  <> "(args: "
  <> args_type(plan)
  <> ", mutant: String) -> Bool {\n  normalise(run_"
  <> plan.name
  <> "(args, \"\"))\n  == normalise(run_"
  <> plan.name
  <> "(args, mutant))\n}"
}

/// Renders the search for one mutant.
///
/// `offset` numbers the search within its function, while `index` shifts the
/// seed so that no two searches in the module draw the same inputs.
fn search_function(
  probe: ProbeFunction,
  mutant: String,
  offset: Int,
  index: Int,
) -> String {
  let name = probe.plan.name
  let suffix = int.to_string(offset)
  let expected = case probe.plan.return_spec {
    Some(_) ->
      "      let expected = case original {\n        Value(value) -> json_string(show_result_"
      <> name
      <> "(value))\n        _ -> \"null\"\n      }"
    None -> "      let expected = \"null\""
  }
  "fn search_"
  <> name
  <> "_"
  <> suffix
  <> "() -> Nil {\n  let outcome =\n    pbt.find_counterexample(\n      gen_"
  <> name
  <> "(),\n      pbt.seed(probe_seed + "
  <> int.to_string(index)
  <> "),\n      max_cases,\n      max_shrinks,\n      fn(args) { agrees_"
  <> name
  <> "(args, "
  <> quoted(mutant)
  <> ") },\n    )\n  case outcome {\n    pbt.Found(shrunk, _, cases, shrinks) -> {\n      let original = normalise(run_"
  <> name
  <> "(shrunk, \"\"))\n      let mutated = normalise(run_"
  <> name
  <> "(shrunk, "
  <> quoted(mutant)
  <> "))\n"
  <> expected
  <> "\n"
  <> emit_call("      ", [
    quoted(name),
    quoted(mutant),
    "\"distinguished\"",
    "show_args_" <> name <> "(shrunk)",
    "expected",
    "string.inspect(original)",
    "string.inspect(mutated)",
    "cases",
    "shrinks",
    "\"\"",
  ])
  <> "\n    }\n    pbt.NotFound(cases) ->\n"
  <> emit_call("      ", [
    quoted(name),
    quoted(mutant),
    "\"indistinguishable\"",
    "[]",
    "\"null\"",
    "\"\"",
    "\"\"",
    "cases",
    "0",
    "\"\"",
  ])
  <> "\n  }\n}"
}

fn emit_call(indent: String, arguments: List(String)) -> String {
  indent
  <> "emit(\n"
  <> string.join(
    list.map(arguments, fn(argument) { indent <> "  " <> argument <> "," }),
    "\n",
  )
  <> "\n"
  <> indent
  <> ")"
}

// --- Rendering the Erlang FFI ------------------------------------------------

/// Renders the Erlang module that runs one call in an isolated process.
///
/// `isolated/3` spawns a monitored process, seeds its process dictionary with
/// the active mutant (an empty binary means the original), and answers with
/// `{value, V}`, `{panic, Reason}` or `timeout` — the Erlang shapes of the
/// probe's `Observation` constructors. A unique tag keeps a late reply from a
/// killed child out of the caller's mailbox.
pub fn render_ffi(spec: ProbeSpec) -> String {
  "%% Generated by gleam_mutants. Do not edit.
-module(" <> spec.ffi_module <> ").
-export([isolated/3]).

isolated(Fun, Mutant, TimeoutMs) ->
    Parent = self(),
    Tag = make_ref(),
    {Pid, MonitorRef} = spawn_monitor(fun() ->
        %% Always set the key, empty binary included: it matches no mutant id,
        %% so the original runs even when the surrounding VM carries a stray
        %% persistent term or GLEAM_MUTANTS_ACTIVE variable.
        put(gleam_mutants_active, Mutant),
        %% Catching here keeps a panicking mutant from writing a crash report
        %% onto the stdout the probe reports its results on.
        Answer = try {value, Fun()} catch
            Class:Reason:Stack -> {panic, reason_text({Class, Reason, Stack})}
        end,
        Parent ! {Tag, Answer}
    end),
    receive
        {'DOWN', MonitorRef, process, Pid, normal} ->
            receive
                {Tag, Answer} -> Answer
            after 0 ->
                {panic, <<\"no result\">>}
            end;
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            flush(Tag),
            {panic, reason_text(Reason)}
    after TimeoutMs ->
        exit(Pid, kill),
        receive
            {'DOWN', MonitorRef, process, Pid, _} -> ok
        end,
        flush(Tag),
        timeout
    end.

flush(Tag) ->
    receive
        {Tag, _} -> flush(Tag)
    after 0 -> ok
    end.

reason_text(Reason) ->
    Text = unicode:characters_to_binary(io_lib:format(\"~p\", [Reason])),
    case byte_size(Text) > 200 of
        true -> valid_prefix(binary:part(Text, 0, 200));
        false -> Text
    end.

valid_prefix(<<>>) ->
    <<>>;
valid_prefix(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Valid when is_binary(Valid) -> Valid;
        _ -> valid_prefix(binary:part(Bin, 0, byte_size(Bin) - 1))
    end.
"
}
