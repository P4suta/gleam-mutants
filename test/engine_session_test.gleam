// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/engine
import gleam_mutants/platform
import gleam_mutants/snapshot
import simplifile

fn workspace(label: String) -> String {
  let root =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-session-" <> label <> "-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(path.join(root, "src"))
  let assert Ok(Nil) =
    simplifile.write(
      path.join(root, "gleam.toml"),
      "name = \"session_fixture\"\nversion = \"0.0.0\"\n[tools.gleam_mutants]\nversion = 1\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      path.join(root, "src/main.gleam"),
      "pub fn enabled() { True }\n",
    )
  root
}

pub fn catalogue_session_disposes_its_single_snapshot_after_success_test() {
  let root = workspace("success")
  let assert Ok(#(captured, ids)) =
    engine.with_catalog_session(root, engine.default_options(), fn(session) {
      Ok(#(
        snapshot.root(engine.session_snapshot(session)),
        engine.session_candidates(session)
          |> list.map(fn(mutant) { mutant.id }),
      ))
    })
  assert ids != []
  assert simplifile.is_directory(captured) == Ok(False)
  let assert Ok(Nil) = simplifile.delete(root)
}

pub fn catalogue_session_disposes_its_single_snapshot_after_callback_error_test() {
  let root = workspace("error")
  let witness = path.join(root, "captured.txt")
  let attempt: Result(Nil, String) =
    engine.with_catalog_session(root, engine.default_options(), fn(session) {
      let assert Ok(Nil) =
        simplifile.write(
          witness,
          snapshot.root(engine.session_snapshot(session)),
        )
      Error("sentinel")
    })
  let assert Error("sentinel") = attempt
  let assert Ok(captured) = simplifile.read(witness)
  assert !string.is_empty(captured)
  assert simplifile.is_directory(captured) == Ok(False)
  let assert Ok(Nil) = simplifile.delete(root)
}

/// A worker carries the build directory the snapshot it came from has.
///
/// This is the whole point of `duplicate`, and it is not visible in a verdict:
/// a worker without `build` compiles the package and every dependency from
/// cold, once per worker, so asking for more workers asked the compiler for
/// more of the same work.
pub fn a_duplicated_snapshot_carries_the_build_directory_test() {
  let root = workspace("duplicate")
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(root, "build/dev/erlang"))
  let assert Ok(Nil) =
    simplifile.write(path.join(root, "build/dev/erlang/stale.beam"), "stale")

  // A workspace's build directory is the user's, and `create` leaves it there:
  // the copy is of the sources, and the compiler fills the rest in.
  let assert Ok(captured) = snapshot.create(root)
  assert simplifile.is_file(path.join(
      snapshot.root(captured),
      "build/dev/erlang/stale.beam",
    ))
    == Ok(False)

  // What the baseline then does inside it: build. The artefacts are this run's
  // own, and they are what a worker must not have to make for itself.
  let built = path.join(snapshot.root(captured), "build/dev/erlang")
  let assert Ok(Nil) = simplifile.create_directory_all(built)
  let assert Ok(Nil) =
    simplifile.write(path.join(built, "artefact.beam"), "beam")

  let assert Ok(worker) = snapshot.duplicate(captured)
  let assert Ok(carried) =
    simplifile.read(path.join(
      snapshot.root(worker),
      "build/dev/erlang/artefact.beam",
    ))
  assert carried == "beam"
  // The sources came too, or the worker would have nothing to run.
  let assert Ok(source) =
    simplifile.read(path.join(snapshot.root(worker), "src/main.gleam"))
  assert source == "pub fn enabled() { True }\n"
  // Identity is the snapshot's, not the copy's: a worker is the same tree.
  assert snapshot.digest(worker) == snapshot.digest(captured)

  let assert Ok(Nil) = snapshot.dispose(worker)
  let assert Ok(Nil) = snapshot.dispose(captured)
  let assert Ok(Nil) = platform.delete_tree(root)
}

