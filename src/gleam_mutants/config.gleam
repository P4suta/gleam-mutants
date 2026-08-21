// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/core/glob
import gleam_mutants/core/operator.{type Operator}
import gleam_mutants/core/path
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
  CacheAuto
  CacheOff
  CacheReadOnly
  CacheWriteOnly
  CacheReadWrite
}

pub type DiagnosticsMode {
  DiagnosticsNone
  DiagnosticsErrors
  DiagnosticsAll
}

pub type ReportConfig {
  ReportConfig(
    directory: String,
    formats: List(String),
    history: Bool,
    diagnostics: DiagnosticsMode,
    high: Int,
    low: Int,
  )
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
    cache_key: Option(String),
    cache_files: List(String),
    cache_env: List(String),
    strict: Option(Bool),
    minimum_score: Float,
    require_mutants: Bool,
    report: ReportConfig,
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
    cache_mode: CacheAuto,
    cache_key: None,
    cache_files: [],
    cache_env: [],
    strict: Some(False),
    minimum_score: 100.0,
    require_mutants: True,
    report: ReportConfig(
      "reports/mutation",
      ["json", "html"],
      True,
      DiagnosticsErrors,
      80,
      60,
    ),
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
  use cache_key <- result.try(optional_optional_string(
    source,
    document,
    ["tools", "gleam_mutants", "cache", "key"],
    base.cache_key,
  ))
  use cache_files <- result.try(optional_strings(
    source,
    document,
    ["tools", "gleam_mutants", "cache", "files"],
    base.cache_files,
  ))
  use cache_env <- result.try(optional_strings(
    source,
    document,
    ["tools", "gleam_mutants", "cache", "env"],
    base.cache_env,
  ))
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
  use require_mutants <- result.try(optional_bool(
    source,
    document,
    ["tools", "gleam_mutants", "policy", "require_mutants"],
    base.require_mutants,
  ))
  use report_directory <- result.try(optional_string(
    source,
    document,
    ["tools", "gleam_mutants", "report", "directory"],
    base.report.directory,
  ))
  let report_directory = normalize_report_directory(report_directory)
  use report_formats <- result.try(optional_strings(
    source,
    document,
    ["tools", "gleam_mutants", "report", "formats"],
    base.report.formats,
  ))
  use report_history <- result.try(optional_bool(
    source,
    document,
    ["tools", "gleam_mutants", "report", "history"],
    base.report.history,
  ))
  use report_diagnostics_name <- result.try(optional_string(
    source,
    document,
    ["tools", "gleam_mutants", "report", "diagnostics"],
    diagnostics_name(base.report.diagnostics),
  ))
  use report_diagnostics <- result.try(decode_diagnostics(
    source,
    report_diagnostics_name,
  ))
  use report_high <- result.try(optional_int(
    source,
    document,
    ["tools", "gleam_mutants", "report", "high"],
    base.report.high,
  ))
  use report_low <- result.try(optional_int(
    source,
    document,
    ["tools", "gleam_mutants", "report", "low"],
    base.report.low,
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
    when: jobs < 1 || jobs > 32,
    return: Error(error_at(
      source,
      "jobs",
      "execution.jobs must be between 1 and 32",
    )),
  )
  use <- bool.guard(
    when: minimum_score <. 0.0 || minimum_score >. 100.0,
    return: Error(error_at(
      source,
      "minimum_score",
      "policy.minimum_score must be between 0 and 100",
    )),
  )
  use <- bool.guard(
    when: !valid_report_formats(report_formats),
    return: Error(error_at(
      source,
      "formats",
      "report.formats may contain only json and html without duplicates",
    )),
  )
  use <- bool.guard(
    when: test_command != ["gleam", "test"]
      && cache_mode != CacheAuto
      && cache_mode != CacheOff
      && cache_key == None,
    return: Error(error_at(
      source,
      "key",
      "cache.key is required when persistent cache is enabled for a custom test command",
    )),
  )
  use <- bool.guard(
    when: !safe_report_directory(report_directory),
    return: Error(error_at(
      source,
      "directory",
      "report.directory must be a safe relative subdirectory",
    )),
  )
  use <- bool.guard(
    when: report_low < 0 || report_high < report_low || report_high > 100,
    return: Error(error_at(
      source,
      case report_low < 0 {
        True -> "low"
        False -> "high"
      },
      "report thresholds must satisfy 0 <= low <= high <= 100",
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
    jobs: jobs,
    cache_mode: cache_mode,
    cache_key: cache_key,
    cache_files: cache_files,
    cache_env: cache_env,
    strict: strict,
    minimum_score: minimum_score,
    require_mutants: require_mutants,
    report: ReportConfig(
      report_directory,
      report_formats,
      report_history,
      report_diagnostics,
      report_high,
      report_low,
    ),
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
      "report",
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
    #(["tools", "gleam_mutants", "cache"], ["mode", "key", "files", "env"]),
    #(["tools", "gleam_mutants", "policy"], [
      "strict",
      "minimum_score",
      "require_mutants",
    ]),
    #(["tools", "gleam_mutants", "report"], [
      "directory",
      "formats",
      "history",
      "diagnostics",
      "high",
      "low",
    ]),
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

fn normalize_report_directory(value: String) -> String {
  string.replace(value, "\\", "/")
}

fn safe_report_directory(value: String) -> Bool {
  let components = string.split(value, "/")
  value != ""
  && !string.starts_with(value, "/")
  && !string.contains(value, ":")
  && !string.contains(value, "*")
  && !string.contains(value, "?")
  && !string.contains(value, "[")
  && !string.contains(value, "]")
  && list.all(string.to_utf_codepoints(value), fn(codepoint) {
    let value = string.utf_codepoint_to_int(codepoint)
    value >= 32 && value != 127
  })
  && list.all(components, safe_report_component)
}

fn safe_report_component(component: String) -> Bool {
  let stem =
    component
    |> string.split_once(".")
    |> result.map(fn(parts) { parts.0 })
    |> result.unwrap(component)
    |> string.uppercase
  component != ""
  && component != "."
  && component != ".."
  && !string.ends_with(component, ".")
  && !string.ends_with(component, " ")
  && !list.contains(
    [
      "CON",
      "PRN",
      "AUX",
      "NUL",
      "COM1",
      "COM2",
      "COM3",
      "COM4",
      "COM5",
      "COM6",
      "COM7",
      "COM8",
      "COM9",
      "LPT1",
      "LPT2",
      "LPT3",
      "LPT4",
      "LPT5",
      "LPT6",
      "LPT7",
      "LPT8",
      "LPT9",
    ],
    stem,
  )
}

pub fn report_overlaps_mutation_sources(config: Config) -> Bool {
  let directory = config.report.directory
  let probe = path.join(directory, "__gleam_mutants_report__.gleam")
  let excluded =
    list.any(config.excludes, fn(pattern) { glob.matches(pattern, probe) })
  !excluded
  && list.any(config.includes, fn(pattern) {
    glob.matches(pattern, probe)
    || paths_overlap(directory, static_prefix(pattern))
  })
}

fn static_prefix(pattern: String) -> String {
  pattern
  |> string.replace("\\", "/")
  |> string.split("/")
  |> static_prefix_loop([])
}

fn static_prefix_loop(parts: List(String), prefix: List(String)) -> String {
  case parts {
    [] -> prefix |> list.reverse |> string.join("/")
    [part, ..rest] ->
      case
        string.contains(part, "*")
        || string.contains(part, "?")
        || string.contains(part, "[")
      {
        True -> prefix |> list.reverse |> string.join("/")
        False -> static_prefix_loop(rest, [part, ..prefix])
      }
  }
}

fn paths_overlap(left: String, right: String) -> Bool {
  right == ""
  || left == right
  || string.starts_with(left, right <> "/")
  || string.starts_with(right, left <> "/")
}

fn valid_report_formats(formats: List(String)) -> Bool {
  list.length(formats) == list.length(list.unique(formats))
  && list.all(formats, fn(format) { format == "json" || format == "html" })
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
    Ok(value) if value >= 100 && value <= 86_400_000 -> Ok(Some(value))
    Ok(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must be between 100 and 86400000",
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

fn optional_optional_string(
  source: String,
  document: tomlet.Document,
  path: List(String),
  default: Option(String),
) -> Result(Option(String), ConfigError) {
  case tomlet.get_string(document, path) {
    Ok("") ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " must not be empty",
      ))
    Ok(value) -> Ok(Some(value))
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

fn optional_bool(
  source: String,
  document: tomlet.Document,
  path: List(String),
  default: Bool,
) -> Result(Bool, ConfigError) {
  case tomlet.get_bool(document, path) {
    Ok(value) -> Ok(value)
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
    "auto" -> Ok(CacheAuto)
    "off" -> Ok(CacheOff)
    "read-only" -> Ok(CacheReadOnly)
    "write-only" -> Ok(CacheWriteOnly)
    "read-write" -> Ok(CacheReadWrite)
    _ ->
      Error(error_at(
        source,
        "mode",
        "cache.mode must be auto, off, read-only, write-only, or read-write",
      ))
  }
}

fn decode_diagnostics(
  source: String,
  value: String,
) -> Result(DiagnosticsMode, ConfigError) {
  case value {
    "none" -> Ok(DiagnosticsNone)
    "errors" -> Ok(DiagnosticsErrors)
    "all" -> Ok(DiagnosticsAll)
    _ ->
      Error(error_at(
        source,
        "diagnostics",
        "report.diagnostics must be none, errors, or all",
      ))
  }
}

fn diagnostics_name(mode: DiagnosticsMode) -> String {
  case mode {
    DiagnosticsNone -> "none"
    DiagnosticsErrors -> "errors"
    DiagnosticsAll -> "all"
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
    CacheAuto -> "auto"
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
  use _ <- result.try(
    case tomlet.table_keys(document, ["tools", "gleam_mutants"]) {
      Ok(_) | Error(tomlet.KeyNotFound(_)) -> Ok(Nil)
      Error(tomlet.WrongType(_, _)) ->
        Error(error_at(
          source,
          "gleam_mutants",
          "tools.gleam_mutants must be a table",
        ))
    },
  )
  use version <- result.try(ensure_int(
    source,
    document,
    ["tools", "gleam_mutants", "version"],
    1,
  ))
  use cache_mode <- result.try(ensure_string(
    source,
    version.0,
    ["tools", "gleam_mutants", "cache", "mode"],
    "auto",
  ))
  use strict <- result.try(ensure_bool(
    source,
    cache_mode.0,
    ["tools", "gleam_mutants", "policy", "strict"],
    False,
  ))
  use minimum <- result.try(ensure_int(
    source,
    strict.0,
    ["tools", "gleam_mutants", "policy", "minimum_score"],
    100,
  ))
  use require_mutants <- result.try(ensure_bool(
    source,
    minimum.0,
    ["tools", "gleam_mutants", "policy", "require_mutants"],
    True,
  ))
  use directory <- result.try(ensure_string(
    source,
    require_mutants.0,
    ["tools", "gleam_mutants", "report", "directory"],
    "reports/mutation",
  ))
  use formats <- result.try(
    ensure_array(
      source,
      directory.0,
      ["tools", "gleam_mutants", "report", "formats"],
      [tomlet.StringValue("json"), tomlet.StringValue("html")],
    ),
  )
  use history <- result.try(ensure_bool(
    source,
    formats.0,
    ["tools", "gleam_mutants", "report", "history"],
    True,
  ))
  use diagnostics <- result.try(ensure_string(
    source,
    history.0,
    ["tools", "gleam_mutants", "report", "diagnostics"],
    "errors",
  ))
  use high <- result.try(ensure_int(
    source,
    diagnostics.0,
    ["tools", "gleam_mutants", "report", "high"],
    80,
  ))
  use low <- result.try(ensure_int(
    source,
    high.0,
    ["tools", "gleam_mutants", "report", "low"],
    60,
  ))
  let changed =
    version.1
    || cache_mode.1
    || strict.1
    || minimum.1
    || require_mutants.1
    || directory.1
    || formats.1
    || history.1
    || diagnostics.1
    || high.1
    || low.1
  let rendered = case changed {
    False -> source
    True -> preserve_newlines(source, tomlet.to_string(low.0))
  }
  use _ <- result.try(decode(rendered, 1))
  Ok(#(rendered, changed))
}

fn preserve_newlines(source: String, rendered: String) -> String {
  case string.contains(source, "\r\n") {
    True ->
      rendered |> string.replace("\r\n", "\n") |> string.replace("\n", "\r\n")
    False -> rendered
  }
}

fn key_missing(
  source: String,
  document: tomlet.Document,
  path: List(String),
) -> Result(Bool, ConfigError) {
  case tomlet.get(document, path) {
    Ok(_) -> Ok(False)
    Error(tomlet.KeyNotFound(_)) -> Ok(True)
    Error(_) ->
      Error(error_at(
        source,
        last_path(path),
        string.join(path, ".") <> " has an invalid parent table",
      ))
  }
}

fn ensure_int(
  source: String,
  document: tomlet.Document,
  path: List(String),
  value: Int,
) -> Result(#(tomlet.Document, Bool), ConfigError) {
  use missing <- result.try(key_missing(source, document, path))
  case missing {
    False -> Ok(#(document, False))
    True ->
      tomlet.set_int(document, path, value)
      |> result.map(fn(document) { #(document, True) })
      |> result.map_error(fn(_) {
        ConfigError(1, 1, "could not edit gleam.toml")
      })
  }
}

fn ensure_string(
  source: String,
  document: tomlet.Document,
  path: List(String),
  value: String,
) -> Result(#(tomlet.Document, Bool), ConfigError) {
  use missing <- result.try(key_missing(source, document, path))
  case missing {
    False -> Ok(#(document, False))
    True ->
      tomlet.set_string(document, path, value)
      |> result.map(fn(document) { #(document, True) })
      |> result.map_error(fn(_) {
        ConfigError(1, 1, "could not edit gleam.toml")
      })
  }
}

fn ensure_bool(
  source: String,
  document: tomlet.Document,
  path: List(String),
  value: Bool,
) -> Result(#(tomlet.Document, Bool), ConfigError) {
  use missing <- result.try(key_missing(source, document, path))
  case missing {
    False -> Ok(#(document, False))
    True ->
      tomlet.set_bool(document, path, value)
      |> result.map(fn(document) { #(document, True) })
      |> result.map_error(fn(_) {
        ConfigError(1, 1, "could not edit gleam.toml")
      })
  }
}

fn ensure_array(
  source: String,
  document: tomlet.Document,
  path: List(String),
  value: List(tomlet.Value),
) -> Result(#(tomlet.Document, Bool), ConfigError) {
  use missing <- result.try(key_missing(source, document, path))
  case missing {
    False -> Ok(#(document, False))
    True ->
      tomlet.set_array(document, path, value)
      |> result.map(fn(document) { #(document, True) })
      |> result.map_error(fn(_) {
        ConfigError(1, 1, "could not edit gleam.toml")
      })
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
