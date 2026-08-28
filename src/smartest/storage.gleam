//// Filesystem shell for reviewable findings and the tracked corpus.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import smartest/corpus.{type Envelope}
import smartest/corpus_json
import smartest/evidence.{type TestId}
import smartest/internal/path
import smartest/internal/shell

const generator_manifest_schema = 1

/// A property/model generator schema attached to its stable test id.
pub type GeneratorBinding {
  GeneratorBinding(test_id: TestId, schema: String)
}

pub type GeneratorAudit {
  GeneratorAudit(fresh: Int, stale: Int)
}

pub fn inbox_path(root: String, id: String) -> String {
  artifact_path(root, "inbox", id)
}

pub fn corpus_path(root: String, id: String) -> String {
  artifact_path(root, "corpus", id)
}

pub fn rejected_path(root: String, id: String) -> String {
  artifact_path(root, "rejected", id)
}

pub fn generator_manifest_path(root: String) -> String {
  root |> path.join(".smartest") |> path.join("generator-manifest-v1.json")
}

fn artifact_path(root: String, lifecycle: String, id: String) -> String {
  root
  |> path.join("test/smartest")
  |> path.join(lifecycle)
  |> path.join(id <> ".json")
}

/// Places a new finding in the review inbox. Repeating the exact same write is
/// idempotent; a different artifact with the same id is a visible conflict.
pub fn put_inbox(root: String, envelope: Envelope) -> Result(String, String) {
  use _ <- result.try(validate_id(envelope.id))
  use _ <- result.try(
    corpus.validate(envelope)
    |> result.map_error(fn(error) {
      "invalid corpus envelope: " <> string.inspect(error)
    }),
  )
  case envelope.lifecycle {
    corpus.Inbox -> write_new(inbox_path(root, envelope.id), envelope)
    _ -> Error("only inbox artifacts can be written with put_inbox")
  }
}

pub fn load_inbox(root: String, id: String) -> Result(Envelope, String) {
  load(inbox_path(root, id), id, corpus.Inbox)
}

pub fn load_corpus(root: String, id: String) -> Result(Envelope, String) {
  load(corpus_path(root, id), id, corpus.Accepted)
}

pub fn load_rejected(root: String, id: String) -> Result(Envelope, String) {
  load(rejected_path(root, id), id, corpus.Rejected)
}

pub fn list_inbox(root: String) -> Result(List(Envelope), String) {
  list_directory(directory(root, "inbox"), corpus.Inbox)
}

pub fn list_corpus(root: String) -> Result(List(Envelope), String) {
  list_directory(directory(root, "corpus"), corpus.Accepted)
}

pub fn list_rejected(root: String) -> Result(List(Envelope), String) {
  list_directory(directory(root, "rejected"), corpus.Rejected)
}

pub fn accept(
  root: String,
  id: String,
  at_ms at_ms: Int,
  review_note review_note: String,
  human_oracle human_oracle: Option(String),
) -> Result(Envelope, String) {
  use envelope <- result.try(load_inbox(root, id))
  let accepted =
    corpus.accept(
      envelope,
      at_ms: at_ms,
      review_note: review_note,
      human_oracle: human_oracle,
    )
  use _ <- result.try(write_new(corpus_path(root, id), accepted))
  use _ <- result.try(delete_artifact(inbox_path(root, id)))
  Ok(accepted)
}

pub fn reject(
  root: String,
  id: String,
  reason: String,
) -> Result(Envelope, String) {
  use envelope <- result.try(load_inbox(root, id))
  let rejected = corpus.reject(envelope, reason)
  use _ <- result.try(write_new(rejected_path(root, id), rejected))
  use _ <- result.try(delete_artifact(inbox_path(root, id)))
  Ok(rejected)
}

/// Explicitly migrates a stable test id in every tracked lifecycle directory.
pub fn move_test_id(
  root: String,
  old: TestId,
  new: TestId,
) -> Result(Int, String) {
  move_directories(
    [
      #(directory(root, "inbox"), corpus.Inbox),
      #(directory(root, "corpus"), corpus.Accepted),
      #(directory(root, "rejected"), corpus.Rejected),
    ],
    old,
    new,
    0,
  )
}

