// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Derives generator specifications from the Glance type AST of a module.
//
// The suggestion probe lives in a module of its own, so only types it can
// name and construct are derivable: public, non-opaque custom types of the
// module under test, its type aliases, and the built-in shapes.

import glance
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mutants/suggest/genspec.{
  type FieldSpec, type GenSpec, type VariantSpec, BitArraySpec, BoolSpec,
  CustomSpec, FieldSpec, FloatSpec, IntSpec, ListSpec, NilSpec, OptionSpec,
  RecursiveRef, ResultSpec, StringSpec, TupleSpec, VariantSpec,
}

/// The type declarations of one module, used to resolve type names.
pub type Context {
  Context(
    custom_types: List(glance.CustomType),
    type_aliases: List(glance.TypeAlias),
  )
}

/// A single derivable parameter of a function under test.
pub type ParameterPlan {
  ParameterPlan(name: String, label: Option(String), spec: GenSpec)
}

/// Everything the probe needs in order to call one function with random input.
pub type FunctionPlan {
  FunctionPlan(
    name: String,
    parameters: List(ParameterPlan),
    return_spec: Option(GenSpec),
  )
}

/// Bound type variables plus the types whose derivation is still in progress.
///
/// A type in progress is remembered with the arguments it is being derived at:
/// a reference back at it stands for that one instantiation, and `Box(Int)`
/// inside `Box(String)` is another type entirely.
type Scope {
  Scope(
    bindings: List(#(String, GenSpec)),
    types_in_progress: List(#(String, List(GenSpec))),
    aliases_in_progress: List(String),
  )
}

/// Collects the custom types and type aliases declared by a module.
pub fn context(module: glance.Module) -> Context {
  Context(
    custom_types: list.map(module.custom_types, fn(definition) {
      definition.definition
    }),
    type_aliases: list.map(module.type_aliases, fn(definition) {
      definition.definition
    }),
  )
}

/// Derives the generator specification of one type, or explains why it cannot.
pub fn derive_type(
  ctx: Context,
  type_: glance.Type,
) -> Result(GenSpec, String) {
  derive_in(ctx, Scope([], [], []), type_)
}

/// Plans random input for a public function whose parameters are all annotated.
pub fn derive_function(
  ctx: Context,
  function: glance.Function,
) -> Result(FunctionPlan, String) {
  case function.publicity {
    glance.Private ->
      Error("private function " <> function.name <> " cannot be probed")
    glance.Public -> {
      use parameters <- result.try(
        list.try_map(function.parameters, derive_parameter(ctx, _)),
      )
      Ok(FunctionPlan(function.name, parameters, derive_return(ctx, function)))
    }
  }
}

/// Plans one parameter, naming it in any failure.
fn derive_parameter(
  ctx: Context,
  parameter: glance.FunctionParameter,
) -> Result(ParameterPlan, String) {
  let name = parameter_name(parameter.name)
  case parameter.type_ {
    None -> Error("parameter " <> name <> " has no type annotation")
    Some(type_) ->
      case derive_type(ctx, type_) {
        Ok(spec) -> Ok(ParameterPlan(name, parameter.label, spec))
        Error(reason) -> Error("parameter " <> name <> ": " <> reason)
      }
  }
}

/// Discarded parameters keep their name; the underscore carries no meaning here.
fn parameter_name(name: glance.AssignmentName) -> String {
  case name {
    glance.Named(name) -> name
    glance.Discarded(name) -> name
  }
}

/// A return type that cannot be derived is not an error, only unknown.
fn derive_return(ctx: Context, function: glance.Function) -> Option(GenSpec) {
  case function.return {
    None -> None
    Some(type_) -> option.from_result(derive_type(ctx, type_))
  }
}

fn derive_in(
  ctx: Context,
  scope: Scope,
  type_: glance.Type,
) -> Result(GenSpec, String) {
  case type_ {
    glance.NamedType(_, name, module, parameters) ->
      derive_named(ctx, scope, name, module, parameters)
    glance.TupleType(_, elements) ->
      elements
      |> list.try_map(derive_in(ctx, scope, _))
      |> result.map(TupleSpec)
    glance.FunctionType(_, _, _) ->
      Error("function-typed values are not supported")
    glance.VariableType(_, name) ->
      case list.key_find(scope.bindings, name) {
        Ok(spec) -> Ok(spec)
        Error(_) -> Ok(IntSpec)
      }
    glance.HoleType(_, name) ->
      Error("type hole " <> name <> " is not supported")
  }
}

fn derive_named(
  ctx: Context,
  scope: Scope,
  name: String,
  module: Option(String),
  parameters: List(glance.Type),
) -> Result(GenSpec, String) {
  case module {
    Some("option") if name == "Option" ->
      case parameters {
        [inner] -> result.map(derive_in(ctx, scope, inner), OptionSpec)
        _ -> Error(external_reason("option", name))
      }
    Some(qualifier) -> Error(external_reason(qualifier, name))
    None -> derive_unqualified(ctx, scope, name, parameters)
  }
}

fn external_reason(qualifier: String, name: String) -> String {
  "external type " <> qualifier <> "." <> name <> " is not supported yet"
}

fn derive_unqualified(
  ctx: Context,
  scope: Scope,
  name: String,
  parameters: List(glance.Type),
) -> Result(GenSpec, String) {
  case name, parameters {
    "Int", [] -> Ok(IntSpec)
    "Float", [] -> Ok(FloatSpec)
    "Bool", [] -> Ok(BoolSpec)
    "String", [] -> Ok(StringSpec)
    "Nil", [] -> Ok(NilSpec)
    "BitArray", [] -> Ok(BitArraySpec)
    "List", [element] -> result.map(derive_in(ctx, scope, element), ListSpec)
    "Option", [inner] -> result.map(derive_in(ctx, scope, inner), OptionSpec)
    "Result", [ok, error] -> {
      use ok_spec <- result.try(derive_in(ctx, scope, ok))
      use error_spec <- result.try(derive_in(ctx, scope, error))
      Ok(ResultSpec(ok_spec, error_spec))
    }
    _, _ -> derive_local(ctx, scope, name, parameters)
  }
}

/// Resolves a name declared by the module under test.
///
/// A `RecursiveRef` carries no arguments of its own: it stands for the very
/// instantiation the enclosing derivation is defining, which is what keeps a
/// recursive type finite. A type that recurses at *another* instantiation —
/// `pub type W(a) { Stop Go(W(Int)) }` reached at `W(String)` — is a second
/// type that reference cannot name, and following such a hop is not always
/// finite either: `pub type N(a) { NE NN(N(List(a))) }` grows an argument
/// every time round. Declining it gives up on the one function it annotates,
/// where rendering it anyway would leave the whole snapshot uncompilable.
fn derive_local(
  ctx: Context,
  scope: Scope,
  name: String,
  arguments: List(glance.Type),
) -> Result(GenSpec, String) {
  case list.key_find(scope.types_in_progress, name) {
    Ok(in_progress) -> {
      use requested <- result.try(
        list.try_map(arguments, derive_in(ctx, scope, _)),
      )
      case requested == in_progress {
        True -> Ok(RecursiveRef(name))
        False ->
          Error(
            "recursive type " <> name <> " is used at another instantiation",
          )
      }
    }
    Error(_) ->
      case find_alias(ctx, name), find_custom_type(ctx, name) {
        Ok(alias), _ -> derive_alias(ctx, scope, alias, arguments)
        _, Ok(custom) -> derive_custom(ctx, scope, custom, arguments)
        _, _ -> Error("unknown type " <> name)
      }
  }
}

fn find_alias(ctx: Context, name: String) -> Result(glance.TypeAlias, Nil) {
  list.find(ctx.type_aliases, fn(alias) { alias.name == name })
}

fn find_custom_type(
  ctx: Context,
  name: String,
) -> Result(glance.CustomType, Nil) {
  list.find(ctx.custom_types, fn(custom) { custom.name == name })
}

/// Expands an alias by substituting its type parameters, then derives the body.
fn derive_alias(
  ctx: Context,
  scope: Scope,
  alias: glance.TypeAlias,
  arguments: List(glance.Type),
) -> Result(GenSpec, String) {
  case list.contains(scope.aliases_in_progress, alias.name) {
    True -> Error("recursive type alias " <> alias.name <> " cannot be derived")
    False -> {
      use bindings <- result.try(bind(
        ctx,
        scope,
        alias.name,
        alias.parameters,
        arguments,
      ))
      derive_in(
        ctx,
        Scope(bindings, scope.types_in_progress, [
          alias.name,
          ..scope.aliases_in_progress
        ]),
        alias.aliased,
      )
    }
  }
}

/// Derives every variant of a constructible custom type.
fn derive_custom(
  ctx: Context,
  scope: Scope,
  custom: glance.CustomType,
  arguments: List(glance.Type),
) -> Result(GenSpec, String) {
  case custom.publicity, custom.opaque_ {
    glance.Private, _ -> Error("private type " <> custom.name)
    _, True -> Error("opaque type " <> custom.name)
    glance.Public, False -> {
      use bindings <- result.try(bind(
        ctx,
        scope,
        custom.name,
        custom.parameters,
        arguments,
      ))
      // The arguments are what tell two instantiations of one parameterised
      // type apart, so they travel with the specification and with the name
      // while it is in progress: `bindings` already holds them, derived once
      // and in declaration order.
      let instantiation = list.map(bindings, fn(binding) { binding.1 })
      let inner =
        Scope(
          bindings,
          [#(custom.name, instantiation), ..scope.types_in_progress],
          scope.aliases_in_progress,
        )
      use variants <- result.try(
        list.try_map(custom.variants, derive_variant(ctx, inner, _)),
      )
      case has_base_case(custom.name, variants) {
        True -> Ok(CustomSpec(custom.name, instantiation, variants))
        False -> Error("recursive type " <> custom.name <> " has no base case")
      }
    }
  }
}

fn derive_variant(
  ctx: Context,
  scope: Scope,
  variant: glance.Variant,
) -> Result(VariantSpec, String) {
  variant.fields
  |> list.try_map(derive_field(ctx, scope, _))
  |> result.map(VariantSpec(variant.name, _))
}

fn derive_field(
  ctx: Context,
  scope: Scope,
  field: glance.VariantField,
) -> Result(FieldSpec, String) {
  case field {
    glance.LabelledVariantField(item, label) ->
      result.map(derive_in(ctx, scope, item), FieldSpec(Some(label), _))
    glance.UnlabelledVariantField(item) ->
      result.map(derive_in(ctx, scope, item), FieldSpec(None, _))
  }
}

/// Derives the arguments of a parameterised type and binds them by name.
fn bind(
  ctx: Context,
  scope: Scope,
  name: String,
  parameters: List(String),
  arguments: List(glance.Type),
) -> Result(List(#(String, GenSpec)), String) {
  let expected = list.length(parameters)
  case expected == list.length(arguments) {
    False ->
      Error(
        "type "
        <> name
        <> " expects "
        <> int.to_string(expected)
        <> " type parameters",
      )
    True -> {
      use specs <- result.try(list.try_map(arguments, derive_in(ctx, scope, _)))
      Ok(list.zip(parameters, specs))
    }
  }
}

/// True when some variant of `name` holds no reference back to `name`.
fn has_base_case(name: String, variants: List(VariantSpec)) -> Bool {
  list.any(variants, fn(variant) { !variant_references(variant, name) })
}

fn variant_references(variant: VariantSpec, name: String) -> Bool {
  list.any(variant.fields, fn(field) { references(field.spec, name) })
}

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
