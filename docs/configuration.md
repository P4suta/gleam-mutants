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
timeout_seconds = 15.0
baseline_runs = 1
command = ["gleam", "test"]

[tools.gleam_mutants.execution]
jobs = 4

[tools.gleam_mutants.cache]
mode = "read-write"        # off, read-only, write-only, read-write

[tools.gleam_mutants.policy]
strict = true
minimum_score = 90.0
```

Precedence is built-in defaults, then `gleam.toml`, then CLI flags. `init` edits
the existing TOML through Tomlet, preserving comments and ordering, and is
idempotent. `--test-command` consumes the remaining argv verbatim.
