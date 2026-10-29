---
date: 2026-10-29
---

<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Mutation-testing package boundary

## Status

Accepted.

## Context

A useful mutation-testing tool must measure the sensitivity of existing tests to controlled source changes.
Discovery, compiler validation, isolated execution, conservative aggregation, and inspectable reports form one coherent contract.
A general test framework, automatic test generation, and editor ownership introduce separate public APIs and dependencies.
They expand the maintenance surface without being necessary to measure existing tests.

The existing operators, source identities, JSON formats, and supported runtimes constrain the refactor.
Library callers also need typed results without terminal output or host termination.

## Decision

The package provides the CLI entry module, `gleam_mutants/api`, and `gleam_mutants/types`.
The engine and CLI use the same canonical domain types.
Other modules remain internal.
The API supports discovery, compiler validation, and mutation execution.
It captures child output and returns errors, including interruption, to its caller.
Report persistence requires an explicit library option.
The CLI owns rendering, annotations, and process exit.

The product retains the 15 operators, snapshots, worker pool, cache, optional provider-independent test selection with full-suite fallback, scoring, and existing report formats.
It removes Smartest, automatic test generation, generation schemas, and the VS Code extension.
The CLI exposes `run`, `list`, `doctor`, `init`, `report`, and `cache`.
Compiler explanations remain available through `list --validate --explain`.

Assurance remains project development infrastructure.
The project keeps its own property, fault, ecosystem, packaging, and mutation checks.
Changed integer predicates are translated from the actual restricted Gleam source into Lean and checked against independent contracts.
The translation rejects unsupported syntax and an incomplete inventory.
External filesystem, compiler, and process semantics require native integration checks.
The [verification contracts](../verification.md) define the model link and its limits.

Keeping the combined verification framework would preserve multiple unrelated product contracts.
Providing only a CLI would prevent typed embedding.
Splitting the removed features into additional packages would preserve their maintenance burden before the mutation-testing boundary is established.
These alternatives are rejected for this scope.

## Consequences

Consumers can embed the same engine that the CLI uses.
The product has one purpose and a smaller dependency and distribution surface.
Consumers of removed modules and commands must follow the [migration guide](../migration.md).
Test generation and editor integrations may be developed independently against the public API or reports.
They are outside this package's ownership.

The proof translator, compiler, and runtime remain explicit trust boundaries.
The scoped proofs do not certify the entire engine or arbitrary test programs.
Platform and publication claims still require the protected release evidence.
