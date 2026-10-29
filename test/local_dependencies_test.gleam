// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/string
import gleam_mutants/api
import gleam_mutants/core/path
import gleam_mutants/local_dependencies
import gleam_mutants/platform
import gleam_mutants/snapshot
import simplifile
import tomlet

fn fixture() -> String {
  let root =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-dependencies-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory(root)
  root
}

fn package(root: String, name: String, dependencies: String) -> String {
  let directory = path.join(root, name)
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(directory, "src"))
  let assert Ok(Nil) =
    simplifile.write(
      path.join(directory, "gleam.toml"),
      "name = \"" <> name <> "\"\nversion = \"0.0.0\"\n" <> dependencies,
    )
  let assert Ok(Nil) =
    simplifile.write(
      path.join(directory, "src/" <> name <> ".gleam"),
      "pub fn enabled() { True }\n",
    )
  directory
}

fn dependency_path(root: String, name: String) -> String {
  path.join(root, ".gleam_mutants/dependencies/" <> name)
}

fn config(root: String) -> tomlet.Document {
  let assert Ok(source) = simplifile.read(path.join(root, "gleam.toml"))
  let assert Ok(document) = tomlet.parse(source)
  document
}

pub fn transitive_and_shared_dependencies_are_frozen_and_relocatable_test() {
  let root = fixture()
  let source =
    package(
      root,
      "consumer",
      "[dependencies]\nleft = { path = \"../left\" }\nright = { path = \"../right\" }\n[dev_dependencies]\nsupport = { path = \"../support\" }\n",
    )
  let left =
    package(
      root,
      "left",
      "[dependencies]\nshared = { path = \"../shared\" }\n[dev_dependencies]\nunused = { path = \"../missing\" }\n",
    )
  let _ =
    package(
      root,
      "right",
      "[dependencies]\nshared = { path = \"../shared\" }\n",
    )
  let shared = package(root, "shared", "")
  let _ = package(root, "support", "")
  let assert Ok(captured) = snapshot.create(source)
  let assert Ok(frozen) = local_dependencies.prepare(source, captured, [])
  let assert Ok(names) =
    simplifile.read_directory(path.join(
      snapshot.root(frozen),
      ".gleam_mutants/dependencies",
    ))
  assert list.sort(names, string.compare)
    == ["left", "right", "shared", "support"]
  assert tomlet.get_string(config(snapshot.root(frozen)), [
      "dependencies",
      "left",
      "path",
    ])
    == Ok(".gleam_mutants/dependencies/left")
  assert tomlet.get_string(
      config(dependency_path(snapshot.root(frozen), "left")),
      ["dependencies", "shared", "path"],
    )
    == Ok("../shared")
  assert tomlet.get_string(config(left), ["dependencies", "shared", "path"])
    == Ok("../shared")
  let assert Ok(Nil) = platform.delete_tree(shared)
  let assert Ok(worker) = snapshot.duplicate(frozen)
  assert simplifile.read(path.join(
      dependency_path(snapshot.root(worker), "shared"),
      "src/shared.gleam",
    ))
    == Ok("pub fn enabled() { True }\n")
  let assert Ok(Nil) = snapshot.dispose(worker)
  let assert Ok(Nil) = snapshot.dispose(captured)
  let assert Ok(Nil) = platform.delete_tree(root)
}

pub fn dependency_changes_invalidate_identity_and_kept_copies_drop_removed_files_test() {
  let root = fixture()
  let dependency = package(root, "library", "")
  let source =
    package(
      root,
      "consumer",
      "[dependencies]\nlibrary = { path = \"../library\" }\n",
    )
  let destination = path.join(root, "kept")
  let removed = path.join(dependency, "src/removed.gleam")
  let assert Ok(Nil) = simplifile.write(removed, "pub fn removed() { Nil }\n")
  let assert Ok(first) = snapshot.keep(source, destination, [])
  let assert Ok(first) = local_dependencies.prepare(source, first, [])
  let assert Ok(Nil) = simplifile.delete(removed)
  let assert Ok(Nil) =
    simplifile.write(
      path.join(dependency, "src/library.gleam"),
      "pub fn enabled() { False }\n",
    )
  let assert Ok(second) = snapshot.keep(source, destination, [])
  let assert Ok(second) = local_dependencies.prepare(source, second, [])
  assert snapshot.digest(first) != snapshot.digest(second)
  assert simplifile.is_file(path.join(
      dependency_path(destination, "library"),
      "src/removed.gleam",
    ))
    == Ok(False)
  let assert Ok(third) = snapshot.keep(source, destination, [])
  let assert Ok(third) = local_dependencies.prepare(source, third, [])
  assert snapshot.digest(second) == snapshot.digest(third)
  let assert Ok(Nil) =
    simplifile.write(
      path.join(source, "gleam.toml"),
      "name = \"consumer\"\nversion = \"0.0.0\"\n",
    )
  let assert Ok(last) = snapshot.keep(source, destination, [])
  let assert Ok(_) = local_dependencies.prepare(source, last, [])
  assert simplifile.is_directory(path.join(
      destination,
      ".gleam_mutants/dependencies",
    ))
    == Ok(False)
  let assert Ok(Nil) = platform.delete_tree(root)
}

