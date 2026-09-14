// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Two mutants of the same operator family, told apart by nothing but whether
// the replacement ever answers differently from what it replaces.

/// `n * 1` and `n / 1` are the same answer for every `n`. No test can tell the
/// mutant from this, so the walk that has nothing mutated is enough to say so.
pub fn keep(n: Int) -> Int {
  n * 1
}

/// `a + b` and `a - b` part wherever `b` is not zero, which the test below is.
pub fn add(a: Int, b: Int) -> Int {
  a + b
}
