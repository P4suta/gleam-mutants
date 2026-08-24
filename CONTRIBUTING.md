<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Contributing

Install the pinned tools and dependencies with `mise run bootstrap`. Before a
change is submitted, run `mise run check` and `mise run test-matrix`. Mutation
engine changes should also pass `mise run dogfood`.

Changes to discovery, compiler validation, runtime execution, or report counts
must run the networked `mise run test-ecosystem` golden smoke (allow up to 13
minutes). To update a corpus, review the upstream diff, replace its full commit
SHA in `scripts/ecosystem-smoke.mjs`, run the task twice, and update expected
counts plus the README table only when both reports and source hashes agree.
Never float a branch/tag or weaken a count to make a transient failure pass.
Survivors are intentional golden outcomes, so this task does not use a minimum
score gate.

Keep the pure domain model under `src/gleam_mutants/core`; operating-system
operations belong behind capability records and the small platform FFI. New
operators need byte-preservation tests, compiler-validation fixtures, and an
operator version decision. Add SPDX headers to new files and run `reuse lint`.
