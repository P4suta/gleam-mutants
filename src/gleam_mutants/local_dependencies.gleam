// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/core/mutant
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/snapshot.{type Snapshot}
import simplifile
import tomlet.{type Document}

type Dependency {
  Dependency(key: List(String), name: String, location: String)
}

type CapturedDependency {
  CapturedDependency(source: String, captured: Snapshot)
}

const dependency_directory = ".gleam_mutants/dependencies"

pub fn prepare(
  workspace: String,
  captured: Snapshot,
  excluded: List(String),
) -> Result(Snapshot, String) {
  use source <- result.try(resolve(workspace))
  use document <- result.try(read_config(snapshot.root(captured)))
  use direct <- result.try(read_references(document, True))
  use _ <- result.try(
    owned_directory(path.join(snapshot.root(captured), ".gleam_mutants")),
  )
  case direct {
    [] -> {
      use _ <- result.try(
        platform.delete_tree(path.join(
          snapshot.root(captured),
          dependency_directory,
        )),
      )
      Ok(captured)
    }
    _ -> {
      use _ <- result.try(
        owned_directory(path.join(snapshot.root(captured), dependency_directory)),
      )
      use dependencies <- result.try(capture_references(
        direct,
        source,
        snapshot.root(captured),
        [source],
        dict.new(),
      ))
      let ordered =
        dependencies
        |> dict.to_list
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      use _ <- result.try(
        list.try_each(ordered, fn(entry) {
          snapshot.verify_source(entry.1.source, entry.1.captured, [])
        }),
      )
      use _ <- result.try(snapshot.verify_source(source, captured, excluded))
      use relocated <- result.try(relocate(document, direct, True))
      use _ <- result.try(write_config(snapshot.root(captured), relocated))
      use _ <- result.try(relocate_manifest(
        snapshot.root(captured),
        dependencies,
      ))
      use names <- result.try(
        simplifile.read_directory(path.join(
          snapshot.root(captured),
          dependency_directory,
        ))
        |> result.map_error(simplifile.describe_error),
      )
      use _ <- result.try(
        list.try_each(names, fn(name) {
          case dict.has_key(dependencies, name) {
            True -> Ok(Nil)
            False ->
              platform.delete_tree(path.join(
                path.join(snapshot.root(captured), dependency_directory),
                name,
              ))
          }
        }),
      )
      Ok(snapshot.with_dependencies(
        captured,
        list.map(ordered, fn(entry) {
          #(entry.0, snapshot.digest(entry.1.captured))
        }),
      ))
    }
  }
}

fn capture_references(
  references: List(Dependency),
  source: String,
  destination: String,
  active: List(String),
  captured: Dict(String, CapturedDependency),
) -> Result(Dict(String, CapturedDependency), String) {
  use captured, dependency <- list.try_fold(references, captured)
  let location = mutant.normalize_path(dependency.location)
  let absolute =
    string.starts_with(location, "/") || string.slice(location, 1, 1) == ":"
  use dependency_source <- result.try(
    resolve(case absolute {
      True -> location
      False -> path.join(source, location)
    }),
  )
  case list.contains(active, dependency_source) {
    True -> Error("local dependency cycle: " <> dependency.name)
    False ->
      case dict.get(captured, dependency.name) {
        Ok(previous) if previous.source == dependency_source -> Ok(captured)
        Ok(_) -> Error("conflicting local dependency: " <> dependency.name)
        Error(Nil) -> {
          use _ <- result.try(regular_directory(dependency_source))
          let target =
            path.join(
              path.join(destination, dependency_directory),
              dependency.name,
            )
          use _ <- result.try(owned_directory(target))
          use copied <- result.try(snapshot.keep(dependency_source, target, []))
          use document <- result.try(read_config(target))
          use _ <- result.try(
            case tomlet.get_string(document, ["name"]) == Ok(dependency.name) {
              True -> Ok(Nil)
              False ->
                Error("local dependency name mismatch: " <> dependency.name)
            },
          )
          use references <- result.try(read_references(document, False))
          let captured =
            dict.insert(
              captured,
              dependency.name,
              CapturedDependency(dependency_source, copied),
            )
          use captured <- result.try(capture_references(
            references,
            dependency_source,
            destination,
            [dependency_source, ..active],
            captured,
          ))
          use relocated <- result.try(relocate(document, references, False))
          use _ <- result.try(write_config(target, relocated))
          Ok(captured)
        }
      }
  }
}

