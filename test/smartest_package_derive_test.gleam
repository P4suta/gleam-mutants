// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import girard
import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/suggest/diff_runner
import gleam_mutants/suggest/genspec.{
  FieldSpec, ImportedCustomSpec, IntSpec, OpaqueObserver, OpaqueProvider,
  OpaqueSpec, OptionProvider, ResultProvider, StringSpec, TargetModuleAccess,
  ValueProvider, VariantSpec,
}
import gleam_mutants/suggest/harness.{ProbeFunction, ProbeSpec}
import gleam_mutants/suggest/hints
import gleam_mutants/suggest/package_derive
import gleam_mutants/suggest/package_types
import gleam_mutants/suggest/typederive.{FunctionPlan, ParameterPlan}

const types_source = "pub type Box(a) { Box(value: a) }"

pub fn smartest_package_derivation_builds_a_cross_module_generic_generator_test() {
  let use_source =
    "import demo/types\n\npub fn keep(value: types.Box(Int)) -> types.Box(Int) { value }"
  let assert Ok(index) =
    package_types.annotate(
      [
        package_types.ModuleSource("demo/types", types_source),
        package_types.ModuleSource("demo/use", use_source),
      ],
      girard.Erlang,
    )

  assert package_derive.function(index, "demo/use", "keep")
    == Ok(FunctionPlan(
      "keep",
      [
        ParameterPlan(
          "value",
          None,
          ImportedCustomSpec("demo/types", "Box", [IntSpec], [
            VariantSpec("Box", [FieldSpec(Some("value"), IntSpec)]),
          ]),
        ),
      ],
      Some(
        ImportedCustomSpec("demo/types", "Box", [IntSpec], [
          VariantSpec("Box", [FieldSpec(Some("value"), IntSpec)]),
        ]),
      ),
    ))
}

pub fn smartest_package_derivation_resolves_unqualified_imported_types_test() {
  let use_source =
    "import demo/types.{type Box}\n\npub fn keep(value: Box(String)) { value }"
  let assert Ok(index) =
    package_types.annotate(
      [
        package_types.ModuleSource("demo/types", types_source),
        package_types.ModuleSource("demo/use", use_source),
      ],
      girard.Erlang,
    )
  let assert Ok(plan) = package_derive.function(index, "demo/use", "keep")
  let assert [parameter] = plan.parameters
  assert parameter.spec
    == ImportedCustomSpec("demo/types", "Box", [StringSpec], [
      VariantSpec("Box", [FieldSpec(Some("value"), StringSpec)]),
    ])
}

pub fn smartest_package_derivation_uses_inferred_unannotated_parameters_test() {
  let source = "pub fn increment(value) { value + 1 }"
  let assert Ok(index) =
    package_types.annotate(
      [package_types.ModuleSource("demo/inferred", source)],
      girard.Erlang,
    )

  assert package_derive.function(index, "demo/inferred", "increment")
    == Ok(FunctionPlan(
      "increment",
      [ParameterPlan("value", None, IntSpec)],
      Some(IntSpec),
    ))
}

pub fn smartest_package_derivation_does_not_construct_private_external_types_test() {
  let hidden = "type Hidden { Hidden(Int) }\n\npub fn hidden() { Hidden(1) }"
  let use_source =
    "import demo/hidden\n\npub fn passthrough(value) { hidden.hidden() }"
  let assert Ok(index) =
    package_types.annotate(
      [
        package_types.ModuleSource("demo/hidden", hidden),
        package_types.ModuleSource("demo/use", use_source),
      ],
      girard.Erlang,
    )
  let assert Error(reason) =
    package_derive.function(index, "demo/use", "passthrough")
  assert reason
    == "parameter value: unconstrained generic type cannot be generated"
}

pub fn smartest_cross_module_probe_uses_collision_free_imports_and_helpers_test() {
  let alpha =
    ImportedCustomSpec("alpha/item", "Box", [IntSpec], [
      VariantSpec("Box", [FieldSpec(None, IntSpec)]),
    ])
  let beta =
    ImportedCustomSpec("beta/item", "Box", [StringSpec], [
      VariantSpec("Box", [FieldSpec(None, StringSpec)]),
    ])
  let plan =
    FunctionPlan(
      "compare",
      [
        ParameterPlan("left", None, alpha),
        ParameterPlan("right", None, beta),
      ],
      Some(IntSpec),
    )
  let rendered =
    harness.render_probe(ProbeSpec(
      target_module: "demo/use",
      probe_module: "probe",
      pbt_module: "probe_pbt",
      ffi_module: "probe_ffi",
      results_path: "/tmp/results",
      functions: [ProbeFunction(plan, ["m1"], hints.none())],
      seed: 1,
      max_cases: 10,
      max_shrinks: 10,
      call_timeout_ms: 100,
      nondeterminism_checks: 1,
    ))

  assert string.contains(
    rendered,
    "import alpha/item as smartest_type_alpha_s_item",
  )
  assert string.contains(
    rendered,
    "import beta/item as smartest_type_beta_s_item",
  )
  assert string.contains(rendered, "gen_type_m_alpha_s_item_box_int")
  assert string.contains(rendered, "gen_type_m_beta_s_item_box_string")
  assert string.contains(rendered, "smartest_type_alpha_s_item.Box(f0)")
  assert string.contains(rendered, "smartest_type_beta_s_item.Box(f0)")
}

