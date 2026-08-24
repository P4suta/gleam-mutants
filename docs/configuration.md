<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Configuration

Configuration belongs in `gleam.toml` and is decoded strictly. Unknown keys and
invalid values produce positioned errors.

```toml
[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.mutation]
include = ["src/**/*.gleam"]
exclude = ["test/**", "dev/**", "build/**"]
operators = ["boolean-literal", "integer-arithmetic"]

[tools.gleam_mutants.test]
target = "auto"            # auto, erlang, javascript
runtime = "auto"           # auto, erlang, node, deno, bun
timeout_ms = 15000
baseline_runs = 1
command = ["gleam", "test"]

[tools.gleam_mutants.execution]
jobs = 4

[tools.gleam_mutants.cache]
mode = "auto"              # auto, off, read-only, write-only, read-write
# key = "custom-suite-v1"  # required for persistent custom-command caching
# files = ["test/support.json"]
# env = ["FEATURE_MODE"]

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

Precedence is built-in defaults, then `gleam.toml`, then CLI flags. `init` edits
the existing TOML through Tomlet, preserving comments and ordering, and is
idempotent. `--test-command` consumes the remaining argv verbatim.

`jobs` defaults to `min(logical CPU, 8)` and explicit values must be 1–32.
Explicit timeouts must be 100ms–24h. CLI durations accept `30000ms`, `30s`,
`1.5s`, `1m`, `1h`, and unitless integer seconds; unknown units, unitless
decimals, NaN, and Infinity are rejected. The derived timeout is five times the
baseline clamped to 10 seconds–30 minutes. Cache `auto` is read-write only for
the exact `gleam test` command and is off for custom commands.

`list` applies mutation selection configuration but deliberately does not build,
instrument, run a baseline, invoke the configured test command, read/write the
outcome cache, or create reports/history. Its List JSON v1 output has required
`validated: false`. `list --validate` additionally builds the unmutated snapshot
once and compiler-validates all candidates, returning `validated: true` plus
compiler rejections; it still never invokes the test command. `run` alone uses
the complete execution configuration and all safety gates.

`report.directory` must be a safe relative subdirectory of the workspace. It
cannot overlap mutation target sources and no existing component may be a
symlink, junction, special file, or non-directory. Thresholds are integers and
must satisfy `0 <= low <= high <= 100`; they only control Mutation Testing
Elements colours and are independent of `policy.minimum_score`.

Enabled project formats atomically replace fixed `mutation.json` and
`mutation.html` targets in that directory. `formats = []` or `--report none`
disables project reports without deleting existing files; `history = false`
also disables native history. Reports may contain original source and error
diagnostics. The report directory is excluded from snapshot manifests and
cache fingerprints. `.gitignore` changes only with explicit `init --gitignore`.
