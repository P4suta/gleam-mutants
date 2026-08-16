<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Security

Do not include secrets in reports or fixtures. Until a public repository exists,
report vulnerabilities privately to the project maintainer. The tool does not
perform runtime network communication. Treat custom test commands as trusted
project code: they execute inside a disposable filesystem snapshot but are not
an operating-system sandbox.
