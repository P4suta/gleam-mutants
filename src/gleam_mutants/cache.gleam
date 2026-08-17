// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/config.{
  type CacheMode, CacheAuto, CacheOff, CacheReadOnly, CacheReadWrite,
  CacheWriteOnly,
}
import gleam_mutants/core/bytes
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/outcome.{
  type Outcome, type Runtime, type RuntimeOutcome, Killed, RuntimeOutcome,
  Survived, TestError, TimedOut,
}
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/version
import simplifile

pub fn fingerprint(
  workspace_digest: String,
  runtimes: List(Runtime),
  command: List(String),
  timeout_ms: Int,
) -> String {
  [
    "gleam-mutants-cache-v1",
    version.current,
    workspace_digest,
    runtimes |> list.map(outcome.runtime_name) |> string.join(","),
    command |> list.map(length_prefix) |> string.concat,
    int.to_string(timeout_ms),
  ]
  |> list.map(length_prefix)
  |> string.concat
  |> bytes.sha256
}

pub fn fingerprint_v1(
  workspace_digest: String,
  runtimes: List(Runtime),
  command: List(String),
  timeout_ms: Int,
  execution_context_hash: String,
) -> String {
  [
    fingerprint(workspace_digest, runtimes, command, timeout_ms),
    execution_context_hash,
  ]
  |> list.map(length_prefix)
  |> string.concat
  |> bytes.sha256
}

fn length_prefix(value: String) -> String {
  int.to_string(string.byte_size(value)) <> ":" <> value
}

pub fn workspace_id(workspace: String) -> String {
  workspace
  |> platform.resolve_path
  |> normalize_workspace_identity
  |> bytes.sha256
}

fn normalize_workspace_identity(workspace: String) -> String {
  case platform.os_name() {
    "windows" -> workspace |> string.replace("\\", "/") |> string.lowercase
    _ -> string.replace(workspace, "\\", "/")
  }
}

fn workspace_directory(id: String) -> String {
  platform.cache_directory()
  |> path.join("gleam-mutants/v1/workspaces")
  |> path.join(id)
}

fn cache_path(
  workspace: String,
  fingerprint: String,
  mutant: Mutant,
  runtime: Runtime,
) -> String {
  workspace_directory(workspace)
  |> path.join("outcomes")
  |> path.join(fingerprint)
  |> path.join(mutant.id <> "-" <> outcome.runtime_name(runtime) <> ".txt")
}

pub fn read(
  mode: CacheMode,
  workspace: String,
  fingerprint: String,
  mutant: Mutant,
  runtime: Runtime,
) -> Result(RuntimeOutcome, Nil) {
  case mode {
    CacheOff | CacheWriteOnly -> Error(Nil)
    CacheAuto | CacheReadOnly | CacheReadWrite ->
      case
        simplifile.read(cache_path(workspace, fingerprint, mutant, runtime))
      {
        Error(_) -> Error(Nil)
        Ok(text) -> {
          let lines = string.split(text, "\n")
          case lines {
            ["schema=1", outcome_line, duration_line, checksum_line, ..] -> {
              let payload =
                "schema=1\n" <> outcome_line <> "\n" <> duration_line <> "\n"
              use name <- result.try(field(outcome_line, "outcome="))
              use duration_text <- result.try(field(duration_line, "duration="))
              use expected_checksum <- result.try(field(
                checksum_line,
                "checksum=",
              ))
              use duration <- result.try(int.parse(duration_text))
              use _ <- result.try(
                case
                  duration >= 0 && bytes.sha256(payload) == expected_checksum
                {
                  True -> Ok(Nil)
                  False -> Error(Nil)
                },
              )
              use value <- result.try(decode_outcome(name))
              Ok(RuntimeOutcome(runtime, value, duration, "", True))
            }
            _ -> Error(Nil)
          }
        }
      }
  }
}

fn field(value: String, prefix: String) -> Result(String, Nil) {
  case string.starts_with(value, prefix) {
    True -> Ok(string.drop_start(value, string.length(prefix)))
    False -> Error(Nil)
  }
}

pub fn write(
  mode: CacheMode,
  workspace: String,
  fingerprint: String,
  mutant: Mutant,
  runtime_outcome: RuntimeOutcome,
) -> Result(Nil, String) {
  case mode, runtime_outcome.outcome {
    CacheOff, _ | CacheReadOnly, _ -> Ok(Nil)
    _, TimedOut | _, TestError(_) -> Ok(Nil)
    CacheAuto, Killed
    | CacheAuto, Survived
    | CacheWriteOnly, Killed
    | CacheWriteOnly, Survived
    | CacheReadWrite, Killed
    | CacheReadWrite, Survived
    -> {
      let target =
        cache_path(workspace, fingerprint, mutant, runtime_outcome.runtime)
      let temporary = target <> ".tmp-" <> platform.random_nonce()
      use _ <- result.try(
        simplifile.create_directory_all(path.parent(target))
        |> result.map_error(simplifile.describe_error),
      )
      let payload =
        "schema=1\noutcome="
        <> encode_outcome(runtime_outcome.outcome)
        <> "\nduration="
        <> int.to_string(runtime_outcome.duration_ms)
        <> "\n"
      let text = payload <> "checksum=" <> bytes.sha256(payload) <> "\n"
      use _ <- result.try(
        simplifile.write(temporary, text)
        |> result.map_error(simplifile.describe_error),
      )
      case simplifile.rename(at: temporary, to: target) {
        Ok(Nil) -> Ok(Nil)
        Error(error) -> {
          let _ = simplifile.delete_file(at: temporary)
          Error(simplifile.describe_error(error))
        }
      }
    }
  }
}

pub fn status(workspace: String) -> String {
  let id = workspace_id(workspace)
  let directory = workspace_directory(id) |> path.join("outcomes")
  case simplifile.is_directory(directory) {
    Ok(True) ->
      "cache: present\nworkspace: " <> id <> "\npath: " <> directory <> "\n"
    _ -> "cache: empty\nworkspace: " <> id <> "\npath: " <> directory <> "\n"
  }
}

pub fn clean(workspace: String) -> Result(Nil, String) {
  let target =
    workspace_directory(workspace_id(workspace)) |> path.join("outcomes")
  case simplifile.delete(target) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) -> Error(simplifile.describe_error(error))
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
