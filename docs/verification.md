<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Verification contracts

Verification is development infrastructure for the mutation engine.
It does not add a test framework or proof service to the published API.
The [package boundary ADR](adr/mutation-testing-package-boundary.md) records this choice.

## Source-derived integer decisions

`mise run prove` reads the current [limits module](../src/gleam_mutants/core/limits.gleam).
The unpublished, dependency-free Rust helper parses a closed Gleam fragment of integer constants, typed comparisons, conjunction, and disjunction.
It lowers those expressions into Lean Boolean decisions over integers.
It rejects additional declarations, missing predicates, unknown names, arithmetic, calls, imports, and unsupported tokens.
Boolean precedence is preserved.
The generated model and the exact source copy are isolated under a fresh `build/verification/` directory.

[Independent contracts](../verification/Contracts.lean) require jobs in 1–32, explicit timeouts in 100–86,400,000 milliseconds, interruption exactly at 130 or 143, and file link counts and compiler rejection statuses exactly equal to one.
Each theorem quantifies over all mathematical integers.
This covers admitted Gleam integer inputs under the compiler's ordinary integer-comparison semantics.
Constants and boundary values are exactly representable on the JavaScript target.
There is no arithmetic overflow in this fragment.
Malformed foreign values such as NaN forged through FFI are outside the typed input domain.

The trusted model link is the reviewed translator, Gleam's compiler, and integer comparison semantics.
The proof is about a source-derived model; Lean does not directly verify Gleam executable code.
Parser tests check production derivation, source-bound changes, Boolean precedence, and refusal of unsupported syntax.
Both Gleam targets compile the same production predicates.

Lean 4.34.1 and elan 4.2.4 are downloaded with pinned SHA-256 checksums in the [proof image](../verification/Dockerfile).
Proof commands run without network access, with two CPUs, 2GiB memory and no additional swap, 256 processes, and a 900-second operational limit.
A resource stop is inconclusive.
The process supervisor terminates and reaps a timed-out client before attempting container cleanup.
Cleanup has a separate ten-second deadline and preserves the primary failure when it also fails.
Native fixtures cover zero-deadline termination, completed statuses, cleanup failure, missing cleanup commands, and a blocked cleanup command.
These checks depend on ordinary OS process termination and Docker daemon behavior.
An inability to terminate a client or remove its container remains a reported failure, never a proof result.
The gate requires all six named theorems to have no axioms and replays their compiled module through a fresh kernel.
It changes one production constant for each predicate and requires the corresponding equality-proof failure against the unchanged contracts.
A successful broken proof or another kind of tool failure fails the gate.
The original production source and independent contracts must still match their copies at completion.
Generated models and logs are evidence for that invocation; later invocations generate fresh evidence.

## Source-derived filename decisions

The gate also reads the complete [filesystem entry module](../src/gleam_mutants/core/filesystem_entry.gleam).
A closed translator admits its typed string inequalities, conjunctions, and negated single-character containment checks.
It refuses other declarations, calls, operators, and literals.
The model represents a string as its sequence of Unicode scalar values.
Empty text, dot, and parent components become empty, singleton, and two-element lists.
Slash, backslash, and NUL containment become membership of their scalar values.
The independent contract quantifies over every finite list of natural numbers, including all Unicode scalar sequences.
This representation uses constructive list operations and needs no additional axioms.
The reviewed translation and ordinary Gleam equality and containment semantics remain trusted.
It does not prove an operating system's path resolution or verify Gleam executables directly.

All directory traversal checks the production predicate before joining names or applying exclusions.
An independent executable reference checks every ASCII component of length zero through two, plus Unicode and whitespace controls.
Native regressions cover escaped writes, literal whitespace, source directories named `build`, duplicate and prune refusal, private roots, and active-copy collection.
A Rust fixture runs those boundaries with umask zero on Erlang, Node, Deno, and Bun.
POSIX permission assertions are conditional on the host platform; Windows ACL behavior remains an external assumption.
A synchronized two-process fixture pauses directory creation while another participant populates shared state, then checks that both operations preserve that state.
The [filesystem boundary decision](adr/preserve-filesystem-entry-boundaries.md) records the compatibility and ownership limits.