/// A link under the copy is left for the compiler to make again.
///
/// Gleam links each package's `priv` into `build` by absolute path, so copying
/// one would point the worker back at the tree it was copied from. Leaving it
/// out costs nothing -- the next build makes it again, into the worker -- and
/// it is the isolation a worker is for.
pub fn a_duplicated_snapshot_leaves_a_link_for_the_compiler_test() {
  let root = workspace("duplicate-link")
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(root, "build/dev/erlang/fixture"))
  let assert Ok(captured) = snapshot.create(root)
  let linked =
    path.join(snapshot.root(captured), "build/dev/erlang/fixture/priv")
  let assert Ok(Nil) =
    simplifile.create_directory_all(path.join(
      snapshot.root(captured),
      "build/dev/erlang/fixture",
    ))
  let assert Ok(Nil) =
    simplifile.create_symlink(path.join(snapshot.root(captured), "src"), linked)

  let assert Ok(worker) = snapshot.duplicate(captured)
  let copied = path.join(snapshot.root(worker), "build/dev/erlang/fixture/priv")
  assert simplifile.is_directory(copied) == Ok(False)
  assert simplifile.is_file(copied) == Ok(False)

  let assert Ok(Nil) = snapshot.dispose(worker)
  let assert Ok(Nil) = snapshot.dispose(captured)
  let assert Ok(Nil) = platform.delete_tree(root)
}

/// The compiler's work survives into the next capture; a stale source does not.
///
/// Capturing into a directory that is kept is what lets the next run compile
/// only what changed, and the whole risk of it is the other half: a file the
/// workspace no longer has, or one an earlier run generated, would still be
/// there to compile. Both are pinned here, because neither is visible in a
/// verdict until it is wrong.
pub fn a_kept_snapshot_holds_the_build_and_drops_what_the_workspace_lost_test() {
  let root = workspace("kept")
  let destination =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-kept-" <> platform.random_nonce(),
    )

  let assert Ok(first) = snapshot.keep(root, destination, [])
  assert snapshot.root(first) == destination
  // Disposing a kept copy leaves it where it is; that is the point of it.
  let assert Ok(Nil) = snapshot.dispose(first)
  assert simplifile.is_directory(destination) == Ok(True)

  // What the baseline leaves behind, and an earlier run's generated module.
  let built = path.join(destination, "build/dev/erlang")
  let assert Ok(Nil) = simplifile.create_directory_all(built)
  let assert Ok(Nil) =
    simplifile.write(path.join(built, "artefact.beam"), "beam")
  let assert Ok(Nil) =
    simplifile.write(
      path.join(destination, "src/gleam_mutants_runtime_abc.gleam"),
      "pub fn active() { \"\" }\n",
    )
  // And a source the workspace has since lost.
  let assert Ok(Nil) =
    simplifile.write(path.join(root, "src/gone.gleam"), "pub fn gone() { 1 }\n")
  let assert Ok(second) = snapshot.keep(root, destination, [])
  let assert Ok(Nil) = snapshot.dispose(second)
  assert simplifile.is_file(path.join(destination, "src/gone.gleam"))
    == Ok(True)

  let assert Ok(Nil) = simplifile.delete(path.join(root, "src/gone.gleam"))
  let assert Ok(third) = snapshot.keep(root, destination, [])

  // The artefacts are still there, so the compiler has nothing to redo.
  let assert Ok(carried) = simplifile.read(path.join(built, "artefact.beam"))
  assert carried == "beam"
  // The lost source is gone, and so is the module the earlier run generated.
  assert simplifile.is_file(path.join(destination, "src/gone.gleam"))
    == Ok(False)
  assert simplifile.is_file(path.join(
      destination,
      "src/gleam_mutants_runtime_abc.gleam",
    ))
    == Ok(False)
  // Which is to say: the kept copy is the workspace, and says so.
  assert snapshot.digest(third) == snapshot.digest(first)

  let assert Ok(Nil) = snapshot.dispose(third)
  let assert Ok(Nil) = platform.delete_tree(destination)
  let assert Ok(Nil) = platform.delete_tree(root)
}
