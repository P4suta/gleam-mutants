// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import glance
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam_mutants/suggest/genspec.{
  type GenSpec, BitArraySpec, BoolSpec, CustomSpec, FieldSpec, FloatSpec,
  IntSpec, ListSpec, NilSpec, OptionSpec, RecursiveRef, ResultSpec, StringSpec,
  TupleSpec, VariantSpec,
}
import gleam_mutants/suggest/typederive.{
  type FunctionPlan, FunctionPlan, ParameterPlan,
}

// --- helpers ----------------------------------------------------------------

fn parsed(source: String) -> glance.Module {
  let assert Ok(module) = glance.module(source)
  module
}

fn function_named(module: glance.Module, name: String) -> glance.Function {
  let assert Ok(found) =
    list.find(module.functions, fn(candidate) {
      candidate.definition.name == name
    })
  found.definition
}

fn annotated_parameters(function: glance.Function) -> List(glance.Type) {
  list.filter_map(function.parameters, fn(parameter) {
    option.to_result(parameter.type_, Nil)
  })
}

/// Derives every annotated parameter type of the named function in `source`.
fn derive_parameters(
  source: String,
  name: String,
) -> List(Result(GenSpec, String)) {
  let module = parsed(source)
  let ctx = typederive.context(module)
  function_named(module, name)
  |> annotated_parameters
  |> list.map(typederive.derive_type(ctx, _))
}

/// Derives the single parameter type of `pub fn probe(x: T)` in `source`.
fn derive_probe(source: String) -> Result(GenSpec, String) {
  let assert [spec] = derive_parameters(source, "probe")
  spec
}

fn plan_of(source: String, name: String) -> Result(FunctionPlan, String) {
  let module = parsed(source)
  typederive.derive_function(
    typederive.context(module),
    function_named(module, name),
  )
}

fn nat_spec() -> GenSpec {
  CustomSpec("Nat", [], [
    VariantSpec("Zero", []),
    VariantSpec("Succ", [FieldSpec(None, RecursiveRef("Nat"))]),
  ])
}

// --- primitives and builtin containers --------------------------------------

pub fn primitive_types_derive_to_primitive_specs_test() {
  assert derive_parameters(
      "pub fn probe(a: Int, b: Float, c: Bool, d: String, e: Nil, f: BitArray) -> Nil { todo }",
      "probe",
    )
    == [
      Ok(IntSpec),
      Ok(FloatSpec),
      Ok(BoolSpec),
      Ok(StringSpec),
      Ok(NilSpec),
      Ok(BitArraySpec),
    ]
}

pub fn builtin_containers_derive_to_container_specs_test() {
  assert derive_probe("pub fn probe(x: List(Int)) -> Nil { todo }")
    == Ok(ListSpec(IntSpec))
  assert derive_probe("pub fn probe(x: Option(String)) -> Nil { todo }")
    == Ok(OptionSpec(StringSpec))
  assert derive_probe("pub fn probe(x: Result(Bool, Nil)) -> Nil { todo }")
    == Ok(ResultSpec(BoolSpec, NilSpec))
  assert derive_probe("pub fn probe(x: #(Int, Float, String)) -> Nil { todo }")
    == Ok(TupleSpec([IntSpec, FloatSpec, StringSpec]))
}

pub fn nested_container_types_nest_their_specs_test() {
  assert derive_probe(
      "pub fn probe(x: List(Option(Result(Int, String)))) -> Nil { todo }",
    )
    == Ok(ListSpec(OptionSpec(ResultSpec(IntSpec, StringSpec))))
  assert derive_probe(
      "pub fn probe(x: #(List(Int), Option(#(Bool, Float)))) -> Nil { todo }",
    )
    == Ok(
      TupleSpec([
        ListSpec(IntSpec),
        OptionSpec(TupleSpec([BoolSpec, FloatSpec])),
      ]),
    )
}

pub fn qualified_option_type_derives_to_option_spec_test() {
  assert derive_probe(
      "import gleam/option\npub fn probe(x: option.Option(Int)) -> Nil { todo }",
    )
    == Ok(OptionSpec(IntSpec))
}

// --- aliases and custom types -----------------------------------------------

pub fn type_aliases_are_expanded_before_derivation_test() {
  assert derive_probe("pub type Id = Int pub fn probe(x: Id) -> Nil { todo }")
    == Ok(IntSpec)
  assert derive_probe(
      "pub type Id = Int pub type Ids = List(Id) pub fn probe(x: Ids) -> Nil { todo }",
    )
    == Ok(ListSpec(IntSpec))
}

pub fn parametric_type_alias_substitutes_its_arguments_test() {
  assert derive_probe(
      "pub type Pair(a) = #(a, a) pub fn probe(x: Pair(Bool)) -> Nil { todo }",
    )
    == Ok(TupleSpec([BoolSpec, BoolSpec]))
}

