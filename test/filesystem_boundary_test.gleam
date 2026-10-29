// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/string
import gleam_mutants/cache
import gleam_mutants/core/filesystem_entry
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/snapshot
import simplifile

pub fn main() {
  native_names_cannot_redirect_snapshot_reads_or_writes_test()
  snapshot_names_preserve_whitespace_and_source_directories_test()
  all_snapshot_roots_are_owner_private_test()
  collection_never_removes_a_locked_snapshot_test()
  filesystem_join_preserves_native_spelling_test()
  component_admission_matches_an_independent_ascii_reference_test()
  duplicate_and_prune_refuse_ambiguous_native_entries_test()
  unsafe_retained_roots_are_refused_and_existing_directories_are_preserved_test()
}

fn fixture() -> String {
  let root =
    platform.temporary_directory()
    <> "/gleam-mutants-filesystem-"
    <> platform.random_nonce()
  let assert Ok(Nil) = simplifile.create_directory(root)
  root
}

pub fn native_names_cannot_redirect_snapshot_reads_or_writes_test() {
  case platform.os_name() {
    "windows" -> Nil
    _ -> {
      let root = fixture()
      let source = root <> "/source"
      let destination = root <> "/output/kept"
      let assert Ok(Nil) = simplifile.create_directory(source)
      let assert Ok(Nil) = simplifile.create_directory(root <> "/output")
      let assert Ok(Nil) = simplifile.write(root <> "/sentinel.txt", "private")
      let assert Ok(Nil) =
        simplifile.write(root <> "/output/sentinel.txt", "preserved")
      let assert Ok(Nil) =
        simplifile.write(source <> "/..\\sentinel.txt", "filename")
      let attempted = snapshot.keep(source, destination, [])
      let outside = simplifile.read(root <> "/output/sentinel.txt")
      let assert Ok(Nil) = platform.delete_tree(root)
      assert outside == Ok("preserved")
      let assert Error(message) = attempted
      assert string.contains(message, "filename")
    }
  }
}

pub fn snapshot_names_preserve_whitespace_and_source_directories_test() {
  let root = fixture()
  let source = root <> "/source"
  let destination = root <> "/kept"
  let assert Ok(Nil) = simplifile.create_directory_all(source <> "/src/build")
  let assert Ok(Nil) = simplifile.write(source <> "/ name .txt", "spaces")
  let assert Ok(Nil) =
    simplifile.write(source <> "/src/build/value.gleam", "pub const x = 1\n")
  let attempted = snapshot.keep(source, destination, [])
  let names = case attempted {
    Ok(captured) ->
      list.map(snapshot.entries(captured), fn(entry) { entry.path })
    Error(_) -> []
  }
  let copied = simplifile.read(destination <> "/ name .txt")
  let assert Ok(Nil) = platform.delete_tree(root)
  assert copied == Ok("spaces")
  assert list.contains(names, " name .txt")
  assert list.contains(names, "src/build/value.gleam")
}

pub fn all_snapshot_roots_are_owner_private_test() {
  case platform.os_name() {
    "windows" -> Nil
    _ -> {
      let root = fixture()
      let source = root <> "/source"
      let assert Ok(Nil) = simplifile.create_directory(source)
      let assert Ok(Nil) = simplifile.set_permissions_octal(source, 0o700)
      let assert Ok(Nil) = simplifile.write(source <> "/private.txt", "private")
      let assert Ok(first) = snapshot.create(source)
      let assert Ok(worker) = snapshot.duplicate(first)
      let assert Ok(kept) = snapshot.keep(source, root <> "/kept", [])
      let modes =
        list.map([first, worker, kept], fn(copy) {
          let assert Ok(info) = simplifile.link_info(snapshot.root(copy))
          simplifile.file_info_permissions_octal(info)
        })
      let assert Ok(Nil) = snapshot.dispose(worker)
      let assert Ok(Nil) = snapshot.dispose(first)
      let assert Ok(Nil) = platform.delete_tree(root)
      assert modes == [0o700, 0o700, 0o700]
    }
  }
}