fn read_references(
  document: Document,
  development: Bool,
) -> Result(List(Dependency), String) {
  let sections = case development {
    True -> ["dependencies", "dev_dependencies"]
    False -> ["dependencies"]
  }
  use found, section <- list.try_fold(sections, [])
  use names <- result.try(case tomlet.table_keys(document, [section]) {
    Ok(names) -> Ok(names)
    Error(tomlet.KeyNotFound(_)) -> Ok([])
    Error(_) -> Error("invalid dependency table: " <> section)
  })
  use found, name <- list.try_fold(names, found)
  let key = [section, name]
  case tomlet.get(document, list.append(key, ["git"])) {
    Ok(_) -> Ok(found)
    Error(_) ->
      case tomlet.get_string(document, list.append(key, ["path"])) {
        Ok(location) -> {
          use _ <- result.try(case valid_name(name) {
            True -> Ok(Nil)
            False -> Error("invalid local dependency name: " <> name)
          })
          Ok([Dependency(key, name, location), ..found])
        }
        Error(tomlet.KeyNotFound(_)) -> Ok(found)
        Error(_) -> Error("invalid local dependency path: " <> name)
      }
  }
}

fn valid_name(name: String) -> Bool {
  let characters = string.to_graphemes(name)
  case characters {
    [first, ..] ->
      string.contains("abcdefghijklmnopqrstuvwxyz", first)
      && list.all(characters, fn(character) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", character)
      })
    [] -> False
  }
}

fn relocate(
  document: Document,
  dependencies: List(Dependency),
  root: Bool,
) -> Result(Document, String) {
  use document, dependency <- list.try_fold(dependencies, document)
  tomlet.set_string(
    document,
    list.append(dependency.key, ["path"]),
    relocated_path(dependency.name, root),
  )
  |> result.replace_error(
    "could not relocate local dependency: " <> dependency.name,
  )
}

fn relocated_path(name: String, root: Bool) -> String {
  case root {
    True -> path.join(dependency_directory, name)
    False -> "../" <> name
  }
}

