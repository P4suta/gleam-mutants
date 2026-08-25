// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/glob
import gleam_mutants/core/mutant
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile

pub type ManifestEntry {
  ManifestEntry(path: String, digest: String, size: Int)
}

pub opaque type Snapshot {
  Snapshot(root: String, entries: List(ManifestEntry), digest: String)
}

const tool_directory = ".gleam_mutants"

pub fn create(source_root: String) -> Result(Snapshot, String) {
  create_excluding(source_root, [])
}

pub fn create_excluding(
  source_root: String,
  excluded_directories: List(String),
) -> Result(Snapshot, String) {
  create_attempt(source_root, excluded_directories, 1)
}

fn create_attempt(
  source_root: String,
  excluded_directories: List(String),
  retries: Int,
) -> Result(Snapshot, String) {
  let destination =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-" <> platform.random_nonce(),
    )
  use _ <- result.try(
    simplifile.create_directory(destination)
    |> result.map_error(simplifile.describe_error),
  )
  let exclusions = list.map(excluded_directories, mutant.normalize_path)
  case copy_directory(source_root, destination, "", [], exclusions) {
    Ok(entries) -> {
      let sorted =
        list.sort(entries, fn(a, b) { string.compare(a.path, b.path) })
      let copied_digest = manifest_digest(sorted)
      case scan_directory(source_root, "", [], exclusions) {
        Error(error) -> cleanup_failed_snapshot(destination, error)
        Ok(current_entries) -> {
          let current_digest =
            current_entries
            |> list.sort(fn(a, b) { string.compare(a.path, b.path) })
            |> manifest_digest
          case current_digest == copied_digest {
            True -> Ok(Snapshot(destination, sorted, copied_digest))
            False ->
              case platform.delete_tree(destination), retries {
                Ok(Nil), retries if retries > 0 ->
                  create_attempt(source_root, excluded_directories, retries - 1)
                Ok(Nil), _ ->
                  Error("workspace changed while snapshot was being captured")
                Error(cleanup_error), _ ->
                  Error(
                    "workspace changed while snapshot was being captured; cleanup failed: "
                    <> cleanup_error,
                  )
              }
          }
        }
      }
    }
    Error(error) -> cleanup_failed_snapshot(destination, error)
  }
}

fn cleanup_failed_snapshot(
  destination: String,
  error: String,
) -> Result(a, String) {
  case platform.delete_tree(destination) {
    Ok(Nil) -> Error(error)
    Error(cleanup_error) ->
      Error(error <> "; snapshot cleanup failed: " <> cleanup_error)
  }
}

fn scan_directory(
  source_root: String,
  relative: String,
  entries: List(ManifestEntry),
  excluded_directories: List(String),
) -> Result(List(ManifestEntry), String) {
  let directory = path.join(source_root, relative)
  use names <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(simplifile.describe_error),
  )
  use entries, name <- list.try_fold(
    names |> list.sort(string.compare),
    entries,
  )
  let child_relative = case relative {
    "" -> name
    _ -> path.join(relative, name)
  }
  case excluded(child_relative, excluded_directories) {
    True -> Ok(entries)
    False -> {
      let source = path.join(source_root, child_relative)
      use info <- result.try(
        simplifile.link_info(source)
        |> result.map_error(simplifile.describe_error),
      )
      case simplifile.file_info_type(info), platform.is_reparse_point(source) {
        simplifile.Symlink, _ | _, True ->
          Error("refusing symlink or junction in workspace: " <> child_relative)
        simplifile.Other, _ -> Error(special_file_refusal(child_relative))
        simplifile.Directory, _ ->
          scan_directory(
            source_root,
            child_relative,
            entries,
            excluded_directories,
          )
        simplifile.File, _ -> {
          use content <- result.try(
            simplifile.read_bits(source)
            |> result.map_error(simplifile.describe_error),
          )
          Ok([
            ManifestEntry(
              child_relative,
              bytes.sha256_bits(content),
              bit_array.byte_size(content),
            ),
            ..entries
          ])
        }
      }
    }
  }
}

fn copy_directory(
  source_root: String,
  destination_root: String,
  relative: String,
  entries: List(ManifestEntry),
  excluded_directories: List(String),
) -> Result(List(ManifestEntry), String) {
  let source_directory = path.join(source_root, relative)
  use names <- result.try(
    simplifile.read_directory(source_directory)
    |> result.map_error(simplifile.describe_error),
  )
  use entries, name <- list.try_fold(
    names |> list.sort(string.compare),
    entries,
  )
  let child_relative = case relative {
    "" -> name
    _ -> path.join(relative, name)
  }
  case excluded(child_relative, excluded_directories) {
    True -> Ok(entries)
    False ->
      copy_entry(
        source_root,
        destination_root,
        child_relative,
        entries,
        excluded_directories,
      )
  }
}

