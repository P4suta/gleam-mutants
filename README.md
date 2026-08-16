<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# gleam_mutants

Mutation testing for Gleam without modifying or building the original workspace.
The same mutation catalogue can be exercised on Erlang, Node.js, Deno, and Bun.
Version 0.1.0 is release-ready but intentionally unpublished.

## Install

The future Hex route is:

```sh
gleam add --dev gleam_mutants
gleam run -m gleam_mutants -- run
```

The escript and npm artifacts expose the same command tree as `gleam-mutants`.
No package or repository has been published by this project.

## Quick start

```sh
gleam run -m gleam_mutants -- doctor
gleam run -m gleam_mutants -- init
gleam run -m gleam_mutants -- run
gleam run -m gleam_mutants -- run --matrix
gleam run -m gleam_mutants -- run --changed origin/main
```

With no arguments, `run` is selected. Other commands are `list`, `doctor`,
`init`, and `report latest`. Run `--help` for all flags.

Configuration lives in `[tools.gleam_mutants]` in `gleam.toml`; there is no
separate configuration file. With no configuration the tool mutates
`src/**/*.gleam`, excludes test/dev/build/tool data, runs `gleam test`, uses at
most eight workers, and derives its timeout from the baseline (at least ten
seconds).

Interactive runs report survivors and exit successfully. CI, non-interactive,
or `--strict` runs fail when the configured minimum score is not met. Exit 2
means configuration, baseline, or tool failure; exit 130 means interruption.
A timeout counts as detected in the score but is always displayed separately.

## Safety model

The source workspace is read only. `gleam_mutants` creates a sorted disposable
snapshot, rejects symlinks, junctions and special files, and performs all build
and test work there. A bounded parallel worker pool uses independent snapshots,
reuses each worker's local build cache between mutant waves, and terminates full
process trees on timeout or interruption. Generated runtime modules exist only
in those snapshots. The tool performs no telemetry and no runtime network
requests.

Reports are saved below the operating-system cache directory and can be read
with `report latest`. `--json` emits JSON Schema v1 data, while CI runs also
produce GitHub annotations and a job summary.

## Development

The pinned toolchain is managed by mise:

```sh
mise run bootstrap
mise run check
mise run test-matrix
mise run dogfood
mise run package
```

`mise run package` creates unpublished Hex, escript, and npm artifacts,
SHA-256 checksums, and a Syft CycloneDX SBOM under `dist/`, then smoke-tests the
installable command. It contains no publish or GitHub Release operation.

See [configuration](docs/configuration.md), [operators](docs/operators.md), and
[architecture](docs/architecture.md) for details.

## Licence

`MIT OR Apache-2.0`, at your option. The repository is REUSE-compliant.
