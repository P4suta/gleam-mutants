// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam/json
import gleam/list
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/operator
import gleam_mutants/engine
import gleam_mutants/platform
import gleam_mutants/snapshot

pub fn main() {
  let assert [workspace] = platform.arguments()
  let snapshot_started = platform.monotonic_milliseconds()
  let assert Ok(copy) = snapshot.create(workspace)
  let snapshot_ms = platform.monotonic_milliseconds() - snapshot_started
  let discovery_started = platform.monotonic_milliseconds()
  let files = snapshot.source_files(copy, ["src/**/*.gleam"], [])
  let assert Ok(catalogs) =
    engine.discover_catalogs(snapshot.root(copy), files, operator.all())
  let discovery_ms = platform.monotonic_milliseconds() - discovery_started
  let ids =
    catalogs
    |> list.flat_map(fn(catalog) {
      list.map(catalog.mutants, fn(mutant) { mutant.id })
    })
  let mutants = list.length(ids)
  let order_digest =
    ids |> list.map(fn(id) { "64:" <> id }) |> string.concat |> bytes.sha256
  assert list.length(files) == 1000
  assert mutants == 20_000
  assert order_digest
    == "343CD84AD684297CCB740F7ED7398AE4AF924D110CF09A73CFA6A0C67CBAF42C"
  assert snapshot_ms <= 60_000
  assert discovery_ms <= 60_000
  let assert Ok(Nil) = snapshot.dispose(copy)
  io.println(
    json.object([
      #("files", json.int(list.length(files))),
      #("mutants", json.int(mutants)),
      #("order_digest", json.string(order_digest)),
      #("snapshot_ms", json.int(snapshot_ms)),
      #("discovery_ms", json.int(discovery_ms)),
    ])
    |> json.to_string,
  )
}
