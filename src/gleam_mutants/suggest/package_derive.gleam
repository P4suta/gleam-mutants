//// Generator derivation from Girard's package-wide inferred signatures.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import girard
import glance
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/suggest/genspec.{
  type GenSpec, type VariantSpec, BitArraySpec, BoolSpec, CustomSpec, FieldSpec,
  FloatSpec, ImportedCustomSpec, ImportedModuleAccess, IntSpec, ListSpec,
  NilSpec, OpaqueObserver, OpaqueProvider, OpaqueSpec, OptionProvider,
  OptionSpec, RecursiveRef, ResultProvider, ResultSpec, StringSpec,
  TargetModuleAccess, TupleSpec, ValueProvider, VariantSpec,
}
import gleam_mutants/suggest/package_types.{type PackageIndex}
import gleam_mutants/suggest/typederive.{
  type FunctionPlan, type ParameterPlan, FunctionPlan, ParameterPlan,
}

type Scope {
  Scope(
    bindings: List(#(String, GenSpec)),
    in_progress: List(#(String, String, List(GenSpec))),
    aliases: List(#(String, String)),
    excluded_observer: Option(#(String, String)),
  )
}

/// Derives one public function from Girard's inferred package signature.
pub fn function(
  package: PackageIndex,
  module_name: String,
  function_name: String,
) -> Result(FunctionPlan, String) {
  use module <- result.try(package_types.parsed_module(package, module_name))
  use definition <- result.try(find_function(module, module_name, function_name))
  use scheme <- result.try(package_types.function_scheme(
    package,
    module_name,
    function_name,
  ))
  case definition.publicity, scheme.type_ {
    glance.Private, _ -> Error("private function")
    glance.Public, girard.Fn(arguments, return) -> {
      let scope = Scope([], [], [], Some(#(module_name, function_name)))
      use parameters <- result.try(derive_parameters(
        package,
        module_name,
        definition.parameters,
        arguments,
        scope,
      ))
      Ok(FunctionPlan(
        name: function_name,
        parameters: parameters,
        return_spec: option.from_result(derive_girard(
          package,
          module_name,
          module_name,
          scope,
          return,
        )),
      ))
    }
    _, _ -> Error("inferred definition is not a function")
  }
}

fn derive_parameters(
  package: PackageIndex,
  target_module: String,
  parameters: List(glance.FunctionParameter),
  types: List(girard.Type),
  scope: Scope,
) -> Result(List(ParameterPlan), String) {
  case parameters, types {
    [], [] -> Ok([])
    [parameter, ..parameter_rest], [type_, ..type_rest] -> {
      let name = parameter_name(parameter.name)
      use spec <- result.try(
        derive_girard(package, target_module, target_module, scope, type_)
        |> result.map_error(fn(reason) {
          "parameter " <> name <> ": " <> reason
        }),
      )
      use rest <- result.try(derive_parameters(
        package,
        target_module,
        parameter_rest,
        type_rest,
        scope,
      ))
      Ok([ParameterPlan(name, parameter.label, spec), ..rest])
    }
    _, _ -> Error("inferred function arity does not match its source")
  }
}

fn derive_girard(
  package: PackageIndex,
  target_module: String,
  defining_module: String,
  scope: Scope,
  type_: girard.Type,
) -> Result(GenSpec, String) {
  case type_ {
    girard.Named("gleam/option", "Option", [inner]) ->
      derive_girard(package, target_module, defining_module, scope, inner)
      |> result.map(OptionSpec)
    girard.Named("gleam/result", "Result", [ok, error]) -> {
      use ok <- result.try(derive_girard(
        package,
        target_module,
        defining_module,
        scope,
        ok,
      ))
      use error <- result.try(derive_girard(
        package,
        target_module,
        defining_module,
        scope,
        error,
      ))
      Ok(ResultSpec(ok, error))
    }
    girard.Named("gleam", name, arguments) ->
      derive_builtin_girard(
        package,
        target_module,
        defining_module,
        scope,
        name,
        arguments,
      )
    girard.Named(module, name, arguments) -> {
      use arguments <- result.try(
        list.try_map(arguments, fn(argument) {
          derive_girard(
            package,
            target_module,
            defining_module,
            scope,
            argument,
          )
        }),
      )
      derive_nominal(package, target_module, module, scope, name, arguments)
    }
    girard.Fn(_, _) -> Error("function-typed values are not supported")
    girard.Var(_) -> Error("unconstrained generic type cannot be generated")
    girard.Tuple(elements) ->
      elements
      |> list.try_map(derive_girard(
        package,
        target_module,
        defining_module,
        scope,
        _,
      ))
      |> result.map(TupleSpec)
  }
}

fn derive_builtin_girard(
  package: PackageIndex,
  target_module: String,
  defining_module: String,
  scope: Scope,
  name: String,
  arguments: List(girard.Type),
) -> Result(GenSpec, String) {
  case name, arguments {
    "Int", [] -> Ok(IntSpec)
    "Float", [] -> Ok(FloatSpec)
    "Bool", [] -> Ok(BoolSpec)
    "String", [] -> Ok(StringSpec)
    "Nil", [] -> Ok(NilSpec)
    "BitArray", [] -> Ok(BitArraySpec)
    "List", [element] ->
      derive_girard(package, target_module, defining_module, scope, element)
      |> result.map(ListSpec)
    "Option", [inner] ->
      derive_girard(package, target_module, defining_module, scope, inner)
      |> result.map(OptionSpec)
    "Result", [ok, error] -> {
      use ok <- result.try(derive_girard(
        package,
        target_module,
        defining_module,
        scope,
        ok,
      ))
      use error <- result.try(derive_girard(
        package,
        target_module,
        defining_module,
        scope,
        error,
      ))
      Ok(ResultSpec(ok, error))
    }
    _, _ -> Error("unsupported prelude type " <> name)
  }
}

fn derive_nominal(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  name: String,
  arguments: List(GenSpec),
) -> Result(GenSpec, String) {
  use module <- result.try(package_types.parsed_module(package, module_name))
  case find_alias(module, name), find_custom(module, name) {
    Ok(alias), _ ->
      derive_alias(package, target_module, module_name, scope, alias, arguments)
    _, Ok(custom) ->
      derive_custom(
        package,
        target_module,
        module_name,
        scope,
        custom,
        arguments,
      )
    _, _ -> Error("unknown type " <> module_name <> "." <> name)
  }
}

fn derive_alias(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  alias: glance.TypeAlias,
  arguments: List(GenSpec),
) -> Result(GenSpec, String) {
  let key = #(module_name, alias.name)
  case list.contains(scope.aliases, key) {
    True -> Error("recursive type alias " <> alias.name <> " cannot be derived")
    False -> {
      use bindings <- result.try(bind(alias.name, alias.parameters, arguments))
      derive_glance(
        package,
        target_module,
        module_name,
        Scope(..scope, bindings: bindings, aliases: [key, ..scope.aliases]),
        alias.aliased,
      )
    }
  }
}

fn derive_custom(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  custom: glance.CustomType,
  arguments: List(GenSpec),
) -> Result(GenSpec, String) {
  case custom.publicity, custom.opaque_ {
    glance.Private, _ ->
      Error("private type " <> module_name <> "." <> custom.name)
    _, True ->
      derive_opaque(
        package,
        target_module,
        module_name,
        scope,
        custom,
        arguments,
      )
    glance.Public, False -> {
      let key = #(module_name, custom.name, arguments)
      case in_progress(scope.in_progress, module_name, custom.name) {
        Ok(in_progress) ->
          case in_progress == arguments {
            True -> Ok(RecursiveRef(custom.name))
            False ->
              Error(
                "recursive type "
                <> custom.name
                <> " is used at another instantiation",
              )
          }
        Error(_) -> {
          use bindings <- result.try(bind(
            custom.name,
            custom.parameters,
            arguments,
          ))
          let inner =
            Scope(..scope, bindings: bindings, in_progress: [
              key,
              ..scope.in_progress
            ])
          use variants <- result.try(
            list.try_map(custom.variants, fn(variant) {
              derive_variant(
                package,
                target_module,
                module_name,
                inner,
                variant,
              )
            }),
          )
          case has_base_case(custom.name, variants) {
            False ->
              Error("recursive type " <> custom.name <> " has no base case")
            True ->
              case module_name == target_module {
                True -> Ok(CustomSpec(custom.name, arguments, variants))
                False ->
                  Ok(ImportedCustomSpec(
                    module_name,
                    custom.name,
                    arguments,
                    variants,
                  ))
              }
          }
        }
      }
    }
  }
}

fn derive_variant(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  variant: glance.Variant,
) -> Result(VariantSpec, String) {
  variant.fields
  |> list.try_map(fn(field) {
    case field {
      glance.LabelledVariantField(type_, label) ->
        derive_glance(package, target_module, module_name, scope, type_)
        |> result.map(FieldSpec(Some(label), _))
      glance.UnlabelledVariantField(type_) ->
        derive_glance(package, target_module, module_name, scope, type_)
        |> result.map(FieldSpec(None, _))
    }
  })
  |> result.map(VariantSpec(variant.name, _))
}

fn derive_opaque(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  custom: glance.CustomType,
  arguments: List(GenSpec),
) -> Result(GenSpec, String) {
  let functions = public_schemes(package, module_name)
  let providers =
    list.filter_map(functions, fn(entry) {
      provider_candidate(
        package,
        target_module,
        module_name,
        scope,
        custom.name,
        arguments,
        entry.0,
        entry.1,
      )
    })
  case providers {
    [] ->
      Error(
        "opaque type "
        <> module_name
        <> "."
        <> custom.name
        <> " has no public constructor returning T, Option(T), or Result(T, e)",
      )
    _ ->
      case
        compatible_opaque_pair(
          package,
          target_module,
          module_name,
          scope,
          custom.name,
          arguments,
          providers,
          functions,
        )
      {
        Ok(#(provider, observer)) ->
          Ok(
            OpaqueSpec(
              module_name,
              custom.name,
              arguments,
              provider,
              observer,
              case module_name == target_module {
                True -> TargetModuleAccess
                False -> ImportedModuleAccess
              },
            ),
          )
        Error(Nil) ->
          Error(
            "opaque type "
            <> module_name
            <> "."
            <> custom.name
            <> " has no independent public observer compatible with a constructor",
          )
      }
  }
}

fn public_schemes(
  package: PackageIndex,
  module_name: String,
) -> List(#(glance.Function, girard.Scheme)) {
  case package_types.parsed_module(package, module_name) {
    Error(_) -> []
    Ok(module) ->
      module.functions
      |> list.map(fn(definition) { definition.definition })
      |> list.filter_map(fn(function) {
        case
          function.publicity,
          package_types.function_scheme(package, module_name, function.name)
        {
          glance.Public, Ok(scheme) -> Ok(#(function, scheme))
          _, _ -> Error(Nil)
        }
      })
  }
}

fn provider_candidate(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  opaque_name: String,
  arguments: List(GenSpec),
  function: glance.Function,
  scheme: girard.Scheme,
) -> Result(genspec.OpaqueProvider, Nil) {
  case scheme.type_ {
    girard.Fn(parameters, return) -> {
      use #(inner, mode) <- result.try(provider_return(return))
      case
        matches_opaque(
          package,
          target_module,
          module_name,
          scope,
          opaque_name,
          arguments,
          inner,
        )
        && !list.any(parameters, contains_named(_, module_name, opaque_name))
      {
        False -> Error(Nil)
        True ->
          parameters
          |> list.try_map(derive_girard(
            package,
            target_module,
            module_name,
            scope,
            _,
          ))
          |> result.map(fn(specs) { OpaqueProvider(function.name, specs, mode) })
          |> result.map_error(fn(_) { Nil })
      }
    }
    _ -> Error(Nil)
  }
}

fn provider_return(
  return: girard.Type,
) -> Result(#(girard.Type, genspec.OpaqueProviderMode), Nil) {
  case return {
    girard.Named("gleam", "Option", [inner])
    | girard.Named("gleam/option", "Option", [inner]) ->
      Ok(#(inner, OptionProvider))
    girard.Named("gleam", "Result", [inner, _])
    | girard.Named("gleam/result", "Result", [inner, _]) ->
      Ok(#(inner, ResultProvider))
    _ -> Ok(#(return, ValueProvider))
  }
}

fn compatible_opaque_pair(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  opaque_name: String,
  arguments: List(GenSpec),
  providers: List(genspec.OpaqueProvider),
  functions: List(#(glance.Function, girard.Scheme)),
) -> Result(#(genspec.OpaqueProvider, genspec.OpaqueObserver), Nil) {
  providers
  |> list.find_map(fn(provider) {
    functions
    |> list.find_map(fn(entry) {
      observer_candidate(
        package,
        target_module,
        module_name,
        scope,
        opaque_name,
        arguments,
        provider,
        entry.0,
        entry.1,
      )
      |> result.map(fn(observer) { #(provider, observer) })
    })
  })
}

fn observer_candidate(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  opaque_name: String,
  arguments: List(GenSpec),
  provider: genspec.OpaqueProvider,
  function: glance.Function,
  scheme: girard.Scheme,
) -> Result(genspec.OpaqueObserver, Nil) {
  let excluded = scope.excluded_observer == Some(#(module_name, function.name))
  case excluded, scheme.type_ {
    True, _ -> Error(Nil)
    False, girard.Fn([input], return) ->
      case
        matches_opaque(
          package,
          target_module,
          module_name,
          scope,
          opaque_name,
          arguments,
          input,
        )
        && !contains_named(return, module_name, opaque_name)
      {
        False -> Error(Nil)
        True ->
          case
            derive_girard(package, target_module, module_name, scope, return)
          {
            Ok(spec) ->
              case observer_rebuilds(provider.parameters, spec) {
                True -> Ok(OpaqueObserver(function.name, spec))
                False -> Error(Nil)
              }
            Error(_) -> Error(Nil)
          }
      }
    _, _ -> Error(Nil)
  }
}

fn observer_rebuilds(parameters: List(GenSpec), observed: GenSpec) -> Bool {
  case parameters {
    [] -> True
    [only] -> only == observed
    many -> TupleSpec(many) == observed
  }
}

fn matches_opaque(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  opaque_name: String,
  arguments: List(GenSpec),
  type_: girard.Type,
) -> Bool {
  case type_ {
    girard.Named(found_module, found_name, found_arguments)
      if found_module == module_name && found_name == opaque_name
    ->
      case
        list.try_map(found_arguments, derive_girard(
          package,
          target_module,
          module_name,
          scope,
          _,
        ))
      {
        Ok(found) -> found == arguments
        Error(_) -> False
      }
    _ -> False
  }
}

fn contains_named(
  type_: girard.Type,
  module_name: String,
  name: String,
) -> Bool {
  case type_ {
    girard.Named(found_module, found_name, arguments) ->
      { found_module == module_name && found_name == name }
      || list.any(arguments, contains_named(_, module_name, name))
    girard.Fn(arguments, return) ->
      list.any(arguments, contains_named(_, module_name, name))
      || contains_named(return, module_name, name)
    girard.Tuple(elements) ->
      list.any(elements, contains_named(_, module_name, name))
    girard.Var(_) -> False
  }
}

fn derive_glance(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  type_: glance.Type,
) -> Result(GenSpec, String) {
  case type_ {
    glance.VariableType(_, name) ->
      list.key_find(scope.bindings, name)
      |> result.map_error(fn(_) { "unbound type variable " <> name })
    glance.TupleType(_, elements) ->
      elements
      |> list.try_map(derive_glance(
        package,
        target_module,
        module_name,
        scope,
        _,
      ))
      |> result.map(TupleSpec)
    glance.FunctionType(_, _, _) ->
      Error("function-typed values are not supported")
    glance.HoleType(_, name) ->
      Error("type hole " <> name <> " is not supported")
    glance.NamedType(_, name, qualifier, arguments) -> {
      use arguments <- result.try(
        list.try_map(arguments, derive_glance(
          package,
          target_module,
          module_name,
          scope,
          _,
        )),
      )
      derive_named_glance(
        package,
        target_module,
        module_name,
        scope,
        name,
        qualifier,
        arguments,
      )
    }
  }
}

fn derive_named_glance(
  package: PackageIndex,
  target_module: String,
  module_name: String,
  scope: Scope,
  name: String,
  qualifier: Option(String),
  arguments: List(GenSpec),
) -> Result(GenSpec, String) {
  case qualifier {
    Some(qualifier) -> {
      use module <- result.try(package_types.parsed_module(package, module_name))
      use imported <- result.try(resolve_qualifier(module, qualifier))
      derive_nominal(package, target_module, imported, scope, name, arguments)
    }
    None ->
      case builtin_from_specs(name, arguments) {
        Ok(spec) -> Ok(spec)
        Error(_) -> {
          use module <- result.try(package_types.parsed_module(
            package,
            module_name,
          ))
          case resolve_unqualified_type(module, name) {
            Ok(imported) ->
              derive_nominal(
                package,
                target_module,
                imported,
                scope,
                name,
                arguments,
              )
            Error(_) ->
              derive_nominal(
                package,
                target_module,
                module_name,
                scope,
                name,
                arguments,
              )
          }
        }
      }
  }
}

fn builtin_from_specs(
  name: String,
  arguments: List(GenSpec),
) -> Result(GenSpec, Nil) {
  case name, arguments {
    "Int", [] -> Ok(IntSpec)
    "Float", [] -> Ok(FloatSpec)
    "Bool", [] -> Ok(BoolSpec)
    "String", [] -> Ok(StringSpec)
    "Nil", [] -> Ok(NilSpec)
    "BitArray", [] -> Ok(BitArraySpec)
    "List", [element] -> Ok(ListSpec(element))
    "Option", [inner] -> Ok(OptionSpec(inner))
    "Result", [ok, error] -> Ok(ResultSpec(ok, error))
    _, _ -> Error(Nil)
  }
}

fn resolve_qualifier(
  module: glance.Module,
  qualifier: String,
) -> Result(String, String) {
  module.imports
  |> list.find_map(fn(definition) {
    let imported = definition.definition
    let default = imported.module |> string.split("/") |> list.last
    let alias = case imported.alias {
      Some(glance.Named(name)) | Some(glance.Discarded(name)) -> Ok(name)
      None -> default
    }
    case alias == Ok(qualifier) {
      True -> Ok(imported.module)
      False -> Error(Nil)
    }
  })
  |> result.map_error(fn(_) { "unknown imported module " <> qualifier })
}

fn resolve_unqualified_type(
  module: glance.Module,
  name: String,
) -> Result(String, Nil) {
  module.imports
  |> list.find_map(fn(definition) {
    let imported = definition.definition
    case
      list.any(imported.unqualified_types, fn(item) {
        case item.alias {
          Some(alias) -> alias == name
          None -> item.name == name
        }
      })
    {
      True -> Ok(imported.module)
      False -> Error(Nil)
    }
  })
}

fn find_function(
  module: glance.Module,
  module_name: String,
  name: String,
) -> Result(glance.Function, String) {
  module.functions
  |> list.map(fn(definition) { definition.definition })
  |> list.find(fn(function) { function.name == name })
  |> result.map_error(fn(_) {
    "unknown function " <> module_name <> "." <> name
  })
}

fn find_alias(
  module: glance.Module,
  name: String,
) -> Result(glance.TypeAlias, Nil) {
  module.type_aliases
  |> list.map(fn(definition) { definition.definition })
  |> list.find(fn(alias) { alias.name == name })
}

fn find_custom(
  module: glance.Module,
  name: String,
) -> Result(glance.CustomType, Nil) {
  module.custom_types
  |> list.map(fn(definition) { definition.definition })
  |> list.find(fn(custom) { custom.name == name })
}

fn bind(
  name: String,
  parameters: List(String),
  arguments: List(GenSpec),
) -> Result(List(#(String, GenSpec)), String) {
  case list.length(parameters) == list.length(arguments) {
    True -> Ok(list.zip(parameters, arguments))
    False -> Error("type " <> name <> " has the wrong number of arguments")
  }
}

fn in_progress(
  entries: List(#(String, String, List(GenSpec))),
  module_name: String,
  name: String,
) -> Result(List(GenSpec), Nil) {
  entries
  |> list.find(fn(entry) { entry.0 == module_name && entry.1 == name })
  |> result.map(fn(entry) { entry.2 })
}

fn parameter_name(name: glance.AssignmentName) -> String {
  case name {
    glance.Named(name) | glance.Discarded(name) -> name
  }
}

fn has_base_case(name: String, variants: List(VariantSpec)) -> Bool {
  list.any(variants, fn(variant) {
    !list.any(variant.fields, fn(field) { references(field.spec, name) })
  })
}

fn references(spec: GenSpec, name: String) -> Bool {
  case spec {
    RecursiveRef(reference) -> reference == name
    ListSpec(element) -> references(element, name)
    OptionSpec(inner) -> references(inner, name)
    ResultSpec(ok, error) -> references(ok, name) || references(error, name)
    TupleSpec(elements) -> list.any(elements, references(_, name))
    CustomSpec(_, _, variants) | ImportedCustomSpec(_, _, _, variants) ->
      list.any(variants, fn(variant) {
        list.any(variant.fields, fn(field) { references(field.spec, name) })
      })
    OpaqueSpec(_, _, arguments, provider, observer, _) ->
      list.any(arguments, references(_, name))
      || list.any(provider.parameters, references(_, name))
      || references(observer.result, name)
    _ -> False
  }
}