pub fn smartest_diff_runner_classifies_with_the_package_typed_graph_test() {
  let use_source =
    "import demo/types\n\npub fn keep(value: types.Box(Int)) -> types.Box(Int) { value }"
  let assert Ok(index) =
    package_types.annotate(
      [
        package_types.ModuleSource("demo/types", types_source),
        package_types.ModuleSource("demo/use", use_source),
      ],
      girard.Erlang,
    )
  let assert Ok(module) = package_types.parsed_module(index, "demo/use")
  let assert [definition] = module.functions
  let assert Ok(plan) =
    diff_runner.classify_package(
      index,
      module: "demo/use",
      function: definition.definition,
    )
  let assert [parameter] = plan.parameters
  assert parameter.spec
    == ImportedCustomSpec("demo/types", "Box", [IntSpec], [
      VariantSpec("Box", [FieldSpec(Some("value"), IntSpec)]),
    ])
}

pub fn smartest_opaque_parameter_uses_a_public_constructor_and_observer_test() {
  let source =
    "pub opaque type Token { Token(Int) }

pub fn new(value: Int) -> Token { Token(value) }
pub fn value(token: Token) -> Int {
  let Token(value) = token
  value
}
pub fn increment(token: Token) -> Int { value(token) + 1 }
"
  let assert Ok(index) =
    package_types.annotate(
      [package_types.ModuleSource("demo/token", source)],
      girard.Erlang,
    )
  let assert Ok(plan) =
    package_derive.function(index, "demo/token", "increment")
  let assert [parameter] = plan.parameters

  assert parameter.spec
    == OpaqueSpec(
      "demo/token",
      "Token",
      [],
      OpaqueProvider("new", [IntSpec], ValueProvider),
      OpaqueObserver("value", IntSpec),
      TargetModuleAccess,
    )
}

pub fn smartest_opaque_parameter_accepts_an_option_smart_constructor_test() {
  let source =
    "import gleam/option.{type Option, Some}
import gleam/string

pub opaque type Token { Token(String) }
pub fn parse(value: String) -> Option(Token) { Some(Token(value)) }
pub fn value(token: Token) -> String {
  let Token(value) = token
  value
}
pub fn size(token: Token) -> Int { value(token) |> string.length }
"
  let assert Ok(index) =
    package_types.annotate(
      [package_types.ModuleSource("demo/token", source)],
      girard.Erlang,
    )
  let assert Ok(plan) = package_derive.function(index, "demo/token", "size")
  let assert [parameter] = plan.parameters
  let assert OpaqueSpec(provider: provider, ..) = parameter.spec

  assert provider == OpaqueProvider("parse", [StringSpec], OptionProvider)
}

pub fn smartest_opaque_parameter_accepts_a_result_smart_constructor_test() {
  let source =
    "import gleam/string

pub opaque type Token { Token(String) }
pub fn parse(value: String) -> Result(Token, String) { Ok(Token(value)) }
pub fn value(token: Token) -> String {
  let Token(value) = token
  value
}
pub fn size(token: Token) -> Int { value(token) |> string.length }
"
  let assert Ok(index) =
    package_types.annotate(
      [package_types.ModuleSource("demo/token", source)],
      girard.Erlang,
    )
  let assert Ok(plan) = package_derive.function(index, "demo/token", "size")
  let assert [parameter] = plan.parameters
  let assert OpaqueSpec(provider: provider, ..) = parameter.spec

  assert provider == OpaqueProvider("parse", [StringSpec], ResultProvider)
}

pub fn smartest_opaque_parameter_requires_an_independent_public_observer_test() {
  let source =
    "pub opaque type Token { Token(Int) }
pub fn new(value: Int) -> Token { Token(value) }
pub fn consume(token: Token) -> Int { 1 }
"
  let assert Ok(index) =
    package_types.annotate(
      [package_types.ModuleSource("demo/token", source)],
      girard.Erlang,
    )
  let assert Error(reason) =
    package_derive.function(index, "demo/token", "consume")

  assert reason
    == "parameter token: opaque type demo/token.Token has no independent public observer compatible with a constructor"
}

