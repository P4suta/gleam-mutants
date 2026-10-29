<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Architecture

The package measures existing test suites through controlled source mutations.
The [package boundary decision](adr/mutation-testing-package-boundary.md) defines its scope.
The public modules are the CLI entry point, `gleam_mutants/api`, and `gleam_mutants/types`.
Canonical options and result types support typed embedding.
The CLI owns terminal rendering, GitHub annotations, and exit status.
The API returns failures and captures child output.

The pure core owns byte spans, operators, stable identities, catalogue construction, interval instrumentation, outcomes, scores, and exit policy.
Filesystem, compiler, process, clock, cache, and reporting operations sit behind concrete capabilities and the platform FFI.

## Discovery and execution

`MutationRule` records an operator, analysis mode, and type evidence.
Syntax-based discovery remains the default.
Semantic rules require definite Glance evidence.
Unavailable type evidence is retained as a reason rather than guessed.
Compiler-invalid candidates remain explicit rejected entries.

The opaque phase pipeline is:

```text
Discovered -> Snapshotted -> BaselinePassed -> Validated -> Instrumented -> Completed
```

Transitions require the preceding phase.
Discovery uses Glance AST locations, while instrumentation assembles original byte slices.
Comments, whitespace, Unicode, and CRLF are preserved.
An interval forest supports nested mutations in one instrumented source.

`list` stops after selection and catalogue discovery.
`list --validate` builds the unmutated snapshot and compiler-checks candidates without tests.
Validation splits failing batches to isolate invalid candidates and normalize compiler diagnostics.
Interrupted builds abort validation instead of being misclassified as compiler rejections.
`run` requires pristine and instrumented baselines before mutation testing.
A failed baseline aborts without a quality score.

The sorted snapshot manifest excludes generated build, dependency, cache, and report data.
Input links and special files are rejected.
A callback-scoped session owns configuration, selection, snapshot, sources, and catalogue.
Every returned result passes through snapshot disposal and lock release.
Generated runtime modules exist only inside snapshots.
Each worker selects its mutant through `GLEAM_MUTANTS_ACTIVE`.

## Optional selection evidence

With automatic test selection, the instrumented baseline receives `GLEAM_MUTANTS_TEST_IMPACT_FILE`.
A compatible provider writes a versioned manifest with ordered opaque test descriptors and reached mutation sites.
Workers receive an atomic selector file through `GLEAM_MUTANTS_TEST_SELECTION_FILE`.
Selectors are not packed into an environment variable.

Evidence is an optimization.
An unsupported runner, invalid or incomplete manifest, unknown identity, or unreached site falls back to the full suite.
Each distinct narrowed selector set first passes an unmutated baseline.
A narrowed kill is final.
Other outcomes are rerun against the full suite, and only the final verdict is cached.
Full selection bypasses the protocol.

For a syntactically safe expression, an instrumented baseline may compare the original and replacement values.
Calls are excluded because evaluating them twice can change behavior.
Only explicit successful observations can settle a mutant as survived without execution.
Missing observations, unwritable evidence, unreached guards, and unsupported runtimes remain missing evidence.
The project's own [fault and boundary checks](verification.md) cover those cases.

## Workers, caching, and outcomes

The cache is queried before allocating workers.
An all-hit run creates no worker pool.
Misses use independent snapshots, reused between waves to retain local build caches.
Cache identity includes source, command, configuration, environment, declared inputs, compiler version, and real runtime versions.
Erlang is identified through `erl`, not the runtime's display name.

Timeout cleanup terminates descendant process trees with TERM then KILL on POSIX and `taskkill /T` on Windows.
A child status of 130/143 stops subsequent work and propagates an interruption error.
Library callers retain control of their host.
The CLI maps the error to the same exit code.

Aggregation prioritizes a test error, then survival, then timeout, then a kill.
An empty runtime result list is a test error.
Timeouts remain distinct and count as detected under the scoring contract.
A failed baseline produces no mutation score.

## Reports

The native `RunReport` is the lossless source of truth for runtime and cache details.
Its deterministic Stryker projection uses report schema 3.9.0 and `schemaVersion: "1.0"`.
Files and mutants are sorted.
Original source stays byte-for-byte intact, while byte spans become one-based, start-inclusive, end-exclusive UTF-16 locations.

The offline renderer embeds the official Mutation Testing Elements IIFE.
Report JSON is stored in a non-executable script element with HTML-significant and line separator characters escaped.
The bundle and fixed bootstrap are authorized by CSP hashes.
The report makes no network requests.

Project reports are staged beside fixed targets and atomically renamed.
Destinations are validated before snapshotting and before writing.
The effective report directory is excluded from snapshot and cache identity.
Native history is separate from project Stryker reports.
The API only persists reports when explicitly requested.
