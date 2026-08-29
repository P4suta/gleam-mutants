<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Architecture

The pure core owns byte spans, operators, stable IDs, catalogue construction,
nested interval instrumentation, outcomes, scores, and exit policy. Effects are
provided through concrete filesystem, compiler/process, clock, cache, and
reporting capabilities.

Catalogue discovery has a small internal rule layer. `MutationRule` records the
operator, `AnalysisMode`, and `TypeEvidence`. The default discovery path remains
syntax-based for compatibility, while semantic rules are created only from
definite Glance evidence (literals and typed binary operators). Expressions
without evidence are not guessed into a typed mutation; the internal Catalog
retains a `type-evidence-unavailable` reason. Compiler-invalid candidates are
retained as rejected entries for diagnostics.

The opaque phase pipeline is:

```text
Discovered -> Snapshotted -> BaselinePassed -> Validated -> Instrumented -> Completed
```

A transition requires the preceding phase type, so a mutant cannot be executed
before the baseline passes. Discovery uses Glance AST locations, but output is
assembled from byte slices of the original source rather than pretty-printing.
This preserves comments, whitespace, Unicode, and CRLF. An interval forest
allows nested mutations to coexist in one instrumented source.

The fast `list` path stops after configuration, snapshotting, selection, and
catalogue discovery. `list --validate` builds the unmutated snapshot once, then
compiler-checks candidates without entering either baseline or test execution.
The full phase pipeline remains mandatory for `run`. A failing validation
batch is split recursively until the invalid candidate and a deterministic,
workspace-independent compiler diagnostic are isolated. Rejected candidates
are available through validated `--explain` and JSON output.

The snapshot manifest is sorted and excludes `.git`, `build`, `.gleam_mutants`,
`.smartest`, and other generated data. Reviewed Smartest corpus under
`test/smartest/corpus/` remains a normal input. Links and special files are
rejected. Catalogue consumers borrow one callback-scoped session containing
the configuration, changed paths, snapshot, sources, and discovered mutants;
the session disposes its one snapshot on every return path. A private runtime
module generated in the snapshot asks its own FFI which mutant is active, and
that FFI answers from the first source that has one: on Erlang the process
dictionary key `gleam_mutants_active`, then the persistent term
`{gleam_mutants, active}`, then the `GLEAM_MUTANTS_ACTIVE` environment
variable; on JavaScript it reads `GLEAM_MUTANTS_ACTIVE` from the runtime's
environment. `run` sets the environment variable per worker process; the
in-process Erlang sources are what let one VM switch mutants between calls,
which the differential probe below depends on. No permanent runtime API is
required in the target package.

Adaptive test selection is provider-independent. With `test_selection =
"auto"`, each instrumented baseline receives
`GLEAM_MUTANTS_TEST_IMPACT_FILE`. A compatible runner atomically writes a
versioned manifest of ordered opaque test descriptors and mutation sites each
test reached. Mutant workers receive those selectors in an atomic JSON file
below their snapshot's `.gleam_mutants/` directory through
`GLEAM_MUTANTS_TEST_SELECTION_FILE`; selectors are never packed into an
environment variable. Smartest supplies the first provider: native plans use
exact leaf ids and legacy tests use their public `*_test` export id. Erlang
propagates the current leaf through the runner's child-process context and a
runtime-local ETS table; JavaScript runtimes use runtime-local global symbols.

Evidence is only an optimisation. An unsupported runner, invalid or incomplete
manifest, unknown identity, or unreached site falls back to the configured full
suite. Every distinct narrowed selector set first passes an unmutated baseline.
A narrowed kill is final; every survive, timeout, or test error is rerun with
the full suite, and only that final verdict is cached. `test_selection =
"full"` does not start the impact protocol and follows the full-suite path
directly.

