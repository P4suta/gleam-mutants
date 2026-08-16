// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/core/operator.{type Operator}
import tomlet

pub type Target {
  AutoTarget
  ErlangTarget
  JavaScriptTarget
}

pub type RuntimeSetting {
  AutoRuntime
  ErlangRuntime
  NodeRuntime
  DenoRuntime
  BunRuntime
}

pub type CacheMode {
  CacheOff
  CacheReadOnly
  CacheWriteOnly
  CacheReadWrite
}

pub type Config {
  Config(
    version: Int,
    includes: List(String),
    excludes: List(String),
    operators: List(Operator),
    test_target: Target,
    test_runtime: RuntimeSetting,
    test_command: List(String),
    timeout_ms: Option(Int),
    baseline_runs: Int,
    jobs: Int,
    cache_mode: CacheMode,
    strict: Option(Bool),
    minimum_score: Float,
  )
}

pub type ConfigError {
  ConfigError(line: Int, column: Int, message: String)
}

pub fn defaults(cpu_count: Int) -> Config {
  Config(
    version: 1,
    includes: ["src/**/*.gleam"],
    excludes: [
      "test/**/*.gleam",
      "dev/**/*.gleam",
      "build/**",
      ".gleam_mutants/**",
    ],
    operators: operator.all(),
    test_target: AutoTarget,
    test_runtime: AutoRuntime,
    test_command: ["gleam", "test"],
    timeout_ms: None,
    baseline_runs: 1,
    jobs: int.max(1, int.min(cpu_count, 8)),
    cache_mode: CacheReadWrite,
    strict: None,
    minimum_score: 100.0,
  )
}

pub fn decode(source: String, cpu_count: Int) -> Result(Config, ConfigError) {
  let base = defaults(cpu_count)
  use document <- result.try(
    tomlet.parse(source)
    |> result.map_error(parse_error(source, _)),
  )

  case tomlet.table_keys(document, ["tools", "gleam_mutants"]) {
    Error(tomlet.KeyNotFound(_)) -> Ok(base)
    Error(_) ->
      Error(error_at(
        source,
        "gleam_mutants",
        "tools.gleam_mutants must be a table",
      ))
    Ok(_) -> decode_document(source, document, base)
  }
}

fn decode_document(
  source: String,
  document: tomlet.Document,
  base: Config,
) -> Result(Config, ConfigError) {
  use _ <- result.try(validate_unknown_keys(source, document))
  use version <- result.try(
    required_int(source, document, ["tools", "gleam_mutants", "version"]),
  )
  use <- bool.guard(
    when: version != 1,
    return: Error(error_at(
      source,
      "version",
      "unsupported tools.gleam_mutants version; expected 1",
    )),
  )
  use includes <- result.try(optional_strings(
    source,
    document,
    ["tools", "gleam_mutants", "mutation", "include"],
    base.includes,
  ))
  use excludes <- result.try(optional_strings(
    source,
    document,
    ["tools", "gleam_mutants", "mutation", "exclude"],
    base.excludes,
  ))
  use operator_names <- result.try(optional_strings(
    source,
    document,
    ["tools", "gleam_mutants", "mutation", "operators"],
    list.map(base.operators, operator.name),
  ))
  use operators <- result.try(decode_operators(source, operator_names))
  use target_name <- result.try(optional_string(
    source,
    document,
    ["tools", "gleam_mutants", "test", "target"],
    target_name(base.test_target),
  ))
  use test_target <- result.try(decode_target(source, target_name))
  use runtime_name <- result.try(optional_string(
    source,
    document,
    ["tools", "gleam_mutants", "test", "runtime"],
    runtime_name(base.test_runtime),
  ))
  use test_runtime <- result.try(decode_runtime(source, runtime_name))
  use test_command <- result.try(optional_strings(
    source,
    document,
    ["tools", "gleam_mutants", "test", "command"],
    base.test_command,
  ))
  use timeout_ms <- result.try(optional_optional_int(
    source,
    document,
    ["tools", "gleam_mutants", "test", "timeout_ms"],
    base.timeout_ms,
  ))
  use baseline_runs <- result.try(optional_int(
    source,
    document,
    ["tools", "gleam_mutants", "test", "baseline_runs"],
    base.baseline_runs,
  ))
  use jobs <- result.try(optional_int(
    source,
    document,
    ["tools", "gleam_mutants", "execution", "jobs"],
    base.jobs,
  ))
  use cache_name <- result.try(optional_string(
    source,
    document,
    ["tools", "gleam_mutants", "cache", "mode"],
    cache_name(base.cache_mode),
  ))
  use cache_mode <- result.try(decode_cache(source, cache_name))
  use strict <- result.try(optional_optional_bool(
    source,
    document,
    ["tools", "gleam_mutants", "policy", "strict"],
    base.strict,
  ))
  use minimum_score <- result.try(optional_number(
    source,
    document,
    ["tools", "gleam_mutants", "policy", "minimum_score"],
    base.minimum_score,
  ))
  use <- bool.guard(
    when: includes == [],
    return: Error(error_at(
      source,
      "include",
      "mutation.include cannot be empty",
    )),
  )
  use <- bool.guard(
    when: test_command == [],
    return: Error(error_at(source, "command", "test.command cannot be empty")),
  )
  use <- bool.guard(
    when: baseline_runs < 1,
    return: Error(error_at(
      source,
      "baseline_runs",
      "test.baseline_runs must be at least 1",
    )),
  )
  use <- bool.guard(
    when: jobs < 1,
    return: Error(error_at(source, "jobs", "execution.jobs must be at least 1")),
  )
  use <- bool.guard(
    when: minimum_score <. 0.0 || minimum_score >. 100.0,
    return: Error(error_at(
      source,
      "minimum_score",
      "policy.minimum_score must be between 0 and 100",
    )),
  )

  Ok(Config(
    version: version,
    includes: includes,
    excludes: excludes,
    operators: operators,
    test_target: test_target,
    test_runtime: test_runtime,
    test_command: test_command,
    timeout_ms: timeout_ms,
    baseline_runs: baseline_runs,
    jobs: int.min(jobs, 256),
    cache_mode: cache_mode,
    strict: strict,
    minimum_score: minimum_score,
  ))
}

