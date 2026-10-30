---
date: 2026-10-30
---

<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Preserve lexical path roots

## Status

Proposed.

## Context

Workspace discovery walks absolute parent directories until it finds `gleam.toml` or reaches a root.
Dropping the final slash-separated component loses the root of `/child` and changes `C:/child` into the drive-relative `C:`.
It also removes the share boundary when walking a UNC root.
The [regression](../../test/path_test.gleam) and independent parent-root contract reject the previous behavior.

## Decision

Represent lexical path roots and remaining components together in the private `RootedParts` type.
Share root extraction between absolute normalization and parent selection.
Recognize a parent operation's Windows root through a nonempty UNC server/share or an ASCII drive letter followed by a colon and separator.
Remove trailing empty components and then one final component while retaining the complete root prefix.
Keep root directories fixed points and preserve literal whitespace and Unicode in components.

Prove root construction, parent preservation, component splitting, ASCII drive admission, and progress for nonempty canonical component lists in the source-derived model.
Compare canonical absolute parents with Node's independent POSIX and Windows path implementations.
Keep filesystem resolution, symlink identity, and OS namespace behavior outside these lexical claims.

Stopping workspace discovery before the root would continue to miss valid root-level projects.
Returning a bare Windows drive would retain dependence on a per-drive current directory.
Duplicating special cases in individual callers would leave other filesystem adapters with the same root-loss behavior.
These alternatives are rejected.

## Consequences

Workspace discovery can inspect a root-level project and terminates when its root has no project manifest.
The existing parent callers share the correction.
Empty relative paths and canonical relative-file parents without root-like prefixes retain their existing results.
Trailing separators are ignored when selecting a parent.
The shared root extractor preserves the existing absolute-normalization behavior.
The new contracts require a fresh distribution candidate because the published implementation changes.
