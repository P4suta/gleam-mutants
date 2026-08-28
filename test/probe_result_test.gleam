// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam_mutants/suggest/probe_result.{
  type ProbeResult, type Status, Distinguished, Indistinguishable,
  Nondeterministic, Panicked, ProbeResult, Returned, TimedOut, Unsupported,
}

// --- fixtures ---------------------------------------------------------------

const distinguished_line = "{\"function\":\"add\",\"mutant\":\"m1\",\"status\":\"distinguished\",\"inputs\":[\"0\",\"1\"],\"expected\":\"1\",\"expected_inspect\":\"1\",\"expected_outcome\":\"returned\",\"actual_inspect\":\"-1\",\"actual_outcome\":\"returned\",\"cases\":7,\"shrinks\":3,\"reason\":\"\",\"kills\":[\"m1\",\"m0\"]}"

/// An original that panicked, so there is no value for the test to state, and
/// a mutant that answered one.
const panicked_line = "{\"function\":\"boom\",\"mutant\":\"m4\",\"status\":\"distinguished\",\"inputs\":[\"0\"],\"expected\":null,\"expected_inspect\":\"\",\"expected_outcome\":\"panicked\",\"actual_inspect\":\"0\",\"actual_outcome\":\"timed_out\",\"cases\":1,\"shrinks\":0,\"reason\":\"\",\"kills\":[\"m4\"]}"

const minimal_line = "{\"function\":\"double\",\"mutant\":\"m2\",\"status\":\"indistinguishable\",\"inputs\":[]}"

const cross_module_line = "{\"function\":\"consume\",\"mutant\":\"m5\",\"status\":\"distinguished\",\"inputs\":[\"token.new(1)\"],\"support_modules\":[\"demo/token\"]}"

const unsupported_line = "{\"function\":\"apply\",\"mutant\":\"m3\",\"status\":\"unsupported\",\"inputs\":[],\"expected\":null,\"reason\":\"parameter type is not derivable\"}"

fn sample(status: Status) -> ProbeResult {
  ProbeResult(
    function: "sample",
    mutant: "mutant-1",
    status: status,
    inputs: ["1", "\"two\""],
    support_modules: [],
    expected: Some("Ok(3)"),
    expected_inspect: "Ok(3)",
    expected_outcome: Returned,
    actual_inspect: "Error(Nil)",
    actual_outcome: Returned,
    cases: 12,
    shrinks: 4,
    reason: "explained",
    kills: ["mutant-1", "mutant-2"],
  )
}

// --- decode_line ------------------------------------------------------------

pub fn decode_line_reads_a_distinguished_result_test() {
  assert probe_result.decode_line(distinguished_line)
    == Ok(
      ProbeResult(
        function: "add",
        mutant: "m1",
        status: Distinguished,
        inputs: ["0", "1"],
        support_modules: [],
        expected: Some("1"),
        expected_inspect: "1",
        expected_outcome: Returned,
        actual_inspect: "-1",
        actual_outcome: Returned,
        cases: 7,
        shrinks: 3,
        reason: "",
        kills: ["m1", "m0"],
      ),
    )
}

pub fn decode_line_defaults_missing_optional_fields_test() {
  assert probe_result.decode_line(minimal_line)
    == Ok(
      ProbeResult(
        function: "double",
        mutant: "m2",
        status: Indistinguishable,
        inputs: [],
        support_modules: [],
        expected: None,
        expected_inspect: "",
        expected_outcome: Returned,
        actual_inspect: "",
        actual_outcome: Returned,
        cases: 0,
        shrinks: 0,
        reason: "",
        kills: [],
      ),
    )
}

pub fn decode_line_reads_an_unsupported_reason_test() {
  assert probe_result.decode_line(unsupported_line)
    == Ok(
      ProbeResult(
        function: "apply",
        mutant: "m3",
        status: Unsupported,
        inputs: [],
        support_modules: [],
        expected: None,
        expected_inspect: "",
        expected_outcome: Returned,
        actual_inspect: "",
        actual_outcome: Returned,
        cases: 0,
        shrinks: 0,
        reason: "parameter type is not derivable",
        kills: [],
      ),
    )
}

pub fn decode_line_reads_the_kill_set_test() {
  let assert Ok(distinguished) = probe_result.decode_line(distinguished_line)
  assert distinguished.kills == ["m1", "m0"]

  // A line without the field is a probe that killed nothing.
  let assert Ok(minimal) = probe_result.decode_line(minimal_line)
  assert minimal.kills == []

  // An empty kill set survives the round trip as one.
  let assert Ok(empty) =
    probe_result.decode_line(
      "{\"function\":\"a\",\"mutant\":\"b\",\"status\":\"distinguished\",\"inputs\":[],\"kills\":[]}",
    )
  assert empty.kills == []
}

