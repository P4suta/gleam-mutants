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
- [ ] `mise run package` in a clean checkout
- [ ] Inspect Hex contents, escript, npm tarball, checksums, and CycloneDX SBOM
- [ ] Confirm all three SBOM scans contain no known High/Critical vulnerability
- [ ] Confirm the SBOM contains Mutation Testing Elements 3.9.0 and an
      application dependency edge
- [ ] Confirm official Draft-07 schema validation, four-runtime report byte
      parity, offline Chromium/Firefox/WebKit smokes, and vendored
      integrity/hash checks
- [ ] Confirm `VERSION`, `gleam.toml`, CLI output, and `CHANGELOG.md` agree
- [ ] Confirm release-please has generated the Release PR and all required CI
      checks passed before merging it
- [ ] Verify every Sigstore bundle and GitHub artifact attestation against the
      immutable workflow identity and commit
- [ ] Confirm the immutable candidate commit is on protected `main`
- [ ] Obtain explicit approval before tagging, creating a GitHub Release, or
      publishing to a registry

Version 0.1.0 preview remains unpublished. Do not call it
production-ready until an
immutable commit has passing GitHub-hosted evidence on all three operating
systems plus verified signatures, attestations, SBOMs, benchmarks, and install
smokes. Tagging, publishing, and creating a release require separate approval.
