// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/core/catalog
import gleam_mutants/core/operator
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/snapshot
import simplifile

pub fn main() {
  let assert [workspace] = platform.arguments()
  let snapshot_started = platform.monotonic_milliseconds()
  let assert Ok(copy) = snapshot.create(workspace)
  let snapshot_ms = platform.monotonic_milliseconds() - snapshot_started
  let discovery_started = platform.monotonic_milliseconds()
  let files = snapshot.source_files(copy, ["src/**/*.gleam"], [])
  let assert Ok(counts) =
    list.try_map(files, fn(relative) {
      use source <- result.try(
        simplifile.read(path.join(snapshot.root(copy), relative))
        |> result.map_error(simplifile.describe_error),
      )
      use mutants <- result.try(
        catalog.discover(relative, source, operator.all())
        |> result.map_error(string.inspect),
      )
      Ok(list.length(mutants.mutants))
    })
  let discovery_ms = platform.monotonic_milliseconds() - discovery_started
  let mutants = list.fold(counts, 0, fn(total, count) { total + count })
  assert list.length(files) == 1000
  assert mutants >= 10_000
  assert snapshot_ms <= 60_000
  assert discovery_ms <= 60_000
  let assert Ok(Nil) = snapshot.dispose(copy)
  io.println(
    json.object([
      #("files", json.int(list.length(files))),
      #("mutants", json.int(mutants)),
      #("snapshot_ms", json.int(snapshot_ms)),
      #("discovery_ms", json.int(discovery_ms)),
    ])
    |> json.to_string,
  )
}
