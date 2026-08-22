//// The stable command-line entrypoint for `gleam_mutants`.
////
//// The remaining modules are implementation details and are intentionally
//// marked internal in `gleam.toml`.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Runs the `gleam-mutants` command-line interface.
import gleam_mutants/cli

pub fn main() -> Nil {
  cli.main()
}
