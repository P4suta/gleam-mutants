// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import girard
import gleam/result
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/suggest/package_types
import simplifile

const types_source = "pub type Box(a) { Box(a) }"

const use_source = "import demo/types.{Box}\n\npub fn wrap(value) { Box(value) }"

pub fn smartest_package_inference_resolves_unannotated_cross_module_types_test() {
  let assert Ok(index) =
    package_types.annotate(
      [
        package_types.ModuleSource("demo/types", types_source),
        package_types.ModuleSource("demo/use", use_source),
      ],
      girard.Erlang,
    )
  let assert Ok(scheme) =
    package_types.function_scheme(index, "demo/use", "wrap")
  let assert girard.Fn([argument], return) = scheme.type_
  let assert girard.Named("demo/types", "Box", [inner]) = return
  assert argument == inner
}

pub fn smartest_package_inference_honours_the_selected_target_test() {
  let source =
    "@target(erlang)\npub fn beam_only() { 1 }\n\n@target(javascript)\npub fn js_only() { 2 }"
  let modules = [package_types.ModuleSource("demo/targeted", source)]
  let assert Ok(erlang) = package_types.annotate(modules, girard.Erlang)
  let assert Ok(javascript) = package_types.annotate(modules, girard.JavaScript)

  assert result.is_ok(package_types.function_scheme(
    erlang,
    "demo/targeted",
    "beam_only",
  ))
  assert result.is_error(package_types.function_scheme(
    erlang,
    "demo/targeted",
    "js_only",
  ))
  assert result.is_ok(package_types.function_scheme(
    javascript,
    "demo/targeted",
    "js_only",
  ))
  assert result.is_error(package_types.function_scheme(
    javascript,
    "demo/targeted",
    "beam_only",
  ))
}

pub fn smartest_package_inference_names_the_module_that_did_not_parse_test() {
  let assert Error(message) =
    package_types.annotate(
      [package_types.ModuleSource("demo/broken", "pub fn broken(")],
      girard.Erlang,
    )
  assert string.contains(message, "demo/broken")
}

pub fn smartest_package_inference_refuses_duplicate_semantic_modules_test() {
  let assert Error(message) =
    package_types.annotate(
      [
        package_types.ModuleSource("demo/repeated", "pub fn one() { 1 }"),
        package_types.ModuleSource("demo/repeated", "pub fn two() { 2 }"),
      ],
      girard.Erlang,
    )
  assert string.contains(message, "duplicate module")
}

pub fn smartest_package_inference_exposes_definition_failures_test() {
  let source = "pub fn broken() { 1 + \"wrong\" }\n\npub fn sound() { 1 + 2 }"
  let assert Ok(index) =
    package_types.annotate(
      [package_types.ModuleSource("demo/partial", source)],
      girard.Erlang,
    )
  assert result.is_ok(package_types.function_scheme(
    index,
    "demo/partial",
    "sound",
  ))
  let assert Error(message) =
    package_types.function_scheme(index, "demo/partial", "broken")
  assert string.contains(message, "broken")
}

pub fn smartest_package_inference_fails_closed_on_an_unresolved_external_import_test() {
  let source = "import absent/module\n\npub fn use_it() { module.value() }"
  let assert Error(message) =
    package_types.annotate_with_resolver(
      [package_types.ModuleSource("demo/use", source)],
      girard.Erlang,
      fn(_) { Error(Nil) },
    )

  assert message == "demo/use imports unresolved external module absent/module"
}

pub fn smartest_workspace_annotation_loads_every_source_module_once_test() {
  let root =
    path.join(
      platform.temporary_directory(),
      "smartest-package-types-" <> platform.random_nonce(),
    )
  let types_path = path.join(root, "src/demo/types.gleam")
  let use_path = path.join(root, "src/demo/use.gleam")
  let assert Ok(Nil) = simplifile.create_directory_all(path.parent(types_path))
  let assert Ok(Nil) = simplifile.write(types_path, types_source)
  let assert Ok(Nil) = simplifile.write(use_path, use_source)

  let assert Ok(index) = package_types.annotate_workspace(root, girard.Erlang)
  assert result.is_ok(package_types.function_scheme(index, "demo/use", "wrap"))
  let _ = platform.delete_tree(root)
  Nil
}

pub fn smartest_workspace_annotation_can_separate_snapshot_sources_from_dependencies_test() {
  let nonce = platform.random_nonce()
  let source_root =
    path.join(
      platform.temporary_directory(),
      "smartest-package-source-" <> nonce,
    )
  let dependency_root =
    path.join(
      platform.temporary_directory(),
      "smartest-package-dependencies-" <> nonce,
    )
  let source_path = path.join(source_root, "src/demo/use.gleam")
  let dependency_path =
    path.join(dependency_root, "build/packages/support/src/external/api.gleam")
  let assert Ok(Nil) = simplifile.create_directory_all(path.parent(source_path))
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.parent(dependency_path))
  let assert Ok(Nil) =
    simplifile.write(
      source_path,
      "import external/api\n\npub fn use_it() { api.value() }",
    )
  let assert Ok(Nil) = simplifile.write(dependency_path, "pub fn value() { 1 }")

  let assert Ok(index) =
    package_types.annotate_workspace_with_dependencies(
      source_root,
      dependency_root,
      girard.Erlang,
    )
  assert result.is_ok(package_types.function_scheme(index, "demo/use", "use_it"))
  let _ = platform.delete_tree(source_root)
  let _ = platform.delete_tree(dependency_root)
  Nil
}

pub fn smartest_workspace_annotation_falls_back_to_the_callers_installed_dependencies_test() {
  let root =
    path.join(
      platform.temporary_directory(),
      "smartest-package-fallback-" <> platform.random_nonce(),
    )
  let source_path = path.join(root, "src/demo/use.gleam")
  let assert Ok(Nil) = simplifile.create_directory_all(path.parent(source_path))
  let assert Ok(Nil) =
    simplifile.write(
      source_path,
      "import gleam/string\n\npub fn loud(value) { string.uppercase(value) }",
    )

  let annotated = package_types.annotate_workspace(root, girard.Erlang)
  let _ = platform.delete_tree(root)

  let assert Ok(index) = annotated
  assert result.is_ok(package_types.function_scheme(index, "demo/use", "loud"))
}