/// Atomically replaces the ephemeral manifest produced by an unfiltered test
/// discovery. Duplicate identical entries are collapsed; conflicting schemas
/// fail before the existing manifest is touched.
pub fn write_generator_manifest(
  root: String,
  bindings: List(GeneratorBinding),
) -> Result(String, String) {
  use bindings <- result.try(normalize_bindings(bindings))
  let target = generator_manifest_path(root)
  let text =
    json.object([
      #("schema_version", json.int(generator_manifest_schema)),
      #(
        "generators",
        json.array(bindings, fn(binding) {
          json.object([
            #(
              "test_id",
              json.string(evidence.test_id_to_string(binding.test_id)),
            ),
            #("schema", json.string(binding.schema)),
          ])
        }),
      ),
    ])
    |> json.to_string
  use _ <- result.try(write_atomic(target, text <> "\n"))
  Ok(target)
}

pub fn read_generator_manifest(
  root: String,
) -> Result(List(GeneratorBinding), String) {
  let target = generator_manifest_path(root)
  use text <- result.try(
    simplifile.read(target)
    |> result.map_error(fn(error) {
      case error {
        simplifile.Enoent ->
          "current generator manifest is missing; run an unfiltered `gleam test` first"
        _ ->
          "could not read generator manifest "
          <> target
          <> ": "
          <> simplifile.describe_error(error)
      }
    }),
  )
  use bindings <- result.try(
    json.parse(text, generator_manifest_decoder())
    |> result.map_error(fn(error) {
      "invalid generator manifest " <> target <> ": " <> string.inspect(error)
    }),
  )
  normalize_bindings(bindings)
}

/// Compares accepted artifacts with the last complete discovery manifest and
/// persists every mismatch as blocking `StaleEvidence`.
pub fn migrate_generator_manifest(
  root: String,
) -> Result(GeneratorAudit, String) {
  use bindings <- result.try(read_generator_manifest(root))
  use entries <- result.try(list_directory_with_paths(
    directory(root, "corpus"),
    corpus.Accepted,
  ))
  migrate_generator_entries(entries, bindings, GeneratorAudit(0, 0))
}

/// Deletes only accepted artifacts already proven stale against a readable
/// current manifest. Absence/corruption of that manifest prevents deletion.
pub fn prune_stale_corpus(root: String) -> Result(Int, String) {
  use _ <- result.try(read_generator_manifest(root))
  use _ <- result.try(migrate_generator_manifest(root))
  use entries <- result.try(list_directory_with_paths(
    directory(root, "corpus"),
    corpus.Accepted,
  ))
  prune_stale_entries(entries, 0)
}

fn generator_manifest_decoder() -> decode.Decoder(List(GeneratorBinding)) {
  use version <- decode.field("schema_version", decode.int)
  use bindings <- decode.field(
    "generators",
    decode.list(generator_binding_decoder()),
  )
  case version == generator_manifest_schema {
    True -> decode.success(bindings)
    False -> decode.failure([], "supported generator manifest schema")
  }
}

fn generator_binding_decoder() -> decode.Decoder(GeneratorBinding) {
  use id_text <- decode.field("test_id", decode.string)
  use schema <- decode.field("schema", decode.string)
  case evidence.test_id_from_string(id_text) {
    Ok(id) -> decode.success(GeneratorBinding(id, schema))
    Error(_) ->
      decode.failure(
        GeneratorBinding(evidence.test_id("invalid", "invalid", "invalid"), ""),
        "canonical test id",
      )
  }
}

fn normalize_bindings(
  bindings: List(GeneratorBinding),
) -> Result(List(GeneratorBinding), String) {
  bindings
  |> list.sort(fn(left, right) {
    string.compare(
      evidence.test_id_to_string(left.test_id),
      evidence.test_id_to_string(right.test_id),
    )
  })
  |> normalize_sorted_bindings([])
}

fn normalize_sorted_bindings(
  bindings: List(GeneratorBinding),
  accumulated: List(GeneratorBinding),
) -> Result(List(GeneratorBinding), String) {
  case bindings {
    [] -> Ok(list.reverse(accumulated))
    [binding, ..rest] ->
      case string.trim(binding.schema) {
        "" ->
          Error(
            "generator schema is empty for "
            <> evidence.test_id_to_string(binding.test_id),
          )
        _ ->
          case accumulated {
            [previous, ..]
              if previous.test_id == binding.test_id
              && previous.schema == binding.schema
            -> normalize_sorted_bindings(rest, accumulated)
            [previous, ..] if previous.test_id == binding.test_id ->
              Error(
                "conflicting generator schemas for "
                <> evidence.test_id_to_string(binding.test_id)
                <> ": "
                <> previous.schema
                <> " and "
                <> binding.schema,
              )
            _ -> normalize_sorted_bindings(rest, [binding, ..accumulated])
          }
      }
  }
}

