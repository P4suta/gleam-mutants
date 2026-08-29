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

/// File-wide data shared by every candidate discovered from one source.
///
/// A source digest used to be recomputed twice for every mutant, and finding a
/// line used to split the whole prefix before every site. Keeping both pieces
/// here makes catalogue construction proportional to the source plus the
/// number of candidates.
pub opaque type SourceIndex {
  SourceIndex(source_digest: String, line_starts: LineIndex)
}

/// A balanced predecessor index. Looking up an arbitrary candidate offset is
/// logarithmic even when one large source contains mutants on many lines.
type LineIndex {
  NoLine
  Line(byte_offset: Int, line_number: Int, left: LineIndex, right: LineIndex)
}

pub fn index_source(source: String) -> SourceIndex {
  let starts = index_lines(string.split(source, "\n"), 0, 1, [])
  SourceIndex(
    source_digest: bytes.sha256(source),
    line_starts: build_line_index(starts, list.length(starts)).0,
  )
}

fn index_lines(
  lines: List(String),
  byte_offset: Int,
  line_number: Int,
  indexed: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case lines {
    [] -> list.reverse(indexed)
    [line, ..rest] ->
      index_lines(
        rest,
        byte_offset + string.byte_size(line) + 1,
        line_number + 1,
        [#(byte_offset, line_number), ..indexed],
      )
  }
}

fn build_line_index(
  starts: List(#(Int, Int)),
  count: Int,
) -> #(LineIndex, List(#(Int, Int))) {
  case count <= 0 {
    True -> #(NoLine, starts)
    False -> {
      let left_count = count / 2
      let #(left, remaining) = build_line_index(starts, left_count)
      let assert [current, ..remaining] = remaining
      let #(right, remaining) =
        build_line_index(remaining, count - left_count - 1)
      #(Line(current.0, current.1, left, right), remaining)
    }
  }
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
  stable_id_from_digests(
    candidate,
    source_digest,
    bytes.sha256(candidate.original),
    bytes.sha256(candidate.replacement),
  )
}

fn stable_id_from_digests(
  candidate: Candidate,
  source_digest: String,
  original_digest: String,
  replacement_digest: String,
) -> String {
  let fields = [
    normalize_path(candidate.path),
    operator.name(candidate.operator),
    int.to_string(operator.version(candidate.operator)),
    source_digest,
    int.to_string(span.start(candidate.span)),
    int.to_string(span.end(candidate.span)),
    original_digest,
    replacement_digest,
  ]

  fields
  |> list.map(length_prefix)
  |> string.concat
  |> bytes.sha256
}

pub fn from_candidate(source: String, candidate: Candidate) -> Mutant {
  from_candidate_indexed(source, candidate, index_source(source))
}

/// Constructs a mutant using the digest and line index shared by its file.
pub fn from_candidate_indexed(
  source: String,
  candidate: Candidate,
  index: SourceIndex,
) -> Mutant {
  let original_digest = bytes.sha256(candidate.original)
  let replacement_digest = bytes.sha256(candidate.replacement)
  let id =
    stable_id_from_digests(
      candidate,
      index.source_digest,
      original_digest,
      replacement_digest,
    )
  let #(line, column) =
    line_column_indexed(source, span.start(candidate.span), index.line_starts)
  Mutant(
    id: id,
    display_id: string.slice(id, 0, 20),
    path: normalize_path(candidate.path),
    operator: candidate.operator,
    operator_version: operator.version(candidate.operator),
    source_digest: index.source_digest,
    span: candidate.span,
    original_digest: original_digest,
    replacement_digest: replacement_digest,
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
  let index = index_source(source)
  line_column_indexed(source, byte_offset, index.line_starts)
}

fn line_column_indexed(
  source: String,
  byte_offset: Int,
  starts: LineIndex,
) -> #(Int, Int) {
  let #(line_start, line_number) = locate_line(starts, byte_offset, #(0, 1))
  let prefix = bytes.unsafe_slice(source, line_start, byte_offset)
  #(line_number, string.length(string.replace(prefix, "\r", "")) + 1)
}

fn locate_line(
  starts: LineIndex,
  byte_offset: Int,
  current: #(Int, Int),
) -> #(Int, Int) {
  case starts {
    NoLine -> current
    Line(offset, line, left, right) ->
      case offset <= byte_offset {
        True -> locate_line(right, byte_offset, #(offset, line))
        False -> locate_line(left, byte_offset, current)
      }
  }
}

pub fn same_semantics(a: Mutant, b: Mutant) -> Bool {
  a.path == b.path
  && span.equal(a.span, b.span)
  && a.replacement_digest == b.replacement_digest
}
