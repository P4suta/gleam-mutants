//// Package-wide typed project view backed by Girard.
////
//// The legacy suggestion engine parsed one target module at a time. This
//// adapter owns package resolution, target selection, partial inference and
//// diagnostics so typed exploration can consume one stable project view.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import girard
import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/core/path
import simplifile

/// One semantic module and the source Girard and Glance should share.
pub type ModuleSource {
  ModuleSource(module: String, source: String)
}

/// Parsed source and best-effort package inference for one selected target.
pub opaque type PackageIndex {
  PackageIndex(
    sources: Dict(String, String),
    modules: Dict(String, glance.Module),
    inferred: Dict(String, girard.ModuleResult),
    target: girard.Target,
  )
}

/// Parses and annotates a package in source order.
pub fn annotate(
  sources: List(ModuleSource),
  target: girard.Target,
) -> Result(PackageIndex, String) {
  annotate_with_resolver(sources, target, girard.disk_resolver())
}

/// Annotates sources with an explicit dependency resolver.
pub fn annotate_with_resolver(
  sources: List(ModuleSource),
  target: girard.Target,
  fallback: girard.Resolver,
) -> Result(PackageIndex, String) {
  use _ <- result.try(reject_duplicate_modules(sources))
  use parsed <- result.try(list.try_map(sources, parse_module))
  let source_dict =
    sources
    |> list.map(fn(item) { #(item.module, item.source) })
    |> dict.from_list
  let module_dict = dict.from_list(parsed)
  let resolver = fn(path: String) {
    case dict.get(source_dict, path) {
      Ok(source) -> Ok(source)
      Error(_) -> fallback(path)
    }
  }
  use _ <- result.try(ensure_imports(parsed, resolver, target))
  let options =
    girard.default_options()
    |> girard.with_target(target)
    |> girard.with_resolver(resolver)
  let inferred = girard.annotate_package(parsed, options)
  use _ <- result.try(ensure_every_module(parsed, inferred))
  Ok(PackageIndex(source_dict, module_dict, inferred, target))
}

/// Refuses to turn a missing external interface into a collection of
/// misleading per-function inference failures.
fn ensure_imports(
  modules: List(#(String, glance.Module)),
  resolver: girard.Resolver,
  target: girard.Target,
) -> Result(Nil, String) {
  use #(module_name, module) <- list.try_each(modules)
  use definition <- list.try_each(module.imports)
  case import_on_target(definition, target) {
    False -> Ok(Nil)
    True -> {
      let imported = definition.definition.module
      resolver(imported)
      |> result.replace(Nil)
      |> result.map_error(fn(_) {
        module_name <> " imports unresolved external module " <> imported
      })
    }
  }
}

fn import_on_target(
  definition: glance.Definition(a),
  target: girard.Target,
) -> Bool {
  let active = case target {
    girard.Erlang -> "erlang"
    girard.JavaScript -> "javascript"
  }
  list.all(definition.attributes, fn(attribute) {
    case attribute.name, attribute.arguments {
      "target", [glance.Variable(_, selected)] -> selected == active
      _, _ -> True
    }
  })
}

/// Loads every `src/**/*.gleam` module and annotates it against dependencies
/// installed in that same workspace.
pub fn annotate_workspace(
  root: String,
  target: girard.Target,
) -> Result(PackageIndex, String) {
  annotate_workspace_with_dependencies(root, root, target)
}

/// Loads package sources from a content snapshot while resolving external
/// interfaces from the workspace whose dependencies Gleam already installed.
///
/// Mutation snapshots deliberately omit `build/`; coupling the two roots
/// would otherwise force a network fetch or type against mutable source.
pub fn annotate_workspace_with_dependencies(
  source_workspace: String,
  dependency_workspace: String,
  target: girard.Target,
) -> Result(PackageIndex, String) {
  let source_root = path.join(source_workspace, "src")
  use files <- result.try(
    simplifile.get_files(in: source_root)
    |> result.map_error(fn(error) {
      "could not list package sources in "
      <> source_root
      <> ": "
      <> simplifile.describe_error(error)
    }),
  )
  use sources <- result.try(
    files
    |> list.filter(fn(file) { string.ends_with(file, ".gleam") })
    |> list.sort(string.compare)
    |> list.try_map(fn(file) {
      use source <- result.try(
        simplifile.read(file)
        |> result.map_error(fn(error) {
          "could not read " <> file <> ": " <> simplifile.describe_error(error)
        }),
      )
      use module <- result.try(module_path(source_root, file))
      Ok(ModuleSource(module, source))
    }),
  )
  annotate_with_resolver(
    sources,
    target,
    workspace_resolver(dependency_workspace),
  )
}

/// The inferred scheme of a function, or its explicit inference failure.
pub fn function_scheme(
  index: PackageIndex,
  module: String,
  function: String,
) -> Result(girard.Scheme, String) {
  use result <- result.try(module_result(index, module))
  case list.key_find(result.annotated.functions, function) {
    Ok(scheme) -> Ok(scheme)
    Error(_) ->
      case list.key_find(result.skipped, function) {
        Ok(error) ->
          Error(
            module
            <> "."
            <> function
            <> " could not be inferred: "
            <> girard.describe_error(error),
          )
        Error(_) -> Error("unknown function " <> module <> "." <> function)
      }
  }
}

/// Retrieves the parsed AST used by package inference.
pub fn parsed_module(
  index: PackageIndex,
  module: String,
) -> Result(glance.Module, String) {
  dict.get(index.modules, module)
  |> result.map_error(fn(_) { "unknown module " <> module })
}

/// Retrieves the exact source used by package inference.
pub fn module_source(
  index: PackageIndex,
  module: String,
) -> Result(String, String) {
  dict.get(index.sources, module)
  |> result.map_error(fn(_) { "unknown module " <> module })
}

pub fn selected_target(index: PackageIndex) -> girard.Target {
  index.target
}

fn module_result(
  index: PackageIndex,
  module: String,
) -> Result(girard.ModuleResult, String) {
  dict.get(index.inferred, module)
  |> result.map_error(fn(_) { "module " <> module <> " was not inferred" })
}

fn parse_module(
  source: ModuleSource,
) -> Result(#(String, glance.Module), String) {
  glance.module(source.source)
  |> result.map(fn(module) { #(source.module, module) })
  |> result.map_error(fn(error) {
    "Glance could not parse " <> source.module <> ": " <> string.inspect(error)
  })
}

fn reject_duplicate_modules(
  sources: List(ModuleSource),
) -> Result(Nil, String) {
  let duplicate =
    sources
    |> list.map(fn(source) { source.module })
    |> first_duplicate([])
  case duplicate {
    Ok(module) -> Error("duplicate module " <> module)
    Error(_) -> Ok(Nil)
  }
}

fn first_duplicate(values: List(a), seen: List(a)) -> Result(a, Nil) {
  case values {
    [] -> Error(Nil)
    [value, ..rest] ->
      case list.contains(seen, value) {
        True -> Ok(value)
        False -> first_duplicate(rest, [value, ..seen])
      }
  }
}

fn ensure_every_module(
  modules: List(#(String, glance.Module)),
  inferred: Dict(String, girard.ModuleResult),
) -> Result(Nil, String) {
  case list.find(modules, fn(entry) { !dict.has_key(inferred, entry.0) }) {
    Ok(entry) -> Error("Girard did not return module " <> entry.0)
    Error(_) -> Ok(Nil)
  }
}

fn module_path(source_root: String, file: String) -> Result(String, String) {
  let root = normalise(source_root) |> string.trim_end
  let file = normalise(file)
  let prefix = root <> "/"
  case string.starts_with(file, prefix) && string.ends_with(file, ".gleam") {
    True ->
      file
      |> string.drop_start(string.length(prefix))
      |> string.drop_end(6)
      |> Ok
    False -> Error("source file is outside package src: " <> file)
  }
}

fn workspace_resolver(root: String) -> girard.Resolver {
  let packages_root = path.join(root, "build/packages")
  let packages = case simplifile.read_directory(at: packages_root) {
    Ok(packages) -> list.sort(packages, string.compare)
    Error(_) -> []
  }
  // `--root` may name a clean checkout while the CLI itself is running from
  // the package graph that Gleam has already installed. Prefer the selected
  // workspace, but retain Girard's invoking-workspace fallback so suggestion
  // does not require writing `build/` into the user's project first.
  let invoking_workspace = girard.disk_resolver()
  fn(module: String) {
    let candidates = [
      path.join(root, "src/" <> module <> ".gleam"),
      ..list.map(packages, fn(package) {
        path.join(packages_root, package <> "/src/" <> module <> ".gleam")
      })
    ]
    case first_readable(candidates) {
      Ok(source) -> Ok(source)
      Error(_) -> invoking_workspace(module)
    }
  }
}

fn first_readable(files: List(String)) -> Result(String, Nil) {
  case files {
    [] -> Error(Nil)
    [file, ..rest] ->
      case simplifile.read(file) {
        Ok(source) -> Ok(source)
        Error(_) -> first_readable(rest)
      }
  }
}

fn normalise(value: String) -> String {
  string.replace(value, "\\", "/")
}
