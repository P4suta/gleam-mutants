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
