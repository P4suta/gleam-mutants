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
test suite went red. Each probe writes its verdicts to a `.jsonl` file inside
the snapshot rather than printing them, so a module whose values run to
kilobytes is reported in full however many mutants it has; its stdout carries
nothing but a closing count.

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

## Side effects

**The probe calls your code for real.** Every public function of the selected
files is called, with generated arguments, in the environment the command was
run in: the real home directory, the real cache directory, the real network,
the real subprocess table. A function that writes a file writes it; one that
deletes a directory deletes it; one that posts to an endpoint posts to it. It
is called hundreds of times over — once per case, per mutant, per shrink step —
and the generated test calls it again on every `gleam test` afterwards.

**The snapshot isolates source, not effects.** The workspace is copied so that
an instrumented mutant never touches your files, and everything a copy of your
code reaches through an absolute path, an environment variable, a socket or a
subprocess is the very thing the original would have reached. A twenty-line
function writing `/tmp/<name>` under a generated `name` left 583 files behind
in one `suggest` run while this was being measured.

So run `suggest` where a stray write is harmless: a checkout, not a machine
holding production credentials. Ways to keep a function out of the probe, in
ascending order of what they give up:

* **`exclude_functions`** in `[tools.gleam_mutants.suggest]` names the
  functions the probe leaves alone. They are never compiled into a probe,
  never called and never timed, and their mutants are reported as unsupported
  so nothing the run selected goes unaccounted for. Write it down for anything
  that touches the filesystem, the network, the clock or a subprocess before
  you run `suggest` the first time.
* **`--function <name>`** probes one function and nothing else; `--include
  <glob>` narrows to one file and `--mutant <id-prefix>` to one mutant.
  Whatever the narrowing leaves out is never compiled into a probe.
* **Probe pure modules only.** Point the command at the files that compute
  rather than act, and leave the ones that do I/O to tests you write yourself.
  It gives up the most coverage and it is the only approach that needs nothing
  configured.

None of this is enforcement: `exclude_functions` is opt-in and per name, and a
pure-looking function that calls an effectful one still performs the effect.
Read the list of modules a run selected before you let it loose on a codebase
you do not know.

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
`suggest --survivors` for a machine-readable answer. A suggestion step that
fails — on a workspace whose tests run on JavaScript, say — is printed as a
warning under its own code, beside a run that still stands.

### What `--verify` attributes

Verification re-runs your whole suite, so "the mutant is dead" is not by itself
"the generated test killed it": a mutant your own tests were already catching
comes back dead whatever the new file does. `--verify` therefore grades the
workspace **before** it writes as well as after, and says which side of the
write is owed each kill.

| Attribution | In Apply JSON v1 | Meaning |
| --- | --- | --- |
| newly killed | `new` | alive before the tests were written, or not discovered by that run at all; dead now |
| already killed | `already_killed` | dead before the tests were written, and dead now |
| still surviving | `surviving` | alive now, whatever it was before |

`surviving`, and nothing else, is what exits 1. A mutant neither run
discovered counts as surviving too: the file it came from was selected, so its
absence is a finding rather than a pass.

A generated test whose every claimed mutant comes back `already_killed` added
no coverage — your own suite catches everything it catches — so it is named on
stderr under `GMU8017` and deleting it costs you nothing. Only the tests that
run wrote are judged that way. A test the module already held was in the suite
while the baseline ran, so the baseline cannot say what it adds: a second
`--verify` over an applied workspace writes nothing, reports its mutants as
`already_killed`, and warns about none of them.

**This costs two mutation runs where `--verify` used to cost one**, the first
of them your whole suite over the same files, so expect roughly twice the wall
time. The last line of every `--verify` says which run the attributions above
it were graded against, because the two are not equally fresh:

```text
Baseline: a run of those files taken before the tests were written.
Baseline: the last stored run, which started after everything in src/
and test/ was last written; --no-reuse measures one instead.
```

The baseline run is skipped — the second line — when the workspace's last
stored `run` is still a verdict on this workspace. Two things have to hold.
It must have graded **every** mutant in question: a mutant id carries the
digest of the source it was cut from, so an id that run named is a verdict on
exactly that source, and nothing partial is reused, because a baseline missing
one mutant would credit the generated tests with a kill nobody measured.

The id says nothing about your **tests**, though, which are the other half of
every kill — so the stored run must also have started after the last write to
anything the suite is made of: `src/`, `test/`, `gleam.toml` and
`manifest.toml`, directories included, so that a test module deleted since
counts as a change too. Without that second condition, a run taken while a
since-deleted test was killing a mutant would still call that mutant dead, and
the generated test that now kills it would be reported as adding nothing and
named under `GMU8017` — advice that deletes the only test standing.

