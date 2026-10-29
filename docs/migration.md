<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Migration to the mutation-testing package

The supported product is the `gleam_mutants/api` library and the `gleam_mutants` CLI.
The command families are `run`, `list`, `doctor`, `init`, `report`, and `cache`.
The existing 15 operators, mutant identities, native JSON, Stryker JSON, offline HTML, and four execution runtimes remain part of that contract.

The Smartest test framework, property generators, differential test generation, and VS Code extension have been removed.
There are no compatibility modules for `smartest` or `gleam_mutants/pbt`.
The `suggest`, standalone `explain`, and `apply` commands and `run --suggest` are no longer accepted.
The `tools.gleam_mutants.suggest` table is rejected as an unknown configuration key.
Remove that table and generation-only flags from scripts and configuration.
The removed generation schemas and editor packaging are no longer distributed.

Keep the application's tests under its chosen runner, such as gleeunit.
Use `list --validate --explain` to inspect compiler-valid and rejected mutants.
Use `run --explain`, native JSON, or the offline HTML report to inspect mutation outcomes and improve tests.
The tool no longer writes application test modules.
Use the [library API](library.md) for integrations.

The optional test-impact protocol remains provider-independent.
An absent, invalid, or incomplete provider falls back to the full configured test suite.
No Smartest dependency or test-runner migration is required to run mutation testing.
Historical `.smartest` data is not migrated or deleted automatically.
Archive or remove it according to the application's own data policy.
