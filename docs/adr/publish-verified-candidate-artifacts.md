---
date: 2026-10-29
---

<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Publish verified candidate artifacts

## Status

Proposed.

## Context

A release must distribute the bytes whose compatibility and security evidence was checked.
Rebuilding inside a privileged publishing job breaks that identity and executes build tooling with production authority.
A version-proposal bot must also leave a checked PR without silently publishing a release or waiting for a production approval.
Partial provider success and GitHub job reruns require recovery without replacing immutable outputs or confusing producer attempts.

## Decision

Keep ordinary CI to one Linux gate and put the complete proof, compatibility, mutation, packaging, and artifact campaign in a manual protected-main candidate workflow.
Bind candidate artifacts and verification receipts to the full source, version, builder identity, run, actual producer attempts, targets, sizes, and digests.
An unsigned candidate rehearsal performs no signing, tag creation, release creation, or registry writes.
An optional fresh attestation job signs the verified candidate and an npm-compatible SHA-512 subject without executing candidate code.

Use an unpublished Rust preparation tool with a pure `no_std` decision core and native Kani proofs.
Keep mutation operations in a separate executable used only by the protected publication workflow.
Compile and attest controller binaries before privileged jobs download, verify, and execute them.
Separate GitHub draft creation, Hex upload, npm upload, and final publication behind distinct protected environments.
Use the exact prepared archives and original provenance throughout these phases.
Refuse conflicting outputs and allow retries only after observing missing or identical outputs.
Retain the existing immutable-release and version-tag protections.

Version proposals use a separate automatic environment, skip release creation, and dispatch ordinary CI when GitHub suppresses the token-created PR event.
Active credentials and registry trust registrations are deferred until their issuance and first publication are authorized.

Rebuilding from a tag in a single privileged job would lose the candidate byte identity and combine unrelated authority.
Unconditionally rerunning uploads would obscure uncertain partial success.
Maintaining a separate general release framework would expand the product scope.
These alternatives are rejected.

## Consequences

Preparation can be rehearsed without publication credentials or production approvals.
Release operators can inspect a concrete read-only plan and retained evidence before approving irreversible effects.
Publication requires a still-retained, attested candidate and later validated registry ownership and authentication.
Artifact retention, external providers, compiler behavior, and native adapters remain explicit operational assumptions.
The [release guide](../releasing.md) describes the exact commands, credentials, and recovery boundary.