See Lean's [proof validation documentation](https://lean-lang.org/doc/reference/latest/ValidatingProofs/) for the distinction between elaboration and kernel replay.

## Native boundaries and checked alternatives

No maintained Gleam-native verifier is configured for Glance AST traversal, filesystem operations, or external process trees.
The restricted translator deliberately rejects those semantics.
Encoding their effects as assumptions in Lean would not verify the actual adapter.
The project therefore requires native boundary checks alongside the supported predicate proofs.
Reassess this boundary when a maintained verifier can import the relevant Gleam implementation or when the implementation is decomposed into another supported pure fragment.

| Affected contract | Production path | Required check and boundary |
| --- | --- | --- |
| Option admission | API, engine, configuration, CLI | Source-derived jobs, timeout, and interruption contracts; invalid root, job, timeout, and command regressions |
| Shared API and results | API and canonical types | `api_smoke` compares actual engine scores, selection, policy, identities, and outcomes |
| Diagnostic traceability | Native report projection and schemas | Every outcome category preserves its optional error reason; empty, Unicode, control-character, and escaped messages round-trip through JSON |
| Diagnostic privacy | Execution results and report projections | Real failing processes exercise none, errors, and all modes; suppressed text is absent from API outcomes, native JSON, and Stryker JSON on four runtimes |
| Public package boundary | Package configuration and runtime generator | Exact public-module inventory; generated runtimes preserve explicit, empty, and default internal-module patterns; ordinary tests and mutation dogfood run the same gate |
| Report persistence | API and report adapters | Default no-write and explicit persistence; installed Hex consumer and report storage faults |
| Host preservation | Process FFI, engine, CLI | Child exit 130/143 during compilation, baseline, and mutation batches on all four runtimes; API continuation and CLI exit |
| Process text | Process FFI and report serialization | UTF-8 boundary vectors, BOM preservation, all 65,536 two-byte inputs against Node's replacement decoder, truncated multibyte output, and actual API report serialization on four runtimes |
| Input preservation | Snapshot and instrumenter | Byte digests, spaces, Unicode/CRLF, link rejection, generated-link cleanup, 10,000 fixed-seed properties |
| Filesystem names and privacy | Entry predicate, physical paths, snapshot roots, shared cache | Source-derived scalar-sequence contract; complete two-character ASCII domain; escaped-write controls; four-runtime permissive-umask fixture; synchronized shared-directory creation |
| Absolute workspace identity | Platform path resolution, cache, history, and locks | Dot and parent aliases share an identity; 11,718 rooted paths match Node's independent POSIX and Windows references; drive and UNC roots remain protected |
| Local dependency closure | Local dependency capture and snapshot identity | All 512 directed three-package graphs against an independent transitive-closure reference; shared, absolute, development, Git, retained-copy, and link boundaries; real locked builds and cache invalidation on four runtimes |
| Compiler classification | Validation batches | Source-derived rejection-status contract; mixed and all-rejected catalogues; invalid mutants remain rejected; persistent compiler failures with exit 1 and 75 abort validation on all four runtimes |
| Baseline and aggregation | Execution and outcome core | Baseline failure returns an error; all 341 outcome-category lists of length zero through four match an independent priority reference |
| Selection and cache | Engine, impact protocol, cache | Automatic and full-suite parity, conservative confirmation, all-hit behavior, runtime/compiler identity, source file permissions, and external dependency contents |
| Cleanup and durability | Snapshots, locks, report storage | Source-derived file-link admission; retained-copy file, directory, root symlink, and hard-link refusal; process-tree, interruption, workspace-lock, report lifecycle, and storage fault smokes |
| Consumer compatibility | CLI and artifacts | Schema validation, four-runtime report parity, offline browsers, installed Hex API, escript/npm execution, reproducible packages |
| Mutation semantics | Core and engine | Dogfood score mutation and five fixed official-library corpora with exact expected outcomes and source hashes |
| Assurance completeness | Score dogfood runner | Exact admitted and rejected candidate identities, fresh single-runtime measurements, and negative controls for missing, duplicated, cached, timed-out, erroneous, and inconsistent results |

