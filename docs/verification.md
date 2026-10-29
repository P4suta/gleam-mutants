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

[Independent contracts](../verification/Contracts.lean) require jobs in 1–32, explicit timeouts in 100–86,400,000 milliseconds, and interruption exactly at 130 or 143.
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
The gate requires all three named theorems to have no axioms and replays their compiled module through a fresh kernel.
It then changes the source jobs bound from 32 to 33 and requires an equality-proof failure against the unchanged contract.
A successful broken proof or another kind of tool failure fails the gate.
The original production source must still match the copy at completion.
Generated models and logs are evidence for that invocation; later invocations generate fresh evidence.

See Lean's [proof validation documentation](https://lean-lang.org/doc/reference/latest/ValidatingProofs/) for the distinction between elaboration and kernel replay.

## Native boundaries and checked alternatives

No maintained Gleam-native verifier is configured for Glance AST traversal, filesystem operations, or external process trees.
The restricted translator deliberately rejects those semantics.
Encoding their effects as assumptions in Lean would not verify the actual adapter.
The project therefore requires native boundary checks alongside the supported predicate proofs.
Reassess this boundary when a maintained verifier can import the relevant Gleam implementation or when the implementation is decomposed into another supported pure fragment.

| Affected contract | Production path | Required check and boundary |
| --- | --- | --- |
| Option admission | API, engine, configuration, CLI | Three source-derived contracts; invalid root, job, timeout, and command regressions |
| Shared API and results | API and canonical types | `api_smoke` compares actual engine scores, selection, policy, identities, and outcomes |
| Report persistence | API and report adapters | Default no-write and explicit persistence; installed Hex consumer and report storage faults |
| Host preservation | Process FFI, engine, CLI | Child exit 130/143 during compilation, baseline, and mutation batches on all four runtimes; API continuation and CLI exit |
| Input preservation | Snapshot and instrumenter | Byte digests, spaces, Unicode/CRLF, link rejection, generated-link cleanup, 10,000 fixed-seed properties |
| Compiler classification | Validation batches | Mixed and all-rejected catalogues; invalid mutants remain rejected; interruption aborts validation |
| Baseline and aggregation | Execution and outcome core | Baseline failure returns an error; all 341 outcome-category lists of length zero through four match an independent priority reference |
| Selection and cache | Engine, impact protocol, cache | Automatic and full-suite parity, conservative confirmation, all-hit behavior, runtime/compiler identity |
| Cleanup and durability | Snapshots, locks, report storage | Process-tree, interruption, workspace-lock, report lifecycle, and storage fault smokes |
| Consumer compatibility | CLI and artifacts | Schema validation, four-runtime report parity, offline browsers, installed Hex API, escript/npm execution, reproducible packages |
| Mutation semantics | Core and engine | Dogfood score mutation and five fixed official-library corpora with exact expected outcomes and source hashes |

The finite aggregation check covers the engine's one-runtime and four-runtime category domains, including missing evidence.
It is an exhaustive executable check at that bound, not an unbounded theorem about every list length or arbitrary diagnostic text.
External compiler and OS behavior remain integration assumptions.
Tests cannot establish arbitrary test-program isolation or correctness.

## Gates

`mise run check` runs compilation, unit tests, documentation, metadata, dependency/security checks, and Rust derivation checks.
`mise run test-integration`, `test-matrix`, `test-property`, `test-faults`, `dogfood`, `test-ecosystem`, and `package` exercise the native obligations above.
Properties use 10,000 cases and seed 24301.
The ecosystem corpus identities and expected outcomes are fixed in the maintained runner.
Deadlines only stop resource use and never establish a passing verdict.

The protected candidate and publication workflows run that inventory.
Their `release-candidate` task also requires `mise run prove`.
A skipped, empty, failed, or inconclusive required check leaves the corresponding obligation open.
Local macOS results do not establish Linux or Windows behavior, hosted OIDC, signatures, or publication.