pub fn absolute_dependencies_are_copied_without_changing_original_configuration_test() {
  let root = fixture()
  let dependency = package(root, "library", "")
  let source = package(root, "consumer", "")
  let assert Ok(document) =
    tomlet.set_string(
      config(source),
      ["dependencies", "library", "path"],
      dependency,
    )
  let original = tomlet.to_string(document)
  let assert Ok(Nil) =
    simplifile.write(path.join(source, "gleam.toml"), original)
  let assert Ok(captured) = snapshot.create(source)
  let frozen = local_dependencies.prepare(source, captured, [])
  assert simplifile.read(path.join(source, "gleam.toml")) == Ok(original)
  let assert Ok(_) = frozen
  let assert Ok(Nil) = snapshot.dispose(captured)
  let assert Ok(Nil) = platform.delete_tree(root)
}

pub fn cycles_and_conflicting_local_sources_are_rejected_test() {
  let root = fixture()
  let source =
    package(
      root,
      "consumer",
      "[dependencies]\nlibrary = { path = \"../library\" }\n",
    )
  let library =
    package(
      root,
      "library",
      "[dependencies]\nconsumer = { path = \"../consumer\" }\n",
    )
  let assert Ok(captured) = snapshot.create(source)
  let assert Error(error) = local_dependencies.prepare(source, captured, [])
  assert string.contains(error, "local dependency cycle")
  let assert Ok(Nil) = snapshot.dispose(captured)
  let _ = package(root, "other", "")
  let assert Ok(Nil) =
    simplifile.write(
      path.join(library, "gleam.toml"),
      "name = \"library\"\nversion = \"0.0.0\"\n[dependencies]\nlibrary = { path = \"../other\" }\n",
    )
  let assert Ok(captured) = snapshot.create(source)
  let assert Error(error) = local_dependencies.prepare(source, captured, [])
  assert string.contains(error, "conflicting local dependency")
  let assert Ok(Nil) = snapshot.dispose(captured)
  let assert Ok(Nil) = platform.delete_tree(root)
}

pub fn git_subdirectory_paths_are_not_local_dependencies_test() {
  let root = fixture()
  let source =
    package(
      root,
      "consumer",
      "[dependencies]\nremote = { git = \"https://example.invalid/remote\", ref = \"abc\", path = \"packages/remote\" }\n",
    )
  let assert Ok(captured) = snapshot.create(source)
  let assert Ok(prepared) = local_dependencies.prepare(source, captured, [])
  assert snapshot.digest(prepared) == snapshot.digest(captured)
  let assert Ok(Nil) = snapshot.dispose(captured)
  let assert Ok(Nil) = platform.delete_tree(root)
}

pub fn stale_local_manifest_entries_do_not_require_removed_dependencies_test() {
  let root = fixture()
  let source =
    package(
      root,
      "consumer",
      "[dependencies]\nlibrary = { path = \"../library\" }\n",
    )
  let _ = package(root, "library", "")
  let manifest =
    "packages = [\n"
    <> "{ name = \"library\", version = \"0.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../library\" },\n"
    <> "{ name = \"retired\", version = \"0.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../retired\" },\n]\n"
    <> "[requirements]\nlibrary = { path = \"../library\" }\nretired = { path = \"../retired\" }\n"
  let assert Ok(Nil) =
    simplifile.write(path.join(source, "manifest.toml"), manifest)
  let assert Ok(captured) = snapshot.create(source)
  let attempted = local_dependencies.prepare(source, captured, [])
  let unchanged = simplifile.read(path.join(source, "manifest.toml"))
  let assert Ok(Nil) = snapshot.dispose(captured)
  let assert Ok(Nil) = platform.delete_tree(root)
  assert unchanged == Ok(manifest)
  let assert Ok(_) = attempted
}

pub fn unvalidated_listing_does_not_require_local_dependencies_test() {
  let root = fixture()
  let source =
    package(
      root,
      "consumer",
      "[dependencies]\nmissing = { path = \"../missing\" }\n",
    )
  let listed = api.list_mutants(source, api.default_options())
  let assert Ok(Nil) = platform.delete_tree(root)
  let assert Ok(catalog) = listed
  assert catalog.mutants != []
}