fn relocate_manifest(
  root: String,
  dependencies: Dict(String, CapturedDependency),
) -> Result(Nil, String) {
  let filename = path.join(root, "manifest.toml")
  case simplifile.read(filename) {
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) -> Error(simplifile.describe_error(error))
    Ok(source) -> {
      use document <- result.try(
        tomlet.parse(source)
        |> result.replace_error("invalid dependency manifest"),
      )
      use packages <- result.try(case tomlet.get(document, ["packages"]) {
        Ok(tomlet.ArrayValue(packages)) -> Ok(packages)
        _ -> Error("invalid dependency manifest packages")
      })
      let obsolete =
        list.filter_map(packages, fn(package) {
          case
            tomlet.value_get(package, ["source"]),
            tomlet.value_get(package, ["name"])
          {
            Ok(tomlet.StringValue("local")), Ok(tomlet.StringValue(name)) ->
              case dict.has_key(dependencies, name) {
                True -> Error(Nil)
                False -> Ok(name)
              }
            _, _ -> Error(Nil)
          }
        })
      let packages =
        list.filter(packages, fn(package) {
          case
            tomlet.value_get(package, ["source"]),
            tomlet.value_get(package, ["name"])
          {
            Ok(tomlet.StringValue("local")), Ok(tomlet.StringValue(name)) ->
              !list.contains(obsolete, name)
            _, _ -> True
          }
        })
      use document <- result.try(
        list.try_fold(obsolete, document, fn(document, name) {
          case tomlet.remove(document, ["requirements", name]) {
            Ok(document) -> Ok(document)
            Error(tomlet.MissingEditKey(_)) -> Ok(document)
            Error(_) ->
              Error(
                "could not remove obsolete local dependency requirement: "
                <> name,
              )
          }
        }),
      )
      use packages <- result.try(
        list.try_map(packages, fn(package) {
          case tomlet.value_get(package, ["source"]) {
            Ok(tomlet.StringValue("local")) -> {
              use name <- result.try(
                tomlet.value_get(package, ["name"])
                |> result.try(tomlet.as_string)
                |> result.replace_error(
                  "invalid local dependency manifest name",
                ),
              )
              use _ <- result.try(case dict.has_key(dependencies, name) {
                True -> Ok(Nil)
                False ->
                  Error("unresolved local dependency in manifest: " <> name)
              })
              case package {
                tomlet.InlineTableValue(entries) ->
                  Ok(
                    tomlet.InlineTableValue(
                      list.map(entries, fn(entry) {
                        case entry.0 {
                          ["path"] -> #(
                            ["path"],
                            tomlet.StringValue(relocated_path(name, True)),
                          )
                          _ -> entry
                        }
                      }),
                    ),
                  )
                _ -> Error("invalid local dependency manifest package")
              }
            }
            _ -> Ok(package)
          }
        }),
      )
      use document <- result.try(
        tomlet.set_array(document, ["packages"], packages)
        |> result.replace_error(
          "could not relocate dependency manifest packages",
        ),
      )
      use document <- result.try(
        list.try_fold(dict.to_list(dependencies), document, fn(document, entry) {
          let key = ["requirements", entry.0, "path"]
          case tomlet.get_string(document, key) {
            Ok(_) ->
              tomlet.set_string(document, key, relocated_path(entry.0, True))
              |> result.replace_error(
                "could not relocate dependency manifest requirement: "
                <> entry.0,
              )
            Error(tomlet.KeyNotFound(_)) -> Ok(document)
            Error(_) ->
              Error("invalid dependency manifest requirement: " <> entry.0)
          }
        }),
      )
      simplifile.write(filename, tomlet.to_string(document))
      |> result.map_error(simplifile.describe_error)
    }
  }
}

fn read_config(root: String) -> Result(Document, String) {
  use source <- result.try(
    simplifile.read(path.join(root, "gleam.toml"))
    |> result.map_error(simplifile.describe_error),
  )
  tomlet.parse(source)
  |> result.replace_error("invalid local dependency configuration: " <> root)
}

fn write_config(root: String, document: Document) -> Result(Nil, String) {
  simplifile.write(path.join(root, "gleam.toml"), tomlet.to_string(document))
  |> result.map_error(simplifile.describe_error)
}

fn resolve(location: String) -> Result(String, String) {
  location
  |> platform.resolve_path
  |> mutant.normalize_path
  |> simplifile.resolve
  |> result.map_error(simplifile.describe_error)
}

fn regular_directory(directory: String) -> Result(Nil, String) {
  use info <- result.try(
    simplifile.link_info(directory)
    |> result.map_error(simplifile.describe_error),
  )
  case simplifile.file_info_type(info), platform.is_reparse_point(directory) {
    simplifile.Directory, False -> Ok(Nil)
    _, _ ->
      Error("refusing linked or non-directory local dependency: " <> directory)
  }
}

fn owned_directory(directory: String) -> Result(Nil, String) {
  case simplifile.link_info(directory) {
    Error(simplifile.Enoent) ->
      simplifile.create_directory(directory)
      |> result.map_error(simplifile.describe_error)
    Error(error) -> Error(simplifile.describe_error(error))
    Ok(_) -> regular_directory(directory)
  }
}
