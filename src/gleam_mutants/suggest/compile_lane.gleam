//// Fail-closed planning for mutation sites that cannot be activated by a
//// runtime expression schema.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import glance
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/span
import gleam_mutants/platform

/// Why a catalogued raw source mutation was not safe to apply.
pub type ApplyError {
  SourceChanged(expected_digest: String, actual_digest: String)
  OriginalChanged(expected: String, actual: String)
  SpanOutsideSource(start: Int, end: Int, source_size: Int)
  InvalidJob(field: String)
}

/// The compiler's statement about one isolated source mutation.
///
/// A successful build says only that the mutant is executable; it is not an
/// oracle and therefore makes no correctness claim. `cached` records whether
/// this exact content-addressed result came from persistent storage.
pub type CompileOutcome {
  Compiled(cached: Bool)
  Rejected(diagnostic: String, cached: Bool)
  CompileTimedOut
}

/// The source construct that requires a real compiler invocation.
pub type Site {
  ModuleConstant(name: String)
}

/// One isolated, content-addressed per-mutant compile operation.
pub type Job {
  CompileJob(mutant: Mutant, site: Site, cache_key: String)
}

/// Compile jobs plus sites no typed boundary currently recognises.
pub type Plan {
  CompilePlan(jobs: List(Job), unsupported: List(Mutant))
}

/// Classifies function-external mutants without rewriting constants as
/// functions.
///
/// A cache key includes the complete stable mutant id, selected target and
/// compiler fingerprint, plus the complete workspace digest. Reusing output
/// across any of those boundaries could report evidence produced by different
/// semantics, including a changed imported module.
pub fn plan(
  module: glance.Module,
  mutants: List(Mutant),
  target: String,
  compiler_fingerprint: String,
  workspace_digest: String,
) -> Plan {
  let #(jobs, unsupported) =
    list.fold(mutants, #([], []), fn(acc, mutation) {
      let #(jobs, unsupported) = acc
      case constant_site(module, mutation) {
        Ok(site) -> #(
          [
            CompileJob(
              mutation,
              site,
              compile_key(
                mutation,
                target,
                compiler_fingerprint,
                workspace_digest,
              ),
            ),
            ..jobs
          ],
          unsupported,
        )
        Error(Nil) -> #(jobs, [mutation, ..unsupported])
      }
    })
  CompilePlan(list.reverse(jobs), list.reverse(unsupported))
}

pub fn compile_key(
  mutation: Mutant,
  target: String,
  compiler_fingerprint: String,
  workspace_digest: String,
) -> String {
  [mutation.id, target, compiler_fingerprint, workspace_digest]
  |> list.map(length_prefix)
  |> string.concat
  |> bytes.sha256
}

/// Applies one compile-lane mutant only after revalidating its complete source
/// identity and byte span.
///
/// The catalogue stores byte offsets, so this deliberately uses byte slices
/// rather than Unicode codepoint offsets. No source is written if the job is
/// stale or its stored hashes have been corrupted.
pub fn apply_source(
  source: String,
  mutation: Mutant,
) -> Result(String, ApplyError) {
  let actual_digest = bytes.sha256(source)
  case actual_digest == mutation.source_digest {
    False -> Error(SourceChanged(mutation.source_digest, actual_digest))
    True -> {
      let start = span.start(mutation.span)
      let end = span.end(mutation.span)
      let size = string.byte_size(source)
      case start < 0 || end < start || end > size {
        True -> Error(SpanOutsideSource(start, end, size))
        False ->
          case
            bytes.sha256(mutation.original) == mutation.original_digest,
            bytes.sha256(mutation.replacement) == mutation.replacement_digest
          {
            False, _ -> Error(InvalidJob("original_digest"))
            _, False -> Error(InvalidJob("replacement_digest"))
            True, True -> {
              let actual = bytes.unsafe_slice(source, start, end)
              case actual == mutation.original {
                False -> Error(OriginalChanged(mutation.original, actual))
                True ->
                  Ok(
                    bytes.unsafe_slice(source, 0, start)
                    <> mutation.replacement
                    <> bytes.unsafe_slice(source, end, size),
                  )
              }
            }
          }
      }
    }
  }
}

