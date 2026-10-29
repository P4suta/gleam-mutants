---
date: 2026-10-29
---

<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Preserve filesystem entry boundaries

## Status

Proposed.

## Context

Treating a POSIX filename's backslash as a separator can redirect a snapshot read, write, or deletion outside its root.
Removing whitespace can select another file.
Copying a private workspace into a public temporary directory can also disclose its contents.
Concurrent runs share cache ancestors but own separate snapshot roots.

## Decision

Preserve physical path spelling and translate native Windows separators at the platform boundary.
Validate each enumerated component before joins and exclusions.
Refuse empty, dot, parent, separator-bearing, and NUL-bearing components.
Backslash-bearing POSIX names remain unsupported because catalog identities use portable separators.

Establish owner-private POSIX roots before copying source.
Fresh exclusive roots must still be empty after permissions are established.
Only their creator cleans up a failed fresh root.
Shared cache ancestors accept existing directories and never use that empty-root cleanup protocol.
Refuse unsafe retained roots rather than writing through files that another user could already have opened.
Collection takes the workspace lock before removing a retained copy.

Keep the filename decision pure and derive its constructive scalar-sequence model from the complete source module.
Use the existing [verification gate](../verification.md) for independent contracts, kernel replay, and a deliberately broken parent-component check.
Use native tests for permissions, process interleavings, and actual filesystem effects.

Normalizing every path would preserve the unsafe reinterpretation.
Accepting backslash filenames throughout the catalog would require changing identity and instrumentation contracts.
Treating shared cache ancestors as exclusive empty roots would let one participant delete another's state.

## Consequences

Supported names preserve whitespace and Unicode.
Source directories named `build` are captured while package build artifacts remain excluded.
Busy workspaces can exceed the retention count until collection can acquire their locks.
Directory creation and permission changes remain separate OS operations; the fresh-root emptiness check precedes sensitive writes.
Host-controlled ancestors, Windows ACLs, filesystem atomicity, and trusted test-program effects remain external assumptions.
The scalar-sequence theorem proves the admission decision under its stated string refinement, not arbitrary filesystem behavior.