Modification times are what settle it, so a checkout that rewrote them, or a
filesystem that keeps none, costs you the shortcut and nothing else. Pass
`--no-reuse` to measure the baseline whatever the tree says.

`run` followed by `apply --verify` therefore costs one verification run;
`apply --verify` in a workspace with no history, after the sources or the
tests have changed, or with `--no-reuse`, costs two.

### Flags

`suggest`, `explain`, and `apply` take the same selection and budget flags.

| Flag | Meaning |
| --- | --- |
| `--changed <git-ref>` | only files changed from that ref |
| `--include <glob>` | override the mutation includes (repeatable) |
| `--function <name>` | probe only the function of that name |
| `--mutant <id-prefix>` | probe exactly one unambiguous mutant |
| `--survivors` | keep only the latest stored report's survivors |
| `--operator <name>` | select a mutation operator (repeatable) |
| `--seed <n>` | fix the input search |
| `--max-cases <n>` | inputs tried per mutant (1–100000) |
| `--max-shrinks <n>` | shrinking steps taken (0–100000) |
| `--budget <duration>` | 100ms–24h per probe process, one per module |
| `--style <value>` | `assert` or `should` |
| `--json` | emit one JSON value instead of text |

`apply` adds `--yes`, `--verify` and `--no-reuse`. `explain` takes its mutant
id as a positional argument and refuses `--mutant` beside it. `--operator`
takes the same names `run --operator` and `list --operator` take, and
overrides the workspace's own operator list for this run alone.

Every one of these narrows the probe before anything is compiled: a run
narrowed to one mutant, one operator or one report's survivors instruments only
what it was asked about.

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

| Status | Meaning | Where it lands in `--json` |
| --- | --- | --- |
| distinguished | an input told the mutant apart; a test can be written | the `kills` of a `suggestions` entry |
| indistinguishable | no input told it apart, so it is possibly equivalent | `indistinguishable` |
| nondeterministic | the original disagreed with itself, so no verdict holds | `nondeterministic` |
| unsupported | nothing could be probed; the reason says what stopped it | `unsupported` |

Each of the four is a bucket of its own, and the text summary counts each of
them separately: no consumer has to string-match a reason to recover the status
this table names. A mutant the compiler rejects — a pipeline stage deletion that
leaves the wrong type behind, most often — is reported as unsupported, with a
reason beginning `mutant does not compile`, and every other mutant of its file
is probed as usual. A mutant an input does divide from its original, but only
by something no assertion can state — a result holding a function value, which
`string.inspect` renders as `//fn(a) { ... }` on both sides — is reported as
unsupported as well, rather than as a test that would pass with the mutant
still in place.

The `N of M distinguishable mutant(s)` the summary opens with counts *every*
mutant an input told apart, whether or not a test could be written for it: a
mutant separated and then refused — as unwritable, as inexpressible, or as
bound to this machine — still counts towards `M`. `0 of 5` and `0 of 0` are
different reports, and the first is the one that says where the run's gap is.

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

## How inputs are chosen

Most of the values tried are drawn uniformly from the type: a random integer of
the range, a random string of up to twenty printable ASCII characters, a random
list. The rest is spent on values a uniform draw practically never produces,
because those are the ones that separate a mutant:

* **The edges of a range** — zero, both bounds, the neighbour just inside
  either bound, and the units either side of zero. A boundary mutant (`>` for
  `>=`) is told apart by an exact edge and by nothing else.
* **A handful of shape-carrying strings** — `"a"`, `"ab"`, `"hello"`, `"0"`,
  `" "`, `"\n"`, `"\r\n"`, `"/"`, `"./"` and `"\\"` — so a function that splits
  on a separator or trims a line ending meets one.
* **The literals the function under test writes down.** Every `Int`, `Float`
  and `String` literal in the function's own body — at most thirty-two of each
  kind — becomes a value its parameters are drawn from, in the expressions it
  evaluates and in the patterns it matches on alike: `case method { "GET" -> …`
  and `case path { "./" <> rest -> …` name their literal in a pattern and
  nowhere else. A literal compared against with `<`, `<=`, `>` or `>=`
  contributes its neighbours as well, so `x > 10` is searched with `10`, `9`
  and `11`; a matched literal contributes none, because matching is equality.
  A function holding `string.starts_with(s, "./")` is searched with `"./"`,
  which twenty random characters would produce about once in nine thousand
  draws.

The first two take a quarter of the draws between them, whether or not the
function writes any literal down: they are what separates a boundary mutant,
and a function with literals in it is exactly the kind that also has one.
Harvested literals are added on top rather than traded against them, taking an
eighth of the draws of their own, so a couple of them are reached within the
first tens of cases however many edges the type has. The remaining five eighths
are the uniform draw.

Raising `--max-cases` is rarely the lever it looks like: on real code, going
from 200 to 2000 cases changed no verdict anywhere. Better priors are what move
an `indistinguishable` into a suggestion.

