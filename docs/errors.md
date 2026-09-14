<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Error codes

Every diagnostic `gleam-mutants` writes carries a `GMU` code, and every code
appears here. The code is the stable part: the sentence beside it is written
for a reader and may be reworded, the code is what a script matches on and what
an issue report should name.

Diagnostics go to stderr, never to stdout, so `--json` output stays pipeable
while the run still explains itself. A text diagnostic is one line:

```text
gleam-mutants: GMU2002: no gleam.toml found in this directory or its parents
```

Under `--log-format json` the same diagnostic is one JSON object per line, with
`level` (`info`, `warning`, or `error`), `code`, `message`, and a `usage` string.
`usage` carries the help text, and only a command line that would not parse gets
one -- `GMU1001` and `GMU1002`. Every other diagnostic leaves it null, because
the help text would not be the answer.

A failure exits 2 and a warning does not change the exit code at all. A run that
finishes exits on what it found: 2 when any mutant errored, 1 when `--strict` was
asked for and the score came in under the minimum, and 0 otherwise -- surviving
mutants alone are a result, not a failure.

The first digit groups the code by the stage that raises it, so an unfamiliar
code still says where the run was when it stopped.

| Family | Stage |
| --- | --- |
| `GMU0xxx` | progress, not failure |
| `GMU1xxx` | the command line |
| `GMU2xxx` | finding the workspace |
| `GMU3xxx` | configuration |
| `GMU4xxx` | choosing what to mutate |
| `GMU5xxx` | reading stored reports |
| `GMU6xxx` | writing reports and cache |
| `GMU7xxx` | the workspace lock and its snapshot |
| `GMU8xxx` | `suggest`, `explain`, and `apply` |
| `GMU9000` | a failure that carries no code of its own |

## GMU0xxx -- progress

These are `info`, not failures. They are suppressed by `--quiet`, and the
verbose ones need the verbosity they name.

| Code | When |
| --- | --- |
| `GMU0001` | a mutation run started |
| `GMU0002` | the run id, at `-v` and above |
| `GMU0003` | the workspace digest and how many files were selected, at `-vv` |
| `GMU0004` | where a report was written |
| `GMU0005` | the execution summary: narrowed, confirmed, fallen back, cached |
| `GMU0006` | one line of execution detail, at `-vv` |

## GMU1xxx -- the command line

| Code | When | What to do |
| --- | --- | --- |
| `GMU1001` | the first argument is not a command | the help text is printed beneath it |
| `GMU1002` | an option is missing its value, unknown, or contradicts another | the message names the option, and the help text follows |

## GMU2xxx -- finding the workspace

| Code | When | What to do |
| --- | --- | --- |
| `GMU2001` | `--root` was given a directory with no `gleam.toml` | point `--root` at the package root |
| `GMU2002` | no `gleam.toml` here or in any parent | run inside a Gleam package, or pass `--root` |

## GMU3xxx -- configuration

| Code | When | What to do |
| --- | --- | --- |
| `GMU3004` | a persistent cache is enabled for a custom test command with no `cache.key` | set `cache.key`, so a cache entry cannot outlive the command that produced it |

## GMU4xxx -- choosing what to mutate

| Code | When | What to do |
| --- | --- | --- |
| `GMU4001` | the selection matched no Gleam source file | widen `include`, or check the paths passed on the command line |
| `GMU4003` | every candidate failed compiler validation | the engine and the Gleam compiler disagree; report it with both versions |
| `GMU4004` | no mutant id starts with the prefix given | take a prefix from the report, or re-run without `--mutant` |
| `GMU4005` | the prefix matches more than one mutant | lengthen it; the message lists what it matched |
| `GMU4006` | `--changed` was given something that reads as an option | pass a git reference, such as `--changed main` |
| `GMU4007` | `git merge-base` failed for that reference | fetch the branch, or pass a reference this clone has |
| `GMU4008` | the changed-file query failed | the message carries git's own words |

## GMU5xxx -- reading stored reports

| Code | When | What to do |
| --- | --- | --- |
| `GMU5001` | the stored reports could not be listed | check the cache directory is readable |
| `GMU5002` | the latest report could not be read | re-run, or `report clean` and re-run |
| `GMU5003` | the latest native report is not valid JSON | `report clean`; a truncated report usually means a run was killed mid-write |
| `GMU5004` | the reports could not be cleaned | check the cache directory is writable |

## GMU6xxx -- writing reports and cache

| Code | When | What to do |
| --- | --- | --- |
| `GMU6001` | the cache could not be cleaned | check the cache directory is writable |
| `GMU6002` | the report history could not be written | the message names the path |
| `GMU6003` | a project report could not be written | the message names what failed and where: a read-only checkout, a directory you do not own, a full disk |

## GMU7xxx -- the workspace lock and its snapshot

One run holds a workspace at a time, and each mutant is built in a copy of it.

| Code | When | What to do |
| --- | --- | --- |
| `GMU7001` | another run holds this workspace | the message names the pid, the run, and when it started; wait, or stop that run |
| `GMU7002` | a snapshot could not be cleaned up | the message names the path; it is under the cache directory and safe to delete |
| `GMU7003` | the lock could not be released | the lock file is named in the message; a stale one is reclaimed by the next run once its holder is gone |
| `GMU7004` | the workspace holds a socket, fifo, or device | a snapshot is a byte-for-byte copy and will not copy one; exclude it |
| `GMU7005` | the workspace cache directory could not be created | the first thing a sandboxed run hits; grant write access to the cache directory, or set `XDG_CACHE_HOME` |

## GMU8xxx -- suggest, explain, and apply

These three commands share a probe: an instrumented copy of the workspace that
calls the mutated function directly. Most of these codes are about that probe.

| Code | When | What to do |
| --- | --- | --- |
| `GMU8002` | a file was asked for that the mutation includes do not cover | widen `include`, or drop the file from the command line |
| `GMU8003` | the instrumented snapshot did not compile | the compiler's own message follows; please report it with the source that caused it |
| `GMU8004` | the probe timed out, exited non-zero, or wrote no results | raise `--probe-timeout`; when a mutant hung, the message names which one |
| `GMU8005` | the probe wrote lines that are not results | please report it with the lines quoted in the message |
| `GMU8006` | two sources would generate the same probe module | rename one of the two modules the message names |
| `GMU8007` | the Gleam compiler could not be identified, or the probe would define one name twice | for the second, rename the function or type the message names |
| `GMU8008` | the probe would give one name to two types, or a compile-lane mutant has no source catalog | the first names both types; the second is a bug worth reporting |
| `GMU8009` | the generated probe is not valid Gleam | always a bug; please report it |
| `GMU8010` | `--survivors` found no stored report for this workspace | run `gleam-mutants run` first |
| `GMU8011` | the named mutant is not in the stored report | take an id from the report, or re-run it |
| `GMU8012` | a warning: the run selected no mutant inside the function named | check the name, or widen the selection |
| `GMU8013` | the test module could not be parsed | fix the syntax error in it and re-run |
| `GMU8014` | the generated tests need a name the test module has already bound | import that module under a different alias and re-run |
| `GMU8015` | a test module could not be read or written | the message names the path |
| `GMU8016` | `gleam format` refused the generated tests | always a bug; please report it with the generated file |
| `GMU8017` | a warning: nothing new was written | every test it would have added is already there |

`GMU8001` is retired. It said `suggest`, `explain`, and `apply` were Erlang
only; they now probe on Erlang, Node, Deno, and Bun.

## GMU9000

A failure that reaches the command line without a code of its own is reported
as `GMU9000`. Seeing one is worth an issue: every failure is meant to name
itself, and this code means one did not.