fn validate_unknown_keys(
  source: String,
  document: tomlet.Document,
) -> Result(Nil, ConfigError) {
  let tables = [
    #(["tools", "gleam_mutants"], [
      "version",
      "mutation",
      "test",
      "execution",
      "cache",
      "policy",
    ]),
    #(["tools", "gleam_mutants", "mutation"], [
      "include",
      "exclude",
      "operators",
    ]),
    #(["tools", "gleam_mutants", "test"], [
      "target",
      "runtime",
      "command",
      "timeout_ms",
      "baseline_runs",
    ]),
    #(["tools", "gleam_mutants", "execution"], ["jobs"]),
    #(["tools", "gleam_mutants", "cache"], ["mode"]),
    #(["tools", "gleam_mutants", "policy"], ["strict", "minimum_score"]),
  ]
  use table <- list.try_each(tables)
  let #(path, allowed) = table
  case tomlet.table_keys(document, path) {
    Error(tomlet.KeyNotFound(_)) -> Ok(Nil)
    Error(_) ->
      Error(error_at(
        source,
        string.join(path, "."),
        string.join(path, ".") <> " must be a table",
      ))
    Ok(keys) ->
      case list.find(keys, fn(key) { !list.contains(allowed, key) }) {
        Ok(key) ->
          Error(error_at(
            source,
            key,
            "unknown key " <> string.join(list.append(path, [key]), "."),
          ))
        Error(_) -> Ok(Nil)
      }
  }
}

fn required_int(
  source: String,
  document: tomlet.Document,
  path: List(String),
) -> Result(Int, ConfigError) {
  tomlet.get_int(document, path)
  |> result.map_error(fn(_) {
    error_at(
      source,
      last_path(path),
      string.join(path, ".") <> " is required and must be an integer",
    )
  })
}

fn optional_int(
  source: String,
  document: tomlet.Document,
  path: List(String),
  default: Int,
) -> Result(Int, ConfigError) {
  case tomlet.get_int(document, path) {
    Ok(value) -> Ok(value)
    Error(tomlet.KeyNotFound(_)) -> Ok(default)
    Error(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must be an integer",
      ))
  }
}

