// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/core/limits
import gleam_mutants/types.{
  type MutationError, type Operation, Failure, Interrupted,
}

const interrupt_prefix = "GMU3005: interrupted "

pub fn interruption_message(code: Int) -> String {
  interrupt_prefix <> int.to_string(code)
}

pub fn interruption_code(message: String) -> Option(Int) {
  case string.starts_with(message, interrupt_prefix) {
    False -> None
    True -> {
      let remainder =
        string.drop_start(message, string.length(interrupt_prefix))
      let code =
        string.split_once(remainder, ";")
        |> result.map(fn(pair) { pair.0 })
        |> result.unwrap(remainder)
        |> string.trim
      case int.parse(code) {
        Ok(code) -> {
          case limits.interrupted(code) {
            True -> Some(code)
            False -> None
          }
        }
        Error(_) -> None
      }
    }
  }
}

pub fn from_message(operation: Operation, message: String) -> MutationError {
  case interruption_code(message) {
    Some(code) -> Interrupted(code, message)
    None -> Failure(operation, error_code(message), message)
  }
}

fn error_code(message: String) -> Option(String) {
  case string.split_once(message, ":") {
    Ok(#(code, _)) ->
      case string.starts_with(code, "GMU") && string.length(code) == 7 {
        True ->
          case
            string.drop_start(code, 3)
            |> string.to_graphemes
            |> list.all(fn(digit) { string.contains("0123456789", digit) })
          {
            True -> Some(code)
            False -> None
          }
        False -> None
      }
    _ -> None
  }
}
