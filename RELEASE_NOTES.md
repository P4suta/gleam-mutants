<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 0.1.0 release notes (draft)

`gleam_mutants` 0.1.0 introduces mutation testing for Gleam with byte-exact
source preservation and portable execution across Erlang, Node.js, Deno, and
Bun. It snapshots the project before compiling or testing, filters invalid
mutants with the Gleam compiler, and reports stable IDs usable by caches and CI.

This release is not published. Run `mise run package` to reproduce and verify
the candidate artifacts locally.
