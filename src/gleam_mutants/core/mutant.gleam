// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/operator.{type Operator}
import gleam_mutants/core/span.{type Span}

pub type Candidate {
  Candidate(
    path: String,
    operator: Operator,
    span: Span,
    original: String,
    replacement: String,
  )
}

pub type Mutant {
  Mutant(
    id: String,
    display_id: String,
    path: String,
    operator: Operator,
    operator_version: Int,
    source_digest: String,
    span: Span,
    original_digest: String,
    replacement_digest: String,
    original: String,
    replacement: String,
    line: Int,
    column: Int,
  )
}

pub fn normalize_path(path: String) -> String {
  let normalized = string.replace(path, "\\", "/")
  case string.starts_with(normalized, "./") {
    True -> string.drop_start(normalized, 2)
    False -> normalized
  }
}

fn length_prefix(value: String) -> String {
  int.to_string(string.byte_size(value)) <> ":" <> value
}

pub fn stable_id(source: String, candidate: Candidate) -> String {
  let source_digest = bytes.sha256(source)
  let fields = [
    normalize_path(candidate.path),
    operator.name(candidate.operator),
    int.to_string(operator.version(candidate.operator)),
    source_digest,
    int.to_string(span.start(candidate.span)),
    int.to_string(span.end(candidate.span)),
    bytes.sha256(candidate.original),
    bytes.sha256(candidate.replacement),
  ]

  fields
  |> list.map(length_prefix)
  |> string.concat
  |> bytes.sha256
}

pub fn from_candidate(source: String, candidate: Candidate) -> Mutant {
  let id = stable_id(source, candidate)
  let #(line, column) = line_column(source, span.start(candidate.span))
  Mutant(
    id: id,
    display_id: string.slice(id, 0, 20),
    path: normalize_path(candidate.path),
    operator: candidate.operator,
    operator_version: operator.version(candidate.operator),
    source_digest: bytes.sha256(source),
    span: candidate.span,
    original_digest: bytes.sha256(candidate.original),
    replacement_digest: bytes.sha256(candidate.replacement),
    original: candidate.original,
    replacement: candidate.replacement,
    line: line,
    column: column,
  )
}

pub fn with_display_id(mutant: Mutant, display_id: String) -> Mutant {
  Mutant(..mutant, display_id: display_id)
}

pub fn line_column(source: String, byte_offset: Int) -> #(Int, Int) {
  let prefix = bytes.unsafe_slice(source, 0, byte_offset)
  let lines = string.split(prefix, "\n")
  let line = list.length(lines)
  let column = case list.last(lines) {
    Ok(last) -> string.length(string.replace(last, "\r", "")) + 1
    Error(_) -> 1
  }
  #(line, column)
}

pub fn same_semantics(a: Mutant, b: Mutant) -> Bool {
  a.path == b.path
  && span.equal(a.span, b.span)
  && a.replacement_digest == b.replacement_digest
}
