<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Release checklist

- [ ] `mise run check`
- [ ] `mise run test-integration`
- [ ] `mise run test-matrix`
- [ ] `mise run test-minimum`
- [ ] `mise run test-property`
- [ ] `mise run test-faults`
- [ ] `mise run prove`
- [ ] `mise run prove-release`
- [ ] `mise run audit-tools`
- [ ] `mise run benchmark`
- [ ] `mise run dogfood`
- [ ] `mise run test-ecosystem` completes within its operational deadline
- [ ] Inspect all five fixed corpus commits, outcomes, and source hashes
- [ ] `mise run package` in a clean checkout
- [ ] Inspect installed Hex API, escript, npm, checksums, and CycloneDX SBOMs
- [ ] Confirm all three SBOM scans have no known High/Critical vulnerability
- [ ] Confirm the embedded MTE component and application dependency edge
- [ ] Confirm schemas, four-runtime report parity, offline browsers, and integrity
- [ ] Confirm `VERSION`, `gleam.toml`, CLI output, and `CHANGELOG.md` agree
- [ ] Complete an unsigned hosted rehearsal on Linux, macOS, and Windows
- [ ] Inspect source, run, producer attempts, targets, receipts, and candidate digests
- [ ] Verify protected environments, immutable releases, and version-tag protection

The steps above prepare a release without publishing it.
Follow the [release guide](releasing.md) for the later authorized publication:

- [ ] Confirm the release proposal and required checks passed before merging it
- [ ] Verify signatures and attestations against the immutable workflow identity
- [ ] Confirm the immutable candidate commit is on protected `main`
- [ ] Obtain explicit approval before tagging or publication
- [ ] Validate registry ownership and the selected authentication path
- [ ] Review the read-only publication plan before production approvals
- [ ] Verify downloaded release and registry bytes before finalizing the draft

Version 0.1.0 remains an unreleased development snapshot.
Production-readiness requires passing immutable GitHub-hosted evidence on all three operating systems plus verified signatures, attestations, SBOMs, benchmarks, and installation smokes.
The [verification contracts](verification.md) define the required proof and native checks.
A failed, skipped, or inconclusive obligation remains open.
Tagging, publication, and release creation require separate approval.