fn optional_optional_int(
  source: String,
  document: tomlet.Document,
  path: List(String),
  default: Option(Int),
) -> Result(Option(Int), ConfigError) {
  case tomlet.get_int(document, path) {
    Ok(value) if value > 0 -> Ok(Some(value))
    Ok(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must be greater than zero",
      ))
    Error(tomlet.KeyNotFound(_)) -> Ok(default)
    Error(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must be an integer",
      ))
  }
}

fn optional_string(
  source: String,
  document: tomlet.Document,
  path: List(String),
  default: String,
) -> Result(String, ConfigError) {
  case tomlet.get_string(document, path) {
    Ok(value) -> Ok(value)
    Error(tomlet.KeyNotFound(_)) -> Ok(default)
    Error(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must be a string",
      ))
  }
}

fn optional_strings(
  source: String,
  document: tomlet.Document,
  path: List(String),
  default: List(String),
) -> Result(List(String), ConfigError) {
  case tomlet.get(document, path) {
    Ok(tomlet.ArrayValue(values)) ->
      values
      |> list.try_map(tomlet.as_string)
      |> result.map_error(fn(_) {
        error_at(
          source,
          last_path(path),
          string.join(path, ".") <> " must be an array of strings",
        )
      })
    Ok(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must be an array of strings",
      ))
    Error(tomlet.KeyNotFound(_)) -> Ok(default)
    Error(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must be an array of strings",
      ))
  }
}

fn optional_optional_bool(
  source: String,
  document: tomlet.Document,
  path: List(String),
  default: Option(Bool),
) -> Result(Option(Bool), ConfigError) {
  case tomlet.get_bool(document, path) {
    Ok(value) -> Ok(Some(value))
    Error(tomlet.KeyNotFound(_)) -> Ok(default)
    Error(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must be a boolean",
      ))
  }
}

fn optional_number(
  source: String,
  document: tomlet.Document,
  path: List(String),
  default: Float,
) -> Result(Float, ConfigError) {
  case tomlet.get(document, path) {
    Ok(tomlet.FloatValue(value)) -> Ok(value)
    Ok(tomlet.IntValue(value)) -> Ok(int.to_float(value))
    Ok(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must be a number",
      ))
    Error(tomlet.KeyNotFound(_)) -> Ok(default)
    Error(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must be a number",
      ))
  }
}

fn decode_operators(
  source: String,
  names: List(String),
) -> Result(List(Operator), ConfigError) {
  use operators <- result.map(
    list.try_map(names, operator.from_name)
    |> result.map_error(fn(_) {
      error_at(
        source,
        "operators",
        "mutation.operators contains an unknown operator",
      )
    }),
  )
  list.unique(operators)
}

fn decode_target(source: String, value: String) -> Result(Target, ConfigError) {
  case value {
    "auto" -> Ok(AutoTarget)
    "erlang" -> Ok(ErlangTarget)
    "javascript" -> Ok(JavaScriptTarget)
    _ ->
      Error(error_at(
        source,
        "target",
        "test.target must be auto, erlang, or javascript",
      ))
  }
}

fn decode_runtime(
  source: String,
  value: String,
) -> Result(RuntimeSetting, ConfigError) {
  case value {
    "auto" -> Ok(AutoRuntime)
    "erlang" -> Ok(ErlangRuntime)
    "node" -> Ok(NodeRuntime)
    "deno" -> Ok(DenoRuntime)
    "bun" -> Ok(BunRuntime)
    _ ->
      Error(error_at(
        source,
        "runtime",
        "test.runtime must be auto, erlang, node, deno, or bun",
      ))
  }
}

fn decode_cache(
  source: String,
  value: String,
) -> Result(CacheMode, ConfigError) {
  case value {
    "off" -> Ok(CacheOff)
    "read-only" -> Ok(CacheReadOnly)
    "write-only" -> Ok(CacheWriteOnly)
    "read-write" -> Ok(CacheReadWrite)
    _ ->
      Error(error_at(
        source,
        "mode",
        "cache.mode must be off, read-only, write-only, or read-write",
      ))
  }
}

fn target_name(target: Target) -> String {
  case target {
    AutoTarget -> "auto"
    ErlangTarget -> "erlang"
    JavaScriptTarget -> "javascript"
  }
}

