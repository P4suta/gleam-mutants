// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Generator specifications: the target-independent shape of a value that the
// suggestion engine knows how to build inputs for.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The shape of a value a generator can produce.
///
/// `RecursiveRef` points back at an enclosing `CustomSpec` that is still being
/// defined, which keeps recursive types finite.
///
/// A `CustomSpec` describes one *instantiation* of a type: `type_arguments`
/// holds the arguments it was instantiated with, in declaration order, and is
/// empty for a type that takes none.
pub type GenSpec {
  IntSpec
  FloatSpec
  BoolSpec
  StringSpec
  NilSpec
  BitArraySpec
  ListSpec(element: GenSpec)
  OptionSpec(inner: GenSpec)
  ResultSpec(ok: GenSpec, error: GenSpec)
  TupleSpec(elements: List(GenSpec))
  CustomSpec(
    name: String,
    type_arguments: List(GenSpec),
    variants: List(VariantSpec),
  )
  RecursiveRef(name: String)
}

/// One constructor of a custom type, with its fields in source order.
pub type VariantSpec {
  VariantSpec(name: String, fields: List(FieldSpec))
}

/// One constructor field, labelled when the source labels it.
pub type FieldSpec {
  FieldSpec(label: Option(String), spec: GenSpec)
}

/// Renders a specification as a readable one-line string for diagnostics.
pub fn describe(spec: GenSpec) -> String {
  case spec {
    IntSpec -> "Int"
    FloatSpec -> "Float"
    BoolSpec -> "Bool"
    StringSpec -> "String"
    NilSpec -> "Nil"
    BitArraySpec -> "BitArray"
    ListSpec(element) -> "List(" <> describe(element) <> ")"
    OptionSpec(inner) -> "Option(" <> describe(inner) <> ")"
    ResultSpec(ok, error) ->
      "Result(" <> describe(ok) <> ", " <> describe(error) <> ")"
    TupleSpec(elements) ->
      "#(" <> string.join(list.map(elements, describe), ", ") <> ")"
    CustomSpec(name, _, variants) ->
      name
      <> "{"
      <> string.join(list.map(variants, describe_variant), " | ")
      <> "}"
    RecursiveRef(name) -> name
  }
}

/// Renders one variant, e.g. `Zero` or `Succ(Nat)`.
pub fn describe_variant(variant: VariantSpec) -> String {
  case variant.fields {
    [] -> variant.name
    fields ->
      variant.name
      <> "("
      <> string.join(list.map(fields, describe_field), ", ")
      <> ")"
  }
}

/// Renders one field, prefixing its label when it has one.
pub fn describe_field(field: FieldSpec) -> String {
  case field.label {
    Some(label) -> label <> ": " <> describe(field.spec)
    None -> describe(field.spec)
  }
}
