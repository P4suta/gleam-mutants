// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile
import smartest/internal/watch_shell

pub fn foreground_watch_spec_preserves_test_arguments_and_deadline_test() {
  let spec =
    watch_shell.spec("/workspace", [
      "--target",
      "javascript",
      "--",
      "-m",
      "app_test",
    ])

  assert spec.root == "/workspace"
  assert spec.command == "gleam"
  assert spec.arguments
    == ["test", "--target", "javascript", "--", "-m", "app_test"]
  assert spec.poll_ms <= 250
  assert spec.cancellation_grace_ms == 250
}

pub fn watch_fingerprint_tracks_inputs_by_content_not_mtime_test() {
  let root = temporary_root("fingerprint")
  write(path.join(root, "src/app.gleam"), "pub fn value() { 1 }\n")
  write(path.join(root, "test/app_test.gleam"), "pub fn value_test() { Nil }\n")
  write(path.join(root, "gleam.toml"), "name = \"demo\"\n")
  write(path.join(root, "manifest.toml"), "packages = []\n")
  write(path.join(root, "build/dev/cache"), "generated-a")

  let assert Ok(first) = watch_shell.workspace_fingerprint(root)

  // Rewriting tracked files with identical bytes must not invent an edit.
  write(path.join(root, "src/app.gleam"), "pub fn value() { 1 }\n")
  let assert Ok(same_content) = watch_shell.workspace_fingerprint(root)
  assert same_content == first

  // Compiler output is not a source revision and must not self-trigger watch.
  write(path.join(root, "build/dev/cache"), "generated-b")
  let assert Ok(build_changed) = watch_shell.workspace_fingerprint(root)
  assert build_changed == first

  write(path.join(root, "src/app.gleam"), "pub fn value() { 2 }\n")
  let assert Ok(source_changed) = watch_shell.workspace_fingerprint(root)
  assert source_changed != first

  cleanup(root)
}

pub fn watch_fingerprint_fails_visibly_when_the_workspace_cannot_be_read_test() {
  let missing = temporary_root("missing")
  let assert Error(reason) = watch_shell.workspace_fingerprint(missing)
  assert reason != ""
}

fn write(file: String, contents: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(path.parent(file))
  let assert Ok(Nil) = simplifile.write(file, contents)
  Nil
}

fn temporary_root(label: String) -> String {
  path.join(
    platform.temporary_directory(),
    "smartest-watch-shell-test-" <> label <> "-" <> platform.random_nonce(),
  )
}

fn cleanup(root: String) -> Nil {
  let _ = platform.delete_tree(root)
  Nil
}