fn copy_entry(
  source_root: String,
  destination_root: String,
  relative: String,
  entries: List(ManifestEntry),
  excluded_directories: List(String),
) -> Result(List(ManifestEntry), String) {
  let source = path.join(source_root, relative)
  let destination = path.join(destination_root, relative)
  use info <- result.try(
    simplifile.link_info(source)
    |> result.map_error(simplifile.describe_error),
  )
  case simplifile.file_info_type(info), platform.is_reparse_point(source) {
    simplifile.Symlink, _ | _, True ->
      Error("refusing symlink or junction in workspace: " <> relative)
    simplifile.Other, _ -> Error(special_file_refusal(relative))
    simplifile.Directory, _ -> {
      use _ <- result.try(
        simplifile.create_directory_all(destination)
        |> result.map_error(simplifile.describe_error),
      )
      use entries <- result.try(copy_directory(
        source_root,
        destination_root,
        relative,
        entries,
        excluded_directories,
      ))
      use _ <- result.try(
        simplifile.set_permissions_octal(
          destination,
          simplifile.file_info_permissions_octal(info),
        )
        |> result.map_error(simplifile.describe_error),
      )
      Ok(entries)
    }
    simplifile.File, _ -> {
      use content <- result.try(
        simplifile.read_bits(source)
        |> result.map_error(simplifile.describe_error),
      )
      use _ <- result.try(
        simplifile.write_bits(content, to: destination)
        |> result.map_error(simplifile.describe_error),
      )
      use _ <- result.try(
        simplifile.set_permissions_octal(
          destination,
          simplifile.file_info_permissions_octal(info),
        )
        |> result.map_error(simplifile.describe_error),
      )
      Ok([
        ManifestEntry(
          relative,
          bytes.sha256_bits(content),
          bit_array.byte_size(content),
        ),
        ..entries
      ])
    }
  }
}

/// Why a character device, socket or named pipe stops a snapshot, and the way
/// past it.
///
/// A snapshot is a byte-for-byte copy of the workspace, and there is no honest
/// copy of a special file: reading one can block forever and writing one can
/// have effects nobody asked a mutation run for. So the refusal stands. What
/// it owes the reader is the path — a bare `refusing special file in
/// workspace` over a dotfile the build never reads is a dead end — and the one
/// thing that actually resolves it, which is getting the file out of the tree
/// the run was pointed at. `--root` is worth naming because the file is often
/// not the project's at all: a shell profile a sandbox bind-mounts over a home
/// directory that happens to be the working directory.
fn special_file_refusal(relative: String) -> String {
  "GMU7004: refusing special file in workspace: "
  <> relative
  <> " — a snapshot copies regular files only, so move it out of the "
  <> "workspace or remove it, or point --root at a directory that holds only "
  <> "the project"
}

fn excluded(relative: String, excluded_directories: List(String)) -> Bool {
  let first = relative |> string.split("/") |> list.first |> result.unwrap("")
  list.contains(
    [".git", "build", tool_directory, ".mise", "node_modules"],
    first,
  )
  || list.any(excluded_directories, fn(directory) {
    relative == directory || string.starts_with(relative, directory <> "/")
  })
}

fn manifest_digest(entries: List(ManifestEntry)) -> String {
  entries
  |> list.map(fn(entry) {
    int.to_string(string.byte_size(entry.path))
    <> ":"
    <> entry.path
    <> int.to_string(string.byte_size(entry.digest))
    <> ":"
    <> entry.digest
    <> int.to_string(entry.size)
    <> ";"
  })
  |> string.concat
  |> bytes.sha256
}

pub fn root(snapshot: Snapshot) -> String {
  snapshot.root
}

pub fn entries(snapshot: Snapshot) -> List(ManifestEntry) {
  snapshot.entries
}

pub fn digest(snapshot: Snapshot) -> String {
  snapshot.digest
}

pub fn source_files(
  snapshot: Snapshot,
  includes: List(String),
  excludes: List(String),
) -> List(String) {
  snapshot.entries
  |> list.map(fn(entry) { entry.path })
  |> list.filter(fn(relative) {
    string.ends_with(relative, ".gleam")
    && glob.included(relative, includes, excludes)
  })
}

pub fn dispose(snapshot: Snapshot) -> Result(Nil, String) {
  platform.delete_tree(snapshot.root)
}
