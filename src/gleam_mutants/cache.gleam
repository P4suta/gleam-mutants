// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/config.{
  type CacheMode, CacheOff, CacheReadOnly, CacheReadWrite, CacheWriteOnly,
}
import gleam_mutants/core/bytes
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/outcome.{
  type Outcome, type Runtime, type RuntimeOutcome, Killed, RuntimeOutcome,
  Survived, TestError, TimedOut,
}
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile

pub fn fingerprint(
  workspace_digest: String,
  runtimes: List(Runtime),
  command: List(String),
  timeout_ms: Int,
) -> String {
  [
    "gleam-mutants-cache-v1",
    "0.1.0",
    workspace_digest,
    runtimes |> list.map(outcome.runtime_name) |> string.join(","),
    command |> list.map(length_prefix) |> string.concat,
    int.to_string(timeout_ms),
  ]
  |> list.map(length_prefix)
  |> string.concat
  |> bytes.sha256
}

fn length_prefix(value: String) -> String {
  int.to_string(string.byte_size(value)) <> ":" <> value
}

fn cache_path(fingerprint: String, mutant: Mutant, runtime: Runtime) -> String {
  platform.cache_directory()
  |> path.join("gleam-mutants/v1/outcomes")
  |> path.join(fingerprint)
  |> path.join(mutant.id <> "-" <> outcome.runtime_name(runtime) <> ".txt")
}

pub fn read(
  mode: CacheMode,
  fingerprint: String,
  mutant: Mutant,
  runtime: Runtime,
) -> Result(RuntimeOutcome, Nil) {
  case mode {
    CacheOff | CacheWriteOnly -> Error(Nil)
    CacheReadOnly | CacheReadWrite ->
      case simplifile.read(cache_path(fingerprint, mutant, runtime)) {
        Error(_) -> Error(Nil)
        Ok(text) ->
          case string.split(text, "\n") {
            [name, duration, ..] -> {
              use duration <- result.try(int.parse(duration))
              use value <- result.try(decode_outcome(name))
              Ok(RuntimeOutcome(runtime, value, duration, "", True))
            }
            _ -> Error(Nil)
          }
      }
  }
}

pub fn write(
  mode: CacheMode,
  fingerprint: String,
  mutant: Mutant,
  runtime_outcome: RuntimeOutcome,
) -> Nil {
  case mode {
    CacheOff | CacheReadOnly -> Nil
    CacheWriteOnly | CacheReadWrite -> {
      let target = cache_path(fingerprint, mutant, runtime_outcome.runtime)
      let _ = simplifile.create_directory_all(path.parent(target))
      let _ =
        simplifile.write(
          target,
          encode_outcome(runtime_outcome.outcome)
            <> "\n"
            <> int.to_string(runtime_outcome.duration_ms)
            <> "\n",
        )
      Nil
    }
  }
}

fn encode_outcome(value: Outcome) -> String {
  case value {
    Killed -> "killed"
    Survived -> "survived"
    TimedOut -> "timed-out"
    TestError(_) -> "test-error"
  }
}

fn decode_outcome(value: String) -> Result(Outcome, Nil) {
  case value {
    "killed" -> Ok(Killed)
    "survived" -> Ok(Survived)
    "timed-out" -> Ok(TimedOut)
    _ -> Error(Nil)
  }
}
