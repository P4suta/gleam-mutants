<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Suggesting tests

A surviving mutant is a change to your source that every test still passes on.
`suggest` looks for the call that would have noticed, `explain` shows one of
them in detail, and `apply` writes the tests into your project.

These three commands run on the **Erlang target only**. They compile and run
generated probe code, and only the Erlang runtime is supported for that today.
`run`, `list`, and reporting are unaffected and still cover every runtime.

## What it does

The probe copies the workspace into a disposable snapshot and, for each public
function in the selected files, generates a module that calls the function
twice on the same input: once with no mutant active, and once with each mutant
of that function switched on. Both calls happen in one VM, one after the other,
so the two answers are compared directly rather than inferred from whether a
test suite went red.

The inputs are derived from the function's own type annotations, generated
pseudo-randomly from a fixed seed, so a rerun proposes the same tests. When an
input separates a mutant from the original, it is **shrunk**: the search keeps
looking for a smaller input that still separates them, which is why the
proposed test reads `is_positive(0)` rather than `is_positive(-2_147_483_648)`.

One call sees every mutant of the function at once, so a separating input is
reported with the **kill set** of every mutant it tells apart, not just the one
it was found from. Those kill sets are then **minimised** per function: the
fewest tests that still kill everything any single test in the run could kill.
Seven mutants often come back as three tests.

## Commands

```sh
gleam run -m gleam_mutants -- suggest
gleam run -m gleam_mutants -- suggest --survivors
gleam run -m gleam_mutants -- explain <mutant-id-prefix>
gleam run -m gleam_mutants -- apply --verify
gleam run -m gleam_mutants -- run --suggest
```

`suggest` prints one block per suggestion — the mutant, the source it rewrites,
and the test that kills it — then the import lines each module under test
needs, then a summary. `--json` emits one Suggest JSON v1 value instead.

`explain` takes a mutant id prefix as its first argument and reports that one
mutant: its status, the input that separates it, what each side answered, and
the test to write. It never minimises, so it answers about the mutant you
asked about even when another suggestion would cover it.

`apply` plans the same suggestions into your own test modules. The tests for a
module go into `test/<module path with "/" replaced by "_">_test.gleam`, so
`src/boundary.gleam` is tested by `test/boundary_test.gleam` and
`src/app/util.gleam` by `test/app_util_test.gleam` — one flat test directory
rather than a tree nobody asked for. The file is created when it does not
exist and appended to when it does. Without `--yes` it is a dry run: it prints
the files it would touch, the tests it would add, and the tests already
present, so you can see which file it means before it writes anything. With
`--yes` it writes them, and a file that gains nothing is reported as unchanged
and left alone, formatter included. `--json` emits one Apply JSON v1 value
instead, whose shape is pinned by `schema/apply-v1.schema.json`.

`--verify` implies `--yes` and then runs the mutation engine again over the
source files those suggestions came from, reporting whether every mutant they
claim to kill is dead now. It checks every generated test in those modules,
the ones this run wrote and the ones it skipped as already present alike, so
running it a second time re-checks the suite rather than reporting that it had
nothing to do. A mutant that hangs the suite is counted dead exactly as the
mutation score counts it, and the outcome of each mutant is reported by name.
Exit 0 means every mutant is dead; exit 1 means at least one is not; exit 2 is
a tool failure. The verification run covers only the files those suggestions
came from, so it writes no project report and stores nothing in the report
history: `report latest`, `report list`, and a later `suggest --survivors` all
still answer from your last real `run`.

`run --suggest` appends the suggestions for that run's own survivors under the
normal summary. It never changes the run's exit code, and it is refused
together with `run --json`, which prints exactly one JSON value; use
`suggest --survivors` for a machine-readable answer.

### Flags

`suggest`, `explain`, and `apply` take the same selection and budget flags.

| Flag | Meaning |
| --- | --- |
| `--changed <git-ref>` | only files changed from that ref |
| `--include <glob>` | override the mutation includes (repeatable) |
| `--function <name>` | probe only the function of that name |
| `--mutant <id-prefix>` | probe exactly one unambiguous mutant |
| `--survivors` | keep only the latest stored report's survivors |
| `--seed <n>` | fix the input search |
| `--max-cases <n>` | inputs tried per mutant (1–100000) |
| `--max-shrinks <n>` | shrinking steps taken (0–100000) |
| `--budget <duration>` | 100ms–24h per probe process, one per module |
| `--style <value>` | `assert` or `should` |
| `--json` | emit one JSON value instead of text |

`apply` adds `--yes` and `--verify`. `explain` takes its mutant id as a
positional argument and refuses `--mutant` beside it.

## Configuration

The `[tools.gleam_mutants.suggest]` section supplies the defaults these flags
override; `run`, `list`, and reporting ignore it entirely.

