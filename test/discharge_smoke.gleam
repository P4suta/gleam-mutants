// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam_mutants/cache
import gleam_mutants/core/outcome
import gleam_mutants/engine

const fixture = "fixtures/discharge_project"

/// A mutant that answers what it replaces is settled without running a test.
///
/// The two mutants here are the same operator on the same kind of expression,
/// and the only thing between them is whether the replacement ever answers
/// differently: `n * 1` and `n / 1` agree for every `n`, while `a + b` and
/// `a - b` part wherever `b` is not zero. The first is settled by the walk the
/// run already makes with nothing mutated; the second has to be run.
///
/// The fixture's runner reports no test impact at all, so nothing here is
/// narrowed -- which is the point worth pinning. This evidence does not come
/// from the runner, so it is there for a project whose runner offers none.
pub fn main() {
  let assert Ok(Nil) = cache.clean(fixture)
  let assert Ok(output) =
    engine.run(
      fixture,
      engine.Options(
        ..engine.default_options(),
        jobs: Some(2),
        report_formats: Some([]),
        report_history: Some(False),
        strict: Some(False),
      ),
    )

  let found = fn(original) {
    let assert Ok(result) =
      list.find(output.report.results, fn(item) {
        item.mutant.original == original
      })
    result
  }
  let verdict = fn(original) { found(original).aggregate }
  let reason = fn(original) {
    found(original).outcomes
    |> list.map(fn(item) { item.output })
    |> string.join("")
  }

  assert verdict("n * 1") == outcome.Survived
  assert verdict("a + b") == outcome.Killed
  // One mutant, settled on evidence rather than by running anything.
  assert output.execution.discharged == 1
  // And nothing was narrowed, because this runner reports no impact.
  assert output.execution.narrowed == 0
  // A verdict reached without running anything says so where the reader is:
  // beside the mutant, not only in a count on the way past.
  assert string.contains(reason("n * 1"), "survived without a test run")
  assert reason("a + b") == ""
  io.println(
    "discharge smoke: a mutant that never answers differently is settled "
    <> "without a test run",
  )
}
