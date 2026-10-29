// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam_mutants/api
import gleam_mutants/cache
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/types
import simplifile

const project_config = "name = \"local_dependency_consumer\"\nversion = \"0.0.0\"\n"
  <> "[dependencies]\narithmetic_fixture = { path = \"../arithmetic\" }\n"
  <> "[dev_dependencies]\nassertion_fixture = { path = \"../assertion\" }\n"
  <> "[tools.gleam_mutants]\nversion = 1\n"
  <> "[tools.gleam_mutants.test]\ntarget = \"erlang\"\nruntime = \"erlang\"\n"
  <> "[tools.gleam_mutants.cache]\nmode = \"read-write\"\n"

const source = "import arithmetic_fixture\n"
  <> "pub fn add_one(value: Int) -> Int { arithmetic_fixture.identity(value) + 1 }\n"

pub fn main() {
  let directory =
    path.join(
      platform.temporary_directory(),
      "gleam mutants local dependency " <> platform.random_nonce(),
    )
  let project = path.join(directory, "consumer")
  let dependency = path.join(directory, "arithmetic")
  let identity = path.join(directory, "identity")
  let assertion = path.join(directory, "assertion")
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(project, "src"))
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(project, "test"))
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(dependency, "src"))
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(identity, "src"))
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(assertion, "src"))
  let assert Ok(Nil) =
    simplifile.write(path.join(project, "gleam.toml"), project_config)
  let assert Ok(Nil) =
    simplifile.write(
      path.join(project, "src/local_dependency_consumer.gleam"),
      source,
    )
  let assert Ok(Nil) =
    simplifile.write(
      path.join(project, "test/local_dependency_consumer_test.gleam"),
      "import local_dependency_consumer\nimport assertion_fixture\npub fn main() { assertion_fixture.check(local_dependency_consumer.add_one(1)) }\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      path.join(dependency, "gleam.toml"),
      "name = \"arithmetic_fixture\"\nversion = \"0.0.0\"\n[dependencies]\nidentity_fixture = { path = \"../identity\" }\n[dev_dependencies]\nunneeded = { path = \"../absent\" }\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      path.join(dependency, "src/arithmetic_fixture.gleam"),
      "import identity_fixture\npub fn identity(value: Int) -> Int { identity_fixture.identity(value) }\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      path.join(identity, "gleam.toml"),
      "name = \"identity_fixture\"\nversion = \"0.0.0\"\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      path.join(identity, "src/identity_fixture.gleam"),
      "pub fn identity(value: Int) -> Int { value }\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      path.join(assertion, "gleam.toml"),
      "name = \"assertion_fixture\"\nversion = \"0.0.0\"\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      path.join(assertion, "src/assertion_fixture.gleam"),
      "pub fn check(value: Int) { let assert 2 = value }\n",
    )
  let built =
    platform.run_process(
      "gleam",
      ["build", "--target", "erlang"],
      project,
      [],
      30_000,
    )
  let manifest = simplifile.read(path.join(project, "manifest.toml"))
  let options =
    types.Options(
      ..api.default_options(),
      operators: Some([types.IntegerArithmetic]),
      jobs: Some(2),
      matrix: True,
    )
  let validation = api.validate_mutants(project, options)
  let execution = api.run(project, options)
  let repeated = api.run(project, options)
  let assert Ok(Nil) =
    simplifile.write(
      path.join(assertion, "src/assertion_fixture.gleam"),
      "pub fn check(_value: Int) { Nil }\n",
    )
  let changed = api.run(project, options)
  let original_config = simplifile.read(path.join(project, "gleam.toml"))
  let original_source =
    simplifile.read(path.join(project, "src/local_dependency_consumer.gleam"))
  let original_manifest = simplifile.read(path.join(project, "manifest.toml"))
  let cache_cleanup = cache.clean(project)
  let snapshot_cleanup = platform.delete_tree(cache.workspace_snapshot(project))
  let cleanup = platform.delete_tree(directory)
  let assert Ok(Nil) = cleanup
  let assert Ok(Nil) = cache_cleanup
  let assert Ok(Nil) = snapshot_cleanup
  assert built.status == 0
  let assert Ok(_) = manifest
  assert manifest == original_manifest
  let assert Ok(catalog) = validation
  assert catalog.validation == types.CompilerValidated
  let assert Ok(report) = execution
  assert report.score.total == 1
  assert report.score.killed == 1
  assert report.score.errors == 0
  let assert [result] = report.results
  let assert [_, _, _, _] = result.outcomes
  let assert Ok(repeated) = repeated
  assert repeated.workspace_digest == report.workspace_digest
  assert list.all(repeated.results, fn(result) {
    list.all(result.outcomes, fn(outcome) { outcome.cached })
  })
  let assert Ok(changed) = changed
  assert changed.workspace_digest != report.workspace_digest
  assert changed.score.survived == 1
  assert list.all(changed.results, fn(result) {
    list.all(result.outcomes, fn(outcome) { !outcome.cached })
  })
  assert original_config == Ok(project_config)
  assert original_source == Ok(source)
  io.println(
    "Transitive local and development dependencies, cache invalidation, and input preservation passed on all four runtimes",
  )
}
