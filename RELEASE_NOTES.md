<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 1.0.0 release notes (draft)

`gleam_mutants` 1.0.0 introduces mutation testing for Gleam with byte-exact
source preservation and portable execution across Erlang, Node.js, Deno, and
Bun. It snapshots the project before compiling or testing, filters invalid
mutants with the Gleam compiler, and reports stable IDs usable by caches and CI.

Each completed run now produces `reports/mutation/mutation.json` and a
self-contained offline `mutation.html`. These are deterministic projections for
the Stryker report ecosystem, pinned to report schema and Mutation Testing
Elements 3.9.0, while the native report remains lossless and unchanged in wire
shape. Output storage is atomic, reparse-safe, excluded from snapshot/cache
identity, and configurable only as a safe relative project directory.

This release is not published and is not described as production-ready until
the immutable commit has all hosted evidence, signatures, SBOMs, benchmarks,
and install smokes. Run `mise run package` to verify candidate artifacts.