```toml
[tools.gleam_mutants.suggest]
seed = 1
max_cases = 200
max_shrinks = 500
call_timeout_ms = 1000
probe_timeout_ms = 120000
assert_style = "assert"      # assert, should
# exclude_functions = ["main"]
```

See [configuration](configuration.md) for the full ranges and precedence.
`init` never writes this section; the defaults above apply until you add it.

## Statuses

Every selected mutant is accounted for exactly once, under one of four
statuses.

| Status | Meaning |
| --- | --- |
| distinguished | an input told the mutant apart; a test can be written |
| indistinguishable | no input told it apart, so it is possibly equivalent |
| nondeterministic | the original disagreed with itself, so no verdict holds |
| unsupported | nothing could be probed; the reason says what stopped it |

**Indistinguishable is not proof of equivalence.** It means the search did not
separate the mutant within its budget, and the number of cases tried is
reported beside it so a verdict reached in the full budget can be told from one
reached in ten. Raising `--max-cases` sometimes turns one into a suggestion.

Inputs can be generated for primitives (`Int`, `Float`, `String`, `Bool`,
`BitArray`, `Nil`), `List`, `Option`, `Result`, tuples, and public non-opaque
custom types, generic parameters included. Not yet supported, and reported as
unsupported: external and opaque types, function-typed arguments, unannotated
parameters, and private functions — a probe can only call what a test module
could call. A mutant that is not inside any function of its module, such as one
in a module constant, is reported as unsupported for the same reason.

Functions named in `exclude_functions` are skipped without being compiled into
a probe at all, and their mutants are reported as unsupported.

## Read the tests before you keep them

A generated test pins the behaviour the code has **today**. It is evidence that
one input separates the mutant, not a judgement that the current answer is the
right one. If `abs(-1) == 1` is a bug, `apply` will happily write a test that
locks the bug in.

Read every generated test before committing it. They are written into your own
test modules, formatted with `gleam format`, and each carries a `///` comment
naming the mutant it kills, so a reviewer can see where it came from.

`apply` never rewrites a test you already have: a name it has written before is
reported as skipped, and every module the file already names is called by the
name that file bound it under. That covers the module under test — an alias
reaches the values a generated call is given as much as the call itself, since
the probe prints a value of the module's own type qualified by the module it
belongs to — and the modules the generated tests lean on: a file that imports
`gleam/string as str` inspects through `str`, one that imports
`gleeunit/should as expect` expects through `expect`, and one that imports
`gleam/option.{Some as Just}` gains `Some` beside `Just` rather than a call to
a constructor it never bound. A module you imported as `_` names nothing to
reuse, so a plain import is added beside that line and your own is left as you
wrote it.

`Some` and `None` are the only names a generated test writes unqualified, and
only while they are free. A file that already binds either — `import
other.{Some}`, or a type of its own declaring those constructors — gets
`import gleam/option` and tests that read `option.Some(1)` and `option.None`
instead. That form takes no name of yours at all, so nothing in your file has
to move.

A module under test whose own name a generated import would take — one called
`option`, in a file whose tests write `Some` or `None` — is imported and called
as `option_under_test` throughout. It keeps its own name whenever the file has
no such import to write, so a module called `string` whose tests never inspect
is imported plainly. When the name is genuinely spoken for in a file you
already have — you import your own `app/thing as option` — `apply` refuses with
`GMU8014` naming both modules; importing your own under a different alias
resolves it.

A test module `apply` creates from scratch opens with the SPDX tags of the
module it tests, so a project that lints its own copyright still passes on the
file it was handed. A module you already have is left with the header you gave
it.

## Error codes

All three commands share the `GMU8xxx` range. Every one of these exits 2.

| Code | Meaning |
| --- | --- |
| `GMU8001` | the workspace's tests run on JavaScript, which these commands do not support |
| `GMU8002` | a selected file is not a Gleam source covered by the mutation includes |
| `GMU8003` | the instrumented snapshot did not compile |
| `GMU8004` | a probe timed out or exited non-zero |
| `GMU8005` | a probe printed lines that are not results |
| `GMU8006` | two selected files would generate one probe module; probe them separately |
| `GMU8007` | a probe would define one name twice; rename the function or type |
| `GMU8008` | two types of one module would ask for one generator helper |
| `GMU8009` | a generated probe is not valid Gleam — please report it as a bug |
| `GMU8010` | `--survivors` found no stored report for this workspace |
| `GMU8011` | the mutant `explain` names was narrowed out of the run |
| `GMU8013` | a target test module could not be parsed |
| `GMU8014` | a target test module binds a module qualifier the generated tests need |
| `GMU8015` | a target test module could not be read or written |
| `GMU8016` | `gleam format` refused a file that was written |

One diagnostic is a warning rather than a failure. It is written to stderr,
`--quiet` does not silence it, and the command still exits 0.

| Code | Meaning |
| --- | --- |
| `GMU8012` | `--function` named a function no selected file has a mutant in |
