<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Contributing

Install pinned tools and dependencies with `mise run bootstrap`.
Run `mise run check` and `mise run test-matrix` before submitting changes.
Mutation-engine changes also require `mise run test-integration`, `mise run test-property`, `mise run test-faults`, and `mise run dogfood`.
Run `mise run prove` for changes to the input limits or source derivation.
Release-core changes also require `mise run prove-release` and its rejecting controls.
`mise run check-release` replays the preserved parser fuzz corpus without starting an unbounded campaign.
The full proof and release inventory is described in [verification contracts](docs/verification.md).
The manual [candidate workflow](docs/releasing.md) owns the complete release campaign; ordinary PR CI stays on one Linux gate.

Changes to discovery, compiler validation, runtime execution, or report counts require `mise run test-ecosystem`.
Allow up to 13 minutes; a deadline stop supplies no passing evidence.
To update a corpus, review the upstream diff and replace its full commit SHA in `scripts/ecosystem-smoke.mjs`.
Run the task twice and update expected counts and the [usage table](docs/usage.md) only when both reports and source hashes agree.
Never float a branch or tag or weaken an expected count to hide a failure.
Expected survivors are compatibility outcomes, so this task does not use a minimum-score gate.

Keep pure domain logic under `src/gleam_mutants/core`.
Operating-system operations belong behind capabilities and the platform FFI.
New operators require byte-preservation tests, compiler-validation fixtures, and an operator-version decision.
The supported product boundary is defined by the [ADR](docs/adr/mutation-testing-package-boundary.md).
Add SPDX headers to new files and run the repository's REUSE check.

README content is generated from `repository.toml`.
The documentation index is [docs/README.md](docs/README.md).
