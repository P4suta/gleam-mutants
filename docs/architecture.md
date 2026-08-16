<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Architecture

The pure core owns byte spans, operators, stable IDs, catalogue construction,
nested interval instrumentation, outcomes, scores, and exit policy. Effects are
provided through concrete filesystem, compiler/process, clock, cache, and
reporting capabilities.

The opaque phase pipeline is:

```text
Discovered -> Snapshotted -> BaselinePassed -> Validated -> Instrumented -> Completed
```

A transition requires the preceding phase type, so a mutant cannot be executed
before the baseline passes. Discovery uses Glance AST locations, but output is
assembled from byte slices of the original source rather than pretty-printing.
This preserves comments, whitespace, Unicode, and CRLF. An interval forest
allows nested mutations to coexist in one instrumented source.

Each candidate is compiler-checked. A failing batch is split recursively until
the invalid candidate and compiler diagnostic are isolated. Rejected candidates
are absent from the normal catalogue and available through `--explain` and JSON.

The snapshot manifest is sorted and excludes `.git`, `build`, tool caches, and
other generated data. Links and special files are rejected. A private runtime
module generated in the snapshot reads `GLEAM_MUTANTS_ACTIVE`; no permanent
runtime API is required in the target package.

A bounded worker pool receives independent copies of the instrumented snapshot.
Workers are reused between mutant waves so their local build cache remains warm;
no workspace is shared by concurrently running tests. Timeout cleanup terminates
the entire descendant process tree (TERM then KILL on POSIX, `taskkill /T` on
Windows), and interruption is preserved as exit 130.

Matrix aggregation is intentionally conservative: any surviving runtime makes
the mutant survived; only mutants killed in every runtime are killed. Timeouts
remain a distinct detected outcome. A failed baseline in any selected runtime
aborts without producing a quality score.