pub fn parametric_custom_type_substitutes_its_arguments_test() {
  assert derive_probe(
      "pub type Box(a) { Box(inner: a) } pub fn probe(x: Box(String)) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Box", [StringSpec], [
        VariantSpec("Box", [FieldSpec(Some("inner"), StringSpec)]),
      ]),
    )
}

/// The instantiation's arguments are what tell `Box(Int)` and `Box(String)`
/// apart: their variants can be identical when the parameter is phantom, and
/// the probe has to name a helper and write an annotation per instantiation.
pub fn parameterised_custom_types_record_their_type_arguments_test() {
  assert derive_probe(
      "pub type Box(a) { Box(inner: a) } pub fn probe(x: Box(Int)) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Box", [IntSpec], [
        VariantSpec("Box", [FieldSpec(Some("inner"), IntSpec)]),
      ]),
    )
  assert derive_probe(
      "pub type Box(a) { Box(inner: a) } pub fn probe(x: Box(List(String))) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Box", [ListSpec(StringSpec)], [
        VariantSpec("Box", [FieldSpec(Some("inner"), ListSpec(StringSpec))]),
      ]),
    )
}

pub fn a_type_without_parameters_records_no_type_arguments_test() {
  assert derive_probe(
      "pub type Colour { Red Green Blue } pub fn probe(x: Colour) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Colour", [], [
        VariantSpec("Red", []),
        VariantSpec("Green", []),
        VariantSpec("Blue", []),
      ]),
    )
}

/// A recursive reference names the type that is in progress, which is this
/// very instantiation: `Tree(a)` inside `Tree(Int)` is `Tree(Int)` again.
pub fn a_recursive_parameterised_type_keeps_its_arguments_test() {
  assert derive_probe(
      "pub type Tree(a) { Leaf Node(Tree(a), a, Tree(a)) } pub fn probe(x: Tree(Int)) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Tree", [IntSpec], [
        VariantSpec("Leaf", []),
        VariantSpec("Node", [
          FieldSpec(None, RecursiveRef("Tree")),
          FieldSpec(None, IntSpec),
          FieldSpec(None, RecursiveRef("Tree")),
        ]),
      ]),
    )
}

/// A type whose recursion runs through another parameterised type: the
/// argument of the inner type is the reference back at the outer one, so the
/// instantiation the reference stands for is only known from where it sits.
pub fn a_type_argument_can_be_the_recursive_reference_test() {
  assert derive_probe(
      "pub type Box(a) { Box(inner: a) } pub type Nest(a) { Tip Fork(Box(Nest(a)), a) } pub fn probe(x: Nest(Int)) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Nest", [IntSpec], [
        VariantSpec("Tip", []),
        VariantSpec("Fork", [
          FieldSpec(
            None,
            CustomSpec("Box", [RecursiveRef("Nest")], [
              VariantSpec("Box", [
                FieldSpec(Some("inner"), RecursiveRef("Nest")),
              ]),
            ]),
          ),
          FieldSpec(None, IntSpec),
        ]),
      ]),
    )
}

pub fn two_instantiations_of_one_type_derive_apart_test() {
  let box = fn(inner) {
    CustomSpec("Box", [inner], [
      VariantSpec("Box", [FieldSpec(Some("inner"), inner)]),
    ])
  }
  assert derive_probe(
      "pub type Box(a) { Box(inner: a) } pub fn probe(x: #(Box(Int), Box(String))) -> Nil { todo }",
    )
    == Ok(TupleSpec([box(IntSpec), box(StringSpec)]))
}

pub fn variant_fields_keep_their_labels_and_order_test() {
  assert derive_probe(
      "pub type Point { Point(Int, Float) } pub fn probe(x: Point) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Point", [], [
        VariantSpec("Point", [
          FieldSpec(None, IntSpec),
          FieldSpec(None, FloatSpec),
        ]),
      ]),
    )
  assert derive_probe(
      "pub type User { User(name: String, age: Int) } pub fn probe(x: User) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("User", [], [
        VariantSpec("User", [
          FieldSpec(Some("name"), StringSpec),
          FieldSpec(Some("age"), IntSpec),
        ]),
      ]),
    )
  assert derive_probe(
      "pub type Tagged { Tagged(Int, label: String) } pub fn probe(x: Tagged) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Tagged", [], [
        VariantSpec("Tagged", [
          FieldSpec(None, IntSpec),
          FieldSpec(Some("label"), StringSpec),
        ]),
      ]),
    )
}

pub fn multi_variant_enums_keep_source_order_test() {
  assert derive_probe(
      "pub type Colour { Red Green Blue } pub fn probe(x: Colour) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Colour", [], [
        VariantSpec("Red", []),
        VariantSpec("Green", []),
        VariantSpec("Blue", []),
      ]),
    )
}