fn migrate_generator_entries(
  entries: List(#(String, Envelope)),
  bindings: List(GeneratorBinding),
  audit: GeneratorAudit,
) -> Result(GeneratorAudit, String) {
  case entries {
    [] -> Ok(audit)
    [#(target, envelope), ..rest] ->
      case stale_reason(envelope, bindings) {
        None ->
          case envelope.state {
            evidence.StaleEvidence(_) ->
              migrate_generator_entries(
                rest,
                bindings,
                GeneratorAudit(..audit, stale: audit.stale + 1),
              )
            _ ->
              migrate_generator_entries(
                rest,
                bindings,
                GeneratorAudit(..audit, fresh: audit.fresh + 1),
              )
          }
        Some(reason) -> {
          let stale =
            corpus.Envelope(..envelope, state: evidence.StaleEvidence(reason))
          use _ <- result.try(write_atomic(
            target,
            corpus_json.encode(stale) <> "\n",
          ))
          migrate_generator_entries(
            rest,
            bindings,
            GeneratorAudit(..audit, stale: audit.stale + 1),
          )
        }
      }
  }
}

fn stale_reason(
  envelope: Envelope,
  bindings: List(GeneratorBinding),
) -> Option(String) {
  case
    list.find(bindings, fn(binding) { binding.test_id == envelope.test_id })
  {
    Error(Nil) ->
      Some(
        "generator test "
        <> evidence.test_id_to_string(envelope.test_id)
        <> " is not present in the current manifest",
      )
    Ok(binding) ->
      case corpus.freshness(envelope, binding.schema) {
        corpus.Fresh -> None
        corpus.Stale(expected, found) ->
          Some(
            "generator schema changed: expected "
            <> expected
            <> ", found "
            <> found,
          )
      }
  }
}

fn prune_stale_entries(
  entries: List(#(String, Envelope)),
  deleted: Int,
) -> Result(Int, String) {
  case entries {
    [] -> Ok(deleted)
    [#(target, envelope), ..rest] ->
      case envelope.state {
        evidence.StaleEvidence(_) -> {
          use _ <- result.try(delete_artifact(target))
          prune_stale_entries(rest, deleted + 1)
        }
        _ -> prune_stale_entries(rest, deleted)
      }
  }
}

fn move_directories(
  directories: List(#(String, corpus.Lifecycle)),
  old: TestId,
  new: TestId,
  changed: Int,
) -> Result(Int, String) {
  case directories {
    [] -> Ok(changed)
    [#(current, lifecycle), ..rest] -> {
      use entries <- result.try(list_directory_with_paths(current, lifecycle))
      use count <- result.try(move_entries(entries, old, new, 0))
      move_directories(rest, old, new, changed + count)
    }
  }
}

fn move_entries(
  entries: List(#(String, Envelope)),
  old: TestId,
  new: TestId,
  changed: Int,
) -> Result(Int, String) {
  case entries {
    [] -> Ok(changed)
    [#(target, envelope), ..rest] ->
      case envelope.test_id == old {
        False -> move_entries(rest, old, new, changed)
        True -> {
          use _ <- result.try(write_atomic(
            target,
            corpus_json.encode(corpus.with_test_id(envelope, new)) <> "\n",
          ))
          move_entries(rest, old, new, changed + 1)
        }
      }
  }
}

fn directory(root: String, lifecycle: String) -> String {
  root |> path.join("test/smartest") |> path.join(lifecycle)
}

fn write_new(target: String, envelope: Envelope) -> Result(String, String) {
  use _ <- result.try(
    corpus.validate(envelope)
    |> result.map_error(fn(error) {
      "invalid corpus envelope: " <> corpus.validation_error_message(error)
    }),
  )
  let text = corpus_json.encode(envelope) <> "\n"
  case simplifile.read(target) {
    Ok(existing) if existing == text -> Ok(target)
    Ok(_) -> Error("refusing to overwrite a different artifact at " <> target)
    Error(simplifile.Enoent) -> {
      use _ <- result.try(write_atomic(target, text))
      Ok(target)
    }
    Error(error) ->
      Error(
        "could not inspect artifact "
        <> target
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}

fn write_atomic(target: String, text: String) -> Result(Nil, String) {
  let parent = path.parent(target)
  use _ <- result.try(
    simplifile.create_directory_all(parent)
    |> result.map_error(fn(error) {
      "could not create corpus directory "
      <> parent
      <> ": "
      <> simplifile.describe_error(error)
    }),
  )
  let temporary = target <> ".tmp-" <> shell.random_nonce()
  use _ <- result.try(
    simplifile.write(temporary, text)
    |> result.map_error(fn(error) {
      "could not stage corpus artifact "
      <> temporary
      <> ": "
      <> simplifile.describe_error(error)
    }),
  )
  case simplifile.rename(at: temporary, to: target) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      let _ = simplifile.delete_file(at: temporary)
      Error(
        "could not commit corpus artifact "
        <> target
        <> ": "
        <> simplifile.describe_error(error),
      )
    }
  }
}

fn load(
  target: String,
  id: String,
  lifecycle: corpus.Lifecycle,
) -> Result(Envelope, String) {
  use _ <- result.try(validate_id(id))
  use text <- result.try(
    simplifile.read(target)
    |> result.map_error(fn(error) {
      "could not read artifact "
      <> target
      <> ": "
      <> simplifile.describe_error(error)
    }),
  )
  use envelope <- result.try(
    corpus_json.decode(text)
    |> result.map_error(fn(error) { target <> ": " <> error }),
  )
  ensure_lifecycle(target, envelope, lifecycle)
}

fn list_directory(
  directory: String,
  lifecycle: corpus.Lifecycle,
) -> Result(List(Envelope), String) {
  use entries <- result.try(list_directory_with_paths(directory, lifecycle))
  Ok(list.map(entries, fn(entry) { entry.1 }))
}

fn list_directory_with_paths(
  directory: String,
  lifecycle: corpus.Lifecycle,
) -> Result(List(#(String, Envelope)), String) {
  case simplifile.read_directory(at: directory) {
    Error(simplifile.Enoent) -> Ok([])
    Error(error) ->
      Error(
        "could not list corpus directory "
        <> directory
        <> ": "
        <> simplifile.describe_error(error),
      )
    Ok(entries) ->
      entries
      |> list.filter(fn(entry) { string.ends_with(entry, ".json") })
      |> list.sort(string.compare)
      |> decode_entries(directory, lifecycle, [])
  }
}

fn decode_entries(
  entries: List(String),
  directory: String,
  lifecycle: corpus.Lifecycle,
  accumulated: List(#(String, Envelope)),
) -> Result(List(#(String, Envelope)), String) {
  case entries {
    [] -> Ok(list.reverse(accumulated))
    [entry, ..rest] -> {
      let target = path.join(directory, entry)
      use text <- result.try(
        simplifile.read(target)
        |> result.map_error(fn(error) {
          "could not read artifact "
          <> target
          <> ": "
          <> simplifile.describe_error(error)
        }),
      )
      use envelope <- result.try(
        corpus_json.decode(text)
        |> result.map_error(fn(error) { target <> ": " <> error }),
      )
      use envelope <- result.try(ensure_lifecycle(target, envelope, lifecycle))
      decode_entries(rest, directory, lifecycle, [
        #(target, envelope),
        ..accumulated
      ])
    }
  }
}

fn ensure_lifecycle(
  target: String,
  envelope: Envelope,
  expected: corpus.Lifecycle,
) -> Result(Envelope, String) {
  case envelope.lifecycle == expected {
    True -> Ok(envelope)
    False ->
      Error(
        target
        <> ": artifact lifecycle "
        <> string.inspect(envelope.lifecycle)
        <> " does not match its directory "
        <> string.inspect(expected),
      )
  }
}

fn delete_artifact(target: String) -> Result(Nil, String) {
  simplifile.delete_file(at: target)
  |> result.map_error(fn(error) {
    "could not remove inbox artifact "
    <> target
    <> ": "
    <> simplifile.describe_error(error)
  })
}

fn validate_id(id: String) -> Result(Nil, String) {
  let valid =
    id != ""
    && id != "."
    && id != ".."
    && id
    |> string.to_utf_codepoints
    |> list.map(string.utf_codepoint_to_int)
    |> list.all(valid_id_codepoint)
  case valid {
    True -> Ok(Nil)
    False -> Error("invalid artifact id " <> string.inspect(id))
  }
}

fn valid_id_codepoint(code: Int) -> Bool {
  code >= 48
  && code <= 57
  || code >= 65
  && code <= 90
  || code >= 97
  && code <= 122
  || code == 45
  || code == 46
  || code == 95
}
