<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# gleam_mutants

[![CI](https://github.com/P4suta/gleam-mutants/actions/workflows/ci.yml/badge.svg)](https://github.com/P4suta/gleam-mutants/actions/workflows/ci.yml)
[![REUSE status](https://api.reuse.software/badge/github.com/P4suta/gleam-mutants)](https://api.reuse.software/info/github.com/P4suta/gleam-mutants)

Mutation testing for Gleam without modifying or building the original workspace.
The same mutation catalogue can be exercised on Erlang, Node.js, Deno, and Bun.
The current package version is 0.1.0.

The engine and its lossless `RunReport` are Gleam-native. Every completed run
also projects that report into the Stryker report ecosystem format pinned to
Mutation Testing Elements and report-schema 3.9.0.

The repository also develops **Smartest**, a Gleam-first adaptive verification
layer that unifies lazy examples, properties, models, snapshots, fuzzing,
finite and solver-bounded exploration, integration transcripts, reviewed
corpus replay, and mutation goals. Mutation never acts as its correctness
oracle. See the [Smartest guide](docs/smartest.md) for the current API,
evidence states, capability model, and foreground CLI modes.

## Install

From a checked-out repository, add the tool as a path dependency:

```toml
[dev_dependencies]
gleam_mutants = { path = "../gleam-mutants" }
```

Then run the dependency's public CLI module:

```sh
gleam deps download
gleam run -m gleam_mutants -- run
```

For a Git dependency, pin a commit in the consuming project's `gleam.toml`:

```toml
[dev_dependencies]
gleam_mutants = {
  git = "https://github.com/P4suta/gleam-mutants.git",
  ref = "<commit-sha>"
}
```

The escript and npm distributions expose the same command tree. Run an
escript directly:

```sh
escript ./dist/escript/gleam-mutants.escript --version
escript ./dist/escript/gleam-mutants.escript run
```

Install the npm tarball into a Node.js environment and use its binary:

```sh
npm install --global ./dist/npm/gleam-mutants-0.1.0.tgz
gleam-mutants --version
gleam-mutants run
```

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
gleam run -m gleam_mutants -- list
gleam run -m gleam_mutants -- list --validate
gleam run -m gleam_mutants -- run
gleam run -m gleam_mutants -- run --matrix
gleam run -m gleam_mutants -- run --changed origin/main
gleam run -m gleam_mutants -- suggest --survivors
gleam run -m gleam_mutants -- explain <mutant-id-prefix>
gleam run -m gleam_mutants -- run --suggest
gleam run -m gleam_mutants -- apply --verify
```

With no arguments, help is shown; mutation starts only with `run`. The stable
tree is `run`, `list`, `doctor`, `init`, `suggest`, `explain`, `apply`,
`report list|latest|validate|clean`, and `cache status|clean`. All commands
accept `--root`; without it, the nearest parent `gleam.toml` is selected. Run
`--help` for all flags.

`suggest` proposes the tests that kill surviving mutants and `explain` shows one
mutant with the input that separates it; both probe the workspace differentially
and run on the Erlang target only.

**The probe calls every public function of the selected modules for real**, with
generated arguments, in the environment you ran it in — the snapshot isolates
source, not effects, so a function that writes files, deletes directories or
talks to the network does exactly that, hundreds of times. Name such functions
in `exclude_functions`, or narrow the run with `--function` or `--include`, and
see [side effects](docs/suggest.md#side-effects) before pointing `suggest` at
code you do not know.

`apply` writes those tests into your own test modules, one flat file per module
under test: `src/app/util.gleam` is tested by `test/app_util_test.gleam`.
Without `--yes` it is a dry run that only prints the files and tests it would
add; with `--yes` it appends the missing tests and imports, skipping any test
name it has written before, calling every module by the name your own file
already binds it under, and running `gleam format` over what it touched.
`--verify` implies `--yes` and then re-runs the mutation engine over those
source files, exiting 1 if any mutant the new tests claim to kill is still
alive; that run stores no
report of its own, so `report latest` still answers from your last `run`. It
also grades the workspace before it writes, so each mutant is reported as
newly killed, already killed by your own tests, or still surviving, and a
generated test that added nothing is warned about — two mutation runs instead
of one, unless your last stored `run` graded every mutant in question and
started after the last write to `src/` or `test/`, which `--no-reuse`
refuses.
`run --suggest` prints the suggestions for that run's own survivors under the
normal summary and never changes its exit code; it is refused with `--json`,
which prints exactly one JSON value. A generated test pins the behaviour the
code has today, so read them before committing them — see [suggesting tests](docs/suggest.md).

`list` is the fast discovery path: it reads configuration, snapshots the
workspace, and finds candidates without building, instrumenting, running a
baseline, or invoking tests. Its rows and required List JSON v1 `validated`
field identify those candidates as unvalidated. `list --validate` builds the
unmutated snapshot once and compiler-validates candidates without running
tests; it reports compiler-valid and rejected candidates and succeeds even when
all candidates are rejected. `run` retains the full baseline, compiler
validation, instrumentation, instrumented-baseline, and mutation-test gates.
Display-ID prefixes are collision-checked across the complete selected file set
for all three paths. `report latest` always emits native JSON; `--json` remains
an accepted compatibility alias.

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
Human-readable mutation percentages are rounded to at most two decimal places;
native and Stryker JSON retain their full numeric precision.

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

## Editor integration

A VS Code extension lives in [`editors/vscode`](editors/vscode). It publishes
the surviving mutants of the last `mutation.json` as warnings on the lines they
change, and offers two quick fixes on each of them: generate the test that
kills this mutant, which runs `suggest` and then `apply` and opens the test
module it wrote, and explain this mutant. It shells out to this CLI rather than
reimplementing it, so what the editor shows is what `run`, `suggest` and
`apply` print. Build and install it from source with the instructions in
[`editors/vscode/README.md`](editors/vscode/README.md); the same caveats apply,
`suggest` calls your code for real and supports the Erlang target alone.

## Safety model

The original source files are read only: the only normal project writes are the
two report files above, plus the test modules `apply --yes` is explicitly asked
to write. That covers what the tool writes, not what your code writes when
`suggest`, `explain` or `apply` call it — see
[side effects](docs/suggest.md#side-effects).
`gleam_mutants` creates a sorted disposable snapshot,
excludes the effective report directory from its manifest and cache fingerprint,
rejects symlinks, junctions and special files, and performs all build and test
work there. A refused special file is reported as `GMU7004` and names the path
and a way past it; a cache directory that cannot be created fails under
`GMU7005`, and a report the tool cannot write under `GMU6002` (native history)
or `GMU6003` (project reports) — each naming the path it failed at, rather
than as a bare errno. A bounded parallel worker pool uses independent snapshots,
reuses each worker's local build cache between mutant waves, and terminates full
process trees on timeout or interruption. Generated runtime modules exist only
in those snapshots. The tool performs no telemetry and no runtime network
requests.

The native report history is scoped to the canonical workspace below the OS
cache directory and can be managed with `report`. Reports may contain original
source and diagnostics; treat CI artifacts accordingly. `run --json` writes one
native JSON v1 value plus LF to stdout after a domain result exists, while early
failures keep stdout empty. GitHub annotations are suppressed in JSON mode, and
runs the tool makes on your behalf — the two `apply --verify` takes — never
annotate at all.

## Development

The pinned toolchain is managed by mise:

```sh
mise run bootstrap
mise run check
mise run test-matrix
mise run dogfood
mise run test-ecosystem
mise run package
```

`mise run package` creates Hex, escript, and npm artifacts,
SHA-256 checksums, and CycloneDX SBOMs under `dist/`, then smoke-tests the
installable command. It contains no publish or GitHub Release operation.
The package gate mutation-tests clean projects through all three artifacts,
validates Stryker JSON with Ajv 8.20.0, browser-smokes the offline HTML, and
records the embedded MTE component and dependency edge in the SBOM.

`mise run test-ecosystem` is a networked golden smoke with an internal
13-minute deadline. It fetches only these fixed official-library commits, uses
four workers, disables strict mode, history, project reports, and persistent
cache, validates native report v1 and source hashes, and writes only a
normalized `test-results/ecosystem-summary.json` summary:

| Corpus | Scope | Runtime / timeout | Golden candidates / executed / rejected | Golden killed / survived |
| --- | --- | --- | ---: | ---: |
| `stdlib@55f9454` | `src/gleam/bool.gleam` | Erlang / 60s | 11 / 11 / 0 | 11 / 0 |
| `json@9792d8a` | `src/gleam/json.gleam` | Erlang / 30s | 6 / 3 / 3 | 1 / 2 |
| `http@da44e89` | `src/gleam/http/cookie.gleam` | Erlang / 30s | 34 / 29 / 5 | 26 / 3 |
| `erlang@dfa7cd7` | `src/gleam/erlang/atom.gleam` | Erlang / 30s | 2 / 2 / 0 | 1 / 1 |
| `javascript@b51b436` | `src/**/*.gleam` | Node / 30s | 6 / 2 / 4 | 1 / 1 |

Expected survivors are golden compatibility evidence, not a minimum-score
failure. The Linux workflow runs Sunday at 03:41 UTC or manually, has a
15-minute hard cap, and retains the summary for 14 days. It is intentionally
absent from ordinary PR CI and the daily nightly matrix, but is required by the
manual release-candidate and publish gates.

See [Smartest](docs/smartest.md), [configuration](docs/configuration.md),
[operators](docs/operators.md), [suggesting tests](docs/suggest.md), and
[architecture](docs/architecture.md) for details.

## Licence

`MIT OR Apache-2.0`, at your option. Mutation Testing Elements 3.9.0 is embedded
under Apache-2.0; see [third-party notices](THIRD_PARTY_NOTICES.md). The
repository is REUSE-compliant.