// --- recursion --------------------------------------------------------------

pub fn self_recursive_types_use_a_recursive_reference_test() {
  assert derive_probe(
      "pub type Nat { Zero Succ(Nat) } pub fn probe(x: Nat) -> Nil { todo }",
    )
    == Ok(nat_spec())
}

pub fn nested_self_references_become_recursive_references_test() {
  assert derive_probe(
      "pub type Tree { Leaf(Int) Node(children: List(Tree)) } pub fn probe(x: Tree) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Tree", [], [
        VariantSpec("Leaf", [FieldSpec(None, IntSpec)]),
        VariantSpec("Node", [
          FieldSpec(Some("children"), ListSpec(RecursiveRef("Tree"))),
        ]),
      ]),
    )
}

pub fn recursive_types_without_a_base_case_are_rejected_test() {
  assert derive_probe(
      "pub type Loop { Loop(Loop) } pub fn probe(x: Loop) -> Nil { todo }",
    )
    == Error("recursive type Loop has no base case")
  assert derive_probe(
      "pub type Bad { Bad(#(Bad, Int)) } pub fn probe(x: Bad) -> Nil { todo }",
    )
    == Error("recursive type Bad has no base case")
}

pub fn mutually_recursive_types_reference_the_in_progress_type_test() {
  assert derive_probe(
      "pub type Expr { Lit(Int) Wrap(Stmt) } pub type Stmt { Stmt(Expr) } pub fn probe(x: Expr) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("Expr", [], [
        VariantSpec("Lit", [FieldSpec(None, IntSpec)]),
        VariantSpec("Wrap", [
          FieldSpec(
            None,
            CustomSpec("Stmt", [], [
              VariantSpec("Stmt", [FieldSpec(None, RecursiveRef("Expr"))]),
            ]),
          ),
        ]),
      ]),
    )
}

/// A parameterised type recurses at one instantiation only.
///
/// `W(a)` holding a `W(Int)` is two types, and the probe names a helper and
/// writes an annotation per instantiation, so a reference back at the type
/// being derived can only be taken when it asks for that same instantiation.
pub fn a_type_recursing_at_another_instantiation_is_rejected_test() {
  assert derive_probe(
      "pub type W(a) { Stop Go(W(Int)) } pub fn probe(x: W(String)) -> Nil { todo }",
    )
    == Error("recursive type W is used at another instantiation")
}

/// The very same declaration derives at the instantiation it recurses at.
pub fn a_type_recursing_at_its_own_instantiation_is_derived_test() {
  assert derive_probe(
      "pub type W(a) { Stop Go(W(Int)) } pub fn probe(x: W(Int)) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("W", [IntSpec], [
        VariantSpec("Stop", []),
        VariantSpec("Go", [FieldSpec(None, RecursiveRef("W"))]),
      ]),
    )
}

/// The same wall guards the recursion that has no end: a type whose argument
/// grows every time round would expand for ever.
pub fn a_type_whose_recursion_grows_its_argument_is_rejected_test() {
  assert derive_probe(
      "pub type N(a) { NE NN(N(List(a))) } pub fn probe(x: N(Int)) -> Nil { todo }",
    )
    == Error("recursive type N is used at another instantiation")
}

/// A cycle of two parameterised types that changes instantiation as it turns
/// is the same wall, reached one type further along.
pub fn a_mutual_cycle_that_changes_instantiation_is_rejected_test() {
  assert derive_probe(
      "pub type A(x) { AE AA(B(Int)) } pub type B(y) { BE BB(A(y)) } pub fn probe(x: A(String)) -> Nil { todo }",
    )
    == Error("recursive type A is used at another instantiation")
}

/// A cycle that keeps its instantiation as it turns derives, and the
/// reference back names the type it returns to.
pub fn a_mutual_cycle_at_one_instantiation_is_derived_test() {
  assert derive_probe(
      "pub type A(x) { AE AA(B(x)) } pub type B(y) { BE BB(A(y)) } pub fn probe(x: A(Int)) -> Nil { todo }",
    )
    == Ok(
      CustomSpec("A", [IntSpec], [
        VariantSpec("AE", []),
        VariantSpec("AA", [
          FieldSpec(
            None,
            CustomSpec("B", [IntSpec], [
              VariantSpec("BE", []),
              VariantSpec("BB", [FieldSpec(None, RecursiveRef("A"))]),
            ]),
          ),
        ]),
      ]),
    )
}

// --- rejected types ---------------------------------------------------------

pub fn private_custom_types_are_rejected_test() {
  assert derive_probe(
      "type Secret { Secret(Int) } pub fn probe(x: Secret) -> Nil { todo }",
    )
    == Error("private type Secret")
}