pub fn decode_line_preserves_cross_module_input_provenance_test() {
  let assert Ok(decoded) = probe_result.decode_line(cross_module_line)
  assert decoded.support_modules == ["demo/token"]
  assert probe_result.decode_line(probe_result.encode(decoded)) == Ok(decoded)
}

pub fn encode_puts_the_kill_set_last_test() {
  let encoded = probe_result.encode(sample(Distinguished))
  let assert Ok(#(_, tail)) = string.split_once(encoded, "\"reason\":")
  assert string.contains(tail, "\"kills\":[\"mutant-1\",\"mutant-2\"]")
}

pub fn decode_line_reads_how_each_side_ended_test() {
  // The inspects carry the value a call answered with, and the outcomes say
  // whether there was a value at all: a panicking call has none.
  let assert Ok(panicked) = probe_result.decode_line(panicked_line)
  assert panicked.expected_outcome == Panicked
  assert panicked.expected_inspect == ""
  assert panicked.actual_outcome == TimedOut

  // A line from a probe that predates the field is a call that returned.
  let assert Ok(minimal) = probe_result.decode_line(minimal_line)
  assert minimal.expected_outcome == Returned
  assert minimal.actual_outcome == Returned
}

pub fn decode_line_rejects_an_unknown_outcome_test() {
  assert result.is_error(probe_result.decode_line(
    "{\"function\":\"a\",\"mutant\":\"b\",\"status\":\"distinguished\",\"inputs\":[],\"expected_outcome\":\"exploded\"}",
  ))
}

pub fn encode_writes_each_outcome_beside_its_inspect_test() {
  let encoded =
    probe_result.encode(
      ProbeResult(
        ..sample(Distinguished),
        expected_outcome: Panicked,
        actual_outcome: TimedOut,
      ),
    )
  assert string.contains(encoded, "\"expected_outcome\":\"panicked\"")
  assert string.contains(encoded, "\"actual_outcome\":\"timed_out\"")
  let assert Ok(#(_, tail)) =
    string.split_once(encoded, "\"expected_inspect\":")
  assert string.starts_with(tail, "\"Ok(3)\",\"expected_outcome\":")
}

pub fn decode_line_rejects_malformed_input_test() {
  assert result.is_error(probe_result.decode_line("not json at all"))
  assert result.is_error(probe_result.decode_line("{\"function\":\"a\"}"))
  assert result.is_error(probe_result.decode_line(
    "{\"function\":\"a\",\"mutant\":\"b\",\"status\":\"bogus\",\"inputs\":[]}",
  ))
}

// --- decode_output ----------------------------------------------------------

pub fn decode_output_skips_blank_and_noise_lines_test() {
  let stdout =
    string.join(
      [
        "",
        "   ",
        "Compiling gleam_mutants_probe",
        distinguished_line,
        "",
        minimal_line,
        "{ broken",
        "",
      ],
      "\n",
    )
  let #(results, failures) = probe_result.decode_output(stdout)

  assert list.map(results, fn(entry) { entry.mutant }) == ["m1", "m2"]
  assert failures == ["{ broken"]
}

pub fn decode_output_of_only_noise_is_empty_test() {
  assert probe_result.decode_output("\nhello\n\n") == #([], [])
}

// --- encode -----------------------------------------------------------------

pub fn encode_uses_stable_field_names_test() {
  assert probe_result.encode(
      ProbeResult(
        function: "add",
        mutant: "m1",
        status: Distinguished,
        inputs: ["0"],
        support_modules: [],
        expected: None,
        expected_inspect: "1",
        expected_outcome: Returned,
        actual_inspect: "2",
        actual_outcome: Returned,
        cases: 3,
        shrinks: 1,
        reason: "",
        kills: ["m1", "m2"],
      ),
    )
    == "{\"function\":\"add\",\"mutant\":\"m1\",\"status\":\"distinguished\",\"inputs\":[\"0\"],\"support_modules\":[],\"expected\":null,\"expected_inspect\":\"1\",\"expected_outcome\":\"returned\",\"actual_inspect\":\"2\",\"actual_outcome\":\"returned\",\"cases\":3,\"shrinks\":1,\"reason\":\"\",\"kills\":[\"m1\",\"m2\"]}"
}

pub fn encode_renders_every_status_in_lowercase_test() {
  assert list.map(
      [Distinguished, Indistinguishable, Nondeterministic, Unsupported],
      fn(status) {
        let encoded = probe_result.encode(sample(status))
        let assert Ok(#(_, tail)) = string.split_once(encoded, "\"status\":\"")
        let assert Ok(#(name, _)) = string.split_once(tail, "\"")
        name
      },
    )
    == ["distinguished", "indistinguishable", "nondeterministic", "unsupported"]
}

pub fn encode_and_decode_round_trip_for_every_status_test() {
  list.each(
    [Distinguished, Indistinguishable, Nondeterministic, Unsupported],
    fn(status) {
      let value = sample(status)
      assert probe_result.decode_line(probe_result.encode(value)) == Ok(value)
    },
  )
}
