<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Usage and development

Mutation testing measures whether existing tests detect controlled changes to source.
The library and CLI use one Gleam-native engine and canonical `RunReport`.
Completed runs can also produce Stryker JSON and a single offline HTML report using Mutation Testing Elements 3.9.0.
Version 0.1.0 remains an unreleased development snapshot.

## Install

Add a checked-out repository as a development dependency:

```toml
[dev_dependencies]
gleam_mutants = { path = "../gleam-mutants" }
```

Then use its CLI module:

```sh
gleam deps download
gleam run -m gleam_mutants -- run
```

A Git dependency must pin a commit.
The packaged escript and npm tarball expose the same command tree:

```sh
escript ./dist/escript/gleam-mutants.escript --version
npm install --global ./dist/npm/gleam-mutants-0.1.0.tgz
gleam-mutants --version
```

See the [library guide](library.md) for typed embedding.

## Supported environments

The existing 0.1 support window is Gleam 1.17–1.18, Erlang/OTP 27–29, Node.js 22/24 LTS, Deno 2.9 LTS, and Bun 1.2–1.3.
Tier 1 platforms are Linux, Windows 11/Server 2022, and macOS 13.5 or newer.
x64 is supported on all three; arm64 is tested where a GitHub-hosted runner is available.
Network filesystems and 32-bit operating systems are outside this boundary.
A support line is not removed in a patch release.
Removal requires a minor or major release, advance notice, and migration instructions.
The pins in `mise.toml` define the reproducible development environment.

## Commands

```sh
gleam run -m gleam_mutants -- doctor
gleam run -m gleam_mutants -- init
gleam run -m gleam_mutants -- list
gleam run -m gleam_mutants -- list --validate --explain
gleam run -m gleam_mutants -- run
gleam run -m gleam_mutants -- run --matrix
gleam run -m gleam_mutants -- run --changed origin/main
gleam run -m gleam_mutants -- report latest
gleam run -m gleam_mutants -- cache status
```

With no arguments, help is shown.
Mutation starts only with `run`.
The command families are `run`, `list`, `doctor`, `init`, `report list|latest|validate|clean`, and `cache status|clean`.
All commands accept `--root`; otherwise, the nearest parent `gleam.toml` is selected.
Run `--help` for all flags.

`list` discovers candidates without compiling, instrumenting, running a baseline, or invoking tests.
Its required List JSON v1 `validated` field is `false`.
`list --validate` builds the unmutated snapshot and compiler-checks candidates without running tests.
It returns admitted and rejected candidates with `validated: true`, even if all are rejected.
`--explain` includes rejection diagnostics.
`run` requires pristine and instrumented baselines and compiler validation before mutant execution.
Display-ID prefixes are collision-checked across the complete selected file set.
`report latest` emits native JSON; its `--json` alias remains accepted.

Configuration lives in `[tools.gleam_mutants]` in `gleam.toml`.
Without configuration, mutation selects `src/**/*.gleam`, excludes generated data, runs `gleam test`, and uses at most eight workers.
The derived timeout is at least ten seconds.
Strict policy is disabled by default in every terminal and CI context.
Use `--strict` when a score below the minimum must fail.

Exit 1 means a quality-policy failure.
Exit 2 means usage, configuration, baseline, runtime, storage, or tool failure.
Child interruption preserves exit 130/143 in the CLI.
Timeouts count as detected and remain displayed separately.
Compiler rejections and test errors are excluded from the score denominator; test errors still produce exit 2.
Human-readable percentages use at most two decimal places.
JSON retains full numeric precision.

## Reports and side effects

By default, a completed CLI run writes:

```text
reports/mutation/mutation.json
reports/mutation/mutation.html
```

The project JSON uses Stryker's schema; stdout under `run --json` and native history use the lossless native report.
The HTML embeds its JSON and pinned renderer and uses a hash-based Content Security Policy.
It requires no network requests.
Use `--report none` or `report.formats = []` to disable project report writes.
Use `history = false` to disable native history.
Disabling writes preserves existing reports.
The library requires an explicit option to enable either report destination.

Original source files are read-only to the engine.
Builds and tests run in disposable snapshots.
Snapshots reject input symlinks, junctions, and special files and exclude the effective report directory from their manifests and fingerprints.
Workers use independent snapshots and reuse their local build cache between mutation waves.
Timeout cleanup terminates descendant process trees.
A child exit of 130/143 aborts work, releases the lock, and disposes snapshots through the normal error path.
Test programs retain the caller's permissions; snapshot isolation does not sandbox their external effects.

Native history is scoped to the canonical workspace below the OS cache directory.
Manage it with `report`.
Reports may include source and diagnostics.
`run --json` emits one native JSON value plus LF after a domain result exists; early failures leave stdout empty.
JSON mode suppresses GitHub annotations.
The library emits no annotations or terminal output.

## Development

```sh
mise run bootstrap
mise run check
mise run test-integration
mise run test-matrix
mise run test-property
mise run test-faults
mise run prove
mise run dogfood
mise run test-ecosystem
mise run package
```

The [verification contracts](verification.md) identify each check and its limits.
Docker is required for the pinned, bounded proof environment.
Packaging creates Hex, escript, npm, checksums, and CycloneDX SBOMs under `dist/`.
It verifies installation, public API use, mutation runs, offline rendering, and reproducible checksums.
It performs no publication.

The ecosystem task fetches fixed official-library commits, uses four workers, and has a 13-minute operational deadline.
It disables strict mode, history, project reports, and persistent cache and validates native report and source hashes.
A deadline stop is inconclusive.
The output is `test-results/ecosystem-summary.json`.

| Corpus | Scope | Runtime / timeout | Candidates / executed / rejected | Killed / survived |
| --- | --- | --- | ---: | ---: |
| `stdlib@55f9454` | `src/gleam/bool.gleam` | Erlang / 60s | 11 / 11 / 0 | 11 / 0 |
| `json@9792d8a` | `src/gleam/json.gleam` | Erlang / 30s | 6 / 3 / 3 | 1 / 2 |
| `http@da44e89` | `src/gleam/http/cookie.gleam` | Erlang / 30s | 51 / 46 / 5 | 43 / 3 |
| `erlang@dfa7cd7` | `src/gleam/erlang/atom.gleam` | Erlang / 30s | 2 / 2 / 0 | 1 / 1 |
| `javascript@b51b436` | `src/**/*.gleam` | Node / 30s | 6 / 2 / 4 | 1 / 1 |

Expected survivors are compatibility evidence.
The protected release gates require these golden outcomes and the complete operating-system, host, and target matrix.
Hosted-only permissions, signatures, publication, and other operating systems require their own release evidence.
See the [migration guide](migration.md), [configuration](configuration.md), [operators](operators.md), and [architecture](architecture.md).
