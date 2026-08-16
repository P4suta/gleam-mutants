<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Release checklist

- [ ] `mise run check`
- [ ] `mise run test-matrix`
- [ ] `mise run dogfood`
- [ ] `mise run package` in a clean checkout
- [ ] Inspect Hex contents, escript, npm tarball, checksums, and CycloneDX SBOM
- [ ] Confirm version and draft release notes
- [ ] Confirm no publish token or registry upload step exists
- [ ] Obtain explicit approval before creating a remote repository or publishing

Version 0.1.0 remains unpublished until the last step is separately authorized.
