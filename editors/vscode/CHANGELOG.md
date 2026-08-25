<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Changelog

## Unreleased

- The pure core: mutation-report parsing, Suggest JSON v1, Apply JSON v1,
  argument building, and the diagnostic model, all unit-tested against real
  CLI output.
- The editor glue: surviving mutants as diagnostics, republished whenever the
  report is written; quick fixes that generate a test for one mutant or
  explain it; commands to mutation-test, suggest for, and explain the active
  file; and three settings. Every flow is unit-tested against a fake editor.
- `npm run smoke`: the real CLI on `fixtures/boundary_project`, read back
  through the built core. `mise run vscode` runs it after the other gates.
