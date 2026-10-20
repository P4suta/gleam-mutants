<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# gleam_mutants

Mutation testing for Gleam on Erlang, Node.js, Deno, and Bun.
Runs tests in disposable snapshots and produces JSON and offline HTML reports.
Current artifacts are development snapshots.
The current package version is 0.1.0.

## Use from source

Add the checked-out repository as a development dependency:

```toml
[dev_dependencies]
gleam_mutants = { path = "../gleam-mutants" }
```

```sh
gleam deps download
gleam run -m gleam_mutants -- run
```

Reports go under `reports/mutation/`.
The [usage guide](docs/usage.md) covers installation, runtime versions, commands, side effects, and development checks.
See [Smartest](docs/smartest.md) for adaptive verification and the [VS Code extension](editors/vscode/README.md) for editor integration.

Licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
See [third-party notices](THIRD_PARTY_NOTICES.md) for embedded dependencies.
