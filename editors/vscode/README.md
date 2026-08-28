<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# gleam-mutants for VS Code

Surviving mutants from `gleam-mutants` as editor diagnostics, tests that kill
them one keystroke away, and Smartest evidence findings ready to inspect,
review, and replay.

The extension is a thin shell around the CLI. Everything that reads a report,
parses a suggestion, or decides what a squiggle says lives in `src/core`,
which never imports `vscode` and is unit-tested on real CLI output captured in
`fixtures/`. The editor is reached through one interface, `src/vscode/host.ts`,
so the flows in `src/flows` are tested against a fake editor rather than a
real one.

## Install from source

There is no marketplace listing yet. Build it out of this repository:

```sh
cd editors/vscode
npm ci
npm run build
```

Then load it, either straight from the folder — **Developer: Install Extension
from Location…** in the command palette, pointing at `editors/vscode` — or as
a package:

```sh
npx @vscode/vsce package
code --install-extension gleam-mutants-vscode-0.1.0.vsix
```

It needs VS Code 1.90 or newer, and Node.js 20 or newer to build. The CLI
itself is not bundled: the extension runs whatever `gleam_mutants.command`
names, which by default is the copy in the open workspace's dev dependencies.
Smartest has its own `gleam_mutants.smartestCommand` setting so the two Gleam
entry modules cannot be mixed up.

## What you get

Surviving mutants of the last `run` are published as warnings on the lines
they change, one per mutant, carrying the mutant's id. The report is reread
whenever it is written, so a `run` in a terminal — yours, or a colleague's
report pulled from CI — updates the editor without a command.

On any of those warnings the lightbulb offers two quick fixes:

- **Generate a test that kills this mutant** runs `suggest --json` for that
  one mutant, then `apply --yes --json`, then opens the test module it wrote
  at the test it added. A mutant no input can tell apart is reported as
  probably equivalent instead, and one no test can be written for is reported
  with the reason the CLI gave.
- **Explain this mutant** runs `explain` and shows the output in the
  `gleam_mutants` output channel.

## Commands

| Command | What it does |
| --- | --- |
| `gleam_mutants.runFile` | mutation-tests the active file in a terminal, where its progress can be watched and interrupted |
| `gleam_mutants.suggestFile` | suggests a test for every surviving mutant in the active file and offers them as a list, the generated source as each entry's detail; picking one writes it |
| `gleam_mutants.explainMutant` | explains one mutant into the output channel, picking from the active file's survivors when it is invoked without one |
| `gleam_mutants.refreshDiagnostics` | rereads the report and republishes the survivors, for when the watcher has missed a write |
| `gleam_mutants.smartestFindings` | lists the versioned evidence ledger, then explains the selected witness in the output channel |
| `gleam_mutants.smartestReview` | explains a pending finding, then accepts it with a required review note or rejects it with an audit reason; unjudged evidence may be given an independent oracle |
| `gleam_mutants.smartestReplay` | selects an accepted or inbox witness and replays it in a visible terminal that can be interrupted |

The quick fix runs a fifth command, `gleam_mutants.generateTest`, which takes
a file and a mutant id. It is deliberately not in the palette: without a
mutant to name it could only fail.

## Settings

| Setting | Default | What it is |
| --- | --- | --- |
| `gleam_mutants.command` | `["gleam", "run", "-m", "gleam_mutants", "--"]` | how to run the CLI, executable first. Set it to `["gleam-mutants"]` to use the escript or npm binary instead |
| `gleam_mutants.reportPath` | `reports/mutation/mutation.json` | where `run` leaves its report, relative to the workspace root. Both the diagnostics and the watcher follow it |
| `gleam_mutants.smartestCommand` | `["gleam", "run", "-m", "smartest", "--"]` | how to run the Smartest evidence CLI, executable first |
| `gleam_mutants.timeoutMs` | `300000` | how long one `suggest`, `apply` or `explain` may take. Zero means no budget. `run` is not bound by it: it runs in a terminal you can stop |

Review never turns a differential result into truth by accident. Accepting an
`unjudged` finding without entering an independent oracle keeps it unjudged;
the review note records the decision but does not manufacture a correctness
oracle. A replay is foreground work and leaves no background service behind.

## Suggesting a test runs your code

`suggest` and `apply` are not static analysis. To find an input that tells a
mutant apart from the original, the CLI compiles a probe into a copy of the
workspace and **calls the public function under test for real**, with inputs
it chose. A function that writes a file, sends a request, or drops a table
does those things while a test for it is being suggested.

The mutation `run` behind the diagnostics is bound by the same caveat: it runs
your test suite. Read [side effects](../../docs/suggest.md) in `docs/suggest.md`
before pointing either at code that reaches outside itself, and read the
generated tests before you keep them.

## Erlang only

`suggest`, `apply` and `explain` — and so both quick fixes — support the
Erlang target alone. A workspace whose tests run on JavaScript gets `GMU8001`
back, shown as an error with the failing line. Mutation `run` itself supports
both targets; only the test-writing half is Erlang-only.

## Layout

| Path | What it holds |
| --- | --- |
| `src/core/stryker.ts` | the mutation report and the surviving mutants in it |
| `src/core/suggest.ts` | Suggest JSON v1 and the outcome for one mutant |
| `src/core/apply.ts` | Apply JSON v1 and the notification it summarises to |
| `src/core/cli.ts` | building an argument list, running it, reading its JSON |
| `src/core/smartest.ts` | Smartest's stable finding-line protocol and evidence states |
| `src/core/diagnostics.ts` | one surviving mutant as one diagnostic |
| `src/core/json.ts` | reading one JSON value, and quoting it when it is not one |
| `src/flows/` | the commands, the quick fix and the refresh, editor-agnostic |
| `src/vscode/host.ts` | everything a flow may do to the editor, as one interface |
| `src/vscode/` | the adapter and the code action provider that import `vscode` |
| `src/extension.ts` | activation: the command table, the provider, the watcher |
| `scripts/smoke.mjs` | the real CLI, on the real fixture project |
| `fixtures/` | real CLI output; see `fixtures/README.md` |

## Development

```sh
npm ci
npm run lint    # typecheck + tests
npm test        # vitest run
npm run build   # esbuild bundle into dist/extension.js and dist/core
npm run smoke   # the real CLI on fixtures/boundary_project
```

`npm run smoke` is the only gate that starts a process: it mutation-tests
`fixtures/boundary_project` with the engine in this repository, reads the
report it wrote with the built core, and asks `suggest` for a test that kills
the first mutant that survived. It needs Gleam and Erlang on the path, takes
about half a minute, and removes the `reports/` directory it created.

All five run together from the repository root as one gate:

```sh
mise run vscode
```

It is kept out of `mise run check`, which must work with no network: the first
thing it does is `npm ci`.

The tests never launch VS Code: the core is pure, the flows go through a fake
host, and the glue that is left stays small enough to read.

## Licence

MIT OR Apache-2.0, the same as the rest of the repository. See `LICENSE-MIT`
and `LICENSE-APACHE` at its root.
