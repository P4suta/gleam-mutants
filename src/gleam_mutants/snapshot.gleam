// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/glob
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
  let destination =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-"
        <> int.to_string(platform.process_id())
        <> "-"
        <> int.to_string(platform.now_milliseconds()),
    )
  use _ <- result.try(
    simplifile.create_directory_all(destination)
    |> result.map_error(simplifile.describe_error),
  )
  case copy_directory(source_root, destination, "", []) {
    Ok(entries) -> {
      let sorted =
        list.sort(entries, fn(a, b) { string.compare(a.path, b.path) })
      Ok(Snapshot(destination, sorted, manifest_digest(sorted)))
    }
    Error(error) -> {
      let _ = simplifile.delete(destination)
      Error(error)
    }
  }
}

fn copy_directory(
  source_root: String,
  destination_root: String,
  relative: String,
  entries: List(ManifestEntry),
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
  case excluded(child_relative) {
    True -> Ok(entries)
    False -> copy_entry(source_root, destination_root, child_relative, entries)
  }
}

fn copy_entry(
  source_root: String,
  destination_root: String,
  relative: String,
  entries: List(ManifestEntry),
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
    simplifile.Other, _ ->
      Error("refusing special file in workspace: " <> relative)
    simplifile.Directory, _ -> {
      use _ <- result.try(
        simplifile.create_directory_all(destination)
        |> result.map_error(simplifile.describe_error),
      )
      copy_directory(source_root, destination_root, relative, entries)
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
      let _ =
        simplifile.set_permissions_octal(
          destination,
          simplifile.file_info_permissions_octal(info),
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

fn excluded(relative: String) -> Bool {
  let first = relative |> string.split("/") |> list.first |> result.unwrap("")
  list.contains(
    [".git", "build", tool_directory, ".mise", "node_modules"],
    first,
  )
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
  simplifile.delete(snapshot.root)
  |> result.map_error(simplifile.describe_error)
}
