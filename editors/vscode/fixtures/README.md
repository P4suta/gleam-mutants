<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Fixtures

Every JSON file here is real output of the `gleam-mutants` CLI, captured
verbatim from `fixtures/boundary_project` in this repository. Nothing is
hand-written: the point of these files is that the core parses what the tool
actually prints, not what we remember it printing.

Regenerate them from the repository root with:

```sh
gleam run -m gleam_mutants -- run --root fixtures/boundary_project
cp fixtures/boundary_project/reports/mutation/mutation.json \
  editors/vscode/fixtures/mutation.json
rm -rf fixtures/boundary_project/reports

gleam run -m gleam_mutants -- suggest --root fixtures/boundary_project --json \
  > editors/vscode/fixtures/suggest.json

gleam run -m gleam_mutants -- apply --root fixtures/boundary_project --json \
  > editors/vscode/fixtures/apply-dry-run.json

# `apply --yes` writes into the workspace it is pointed at, so the verified
# capture is taken on a throwaway copy rather than on the fixture itself.
cp -r fixtures/boundary_project "$TMPDIR/boundary_copy"
rm -rf "$TMPDIR/boundary_copy/reports" "$TMPDIR/boundary_copy/build"
gleam run -m gleam_mutants -- apply --root "$TMPDIR/boundary_copy" \
  --yes --verify --json > editors/vscode/fixtures/apply-verified.json
```

`run`, `suggest` and `apply --json` print exactly one JSON value on stdout;
the "Compiling…/Running…" lines go to stderr and are not part of these files.

| File | Command | What it pins |
| --- | --- | --- |
| `mutation.json` | `run` | Stryker mutation-testing-report-schema 3.9.0, 18 mutants over `src/boundary.gleam`, 8 of them `Survived`, one `CompileError` spanning two lines |
| `suggest.json` | `suggest --json` | Suggest JSON v1: 8 suggestions, 2 indistinguishable, 5 unsupported, 2 skipped functions, and kill sets naming mutants that have no suggestion of their own |
| `apply-dry-run.json` | `apply --json` | Apply JSON v1 with `verification: null` — the dry run that writes nothing |
| `apply-verified.json` | `apply --yes --verify --json` | Apply JSON v1 with 11 verified mutants: 5 `new`, 6 `already_killed` |

The mutant ids in these files are stable: an id carries the digest of the
source it was cut from, and `fixtures/boundary_project/src/boundary.gleam` is
part of the repository. Editing that module changes every id here, so
regenerate all four files together when it changes.