fn runtime_name(runtime: RuntimeSetting) -> String {
  case runtime {
    AutoRuntime -> "auto"
    ErlangRuntime -> "erlang"
    NodeRuntime -> "node"
    DenoRuntime -> "deno"
    BunRuntime -> "bun"
  }
}

fn cache_name(mode: CacheMode) -> String {
  case mode {
    CacheOff -> "off"
    CacheReadOnly -> "read-only"
    CacheWriteOnly -> "write-only"
    CacheReadWrite -> "read-write"
  }
}

fn last_path(path: List(String)) -> String {
  path |> list.last |> result.unwrap("")
}

fn parse_error(source: String, error: tomlet.ParseError) -> ConfigError {
  case error {
    tomlet.InvalidEncoding -> ConfigError(1, 1, "gleam.toml is not valid UTF-8")
    tomlet.InvalidSyntax(_, offset) ->
      error_at_offset(source, offset, "invalid gleam.toml syntax")
    tomlet.DuplicateKey(key, offset) ->
      error_at_offset(
        source,
        offset,
        "duplicate TOML key " <> string.join(key, "."),
      )
  }
}

fn error_at(source: String, key: String, message: String) -> ConfigError {
  locate(source, key, 1)
  |> fn(position) { ConfigError(position.0, position.1, message) }
}

fn locate(source: String, key: String, line_number: Int) -> #(Int, Int) {
  case string.split(source, "\n") {
    [] -> #(1, 1)
    lines -> locate_lines(lines, key, line_number)
  }
}

fn locate_lines(
  lines: List(String),
  key: String,
  line_number: Int,
) -> #(Int, Int) {
  case lines {
    [] -> #(1, 1)
    [line, ..rest] ->
      case string.split_once(line, key) {
        Ok(#(before, _)) -> #(line_number, string.length(before) + 1)
        Error(_) -> locate_lines(rest, key, line_number + 1)
      }
  }
}

fn error_at_offset(
  source: String,
  offset: Int,
  message: String,
) -> ConfigError {
  let position = tomlet.line_column(source, offset)
  ConfigError(
    tomlet.position_line(position),
    tomlet.position_column(position),
    message,
  )
}

pub fn initialise(source: String) -> Result(#(String, Bool), ConfigError) {
  use document <- result.try(
    tomlet.parse(source) |> result.map_error(parse_error(source, _)),
  )
  case tomlet.table_keys(document, ["tools", "gleam_mutants"]) {
    Ok(_) -> Ok(#(source, False))
    Error(tomlet.WrongType(_, _)) ->
      Error(error_at(
        source,
        "gleam_mutants",
        "tools.gleam_mutants must be a table",
      ))
    Error(tomlet.KeyNotFound(_)) -> {
      use document <- result.try(
        tomlet.set_int(document, ["tools", "gleam_mutants", "version"], 1)
        |> result.map_error(fn(_) {
          ConfigError(1, 1, "could not edit gleam.toml")
        }),
      )
      use document <- result.try(
        tomlet.set_array(
          document,
          ["tools", "gleam_mutants", "mutation", "include"],
          [tomlet.StringValue("src/**/*.gleam")],
        )
        |> result.map_error(fn(_) {
          ConfigError(1, 1, "could not edit gleam.toml")
        }),
      )
      use document <- result.try(
        tomlet.set_array(
          document,
          ["tools", "gleam_mutants", "mutation", "exclude"],
          [
            tomlet.StringValue("test/**/*.gleam"),
            tomlet.StringValue("dev/**/*.gleam"),
            tomlet.StringValue("build/**"),
          ],
        )
        |> result.map_error(fn(_) {
          ConfigError(1, 1, "could not edit gleam.toml")
        }),
      )
      use document <- result.try(
        tomlet.set_array(
          document,
          ["tools", "gleam_mutants", "test", "command"],
          [tomlet.StringValue("gleam"), tomlet.StringValue("test")],
        )
        |> result.map_error(fn(_) {
          ConfigError(1, 1, "could not edit gleam.toml")
        }),
      )
      Ok(#(tomlet.to_string(document), True))
    }
  }
}

pub fn describe_error(error: ConfigError) -> String {
  "gleam.toml:"
  <> int.to_string(error.line)
  <> ":"
  <> int.to_string(error.column)
  <> ": "
  <> error.message
}