A bounded worker pool receives independent copies of the instrumented snapshot.
The cache is read for every mutant/runtime pair before that pool is allocated,
so only mutants with misses receive workers and an all-hit run creates none.
Workers are reused between mutant waves so their local build cache remains
warm; no workspace is shared by concurrently running tests. Timeout cleanup
terminates the entire descendant process tree (TERM then KILL on POSIX,
`taskkill /T` on Windows), and interruption is preserved as exit 130.

Matrix aggregation is intentionally conservative: any surviving runtime makes
the mutant survived; only mutants killed in every runtime are killed. Timeouts
remain a distinct detected outcome. A failed baseline in any selected runtime
aborts without producing a quality score.

The native `RunReport` remains the lossless source of truth, including runtime
matrix and cache details. A pure deterministic projection emits report schema
3.9.0 data with `schemaVersion: "1.0"`. Files and mutants are sorted, original
source is preserved byte-for-byte, and byte spans are recalculated as 1-based,
start-inclusive/end-exclusive UTF-16 locations. The projection deliberately
omits coverage fields, project root, full configuration, and extensions.

The offline renderer decodes a generated pure-Gleam Base64 module containing
the official Mutation Testing Elements 3.9.0 IIFE. JSON is stored in a
non-executable `application/json` script element with HTML-significant and line
separator characters escaped. The official bundle and a fixed bootstrap are
the only executable scripts and are authorized by CSP hashes.

## Differential suggestion

`suggest`, `explain`, and `apply` do not run the test suite at all. The probe
copies the workspace into a disposable snapshot and generates, per module, a
probe module that calls each public function twice on the same input: once
with no mutant active and once per mutant of that function. Each call runs in
a monitored process of the same VM whose process dictionary names the active
mutant, so a panic and a timeout are contained without a new OS process and
both answers are compared directly rather than inferred from a red suite.
This is why the three commands are Erlang-only: only that runtime's
in-process switch and isolation are supported today.

Inputs are derived from the function's own type annotations into a
target-independent `GenSpec`, then generated from the deterministic property
generator against a configured seed. A separating input is shrunk towards the
smallest one that still separates, and the probe knows every mutant id of the
function it probes, so one input reports a kill set rather than a single
mutant. Kill sets are minimised per function by greedy set cover: a test for
one function can never kill a mutant of another, so minimising across
functions could only make the choice worse.

Every selected mutant is accounted for exactly once — distinguished,
indistinguishable, nondeterministic, or unsupported — including mutants
outside every function of their module, which no probe can call. The snapshot
is deleted before a report is answered, on success and on failure alike.

`apply` resolves each module under test to one flat test module —
`test/<module path with "/" replaced by "_">_test.gleam` — reading the existing
file's own parse tree for the tests it defines, the names it imports modules
under, and the constructors it declares itself. Rendering is scoped to one test
module: which names the generated file's own imports take is a property of the
whole file, so the module under test, `gleam/option`, `gleam/string`, and
`gleeunit/should` are named from one scope and a name the reader's file already
bound wins. A module the file imported as `_` names nothing to reuse, so a
plain import joins it rather than replacing it. `Some` and `None` are the only
names written unqualified, and a file that already binds either gets
`option.Some` and `option.None` through a qualified import instead. What is
left — a module qualifier two modules would both answer to — is refused before
anything is written, since `gleam format` accepts source the compiler does not.
Plans and writes come from the same resolver, so a plan is never a guess at
what a write would do. Files are staged beside their targets and atomically
renamed, then `gleam format` is run over what changed. `apply --verify` re-runs
the mutation engine over the source files the applied suggestions came from and
reports each claimed mutant as killed or not; surviving mutants are a quality
failure, not a tool failure. That run overrides both report formats and report
history, so a narrowed verification never becomes the workspace's latest stored
report.

Project reports are staged beside their fixed targets and atomically renamed.
The destination is validated before snapshotting and again before writing;
existing targets must be regular files. The effective report directory is not
copied or hashed, so a previous run cannot affect discovery or cache identity.
