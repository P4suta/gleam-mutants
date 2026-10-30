---
date: 2026-10-30
---

<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Verify drafts before registry publication

## Status

Proposed.

## Context

The [candidate publication decision](publish-verified-candidate-artifacts.md) separates GitHub write authority from registry publication.
GitHub's [release API](https://docs.github.com/en/rest/releases/releases#list-releases) hides drafts from tokens without push access.
A registry phase with Contents read permission can't use draft lookup as its publication prerequisite.
Local decision proofs omit that incompatibility unless their model includes phase operations and authority.

## Decision

Keep draft creation and complete asset readback in the approved GitHub write phase.
Registry phases verify that preparation through the successful named draft job in their own active protected controller run.
Bind the handoff to repository and owner IDs, workflow, event, controller source, run, and producer attempt.
Parse controller run and attempt through one pure boundary that returns nonzero identity types.
Reject foreign, missing, ambiguous, incomplete, or later failed producers.
An earlier successful producer remains usable for a partial rerun of the same controller source.

Use one pure production dispatcher to select the draft evidence operation for each phase.
Prove its reader selection and call counts with Kani.
Parse the actual workflow in the fast gate and check its permissions, protected environments, candidate bindings, prerequisite graph, and failure propagation.
Exercise the shared registry planning function in a read-only job after draft preparation and before registry approval.
Finalization checks the current complete GitHub draft and both registry archives before making the release immutable.

Giving GitHub write authority to registry jobs would weaken the separation of capabilities.
Assuming that an invisible draft is absent would repeat the failed boundary assumption.
A separate signed receipt would add another artifact and signer without removing the existing dependence on GitHub's job execution and metadata.
These alternatives are rejected.

## Consequences

Registry jobs need no GitHub release authority, and their shared prerequisites run before access to registry secrets.
The handoff attests to completed preparation rather than current draft visibility.
GitHub's truthful metadata, successful execution of the attested controller, protected workflow source, and token semantics remain external assumptions.
The workflow contract binds all phase commands to the same candidate inputs and rejects skipped or ignored preparation failures.
External changes to a mutable draft remain possible before finalization; the final write phase checks its current bytes again.
The design does not provide an atomic transaction across GitHub, Hex, and npm.
The [verification contracts](../verification.md) define the proofs, native fault controls, and hosted readiness check.