pub fn symlinked_dependency_contents_are_rejected_test() {
  let root = fixture()
  let source =
    package(
      root,
      "consumer",
      "[dependencies]\nlibrary = { path = \"../library\" }\n",
    )
  let dependency = package(root, "library", "")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      path.join(source, "src/consumer.gleam"),
      path.join(dependency, "src/linked.gleam"),
    )
  let assert Ok(captured) = snapshot.create(source)
  let assert Error(error) = local_dependencies.prepare(source, captured, [])
  assert string.contains(error, "refusing symlink or junction")
  let assert Ok(Nil) = snapshot.dispose(captured)
  let assert Ok(Nil) = platform.delete_tree(root)
}

pub fn posix_dependency_backslashes_are_refused_before_reinterpretation_test() {
  case platform.os_name() {
    "windows" -> Nil
    _ -> {
      let root = fixture()
      let source =
        package(
          root,
          "consumer",
          "[dependencies]\nlibrary = { path = '..\\library' }\n",
        )
      let _dependency = package(root, "library", "")
      let assert Ok(captured) = snapshot.create(source)
      let attempted = local_dependencies.prepare(source, captured, [])
      let assert Ok(Nil) = snapshot.dispose(captured)
      let assert Ok(Nil) = platform.delete_tree(root)
      let assert Error(message) = attempted
      assert string.contains(message, "unsupported backslash")
    }
  }
}

pub fn posix_colon_dependency_paths_resolve_from_their_package_test() {
  case platform.os_name() {
    "windows" -> Nil
    _ -> {
      let root = fixture()
      let source =
        package(
          root,
          "consumer",
          "[dependencies]\nlibrary = { path = 'x:library' }\n",
        )
      let library = package(root, "library", "")
      let assert Ok(Nil) =
        simplifile.rename(at: library, to: path.join(source, "x:library"))
      let compiled =
        platform.run_process(
          "gleam",
          ["build", "--target", "erlang"],
          source,
          [],
          30_000,
        )
      assert compiled.status == 0
      let assert Ok(captured) = snapshot.create(source)
      let attempted = local_dependencies.prepare(source, captured, [])
      let copied = case attempted {
        Ok(prepared) ->
          tomlet.get_string(
            config(dependency_path(snapshot.root(prepared), "library")),
            ["name"],
          )
          == Ok("library")
        Error(_) -> False
      }
      let assert Ok(Nil) = snapshot.dispose(captured)
      let assert Ok(Nil) = platform.delete_tree(root)
      let assert Ok(_) = attempted
      assert copied
    }
  }
}

pub fn all_three_package_graphs_match_an_independent_reachability_reference_test() {
  let root = fixture()
  check_graphs(root, 0)
  let assert Ok(Nil) = platform.delete_tree(root)
}

fn check_graphs(root: String, mask: Int) -> Nil {
  case mask == 512 {
    True -> Nil
    False -> {
      let names = ["consumer", "left", "right"]
      let edges =
        list.index_map(names, fn(_, from) {
          list.index_map(names, fn(_, to) { #(from, to) })
          |> list.filter(fn(edge) {
            int.bitwise_and(
              mask,
              int.bitwise_shift_left(1, edge.0 * 3 + edge.1),
            )
            != 0
          })
        })
        |> list.flatten
      let closure =
        list.fold([Nil, Nil, Nil], edges, fn(reachable, _) {
          let composed =
            list.flat_map(reachable, fn(first) {
              list.filter_map(reachable, fn(second) {
                case first.1 == second.0 {
                  True -> Ok(#(first.0, second.1))
                  False -> Error(Nil)
                }
              })
            })
          list.unique(list.append(reachable, composed))
        })
      let cyclic =
        list.any(closure, fn(edge) {
          edge.0 == edge.1
          && { edge.0 == 0 || list.contains(closure, #(0, edge.0)) }
        })
      list.index_map(names, fn(name, from) {
        let dependencies =
          list.index_map(names, fn(target, to) {
            case list.contains(edges, #(from, to)) {
              True -> target <> " = { path = \"../" <> target <> "\" }\n"
              False -> ""
            }
          })
          |> string.concat
        package(root, name, "[dependencies]\n" <> dependencies)
      })
      let source = path.join(root, "consumer")
      let assert Ok(captured) = snapshot.create(source)
      let actual = local_dependencies.prepare(source, captured, [])
      let assert Ok(Nil) = snapshot.dispose(captured)
      case actual, cyclic {
        Error(error), True -> {
          assert string.contains(error, "local dependency cycle")
        }
        Ok(_), False -> Nil
        _, _ -> panic as "dependency graph disagrees with reachability reference"
      }
      check_graphs(root, mask + 1)
    }
  }
}