Once an input separates the mutant, it is shrunk to the smallest value that
still does, with two rules that keep the result readable: at equal magnitude an
integer prefers its non-negative form (so a test asserts on `1`, not `-1`), and
a string never shrinks past a single character. The one way `""` reaches a
suggestion is by having been *drawn*: the search keeps the first input that
separates the mutant, and an empty string is a value like any other. Such a
suggestion — `glob.included("", [""], []) == True` is a real one — pins an
accident of an empty input rather than a behaviour, and is worth rejecting on
sight. Records print with the labels their fields were declared with —
`score.Score(total: 1, killed: 0, ...)` — so a six-field constructor is
readable without opening the type.

A suggestion whose inputs or expected value names an absolute path, this
machine's home directory, its cache directory or its temporary directory is
never written down — not by `suggest`, not by `apply`, and not by `explain`,
which says `no test can be written: expected value depends on this machine` and
prints the two answers instead. It is reported as unsupported, with that same
reason. Such a test passes where it was generated and fails for everyone else.
The absolute-path shapes are a fixed list — `/home/`, `/Users/`, `/root/`,
`/tmp/`, `/var/folders/` and `C:\` — so a portable value that happens to hold
one is refused too, and a home, cache or temporary directory that names nothing
below its root (`HOME=/`) is ignored rather than allowed to refuse everything.

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

**Known limitation: two test modules for one source module.** The destination
is computed from the source path alone, so a project whose tests live in a tree
— `test/gleam/erlang/atom_test.gleam` for `src/gleam/erlang/atom.gleam` — gains
`test/gleam_erlang_atom_test.gleam` beside it, and that module is then covered
by two test files. Both compile and both run, nothing is overwritten and no
test of yours is lost, but it is the first thing a reviewer asks about. Moving
the generated tests by hand into the file you already have is the fix, with one
catch: `apply` reads only its own flat target to decide what is already
present, so a later run adds them back to the flat file. Delete the generated
module rather than empty it if you do not want it regenerated, and re-run
`suggest` rather than `apply` once the tests live somewhere else.

## Editors

The same three commands are wired into VS Code by the extension in
[`editors/vscode`](../editors/vscode). A surviving mutant is a warning on the
line it changes; the lightbulb on it offers "Generate a test that kills this
mutant", which runs `suggest --json` for that one mutant, then
`apply --yes --json` for what it suggested, and opens the test module at the
test it added. A mutant no input told apart is reported as probably equivalent
rather than written, and one no test can be written for carries the reason from
the `unsupported` bucket above. There is also a command for the whole file,
which lists every suggestion with its generated source and writes the one you
pick.

The extension runs this CLI — it does not reimplement any of it — so
everything on this page holds inside the editor too, the side effects of
probing above and the Erlang-only support first among them. It is built from
source; see [`editors/vscode/README.md`](../editors/vscode/README.md).

## Error codes

All three commands share the `GMU8xxx` range. Every one of these exits 2.

| Code | Meaning |
| --- | --- |
| `GMU8001` | the workspace's tests run on JavaScript, which these commands do not support |
| `GMU8002` | a selected file is not a Gleam source covered by the mutation includes |
| `GMU8003` | the snapshot did not compile, before or after instrumenting |
| `GMU8004` | a probe timed out, exited non-zero, or wrote no results file |
| `GMU8005` | a probe wrote lines that are not results |
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

Two diagnostics are warnings rather than failures.

| Code | Meaning |
| --- | --- |
| `GMU8012` | `--function` named a function this run selected no mutant in |
| `GMU8017` | `apply --verify` wrote a test whose every claimed mutant was already dead |

A third path turns any code in this range into a warning: `run --suggest`
reports a suggestion step that failed under the code that step raised, because
the run itself already graded its mutants and succeeded. A workspace whose
tests run on JavaScript therefore ends a successful `run --suggest` with

```text
gleam-mutants: GMU8001: suggest supports the Erlang target only
```

rather than failing it. Run `suggest` on its own to get the same refusal as an
exit 2.

Every warning is written to stderr, `--quiet` silences none of them, and none
changes the exit code: a run that raises only these still exits 0. In the
terminal each line names its code exactly once; under `--log-format json` the
code is in the `code` field, the way a failure carries it.

A `GMU8017` raised against a baseline reused from a stored run is a claim
about the tests that were in the tree when that run was taken. Only a stored
run younger than every one of them is reused, so the two are the same tests —
but if you have reason to doubt the timestamps, `--no-reuse` re-asks the
question against a baseline measured on the spot before you delete anything.

`apply --verify` drives the mutation engine, so it can also fail under the
engine's own codes rather than one of these — `GMU7004` for a special file the
snapshot refuses to copy, `GMU7005` for a cache directory it cannot create,
for instance. Those name the path they failed at.
