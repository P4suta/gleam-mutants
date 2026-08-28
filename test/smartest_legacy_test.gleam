// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{Some}
import gleam/string
import smartest/evidence
import smartest/legacy
import smartest/runner

pub fn framework_adapters_are_lazy_and_have_stable_ledger_names_test() {
  let _lazy =
    legacy.gleeunit(fn() { panic as "legacy suite ran during construction" })
  let entries = [
    #("gleeunit_test", legacy.gleeunit(fn() { Nil })),
    #("startest_test", legacy.startest(fn() { Nil })),
    #("unitest_test", legacy.unitest(fn() { Nil })),
    #("qcheck_test", legacy.qcheck(fn() { Nil })),
    #("birdie_test", legacy.birdie(fn() { Nil })),
    #("gleedoc_test", legacy.gleedoc(fn() { Nil })),
  ]
  let report =
    runner.run(
      list.map(entries, fn(entry) {
        runner.entry("demo", "legacy_test", entry.0, entry.1)
      }),
      runner.default_options(),
    )
  assert list.all(report.results, fn(result) {
    result.status == runner.Passed
    && result.oracle == Some(evidence.ExampleOracle)
    && list.length(evidence.test_id_children(result.id)) == 1
  })
  assert list.map(report.results, fn(result) {
      evidence.test_id_children(result.id)
    })
    == [
      ["gleeunit"],
      ["startest"],
      ["unitest"],
      ["qcheck"],
      ["Birdie"],
      ["Gleedoc"],
    ]
}

pub fn framework_adapter_failure_is_contained_by_the_smartest_runner_test() {
  let report =
    runner.run(
      [
        runner.entry(
          "demo",
          "legacy_test",
          "qcheck_test",
          legacy.qcheck(fn() { panic as "property suite failed" }),
        ),
      ],
      runner.default_options(),
    )
  let assert [failure] = report.results
  assert failure.status == runner.Failed
  assert string.contains(failure.message, "property suite failed")
}
