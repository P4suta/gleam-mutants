---
date: 2026-10-30
---

<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Preserve confirmed release identities

## Status

Proposed.

## Context

A successful [GitHub release creation](https://docs.github.com/en/rest/releases/releases#create-a-release) supplies a release ID.
A later collection lookup makes a separate observation and must not replace that confirmed identity.
The [draft preparation decision](verify-drafts-before-registry-publication.md) separates GitHub write authority from registry authority.
That separation must also preserve the exact draft across creation, asset uploads, and final publication.

## Decision

Use one pure acquisition dispatcher that discovers once and creates only after confirmed absence.
Retain the selected or created value, propagate discovery and creation errors, and permit no automatic write retry.
Validate each draft's nonzero ID, candidate tag, and unpublished state before using it.
Allow an explicit existing draft ID for recovery, with canonical readback and the same validation.
Keep the version tag authoritative for the candidate source.

Address asset uploads by the validated release ID rather than discovering the target again by tag.
Export that ID from the draft job only after all assets match the candidate.
Bind finalization to this output, read the draft by ID, and publish that same ID.
Require the publication response and readback to confirm its tag, ID, immutable state, and complete assets.
Keep registry jobs read-only with respect to GitHub and preserve every protected environment.

Repeated collection reads or backoff would add a visibility assumption without retaining the creation result.
Discovering a target independently for each upload or finalization could change the selected resource.
Deleting a partial draft would discard useful identity and evidence.
These alternatives are rejected.

## Consequences

Recovery preserves a matching partial draft and the original candidate bytes.
The workflow carries a validated numeric identity across its GitHub write phases.
Source-bound Kani checks establish acquisition identity and call-count invariants under supplied operation results.
Native HTTP fixtures check the pinned client's protocol with isolated credentials and controlled responses.
JSON interpretation, integer parsing, production authorization, TLS, and provider responses remain native or external boundaries.
The [verification contracts](../verification.md) define the checks and their limits.
