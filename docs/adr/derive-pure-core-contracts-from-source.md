---
date: 2026-10-30
---

<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Derive pure core contracts from source

## Status

Proposed.

## Context

Mutation decisions depend on interval ordering, outcome priority, count conservation, selection uniqueness, and path filtering.
Example tests alone do not establish these properties for arbitrary intervals or list lengths.
The existing source-derived limit and filename contracts cover a small part of this core.
Gleam executables, library string operations, floating-point behavior, and external effects are outside the configured verifier's native semantics.

## Decision

Extend the source-derived Lean gate with explicit contracts for the pure core.
Use a typed expression translator for the complete span module.
Use closed syntax rules for the other admitted modules, capturing actual constants, operators, mappings, and branches.
Reject source outside those rules and changes to the relevant public type domains.
Keep contracts independent of the translators and bind verification to copies of the current production sources.

Prove interval construction and ordering, arbitrary finite outcome aggregation and integer scoring, explicit exit policy, operator identity, unique selection, path component reduction, and wildcard boundaries.
Model percentage calculation as a symbolic sequence of conversions, division, and multiplication.
Do not infer IEEE rounding guarantees from integer or symbolic arithmetic proofs.
Represent strings by scalar sequences and glob input by grapheme symbols with distinct wildcard and separator constructors.
Keep compiler, standard-library, Unicode segmentation, and finite-representation assumptions explicit.

Require the complete named theorem inventory, approved axiom dependencies, fresh kernel replay, source-change refusal, and a rejecting source mutation for each assessed contract family.
Retain the original contracts' stronger requirement of no axioms.
New general proofs may use only Lean's standard logical axioms, `propext`, `Classical.choice`, and `Quot.sound`.
Reject project axioms, incomplete proofs, native evaluation axioms, empty inventories, and tool failures.
Replay preserved parser corpora and round-trip properties in the fast gate.
Compare selected source-derived models with actual Gleam execution on all four runtimes.

A detached specification would not detect implementation drift.
Treating finite reference checks as unbounded proofs would overstate their scope.
Replacing the Gleam product with another implementation language would change its supported package and maintenance contract.
These alternatives are rejected.

## Consequences

General list and integer invariants become release requirements without changing the published package API.
Unsupported source changes require an explicit translator and contract update.
The translators remain a reviewed trust boundary rather than a verified Gleam compiler.
Native comparisons and mutation controls test that boundary but do not prove it correct for every possible program.
External calls, AST parsing, cryptography, OS behavior, process execution, Unicode libraries, and floating-point rounding retain separate native obligations.
The [contract inventory](../verification.md) identifies each model domain and its remaining assumptions.
