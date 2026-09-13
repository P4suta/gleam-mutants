// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// A lock file for the throwaway projects tests build for themselves.
//
// A Gleam project with dependencies and no `manifest.toml` resolves its
// versions against the Hex API every time it is built. A test that writes a
// project, builds it and deletes it therefore asks Hex the same question on
// every run, and Hex answers per address: a hosted runner shares one with
// everyone else on that host, so the answer is sometimes a refusal that has
// nothing to do with this repository.
//
// The versions are read out of this repository's own `manifest.toml` rather
// than written down here, so a dependency bump cannot leave a stale checksum
// behind for a test to fail on. A repository whose manifest cannot be read —
// a test run from somewhere else — simply gets no lock file and the old
// behaviour back.

import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/core/path
import simplifile

/// Writes a `manifest.toml` beside `root`'s `gleam.toml` locking `packages`.
///
/// `requirements` are the dependency lines of that `gleam.toml`, as pairs of
/// name and version range, and they must match it exactly: Gleam re-resolves
/// a manifest whose requirements disagree with the project that owns it.
pub fn lock(root: String, requirements: List(#(String, String))) -> Nil {
  case
    list.try_map(requirements, fn(requirement) { locked_package(requirement.0) })
  {
    Error(Nil) -> Nil
    Ok(packages) -> {
      let manifest =
        "packages = [\n"
        <> string.join(packages, "\n")
        <> "\n]\n\n[requirements]\n"
        <> string.join(
          list.map(requirements, fn(requirement) {
            requirement.0 <> " = { version = \"" <> requirement.1 <> "\" }"
          }),
          "\n",
        )
        <> "\n"
      let _ = simplifile.write(path.join(root, "manifest.toml"), manifest)
      Nil
    }
  }
}

/// The line this repository's own manifest locks one package with.
fn locked_package(name: String) -> Result(String, Nil) {
  use source <- result.try(
    simplifile.read("manifest.toml") |> result.replace_error(Nil),
  )
  source
  |> string.split("\n")
  |> list.filter(string.contains(_, "{ name = \"" <> name <> "\","))
  |> list.first
}
