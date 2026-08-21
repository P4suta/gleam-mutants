// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/json
import gleam/list
import gleam/order.{type Order, Eq}
import gleam/result
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/catalog.{type RejectedMutant}
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator
import gleam_mutants/core/outcome.{
  type Outcome, Killed, Survived, TestError, TimedOut,
}
import gleam_mutants/core/span
import gleam_mutants/report.{type MutantResult, type RunReport}

pub type SourceFile {
  SourceFile(path: String, source: String)
}

type ProjectedMutant {
  Executed(MutantResult)
  CompileRejected(RejectedMutant)
}

type Position {
  Position(line: Int, column: Int)
}

pub fn to_json(
  report: RunReport,
  source_files: List(SourceFile),
  high: Int,
  low: Int,
) -> Result(String, String) {
  use _ <- result.try(validate_thresholds(high, low))
  let source_files =
    source_files
    |> list.map(fn(file) {
      SourceFile(mutant.normalize_path(file.path), file.source)
    })
    |> list.sort(fn(a, b) { string.compare(a.path, b.path) })
  use _ <- result.try(validate_source_files(source_files))
  let items =
    list.append(
      list.map(report.results, Executed),
      list.map(report.rejected, CompileRejected),
    )
  use _ <- result.try(validate_item_sources(items, source_files))
  use files <- result.try(
    list.try_map(source_files, fn(file) {
      use mutants <- result.try(
        items
        |> list.filter(fn(item) { item_mutant(item).path == file.path })
        |> list.sort(projected_compare)
        |> list.try_map(projected_json(file.source, _)),
      )
      Ok(#(
        file.path,
        json.object([
          #("language", json.string("gleam")),
          #("source", json.string(file.source)),
          #("mutants", json.array(mutants, fn(value) { value })),
        ]),
      ))
    }),
  )
  Ok(
    json.object([
      #("schemaVersion", json.string("1.0")),
      #(
        "thresholds",
        json.object([#("high", json.int(high)), #("low", json.int(low))]),
      ),
      #("files", json.object(files)),
    ])
    |> json.to_string,
  )
}

fn validate_thresholds(high: Int, low: Int) -> Result(Nil, String) {
  case low >= 0 && low <= high && high <= 100 {
    True -> Ok(Nil)
    False -> Error("report thresholds must satisfy 0 <= low <= high <= 100")
  }
}

fn validate_source_files(files: List(SourceFile)) -> Result(Nil, String) {
  let paths = list.map(files, fn(file) { file.path })
  case list.length(paths) == list.length(list.unique(paths)) {
    True -> Ok(Nil)
    False -> Error("Stryker report source paths must be unique")
  }
}

fn validate_item_sources(
  items: List(ProjectedMutant),
  files: List(SourceFile),
) -> Result(Nil, String) {
  use item <- list.try_each(items)
  let item_path = item_mutant(item).path
  case list.any(files, fn(file) { file.path == item_path }) {
    True -> Ok(Nil)
    False -> Error("missing original source for mutant file " <> item_path)
  }
}

fn item_mutant(item: ProjectedMutant) -> Mutant {
  case item {
    Executed(result) -> result.mutant
    CompileRejected(rejected) -> rejected.mutant
  }
}

fn projected_compare(a: ProjectedMutant, b: ProjectedMutant) -> Order {
  let a = item_mutant(a)
  let b = item_mutant(b)
  case int.compare(span.start(a.span), span.start(b.span)) {
    Eq ->
      case int.compare(span.end(a.span), span.end(b.span)) {
        Eq -> string.compare(a.id, b.id)
        order -> order
      }
    order -> order
  }
}

fn projected_json(
  source: String,
  item: ProjectedMutant,
) -> Result(json.Json, String) {
  let mutant = item_mutant(item)
  use location <- result.try(location_json(source, mutant))
  let common = [
    #("id", json.string(mutant.id)),
    #("mutatorName", json.string(operator.name(mutant.operator))),
    #("replacement", json.string(mutant.replacement)),
    #("location", location),
  ]
  case item {
    CompileRejected(rejected) ->
      Ok(
        json.object(
          list.append(common, [
            #("status", json.string("CompileError")),
            #("statusReason", json.string(rejected.diagnostic)),
          ]),
        ),
      )
    Executed(result) -> {
      let fields =
        list.append(common, [
          #("status", json.string(status(result.aggregate))),
          #(
            "duration",
            json.int(
              list.fold(result.outcomes, 0, fn(total, outcome) {
                total + outcome.duration_ms
              }),
            ),
          ),
        ])
      let fields = case status_reason(result) {
        "" -> fields
        reason -> list.append(fields, [#("statusReason", json.string(reason))])
      }
      Ok(json.object(fields))
    }
  }
}

fn status(outcome: Outcome) -> String {
  case outcome {
    Killed -> "Killed"
    Survived -> "Survived"
    TimedOut -> "Timeout"
    TestError(_) -> "RuntimeError"
  }
}

fn status_reason(result: MutantResult) -> String {
  let messages = case result.aggregate {
    TestError(message) if message != "" -> [message]
    _ -> []
  }
  result.outcomes
  |> list.fold(messages, fn(messages, outcome) {
    case outcome.output {
      "" -> messages
      output -> list.append(messages, [output])
    }
  })
  |> list.unique
  |> string.join("\n")
}

fn location_json(source: String, mutant: Mutant) -> Result(json.Json, String) {
  let start = span.start(mutant.span)
  let end = span.end(mutant.span)
  use original <- result.try(
    bytes.slice(source, start, end)
    |> result.map_error(fn(_) {
      "mutant byte span is not valid UTF-8 in " <> mutant.path
    }),
  )
  use _ <- result.try(case original == mutant.original {
    True -> Ok(Nil)
    False ->
      Error(
        "mutant byte span does not match original source in " <> mutant.path,
      )
  })
  use start_position <- result.try(position(source, start, mutant.path))
  use end_position <- result.try(position(source, end, mutant.path))
  Ok(
    json.object([
      #("start", position_json(start_position)),
      #("end", position_json(end_position)),
    ]),
  )
}

fn position(
  source: String,
  offset: Int,
  path: String,
) -> Result(Position, String) {
  use prefix <- result.try(
    bytes.slice(source, 0, offset)
    |> result.map_error(fn(_) { "invalid mutant byte offset in " <> path }),
  )
  Ok(utf16_position(string.to_utf_codepoints(prefix), 1, 1))
}

fn utf16_position(
  codepoints: List(UtfCodepoint),
  line: Int,
  column: Int,
) -> Position {
  case codepoints {
    [] -> Position(line, column)
    [codepoint, ..rest] -> {
      let value = string.utf_codepoint_to_int(codepoint)
      case value {
        10 -> utf16_position(rest, line + 1, 1)
        value if value > 65_535 -> utf16_position(rest, line, column + 2)
        _ -> utf16_position(rest, line, column + 1)
      }
    }
  }
}

fn position_json(position: Position) -> json.Json {
  json.object([
    #("line", json.int(position.line)),
    #("column", json.int(position.column)),
  ])
}
