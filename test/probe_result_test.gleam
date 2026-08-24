// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam_mutants/suggest/probe_result.{
  type ProbeResult, type Status, Distinguished, Indistinguishable,
  Nondeterministic, ProbeResult, Unsupported,
}

// --- fixtures ---------------------------------------------------------------

const distinguished_line = "{\"function\":\"add\",\"mutant\":\"m1\",\"status\":\"distinguished\",\"inputs\":[\"0\",\"1\"],\"expected\":\"1\",\"expected_inspect\":\"1\",\"actual_inspect\":\"-1\",\"cases\":7,\"shrinks\":3,\"reason\":\"\"}"

const minimal_line = "{\"function\":\"double\",\"mutant\":\"m2\",\"status\":\"indistinguishable\",\"inputs\":[]}"

const unsupported_line = "{\"function\":\"apply\",\"mutant\":\"m3\",\"status\":\"unsupported\",\"inputs\":[],\"expected\":null,\"reason\":\"parameter type is not derivable\"}"

fn sample(status: Status) -> ProbeResult {
  ProbeResult(
    function: "sample",
    mutant: "mutant-1",
    status: status,
    inputs: ["1", "\"two\""],
    expected: Some("Ok(3)"),
    expected_inspect: "Ok(3)",
    actual_inspect: "Error(Nil)",
    cases: 12,
    shrinks: 4,
    reason: "explained",
  )
}

// --- decode_line ------------------------------------------------------------

pub fn decode_line_reads_a_distinguished_result_test() {
  assert probe_result.decode_line(distinguished_line)
    == Ok(ProbeResult(
      function: "add",
      mutant: "m1",
      status: Distinguished,
      inputs: ["0", "1"],
      expected: Some("1"),
      expected_inspect: "1",
      actual_inspect: "-1",
      cases: 7,
      shrinks: 3,
      reason: "",
    ))
}

pub fn decode_line_defaults_missing_optional_fields_test() {
  assert probe_result.decode_line(minimal_line)
    == Ok(ProbeResult(
      function: "double",
      mutant: "m2",
      status: Indistinguishable,
      inputs: [],
      expected: None,
      expected_inspect: "",
      actual_inspect: "",
      cases: 0,
      shrinks: 0,
      reason: "",
    ))
}

pub fn decode_line_reads_an_unsupported_reason_test() {
  assert probe_result.decode_line(unsupported_line)
    == Ok(ProbeResult(
      function: "apply",
      mutant: "m3",
      status: Unsupported,
      inputs: [],
      expected: None,
      expected_inspect: "",
      actual_inspect: "",
      cases: 0,
      shrinks: 0,
      reason: "parameter type is not derivable",
    ))
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
  assert probe_result.encode(ProbeResult(
      function: "add",
      mutant: "m1",
      status: Distinguished,
      inputs: ["0"],
      expected: None,
      expected_inspect: "1",
      actual_inspect: "2",
      cases: 3,
      shrinks: 1,
      reason: "",
    ))
    == "{\"function\":\"add\",\"mutant\":\"m1\",\"status\":\"distinguished\",\"inputs\":[\"0\"],\"expected\":null,\"expected_inspect\":\"1\",\"actual_inspect\":\"2\",\"cases\":3,\"shrinks\":1,\"reason\":\"\"}"
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
