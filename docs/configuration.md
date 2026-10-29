<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Configuration

Configuration belongs in `gleam.toml` and is decoded strictly.
Unknown keys and invalid values produce positioned errors.

```toml
[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.mutation]
include = ["src/**/*.gleam"]
exclude = ["test/**", "dev/**", "build/**"]
operators = ["boolean-literal", "integer-arithmetic"]

[tools.gleam_mutants.test]
target = "auto"  # auto, erlang, javascript
runtime = "auto"  # auto, erlang, node, deno, bun
timeout_ms = 15000
baseline_runs = 1
command = ["gleam", "test"]

[tools.gleam_mutants.execution]
jobs = 4
test_selection = "auto"  # auto, full

[tools.gleam_mutants.cache]
mode = "auto"  # auto, off, read-only, write-only, read-write
keep_snapshots = 4
# key = "custom-suite-v1" files = ["test/support.json"] env = ["FEATURE_MODE"]

[tools.gleam_mutants.policy]
strict = false
minimum_score = 100
require_mutants = true

[tools.gleam_mutants.report]
directory = "reports/mutation"
formats = ["json", "html"]
history = true
diagnostics = "errors"
high = 80
low = 60
```

Precedence is built-in defaults, then `gleam.toml`, then CLI or API overrides.
`init` preserves TOML comments and ordering and is idempotent.
`--test-command` consumes the remaining arguments verbatim.

Jobs default to `min(logical CPU, 8)`; explicit values must be 1–32.
Explicit timeouts must be 100ms–24h.
CLI durations accept `30000ms`, `30s`, `1.5s`, `1m`, `1h`, and unitless integer seconds.
Unknown units, unitless decimals, NaN, and Infinity are rejected.
Derived timeouts are five times the baseline, clamped to ten seconds–30 minutes.

`test_selection = "auto"` permits a compatible provider to execute impacted tests first.
Unsupported, invalid, incomplete, or missing evidence falls back to the full suite.
Each narrowed selector set must pass an unmutated baseline.
A narrowed survive, timeout, or test error is confirmed with the full suite.
`full` disables the impact protocol.
The protocol does not require a particular test runner.

Cache `auto` is read-write only for the exact `gleam test` command.
Custom commands default to no outcome cache.
Explicit persistent caching for a custom command requires `cache.key`.
Declare external file and environment inputs through `cache.files` and `cache.env`.
The cache context includes the Gleam compiler and selected runtime versions.
`keep_snapshots` controls retained workspace copies; zero disables retention.
Collection skips locked workspaces, so active copies can temporarily exceed the retention count.

`list` does not build, invoke tests, access the outcome cache, or write reports.
`list --validate` adds compilation but never invokes the test command.
`run` uses the complete execution pipeline.

The report directory must be a safe relative subdirectory and cannot overlap mutation sources.
Existing path components must be ordinary directories without symlinks or junctions.
Thresholds must satisfy `0 <= low <= high <= 100`.
They control the existing report renderer and are independent of `policy.minimum_score`.
The library disables report persistence unless `write_reports` is explicitly enabled.

Remove obsolete generation settings according to the [migration guide](migration.md).
