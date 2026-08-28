<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Release checklist

- [ ] `mise run check`
- [ ] `mise run test-integration`
- [ ] `mise run test-matrix`
- [ ] `mise run test-property`
- [ ] `mise run test-faults`
- [ ] `mise run benchmark`
- [ ] `mise run dogfood`
- [ ] `mise run test-ecosystem` completes inside its 13-minute deadline
- [ ] Inspect `test-results/ecosystem-summary.json`; confirm all five fixed
      commits, golden counts/outcomes, zero errors/timeouts, and source hashes
- [ ] `mise run package` in a clean checkout
- [ ] Inspect Hex contents, escript, npm tarball, checksums, and CycloneDX SBOM
- [ ] Confirm all three SBOM scans contain no known High/Critical vulnerability
- [ ] Confirm the SBOM contains Mutation Testing Elements 3.9.0 and an
      application dependency edge
- [ ] Confirm the official Hex API still returns 404 for `smartest`
- [ ] Complete the product-owner name/trademark review and explicitly select
      `approve_smartest_name` when dispatching candidate and publish workflows
- [ ] Confirm official Draft-07 schema validation, four-runtime report byte
      parity, offline Chromium/Firefox/WebKit smokes, and vendored
      integrity/hash checks
- [ ] Confirm `VERSION`, `gleam.toml`, CLI output, and `CHANGELOG.md` agree
- [ ] Confirm release-please has generated the Release PR and all required CI
      checks passed before merging it
- [ ] Verify every Sigstore bundle and GitHub artifact attestation against the
      immutable workflow identity and commit
- [ ] Confirm the immutable candidate commit is on protected `main`
- [ ] Confirm the Sunday 03:41 UTC/manual Linux ecosystem workflow completed
      inside its 15-minute cap and retained the normalized summary artifact
- [ ] Obtain explicit approval before tagging, creating a GitHub Release, or
      publishing to a registry

Version 0.1.0 remains an unreleased development snapshot. Do not call it
production-ready until an immutable commit has passing GitHub-hosted evidence
on all three operating systems plus verified signatures, attestations, SBOMs,
benchmarks, and install smokes. Tagging, publishing, and creating a release
require separate approval.
