---
date: 2026-10-29
---

<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Capture local dependencies in snapshots

## Status

Proposed.

## Context

Relocating only the target package breaks relative dependencies outside its directory.
An absolute dependency path can also make workers compile live inputs that their cache identity does not include.
Gleam supports [local dependencies and Git subdirectory paths](https://gleam.run/documentation/gleam-toml-reference/#path-dependencies), which have different meanings.
Discovery must remain available without compiling or resolving dependencies.

## Decision

Before compiler validation or execution, capture the reachable local dependency closure inside the target snapshot.
Include the target's production and development dependencies and each dependency's production dependencies.
Reject cycles, conflicting package locations, mismatched names, links, and special files.
Recheck captured inputs before accepting the closure.

Rewrite copied configuration and lockfile paths to stable relative locations under `.gleam_mutants/dependencies/`.
Preserve locked registry packages and original files.
Include sorted dependency names and content digests in the snapshot identity.
Workers duplicate the captured closure, and retained snapshots remove obsolete inputs.
Git subdirectory paths retain their original meaning.

Referencing the original absolute directories would preserve live inputs and omit their contents from cache identity.
Rejecting all local dependencies would contradict the supported installation workflow.
Preserving an arbitrary external directory hierarchy would enlarge captures and complicate ownership and cleanup.

## Consequences

Local dependencies compile from captured inputs on every worker.
Changes to their sources or tests invalidate cached outcomes.
Capture and input verification add filesystem work proportional to the reachable closure.
The [verification contracts](../verification.md) distinguish native graph and compiler checks from the integer predicate proofs.
Arbitrary test programs retain their ordinary filesystem permissions.