The finite aggregation check covers the engine's one-runtime and four-runtime category domains, including missing evidence.
Diagnostic round trips cover all outcome constructors, all ASCII scalar values, empty reasons, mixed Unicode and escapes, and text exceeding the process output limit.
These are executable JSON-boundary checks, not an unbounded proof of the JSON library.
It is an exhaustive executable check at that bound, not an unbounded theorem about every list length or arbitrary diagnostic text.
The graph check covers every directed graph on three named packages, including self-edges and unreachable cycles.
It checks the actual filesystem adapter against a separately computed reachability relation.
This is a finite executable check, not an induction proof for arbitrary graph size.
A pinned compiler control accepts a POSIX relative dependency path containing a colon before the capture regression checks its package-relative resolution.
Windows drive-prefix interpretation is conditional on the host platform.
Tomlet document editing and recursive filesystem capture remain outside the restricted proof translator's semantics.
The process-text corpus follows the [UTF-8 replacement decoder](https://encoding.spec.whatwg.org/#utf-8-decoder) and preserves a leading byte order mark as text.
The exhaustive two-byte comparison covers that finite byte domain, and the longer vectors cover valid and malformed three-byte and four-byte boundaries.
Erlang's Unicode decoder and the JavaScript runtime decoders remain external library assumptions.
These native checks do not establish a theorem for arbitrary-length byte streams.
The [local dependency ADR](adr/capture-local-dependencies-in-snapshots.md) records the model boundary and capture decision.
External compiler and OS behavior remain integration assumptions.
Tests cannot establish arbitrary test-program isolation or correctness.
The dogfood runner compares report records and identity lists outside the translator's admitted fragment.
Its negative controls exercise missing or duplicated candidates, unexpected compiler rejections, skipped work, wrong or cached runtimes, timeouts, execution errors, and inconsistent scores.
These finite checks do not prove the runner or compiler correct for every possible report.
Absolute path normalization uses string splitting, list reduction, and platform root conventions outside the closed translator.
Its fixed reference corpus covers every sequence of zero through five components from node, dot, parent, whitespace, and Unicode controls under three root forms.
It also checks idempotence, root clamping, literal POSIX backslashes, and actual report-history reads through dot and parent aliases.
These checks cover that finite corpus and the native boundaries; symlink aliases and arbitrary filesystem path semantics are not proven.

## Gates

`mise run check` runs compilation, unit tests, documentation, metadata, dependency/security checks, and Rust derivation checks.
`mise run test-integration`, `test-matrix`, `test-property`, `test-faults`, `dogfood`, `test-ecosystem`, and `package` exercise the native obligations above.
Properties use 10,000 cases and seed 24301.
The ecosystem corpus identities and expected outcomes are fixed in the maintained runner.
Score dogfood requires all 50 compiler-admitted candidates to fail the complete Erlang unit suite without cached outcomes.
It compares both the admitted identities and the seven compile-invalid identities with a separate compiler-validation run.
All 57 candidates must appear exactly once in the expected partition.
Six rejected score candidates occur in clause guards, where runtime schemata are unsupported.
The 50 executions do not establish detection at those guard sites.
It checks the individual runtime outcomes independently of the reported score.
Timeouts and execution errors leave this assurance inconclusive, even when the product's ordinary scoring counts a timeout as detected.
The per-mutant limit is one minute, and the campaign limit is 15 minutes with two workers.
Deadlines only stop resource use and never establish a passing verdict.

The protected candidate and publication workflows run that inventory.
Their `release-candidate` task also requires `mise run prove`.
A skipped, empty, failed, or inconclusive required check leaves the corresponding obligation open.
Local macOS results do not establish Linux or Windows behavior, hosted OIDC, signatures, or publication.
