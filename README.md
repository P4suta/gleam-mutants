<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# gleam_mutants

[![CI](https://github.com/P4suta/gleam-mutants/actions/workflows/ci.yml/badge.svg)](https://github.com/P4suta/gleam-mutants/actions/workflows/ci.yml)
[![REUSE status](https://api.reuse.software/badge/github.com/P4suta/gleam-mutants)](https://api.reuse.software/info/github.com/P4suta/gleam-mutants)

Mutation testing for Gleam without modifying or building the original workspace.
The same mutation catalogue can be exercised on Erlang, Node.js, Deno, and Bun.
Version 0.1.0 is an intentionally unpublished preview. It must not be
described as production-ready until the immutable commit has the required
GitHub-hosted evidence, signatures, SBOMs, benchmarks, and install smokes.

The engine and its lossless `RunReport` are Gleam-native. Every completed run
also projects that report into the Stryker report ecosystem format pinned to
Mutation Testing Elements and report-schema 3.9.0.

## Install

The future Hex route is:

```sh
gleam add --dev gleam_mutants
gleam run -m gleam_mutants -- run
```

The escript and npm artifacts expose the same command tree as `gleam-mutants`.
No Hex or npm package has been published. This repository contains an
unpublished 0.1.0 preview; a Git tag and GitHub Release do not exist.

## Supported environments

The 0.1 support window is Gleam 1.17–1.18, Erlang/OTP 27–29, Node.js 22/24
(LTS lines only), Deno 2.9 LTS, and Bun 1.2–1.3. Tier 1 platforms are Linux,
Windows 11/Server 2022, and macOS 13.5 or newer. x64 is supported on all three;
arm64 is tested where a GitHub-hosted runner is available. Network filesystems
and 32-bit operating systems are outside the supported boundary. A support line
is not removed in a patch release; removals require a minor or major release,
advance notice, and migration instructions.

## Quick start

```sh
gleam run -m gleam_mutants -- doctor
gleam run -m gleam_mutants -- init
gleam run -m gleam_mutants -- run
gleam run -m gleam_mutants -- run --matrix
gleam run -m gleam_mutants -- run --changed origin/main
```

With no arguments, help is shown; mutation starts only with `run`. The stable
tree is `run`, `list`, `doctor`, `init`, `report list|latest|validate|clean`, and
`cache status|clean`. All commands accept `--root`; without it, the nearest
parent `gleam.toml` is selected. Run `--help` for all flags.

Configuration lives in `[tools.gleam_mutants]` in `gleam.toml`; there is no
separate configuration file. With no configuration the tool mutates
`src/**/*.gleam`, excludes test/dev/build/tool data, runs `gleam test`, uses at
most eight workers, and derives its timeout from the baseline (at least ten
seconds).

The default is `strict = false` in TTY, pipes, IDEs, and CI alike. Use
`--strict` explicitly when a score below the minimum must fail. Exit 1 means a
quality-policy failure; exit 2 means usage, config, baseline, runtime, storage,
or tool failure; signals preserve exit 130/143.
A timeout counts as detected in the score but is always displayed separately.
Compile errors and runtime errors are excluded from the score denominator;
runtime errors still make the tool exit 2.

Every completed run writes these deterministic reports inside the project:

```text
reports/mutation/mutation.json
reports/mutation/mutation.html
```

The HTML is a single offline file with its JSON and the pinned Mutation Testing
Elements bundle inline. It uses a hash-based Content Security Policy and makes
no network request. Set `report.formats = []` or use `--report none` to disable
project reports without deleting existing files; set `history = false` to stop
native history. Fixed project filenames remain `mutation.json` and
`mutation.html` when enabled.

## Safety model

The original source files are read only: the only normal project writes are the
two report files above. `gleam_mutants` creates a sorted disposable snapshot,
excludes the effective report directory from its manifest and cache fingerprint,
rejects symlinks, junctions and special files, and performs all build and test
work there. A bounded parallel worker pool uses independent snapshots,
reuses each worker's local build cache between mutant waves, and terminates full
process trees on timeout or interruption. Generated runtime modules exist only
in those snapshots. The tool performs no telemetry and no runtime network
requests.

The native report history is scoped to the canonical workspace below the OS
cache directory and can be managed with `report`. Reports may contain original
source and diagnostics; treat CI artifacts accordingly. `run --json` writes one
native JSON v1 value plus LF to stdout after a domain result exists, while early
failures keep stdout empty. GitHub annotations are suppressed in JSON mode.

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
SHA-256 checksums, and CycloneDX SBOMs under `dist/`, then smoke-tests the
installable command. It contains no publish or GitHub Release operation.
The package gate mutation-tests clean projects through all three artifacts,
validates Stryker JSON with Ajv 8.20.0, browser-smokes the offline HTML, and
records the embedded MTE component and dependency edge in the SBOM.

See [configuration](docs/configuration.md), [operators](docs/operators.md), and
[architecture](docs/architecture.md) for details.

## Licence

`MIT OR Apache-2.0`, at your option. Mutation Testing Elements 3.9.0 is embedded
under Apache-2.0; see [third-party notices](THIRD_PARTY_NOTICES.md). The
repository is REUSE-compliant.
