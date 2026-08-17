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

The native `RunReport` remains the lossless source of truth, including runtime
matrix and cache details. A pure deterministic projection emits report schema
3.9.0 data with `schemaVersion: "1.0"`. Files and mutants are sorted, original
source is preserved byte-for-byte, and byte spans are recalculated as 1-based,
start-inclusive/end-exclusive UTF-16 locations. The projection deliberately
omits coverage fields, project root, full configuration, and extensions.

The offline renderer decodes a generated pure-Gleam Base64 module containing
the official Mutation Testing Elements 3.9.0 IIFE. JSON is stored in a
non-executable `application/json` script element with HTML-significant and line
separator characters escaped. The official bundle and a fixed bootstrap are
the only executable scripts and are authorized by CSP hashes.

Project reports are staged beside their fixed targets and atomically renamed.
The destination is validated before snapshotting and again before writing;
existing targets must be regular files. The effective report directory is not
copied or hashed, so a previous run cannot affect discovery or cache identity.
