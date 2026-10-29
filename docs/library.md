<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Library API

Add the checkout as a development dependency:

```toml
[dev_dependencies]
gleam_mutants = { path = "../gleam-mutants" }
```

Use the public API and its shared domain types:

```gleam
import gleam/option.{Some}
import gleam_mutants/api
import gleam_mutants/types

pub fn inspect_project(
  root: String,
) -> Result(types.Catalog, types.MutationError) {
  let options = types.Options(..api.default_options(), jobs: Some(2))
  api.list_mutants(root, options)
}
```

`list_mutants` discovers unvalidated candidates without compiling or running tests.
`validate_mutants` compiler-checks the catalogue and returns both admitted and rejected candidates without invoking the test command.
Its catalogue is `CompilerValidated`, including when every candidate is rejected.
`run` executes the pristine baseline, compiler validation, instrumented baseline, and selected mutant tests.
The same canonical mutant, outcome, score, and report types serve the API and CLI.
`start_byte` and `end_byte` expose validated, zero-based, end-exclusive source positions.
`operator_name` returns the stable configuration name.
`report_json` serializes the CLI's native report format.

Absent option overrides inherit `gleam.toml`.
The defaults are available through `default_options()`.
Jobs must be 1–32, explicit timeouts 100–86,400,000 milliseconds, and a test command must contain a nonempty executable.
An empty root or invalid override returns `InvalidOptions` before workspace access.
A workspace or tool failure returns `Failure` with the operation, an optional diagnostic code, and the captured message.
A child exit of 130 or 143 returns `Interrupted` with the exit code and message.
The library captures child output and returns errors without printing diagnostics, emitting GitHub annotations, or exiting the host.
Sending a signal to the host itself remains subject to that runtime's signal handling.

A completed mutation run returns `Ok(RunReport)` even when the quality policy fails.
Inspect `report.policy.failure` and `report.score.errors` to choose the embedding application's behavior.
Timeouts remain distinct from killed mutants and count as detected under the existing scoring contract.
Compiler rejections and test errors remain explicit.

Reports stay in memory by default.
Set `write_reports: True` to use the workspace's configured project reports and native history.
Existing reports are preserved when writes are disabled.
Snapshots, workspace locks, optional outcome caching, and configured tests still perform filesystem and process operations.
Test processes have the caller's permissions.
Deno embedders must grant the environment, filesystem, and subprocess permissions their operation requires.
Compiler validation and execution also capture reachable local dependencies, including the target's development dependencies.
Dependency contents participate in cache identity, and workers use relative paths within their captured copies.
Unvalidated discovery does not resolve dependencies.
The snapshot protects original source files from the mutation engine; it does not sandbox arbitrary test side effects.
See the [configuration](configuration.md) and [verification contracts](verification.md).