pub fn opaque_custom_types_are_rejected_test() {
  assert derive_probe(
      "pub opaque type Token { Token(Int) } pub fn probe(x: Token) -> Nil { todo }",
    )
    == Error("opaque type Token")
}

pub fn types_from_other_modules_are_rejected_test() {
  assert derive_probe(
      "import gleam/dict\npub fn probe(x: dict.Dict(String, Int)) -> Nil { todo }",
    )
    == Error("external type dict.Dict is not supported yet")
}

pub fn unknown_type_names_are_rejected_test() {
  assert derive_probe("pub fn probe(x: Mystery) -> Nil { todo }")
    == Error("unknown type Mystery")
}

pub fn a_failing_variant_field_fails_the_whole_custom_type_test() {
  assert derive_probe(
      "pub type Wrapper { Wrapper(Mystery) } pub fn probe(x: Wrapper) -> Nil { todo }",
    )
    == Error("unknown type Mystery")
}

pub fn function_typed_values_are_rejected_test() {
  assert derive_probe("pub fn probe(x: fn(Int) -> Int) -> Nil { todo }")
    == Error("function-typed values are not supported")
}

pub fn hole_types_are_rejected_test() {
  assert result.is_error(derive_probe(
    "pub fn probe(x: List(_)) -> Nil { todo }",
  ))
}

pub fn unbound_type_variables_derive_to_int_test() {
  assert derive_probe("pub fn probe(x: a) -> a { todo }") == Ok(IntSpec)
  assert derive_probe("pub fn probe(x: List(a)) -> Nil { todo }")
    == Ok(ListSpec(IntSpec))
}

// --- function plans ---------------------------------------------------------

pub fn derive_function_plans_parameters_and_return_test() {
  assert plan_of(
      "pub type Colour { Red Green } pub fn paint(count: Int, with colour: Colour, _skip: Bool) -> String { todo }",
      "paint",
    )
    == Ok(FunctionPlan(
      "paint",
      [
        ParameterPlan("count", None, IntSpec),
        ParameterPlan(
          "colour",
          Some("with"),
          CustomSpec("Colour", [], [
            VariantSpec("Red", []),
            VariantSpec("Green", []),
          ]),
        ),
        ParameterPlan("skip", None, BoolSpec),
      ],
      Some(StringSpec),
    ))
}

pub fn derive_function_keeps_ok_when_the_return_type_does_not_derive_test() {
  assert plan_of("pub fn probe(x: Int) -> Mystery { todo }", "probe")
    == Ok(FunctionPlan("probe", [ParameterPlan("x", None, IntSpec)], None))
  assert plan_of("pub fn probe(x: Int) { todo }", "probe")
    == Ok(FunctionPlan("probe", [ParameterPlan("x", None, IntSpec)], None))
}

pub fn derive_function_rejects_private_functions_test() {
  let assert Error(reason) =
    plan_of("fn helper(x: Int) -> Int { todo }", "helper")
  assert string.contains(reason, "private")
  assert string.contains(reason, "helper")
}

pub fn derive_function_rejects_unannotated_parameters_test() {
  let assert Error(reason) =
    plan_of("pub fn probe(count: Int, raw) -> Nil { todo }", "probe")
  assert string.contains(reason, "raw")
}

pub fn derive_function_error_names_the_failing_parameter_test() {
  let assert Error(reason) =
    plan_of("pub fn probe(count: Int, extra: Mystery) -> Nil { todo }", "probe")
  assert string.contains(reason, "extra")
  assert string.contains(reason, "unknown type Mystery")
}

// --- describe ---------------------------------------------------------------

pub fn describe_renders_a_readable_one_line_form_test() {
  assert genspec.describe(IntSpec) == "Int"
  assert genspec.describe(FloatSpec) == "Float"
  assert genspec.describe(BoolSpec) == "Bool"
  assert genspec.describe(StringSpec) == "String"
  assert genspec.describe(NilSpec) == "Nil"
  assert genspec.describe(BitArraySpec) == "BitArray"
  assert genspec.describe(ListSpec(OptionSpec(IntSpec))) == "List(Option(Int))"
  assert genspec.describe(ResultSpec(BoolSpec, StringSpec))
    == "Result(Bool, String)"
  assert genspec.describe(TupleSpec([IntSpec, FloatSpec])) == "#(Int, Float)"
  assert genspec.describe(RecursiveRef("Nat")) == "Nat"
  assert genspec.describe(nat_spec()) == "Nat{Zero | Succ(Nat)}"
  assert genspec.describe(
      CustomSpec("Box", [StringSpec], [
        VariantSpec("Box", [FieldSpec(Some("inner"), StringSpec)]),
      ]),
    )
    == "Box{Box(inner: String)}"
}