/// Classifies the result of `gleam build` without treating compilation as a
/// correctness oracle.
pub fn classify_process(process: platform.ProcessResult) -> CompileOutcome {
  case process.timed_out, process.status {
    True, _ -> CompileTimedOut
    False, 0 -> Compiled(False)
    False, status -> {
      let diagnostic = process_diagnostic(process)
      Rejected(
        case diagnostic {
          "" -> "gleam build exited " <> int.to_string(status)
          text -> text
        },
        False,
      )
    }
  }
}

/// Encodes only stable compile outcomes. Timeouts are deliberately not cached
/// because they describe a transient budget exhaustion, not source semantics.
pub fn encode_cache(job: Job, outcome: CompileOutcome) -> Option(String) {
  let record = case outcome {
    CompileTimedOut -> None
    Compiled(_) -> Some(#("compiled", ""))
    Rejected(diagnostic, _) -> Some(#("rejected", diagnostic))
  }
  record
  |> option.map(fn(record) {
    let payload = cache_payload(job.cache_key, record.0, record.1)
    json.object([
      #("schema", json.int(1)),
      #("cache_key", json.string(job.cache_key)),
      #("status", json.string(record.0)),
      #("diagnostic", json.string(record.1)),
      #("checksum", json.string(bytes.sha256(payload))),
    ])
    |> json.to_string
  })
}

/// Reads an exact-key, checksummed cache entry. Any stale, corrupt or unknown
/// entry is a miss so the caller recompiles rather than guessing.
pub fn decode_cache(job: Job, text: String) -> Result(CompileOutcome, Nil) {
  use decoded <- result.try(
    json.parse(text, cache_decoder())
    |> result.map_error(fn(_) { Nil }),
  )
  let #(schema, cache_key, status, diagnostic, checksum) = decoded
  use _ <- result.try(
    case
      schema == 1
      && cache_key == job.cache_key
      && checksum == bytes.sha256(cache_payload(cache_key, status, diagnostic))
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  case status {
    "compiled" if diagnostic == "" -> Ok(Compiled(True))
    "rejected" -> Ok(Rejected(diagnostic, True))
    _ -> Error(Nil)
  }
}

fn cache_decoder() -> decode.Decoder(#(Int, String, String, String, String)) {
  use schema <- decode.field("schema", decode.int)
  use cache_key <- decode.field("cache_key", decode.string)
  use status <- decode.field("status", decode.string)
  use diagnostic <- decode.field("diagnostic", decode.string)
  use checksum <- decode.field("checksum", decode.string)
  decode.success(#(schema, cache_key, status, diagnostic, checksum))
}

fn cache_payload(
  cache_key: String,
  status: String,
  diagnostic: String,
) -> String {
  ["smartest-compile-cache-v1", cache_key, status, diagnostic]
  |> list.map(length_prefix)
  |> string.concat
}

fn process_diagnostic(process: platform.ProcessResult) -> String {
  [process.stdout, process.stderr]
  |> list.map(string.trim)
  |> list.filter(fn(text) { text != "" })
  |> string.join("\n")
}

fn constant_site(module: glance.Module, mutation: Mutant) -> Result(Site, Nil) {
  module.constants
  |> list.map(fn(definition) { definition.definition })
  |> list.find(fn(constant) {
    let glance.Span(start, end) = constant.location
    span.start(mutation.span) >= start && span.end(mutation.span) <= end
  })
  |> result.map(fn(constant) { ModuleConstant(constant.name) })
}

fn length_prefix(value: String) -> String {
  int.to_string(string.byte_size(value)) <> ":" <> value
}