pub fn smartest_opaque_probe_constructs_and_renders_only_through_public_api_test() {
  let source =
    "pub opaque type Token { Token(Int) }
pub fn new(value: Int) -> Token { Token(value) }
pub fn value(token: Token) -> Int {
  let Token(value) = token
  value
}
pub fn increment(token: Token) -> Int { value(token) + 1 }
"
  let assert Ok(index) =
    package_types.annotate(
      [package_types.ModuleSource("demo/token", source)],
      girard.Erlang,
    )
  let assert Ok(plan) =
    package_derive.function(index, "demo/token", "increment")
  let spec =
    ProbeSpec(
      target_module: "demo/token",
      probe_module: "probe_opaque",
      pbt_module: "probe_pbt",
      ffi_module: "probe_ffi",
      results_path: "/tmp/results",
      functions: [ProbeFunction(plan, ["m1"], hints.none())],
      seed: 1,
      max_cases: 10,
      max_shrinks: 10,
      call_timeout_ms: 100,
      nondeterminism_checks: 1,
    )
  let rendered = harness.render_probe(spec)

  assert harness.check_spec(spec) == Ok(Nil)
  assert string.contains(rendered, "target.new(values.0)")
  assert string.contains(rendered, "target.value(value)")
  assert string.contains(rendered, "\"token.new(\"")
  assert !string.contains(rendered, "string.inspect(target.value(value))")
}

pub fn smartest_option_opaque_probe_filters_rejected_constructor_results_test() {
  let source =
    "import gleam/option.{type Option, Some}
import gleam/string

pub opaque type Token { Token(String) }
pub fn parse(value: String) -> Option(Token) { Some(Token(value)) }
pub fn value(token: Token) -> String {
  let Token(value) = token
  value
}
pub fn size(token: Token) -> Int { value(token) |> string.length }
"
  let assert Ok(index) =
    package_types.annotate(
      [package_types.ModuleSource("demo/token", source)],
      girard.Erlang,
    )
  let assert Ok(plan) = package_derive.function(index, "demo/token", "size")
  let rendered =
    harness.render_probe(ProbeSpec(
      target_module: "demo/token",
      probe_module: "probe_option_opaque",
      pbt_module: "probe_pbt",
      ffi_module: "probe_ffi",
      results_path: "/tmp/results",
      functions: [ProbeFunction(plan, ["m1"], hints.none())],
      seed: 1,
      max_cases: 10,
      max_shrinks: 10,
      call_timeout_ms: 100,
      nondeterminism_checks: 1,
    ))

  assert string.contains(rendered, "pbt.filter_map(")
  assert string.contains(rendered, "Some(value) -> Some(value)")
  assert string.contains(rendered, "None -> None")
  assert string.contains(rendered, "let assert Some(value) = ")
}

pub fn smartest_opaque_return_is_compared_through_its_public_observer_test() {
  let source =
    "pub opaque type Token { Token(Int) }
pub fn new(value: Int) -> Token { Token(value) }
pub fn value(token: Token) -> Int {
  let Token(value) = token
  value
}
pub fn make(value: Int) -> Token { new(value + 1) }
"
  let assert Ok(index) =
    package_types.annotate(
      [package_types.ModuleSource("demo/token", source)],
      girard.Erlang,
    )
  let assert Ok(plan) = package_derive.function(index, "demo/token", "make")
  let assert Some(OpaqueSpec(observer: observer, ..)) = plan.return_spec
  assert observer == OpaqueObserver("value", IntSpec)
  let rendered =
    harness.render_probe(ProbeSpec(
      target_module: "demo/token",
      probe_module: "probe_opaque_return",
      pbt_module: "probe_pbt",
      ffi_module: "probe_ffi",
      results_path: "/tmp/results",
      functions: [ProbeFunction(plan, ["m1"], hints.none())],
      seed: 1,
      max_cases: 10,
      max_shrinks: 10,
      call_timeout_ms: 100,
      nondeterminism_checks: 1,
    ))

  assert string.contains(
    rendered,
    "show_result_make(original_value) == show_result_make(mutated_value)",
  )
}

pub fn smartest_cross_module_opaque_probe_records_replay_imports_test() {
  let token_source =
    "pub opaque type Token { Token(Int) }
pub fn new(value: Int) -> Token { Token(value) }
pub fn value(token: Token) -> Int {
  let Token(value) = token
  value
}
"
  let use_source =
    "import demo/token
pub fn consume(token: token.Token) -> Int { token.value(token) }
"
  let assert Ok(index) =
    package_types.annotate(
      [
        package_types.ModuleSource("demo/token", token_source),
        package_types.ModuleSource("demo/use", use_source),
      ],
      girard.Erlang,
    )
  let assert Ok(plan) = package_derive.function(index, "demo/use", "consume")
  let assert [parameter] = plan.parameters
  let assert OpaqueSpec(access: access, ..) = parameter.spec

  assert access == genspec.ImportedModuleAccess
  assert harness.support_modules(plan) == ["demo/token"]
  let rendered =
    harness.render_probe(ProbeSpec(
      target_module: "demo/use",
      probe_module: "probe_cross_opaque",
      pbt_module: "probe_pbt",
      ffi_module: "probe_ffi",
      results_path: "/tmp/results",
      functions: [ProbeFunction(plan, ["m1"], hints.none())],
      seed: 1,
      max_cases: 10,
      max_shrinks: 10,
      call_timeout_ms: 100,
      nondeterminism_checks: 1,
    ))
  assert string.contains(rendered, "[\"demo/token\"],")
}
