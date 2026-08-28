<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Smartest

Smartest is the Gleam-first adaptive verification layer developed in this
repository. It combines examples, properties, models, snapshots, finite
enumeration, fuzzing, integration transcripts, bounded solver providers, and
mutation goals in one evidence loop. Mutation is an exploration target and an
adequacy signal; it is never the oracle that decides which behaviour is right.

Smartest is offline by default. No network, AI service, or telemetry is needed
by the core or runner. A human, an AI tool, or another agent may propose a test
or model, but the proposal follows the same compile, replay, oracle, review, and
trust rules as every other finding.

## Quick start

Make the package test entry point delegate discovery to Smartest:

```gleam
import smartest

pub fn main() -> Nil {
  smartest.main()
}
```

Every native test is a lazy `Test` value. Construction does not invoke its
callback, fixture, renderer, solver, or external resource.

```gleam
import gleam/list
import smartest.{type Test}
import smartest/gen
import smartest/property
import smartest/testing

pub fn empty_list_test() -> Test {
  testing.example(fn() {
    assert list.is_empty([])
  })
}

pub fn reverse_twice_test() -> Test {
  property.for_all(gen.list(gen.int()), fn(items) {
    assert list.reverse(list.reverse(items)) == items
  })
}
```

`gleam test` discovers public zero-argument `*_test` exports. Existing
gleeunit, startest, unitest, qcheck, Birdie, and Gleedoc-style tests that return
`Nil` remain valid legacy ledger entries, so migration is incremental.

## Evidence loop and trust

The loop is deliberately one-way:

```text
verification goal -> explore -> execute and observe -> minimal witness
  -> independent oracle -> review -> versioned corpus -> fast replay
```

An original/mutant or left/right difference with no independent oracle is
`UnjudgedDivergence`. Accepting it without `--oracle` records the review but
does not turn it into trusted correctness evidence. Exhausted random, fuzz,
finite, or solver budgets are `NotDistinguishedWithinBudget`; they are not
called equivalent. Equivalence requires an explicit `FormalProof` whose
method, subset, and bound are all recorded.

New generated or recorded evidence begins as `Provisional`. Only an explicit
review can promote independently judged evidence to `Trusted`. `Unjudged`,
`Stale`, `Unsafe`, and `Unsupported` remain visible instead of being silently
dropped. The default CI lane gates existing failures, stale accepted corpus,
and loss of trusted evidence; a new advisory gap does not manufacture a build
failure or a truth claim.

Review from the command line:

The command-tree spelling `smartest accept` below is invoked from a Gleam
workspace as `gleam run -m smartest -- accept`.

```sh
gleam run -m smartest -- findings
gleam run -m smartest -- explain <finding-id>
gleam run -m smartest -- replay <finding-id>
gleam run -m smartest -- accept <finding-id> --review "checked the protocol"
gleam run -m smartest -- accept <finding-id> --review "checked RFC" \
  --oracle "RFC section 4"
gleam run -m smartest -- reject <finding-id> --reason "invalid fixture"
```

Accepted artifacts live under `test/smartest/corpus/`; the working inbox and
reports live under `.smartest/`. Generator schema changes are `StaleEvidence`.
Use `corpus move`, `corpus migrate`, and confirmed `corpus prune --yes` rather
than deleting or ignoring incompatible evidence.

## Native techniques

The initial concrete APIs are intentionally narrower than a generic strategy
plugin protocol:

- `smartest/testing`, `smartest/doctest`, and `smartest/snapshot` provide
  examples, compiler-checked documentation expectations, and reviewed
  observations.
- `smartest/property`, `smartest/metamorphic`, `smartest/reference`, and
  `smartest/hyperproperty` attach independent property or reference oracles to
  portable generator tapes.
- `smartest/model` explores and shrinks state-machine command sequences and
  always runs declared cleanup.
- `smartest/fuzz` retains coverage edges and improving comparison distances,
  mutates useful tapes deterministically, and reuses the normal generator,
  shrinker, seed dictionary, and corpus format.
- `smartest/exhaustive` visits a caller-versioned finite subset once and emits
  `BudgetExhausted` when the case budget cannot cover the declared bound.
- `smartest/solver` accepts lazy concolic or SMT providers. A provider must
  carry a formal method, subset, and bound; no solver binary is bundled.
- `smartest/scenario`, `smartest/fault`, and `smartest/transcript` cover
  resource lifecycle, finite fault matrices, and immutable record/replay
  integration contracts.
- `smartest/concurrency` generates bounded portable schedules, while
  `smartest/performance` reports statistical regressions separately from
  correctness failures.
- `smartest/differential` records a divergence as unjudged until another
  oracle is supplied.

Use `gen.hinted` to mix literals, constants, examples, or reviewed corpus
values into the same deterministic draw-tape engine. Changing the meaning or
order of hints requires a new caller-provided schema.

## Capabilities and effects

Exploratory work is fail-closed. Pure tests run normally. An effectful resource
or provider declares capabilities such as `FileRead`, `FileWrite`, `Network`,
`Subprocess`, `Environment`, `Clock`, or `Randomness`; the runner executes it
only when all are granted. An `Unknown` effect grade is reported as unsafe and
is not run repeatedly. This matters most for fuzzing, model exploration,
integration faults, and external solver processes.

Renderers and observers are not semantic oracles by themselves. Opaque values
must be constructed and observed through public APIs or a registered observer;
`string.inspect` is not used to decide correctness.

## Execution modes

- `gleam test` runs examples, accepted corpus replay, and bounded properties.
- `smartest watch` is an explicit foreground watcher. Hot edits use one worker;
  a new revision requests cancellation immediately and forces it after 250 ms.
  It installs no service and leaves no daemon behind.
- `smartest strengthen` spends a foreground mutation-search budget on evidence
  gaps selected by the caller.
- `smartest ci` runs deterministic tests and checks corpus health.
- `smartest deep` runs the broad target and mutation matrix for nightly or
  manual verification.
- `status`, `findings`, `explain`, `replay`, `accept`, `reject`, `corpus`, and
  `doctor` operate on the same ledger.

The Erlang, Node, Deno, and Bun runners use the same test ids, generator tapes,
schema fingerprints, evidence states, and reports. Runtime-specific process
isolation is a shell concern, not part of the pure test plan.

## TDD development contract

Every development phase uses RED, GREEN, then refactor. A change starts with a
failing executable contract at the narrowest useful boundary. The failure is
observed before production code is added. The smallest implementation that
satisfies it is then run on every affected target, followed by refactoring
under the green suite. Regression, architecture, fault, compatibility, and
performance tests are added in the phase that creates the corresponding risk,
not postponed to a final hardening pass.

Pure core laws, epistemic laws, runner semantics, corpus migration, mutation
compatibility, editor wiring, and release gates are all executable tests. A
phase is not complete merely because code exists: its focused tests, affected
full suites, warnings-as-errors builds, and applicable smoke tests must be
green.
