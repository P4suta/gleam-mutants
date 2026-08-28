//// Lazy adapters for established Gleam test ecosystem suites.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/evidence
import smartest/testing.{type Test}

/// Wraps a gleeunit suite in Smartest timeout and ledger semantics.
pub fn gleeunit(run: fn() -> Nil) -> Test {
  adapter("gleeunit", run)
}

pub fn startest(run: fn() -> Nil) -> Test {
  adapter("startest", run)
}

pub fn unitest(run: fn() -> Nil) -> Test {
  adapter("unitest", run)
}

pub fn qcheck(run: fn() -> Nil) -> Test {
  adapter("qcheck", run)
}

pub fn birdie(run: fn() -> Nil) -> Test {
  adapter("Birdie", run)
}

pub fn gleedoc(run: fn() -> Nil) -> Test {
  adapter("Gleedoc", run)
}

fn adapter(name: String, run: fn() -> Nil) -> Test {
  testing.named(name, testing.example(run))
  |> testing.with_oracle(evidence.ExampleOracle)
}
