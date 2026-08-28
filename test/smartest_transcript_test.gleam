// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{Some}
import gleam/result
import gleam/string
import smartest/evidence
import smartest/runner
import smartest/transcript

fn api_transcript() -> transcript.Transcript(String, String) {
  transcript.new(
    schema: "api-v1",
    exchanges: [#("GET /users/1", "200 Ada"), #("GET /users/2", "404")],
    render_request: fn(request) { request },
  )
}

fn equal(left: String, right: String) -> Bool {
  left == right
}

pub fn transcript_replay_is_lazy_capability_gated_and_consumes_in_order_test() {
  let _lazy =
    transcript.replay(
      api_transcript(),
      capabilities: [evidence.Network],
      run: fn(_) { panic as "transcript callback ran during construction" },
    )
  let value =
    transcript.replay(
      api_transcript(),
      capabilities: [evidence.Network],
      run: fn(replay) {
        use first <- result.try(transcript.exchange(
          replay,
          "GET /users/1",
          equal,
        ))
        let #(replay, response) = first
        assert response == "200 Ada"
        use second <- result.try(transcript.exchange(
          replay,
          "GET /users/2",
          equal,
        ))
        let #(replay, response) = second
        assert response == "404"
        Ok(replay)
      },
    )
  let entry = runner.entry("demo", "contract_test", "api_test", value)

  let guarded = runner.run([entry], runner.default_options())
  let assert [unsafe] = guarded.results
  assert unsafe.status == runner.Unsafe

  let exercised =
    runner.run(
      [entry],
      runner.default_options()
        |> runner.with_capabilities([evidence.Network]),
    )
  let assert [passing] = exercised.results
  assert passing.status == runner.Passed
  assert passing.cases == 1
  assert passing.oracle
    == Some(evidence.ExternalOracle("recorded transcript: api-v1"))
}

pub fn transcript_replay_reports_request_mismatch_with_the_event_index_test() {
  let value =
    transcript.replay(api_transcript(), capabilities: [], run: fn(replay) {
      transcript.exchange(replay, "DELETE /users/1", equal)
      |> result.map(fn(pair) { pair.0 })
    })
  let report =
    runner.run(
      [runner.entry("demo", "contract_test", "mismatch_test", value)],
      runner.default_options(),
    )
  let assert [failure] = report.results
  assert failure.status == runner.Failed
  assert string.contains(failure.message, "event 0")
  assert string.contains(failure.message, "GET /users/1")
  assert string.contains(failure.message, "DELETE /users/1")
}

pub fn transcript_replay_rejects_an_unconsumed_suffix_test() {
  let value =
    transcript.replay(api_transcript(), capabilities: [], run: fn(replay) {
      use first <- result.try(transcript.exchange(replay, "GET /users/1", equal))
      Ok(first.0)
    })
  let report =
    runner.run(
      [runner.entry("demo", "contract_test", "suffix_test", value)],
      runner.default_options(),
    )
  let assert [failure] = report.results
  assert failure.status == runner.Failed
  assert string.contains(failure.message, "1 unconsumed")
}

pub fn transcript_schema_changes_are_visible_in_the_fingerprint_test() {
  let first = api_transcript()
  let second =
    transcript.new(
      schema: "api-v2",
      exchanges: [#("GET /users/1", "200 Ada")],
      render_request: fn(request) { request },
    )
  assert transcript.schema_fingerprint(first)
    != transcript.schema_fingerprint(second)
}
