<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Security

## Supported versions

The 1.0.0 release candidate is not a production release. Security fixes are
made on `main` until the first stable release. After GA, the latest 1.0 patch
line will receive security fixes; older prerelease builds are unsupported.

## Reporting a vulnerability

Do not open a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/P4suta/gleam-mutants/security/advisories/new)
to contact the maintainers. Include affected versions, impact, and a minimal
reproduction without real secrets. You should receive an acknowledgement
within seven days.

## Operational considerations

Reports contain original mutated source and may contain compiler or test output;
do not include secrets in source, output, or fixtures. The tool does not perform
runtime network communication. Treat custom test commands as trusted project
code: they execute inside a disposable filesystem snapshot but are not an
operating-system sandbox.