pub fn collection_never_removes_a_locked_snapshot_test() {
  let root = fixture()
  let directory = root <> "/workspace"
  let assert Ok(Nil) = simplifile.create_directory_all(directory <> "/snapshot")
  let lock_path = directory <> "/run.lock"
  let acquired =
    platform.acquire_lock(
      lock_path,
      "collection-regression",
      platform.now_milliseconds(),
      0,
    )
  assert string.starts_with(acquired, "ok:")
  let assert Ok(Nil) = cache.collect_snapshots(root, 0)
  let while_locked = simplifile.is_directory(directory <> "/snapshot")
  assert platform.release_lock(lock_path, string.drop_start(acquired, 3)) == ""
  let assert Ok(Nil) = cache.collect_snapshots(root, 0)
  let after_release = simplifile.is_directory(directory <> "/snapshot")
  let assert Ok(Nil) = platform.delete_tree(root)
  assert while_locked == Ok(True)
  assert after_release == Ok(False)
}

pub fn filesystem_join_preserves_native_spelling_test() {
  assert path.join("/tmp/root ", " file ") == "/tmp/root / file "
  assert path.join("/tmp/native\\root", "file") == "/tmp/native\\root/file"
  assert path.parent(path.from_native("C:\\repo\\src", True)) == "C:/repo"
  assert path.from_native("/tmp/native\\root", False) == "/tmp/native\\root"
  case platform.os_name() {
    "windows" -> Nil
    _ -> {
      assert cache.workspace_id("/tmp/native\\root")
        != cache.workspace_id("/tmp/native/root")
    }
  }
}

pub fn component_admission_matches_an_independent_ascii_reference_test() {
  let characters =
    int.range(0, 128, [], fn(characters, value) {
      let assert Ok(codepoint) = string.utf_codepoint(value)
      [string.from_utf_codepoints([codepoint]), ..characters]
    })
  let values =
    list.append(
      ["", "日本語", " name ", "...", "x/y", "x\\y"],
      list.append(
        characters,
        list.flat_map(characters, fn(left) {
          list.map(characters, fn(right) { left <> right })
        }),
      ),
    )
  list.each(values, fn(value) {
    let rejected_character =
      value
      |> string.to_utf_codepoints
      |> list.any(fn(codepoint) {
        list.contains([0, 47, 92], string.utf_codepoint_to_int(codepoint))
      })
    let expected = !list.contains(["", ".", ".."], value) && !rejected_character
    assert filesystem_entry.valid(value) == expected
  })
}

pub fn duplicate_and_prune_refuse_ambiguous_native_entries_test() {
  case platform.os_name() {
    "windows" -> Nil
    _ -> {
      let root = fixture()
      let source = root <> "/source"
      let destination = root <> "/kept"
      let assert Ok(Nil) = simplifile.create_directory(source)
      let assert Ok(Nil) = simplifile.write(source <> "/file.txt", "source")
      let assert Ok(copy) = snapshot.keep(source, destination, [])
      let assert Ok(Nil) = simplifile.create_directory(destination <> "/build")
      let assert Ok(Nil) =
        simplifile.write(destination <> "/build/..\\outside", "ambiguous")
      let duplicate = snapshot.duplicate(copy)
      let pruned = snapshot.keep(source, destination, [])
      let assert Ok(Nil) = platform.delete_tree(root)
      let assert Error(duplicate_error) = duplicate
      let assert Error(prune_error) = pruned
      assert string.contains(duplicate_error, "filename")
      assert string.contains(prune_error, "filename")
    }
  }
}

pub fn unsafe_retained_roots_are_refused_and_existing_directories_are_preserved_test() {
  case platform.os_name() {
    "windows" -> Nil
    _ -> {
      let root = fixture()
      let source = root <> "/source"
      let destination = root <> "/kept"
      let assert Ok(Nil) = simplifile.create_directory(source)
      let assert Ok(Nil) = simplifile.create_directory(destination)
      let assert Ok(Nil) = simplifile.set_permissions_octal(destination, 0o755)
      let assert Ok(Nil) =
        simplifile.write(destination <> "/marker", "preserved")
      let kept = snapshot.keep(source, destination, [])
      let exclusive = platform.create_private_directory(destination)
      let marker = simplifile.read(destination <> "/marker")
      let assert Ok(Nil) = platform.delete_tree(root)
      let assert Error(_) = kept
      let assert Error(_) = exclusive
      assert marker == Ok("preserved")
    }
  }
}
