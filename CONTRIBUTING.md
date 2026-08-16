<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Contributing

Install the pinned tools and dependencies with `mise run bootstrap`. Before a
change is submitted, run `mise run check` and `mise run test-matrix`. Mutation
engine changes should also pass `mise run dogfood`.

Keep the pure domain model under `src/gleam_mutants/core`; operating-system
operations belong behind capability records and the small platform FFI. New
operators need byte-preservation tests, compiler-validation fixtures, and an
operator version decision. Add SPDX headers to new files and run `reuse lint`.
