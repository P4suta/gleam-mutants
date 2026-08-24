// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import child_process
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/cache
import gleam_mutants/config
import gleam_mutants/core/catalog.{type RejectedMutant}
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator
import gleam_mutants/core/path
import gleam_mutants/core/span
import gleam_mutants/engine.{type Options, Options}
import gleam_mutants/platform
import gleam_mutants/project_report
import gleam_mutants/report
import gleam_mutants/version
import glint
import simplifile

pub type Command {
  RunCommand(Options)
  ListCommand(options: Options, validate: Bool)
  DoctorCommand(options: Options, json: Bool, all_runtimes: Bool)
  InitCommand(options: Options, dry_run: Bool, check: Bool, gitignore: Bool)
  ReportListCommand(Options)
  ReportLatestCommand(Options)
  ReportValidateCommand(Options)
  ReportCleanCommand(Options)
  CacheStatusCommand(Options)
  CacheCleanCommand(Options)
  HelpCommand
  VersionCommand
}

pub fn main() -> Nil {
  let arguments = platform.arguments()
  case parse(arguments) {
    Error(message) -> {
      write_diagnostic(
        json_log_requested(arguments),
        "error",
        diagnostic_code(message),
        message,
        Some(help_text()),
      )
      platform.exit(2)
    }
    Ok(command) -> execute(command)
  }
}

pub fn parse(arguments: List(String)) -> Result(Command, String) {
  use extracted <- result.try(
    extract_globals(arguments, engine.default_options(), []),
  )
  let #(arguments, options) = extracted
  case options.version_requested, options.help_requested, arguments {
    True, _, _ -> Ok(VersionCommand)
    _, True, _ -> Ok(HelpCommand)
    _, _, [] -> Ok(HelpCommand)
    _, _, ["help", ..] -> Ok(HelpCommand)
    _, _, ["version"] -> Ok(VersionCommand)
    _, _, ["run", ..rest] ->
      parse_options(rest, options) |> result.map(RunCommand)
    _, _, ["list", ..rest] -> parse_list(rest, options)
    _, _, ["doctor", ..rest] -> parse_doctor(rest, options)
    _, _, ["init", ..rest] -> parse_init(rest, options, False, False, False)
    _, _, ["report", "list"] -> Ok(ReportListCommand(options))
    _, _, ["report", "latest"] -> Ok(ReportLatestCommand(options))
    _, _, ["report", "latest", "--json"] -> Ok(ReportLatestCommand(options))
    _, _, ["report", "validate"] -> Ok(ReportValidateCommand(options))
    _, _, ["report", "clean"] -> Ok(ReportCleanCommand(options))
    _, _, ["cache", "status"] -> Ok(CacheStatusCommand(options))
    _, _, ["cache", "clean"] -> Ok(CacheCleanCommand(options))
    _, _, ["report", ..] ->
      Error("GMU1002: expected report list, latest, validate, or clean")
    _, _, ["cache", ..] -> Error("GMU1002: expected cache status or clean")
    _, _, [first, ..] ->
      Error(
        "GMU1001: unknown command "
        <> string.inspect(first)
        <> command_suggestion(first),
      )
  }
}

fn extract_globals(
  arguments: List(String),
  options: Options,
  kept: List(String),
) -> Result(#(List(String), Options), String) {
  case arguments {
    [] -> Ok(#(list.reverse(kept), options))
    ["--", ..] | ["--test-command", ..] ->
      Ok(#(list.append(list.reverse(kept), arguments), options))
    ["--root", directory, ..rest] ->
      extract_globals(rest, Options(..options, root: Some(directory)), kept)
    ["--root"] -> Error("GMU1002: --root requires a directory")
    ["--quiet", ..rest] ->
      extract_globals(rest, Options(..options, quiet: True), kept)
    ["-v", ..rest] ->
      extract_globals(
        rest,
        Options(..options, verbosity: options.verbosity + 1),
        kept,
      )
    ["-vv", ..rest] ->
      extract_globals(
        rest,
        Options(..options, verbosity: options.verbosity + 2),
        kept,
      )
    ["--log-format", format, ..rest] -> {
      use format <- result.try(validate_log_format(format))
      extract_globals(rest, Options(..options, log_format: format), kept)
    }
    ["--log-format"] -> Error("GMU1002: --log-format requires text or json")
    ["--help", ..rest] | ["-h", ..rest] ->
      extract_globals(rest, Options(..options, help_requested: True), kept)
    ["--version", ..rest] | ["-V", ..rest] ->
      extract_globals(rest, Options(..options, version_requested: True), kept)
    [argument, ..rest] ->
      case split_option(argument) {
        Ok(#("root", value)) ->
          extract_globals(rest, Options(..options, root: Some(value)), kept)
        Ok(#("log-format", value)) -> {
          use value <- result.try(validate_log_format(value))
          extract_globals(rest, Options(..options, log_format: value), kept)
        }
        _ -> extract_globals(rest, options, [argument, ..kept])
      }
  }
}

fn validate_log_format(value: String) -> Result(String, String) {
  case value {
    "text" | "json" -> Ok(value)
    _ -> Error("GMU1002: --log-format must be text or json")
  }
}

fn parse_list(
  arguments: List(String),
  options: Options,
) -> Result(Command, String) {
  let validate = list.contains(arguments, "--validate")
  arguments
  |> list.filter(fn(argument) { argument != "--validate" })
  |> parse_options(options)
  |> result.map(fn(options) { ListCommand(options, validate) })
}

fn parse_doctor(
  arguments: List(String),
  options: Options,
) -> Result(Command, String) {
  case
    list.all(arguments, fn(argument) {
      argument == "--json" || argument == "--all-runtimes"
    })
  {
    True ->
      Ok(DoctorCommand(
        options,
        list.contains(arguments, "--json"),
        list.contains(arguments, "--all-runtimes"),
      ))
    False -> Error("GMU1002: doctor accepts only --json and --all-runtimes")
  }
}

fn parse_init(
  arguments: List(String),
  options: Options,
  dry_run: Bool,
  check: Bool,
  gitignore: Bool,
) -> Result(Command, String) {
  case arguments {
    [] ->
      case dry_run && check {
        True -> Error("GMU1002: --dry-run and --check are mutually exclusive")
        False -> Ok(InitCommand(options, dry_run, check, gitignore))
      }
    ["--dry-run", ..rest] -> parse_init(rest, options, True, check, gitignore)
    ["--check", ..rest] -> parse_init(rest, options, dry_run, True, gitignore)
    ["--gitignore", ..rest] -> parse_init(rest, options, dry_run, check, True)
    [argument, ..] ->
      Error("GMU1002: unknown init option " <> string.inspect(argument))
  }
}

fn command_suggestion(value: String) -> String {
  case value {
    "rn" | "ru" -> "; did you mean 'run'?"
    "ls" | "lis" -> "; did you mean 'list'?"
    "doc" | "docter" -> "; did you mean 'doctor'?"
    _ -> ""
  }
}

fn parse_options(
  arguments: List(String),
  options: Options,
) -> Result(Options, String) {
  case arguments {
    [] -> Ok(options)
    ["--matrix", ..rest] ->
      parse_options(rest, Options(..options, matrix: True))
    ["--strict", ..rest] ->
      parse_options(rest, Options(..options, strict: Some(True)))
    ["--no-strict", ..rest] ->
      parse_options(rest, Options(..options, strict: Some(False)))
    ["--json", ..rest] -> parse_options(rest, Options(..options, json: True))
    ["--explain", ..rest] ->
      parse_options(rest, Options(..options, explain: True))
    ["--mutant", prefix, ..rest] ->
      parse_options(rest, Options(..options, mutant_prefix: Some(prefix)))
    ["--report", "none", ..rest] ->
      parse_options(rest, Options(..options, report_formats: Some([])))
    ["--report", format, ..rest] -> {
      use formats <- result.try(parse_report_formats(format))
      parse_options(rest, Options(..options, report_formats: Some(formats)))
    }
    ["--changed", reference, ..rest] ->
      parse_options(rest, Options(..options, changed: Some(reference)))
    ["--include", pattern, ..rest] ->
      parse_options(
        rest,
        Options(..options, includes: list.append(options.includes, [pattern])),
      )
    ["--operator", name, ..rest] -> {
      use selected <- result.try(
        operator.from_name(name)
        |> result.replace_error("unknown mutation operator " <> name),
      )
      let operators = case options.operators {
        Some(values) -> list.append(values, [selected])
        None -> [selected]
      }
      parse_options(rest, Options(..options, operators: Some(operators)))
    }
    ["--jobs", value, ..rest] -> {
      use jobs <- result.try(parse_positive_int("--jobs", value))
      parse_options(rest, Options(..options, jobs: Some(jobs)))
    }
    ["--timeout", value, ..rest] -> {
      use timeout <- result.try(parse_timeout(value))
      parse_options(rest, Options(..options, timeout_ms: Some(timeout)))
    }
    ["--test-command", ..command] | ["--", ..command] ->
      case command {
        [] -> Error("test command cannot be empty")
        _ -> Ok(Options(..options, test_command: Some(command)))
      }
    [argument, ..rest] ->
      case split_option(argument) {
        Ok(#("changed", value)) ->
          parse_options(rest, Options(..options, changed: Some(value)))
        Ok(#("include", value)) ->
          parse_options(
            rest,
            Options(..options, includes: list.append(options.includes, [value])),
          )
        Ok(#("jobs", value)) -> {
          use jobs <- result.try(parse_positive_int("--jobs", value))
          parse_options(rest, Options(..options, jobs: Some(jobs)))
        }
        Ok(#("timeout", value)) -> {
          use timeout <- result.try(parse_timeout(value))
          parse_options(rest, Options(..options, timeout_ms: Some(timeout)))
        }
        Ok(#("operator", value)) -> {
          use selected <- result.try(
            operator.from_name(value)
            |> result.replace_error("unknown mutation operator " <> value),
          )
          let operators = case options.operators {
            Some(values) -> list.append(values, [selected])
            None -> [selected]
          }
          parse_options(rest, Options(..options, operators: Some(operators)))
        }
        Ok(#("mutant", value)) ->
          parse_options(rest, Options(..options, mutant_prefix: Some(value)))
        Ok(#("report", value)) -> {
          use formats <- result.try(parse_report_formats(value))
          parse_options(rest, Options(..options, report_formats: Some(formats)))
        }
        Ok(#(name, _)) -> Error("unknown option --" <> name)
        Error(_) -> Error("unexpected argument " <> string.inspect(argument))
      }
  }
}

fn parse_report_formats(value: String) -> Result(List(String), String) {
  case value {
    "none" -> Ok([])
    "json" -> Ok(["json"])
    "html" -> Ok(["html"])
    "json,html" | "html,json" -> Ok(["json", "html"])
    _ -> Error("GMU1002: --report must be none, json, html, or json,html")
  }
}

fn split_option(argument: String) -> Result(#(String, String), Nil) {
  case string.starts_with(argument, "--"), string.split_once(argument, "=") {
    True, Ok(#(name, value)) -> Ok(#(string.drop_start(name, 2), value))
    _, _ -> Error(Nil)
  }
}

fn parse_positive_int(flag: String, value: String) -> Result(Int, String) {
  case int.parse(value) {
    Ok(number) if number >= 1 && number <= 32 -> Ok(number)
    _ -> Error(flag <> " must be between 1 and 32")
  }
}

fn parse_timeout(value: String) -> Result(Int, String) {
  use parts <- result.try(
    timeout_parts(value)
    |> result.replace_error("--timeout must be between 100ms and 24h"),
  )
  let #(number_text, multiplier, decimal) = parts
  case timeout_number(number_text, decimal) {
    Ok(number) -> {
      let milliseconds = number *. multiplier
      case milliseconds >=. 100.0 && milliseconds <=. 86_400_000.0 {
        True -> Ok(float.round(milliseconds))
        False -> Error("--timeout must be between 100ms and 24h")
      }
    }
    Error(_) -> Error("--timeout must be between 100ms and 24h")
  }
}

fn timeout_number(value: String, decimal: Bool) -> Result(Float, Nil) {
  case int.parse(value) {
    Ok(number) -> Ok(int.to_float(number))
    Error(_) ->
      case decimal {
        True -> float.parse(value) |> result.replace_error(Nil)
        False -> Error(Nil)
      }
  }
}

fn timeout_parts(value: String) -> Result(#(String, Float, Bool), Nil) {
  case string.ends_with(value, "ms") {
    True -> Ok(#(string.drop_end(value, 2), 1.0, True))
    False ->
      case string.ends_with(value, "s") {
        True -> Ok(#(string.drop_end(value, 1), 1000.0, True))
        False ->
          case string.ends_with(value, "m") {
            True -> Ok(#(string.drop_end(value, 1), 60_000.0, True))
            False ->
              case string.ends_with(value, "h") {
                True -> Ok(#(string.drop_end(value, 1), 3_600_000.0, True))
                False ->
                  case int.parse(value) {
                    Ok(_) -> Ok(#(value, 1000.0, False))
                    Error(_) -> Error(Nil)
                  }
              }
          }
      }
  }
}

fn execute(command: Command) -> Nil {
  case command {
    HelpCommand -> io.println(help_text())
    VersionCommand -> io.println("gleam-mutants " <> version.current)
    DoctorCommand(options, json, all_runtimes) ->
      with_workspace(options, fn(workspace) {
        doctor(workspace, json, all_runtimes)
      })
    InitCommand(options, dry_run, check, gitignore) ->
      with_workspace(options, fn(workspace) {
        init(workspace, dry_run, check, gitignore)
      })
    ReportListCommand(options) ->
      with_workspace(options, fn(workspace) {
        case report.list_runs(workspace) {
          Ok(text) -> io.print(text)
          Error(error) -> fail("GMU5001: could not list reports: " <> error)
        }
      })
    ReportLatestCommand(options) ->
      with_workspace(options, fn(workspace) {
        case report.latest(workspace) {
          Ok(text) -> io.print(text)
          Error(error) ->
            fail("GMU5002: could not read latest report: " <> error)
        }
      })
    ReportValidateCommand(options) ->
      with_workspace(options, fn(workspace) {
        case report.validate_latest(workspace) {
          Ok(Nil) -> io.println("Latest native report is valid JSON.")
          Error(error) -> fail("GMU5003: " <> error)
        }
      })
    ReportCleanCommand(options) ->
      with_workspace(options, fn(workspace) {
        case report.clean(workspace) {
          Ok(Nil) ->
            io.println("Removed native report history for this workspace.")
          Error(error) -> fail("GMU5004: could not clean reports: " <> error)
        }
      })
    CacheStatusCommand(options) ->
      with_workspace(options, fn(workspace) {
        io.print(cache.status(workspace))
      })
    CacheCleanCommand(options) ->
      with_workspace(options, fn(workspace) {
        case cache.clean(workspace) {
          Ok(Nil) -> io.println("Removed outcome cache for this workspace.")
          Error(error) -> fail("GMU6001: could not clean cache: " <> error)
        }
      })
    ListCommand(options, validate) ->
      with_workspace(options, fn(workspace) {
        case engine.list_mutants(workspace, options, validate) {
          Error(error) -> fail(error)
          Ok(output) -> {
            case options.json {
              True ->
                io.println(catalog_json(
                  output.mutants,
                  output.rejected,
                  output.validated,
                ))
              False ->
                io.print(render_list(
                  output.mutants,
                  output.rejected,
                  output.validated,
                  options.explain,
                ))
            }
          }
        }
      })
    RunCommand(options) ->
      with_workspace(options, fn(workspace) {
        emit_info(options, "GMU0001", "mutation run started")
        case engine.run(workspace, options) {
          Error(error) -> fail(error)
          Ok(output) -> {
            case options.json {
              True -> io.println(report.to_json(output.report))
              False -> {
                io.print(report.render(output.report, options.explain))
                case options.quiet {
                  True -> Nil
                  False -> {
                    print_report_path(
                      options,
                      "Native report",
                      output.report_path,
                    )
                    print_report_path(
                      options,
                      "Stryker JSON",
                      output.stryker_json_path,
                    )
                    print_report_path(
                      options,
                      "HTML report",
                      output.html_report_path,
                    )
                    case options.verbosity > 0 {
                      True ->
                        emit_info(
                          options,
                          "GMU0002",
                          "run id " <> output.report.run_id,
                        )
                      False -> Nil
                    }
                    case options.verbosity > 1 {
                      True ->
                        emit_info(
                          options,
                          "GMU0003",
                          "workspace digest "
                            <> output.report.workspace_digest
                            <> "; selected "
                            <> int.to_string(
                            output.report.selection.files_selected,
                          )
                            <> " files",
                        )
                      False -> Nil
                    }
                  }
                }
              }
            }
            platform.exit(output.exit_code)
          }
        }
      })
  }
}

fn print_report_path(options: Options, label: String, value: String) -> Nil {
  case value {
    "" -> Nil
    _ -> emit_info(options, "GMU0004", label <> ": " <> value)
  }
}

fn fail(message: String) -> Nil {
  write_diagnostic(
    json_log_requested(platform.arguments()),
    "error",
    diagnostic_code(message),
    message,
    None,
  )
  platform.exit(2)
}

fn emit_info(options: Options, code: String, message: String) -> Nil {
  case options.quiet {
    True -> Nil
    False ->
      write_diagnostic(
        options.log_format == "json",
        "info",
        code,
        message,
        None,
      )
  }
}

fn write_diagnostic(
  json_output: Bool,
  level: String,
  code: String,
  message: String,
  usage: Option(String),
) -> Nil {
  case json_output {
    True ->
      io.println_error(
        json.object([
          #("level", json.string(level)),
          #("code", json.string(code)),
          #("message", json.string(message)),
          #("usage", json.nullable(usage, json.string)),
        ])
        |> json.to_string,
      )
    False -> {
      let prefix = case level {
        "error" -> "gleam-mutants: "
        _ -> "gleam-mutants: "
      }
      io.println_error(
        prefix
        <> message
        <> case usage {
          Some(value) -> "\n\n" <> value
          None -> ""
        },
      )
    }
  }
}

fn diagnostic_code(message: String) -> String {
  case message |> string.split(" ") |> list.first {
    Ok(first) -> {
      let code = case string.ends_with(first, ":") {
        True -> string.drop_end(first, 1)
        False -> first
      }
      case string.starts_with(code, "GMU") {
        True -> code
        False -> "GMU9000"
      }
    }
    Error(_) -> "GMU9000"
  }
}

fn json_log_requested(arguments: List(String)) -> Bool {
  case arguments {
    [] -> False
    ["--log-format", "json", ..] -> True
    ["--log-format=json", ..] -> True
    [_, ..rest] -> json_log_requested(rest)
  }
}

fn with_workspace(options: Options, action: fn(String) -> Nil) -> Nil {
  case resolve_workspace(options.root) {
    Ok(workspace) -> action(workspace)
    Error(error) -> fail(error)
  }
}

fn resolve_workspace(root: Option(String)) -> Result(String, String) {
  case root {
    Some(directory) -> {
      let directory = platform.resolve_path(directory)
      case simplifile.is_file(path.join(directory, "gleam.toml")) {
        Ok(True) -> Ok(directory)
        _ -> Error("GMU2001: --root does not contain gleam.toml: " <> directory)
      }
    }
    None ->
      discover_workspace(platform.resolve_path(platform.current_directory()))
  }
}

fn discover_workspace(directory: String) -> Result(String, String) {
  case simplifile.is_file(path.join(directory, "gleam.toml")) {
    Ok(True) -> Ok(directory)
    _ -> {
      let parent = path.parent(directory)
      case parent == "" || parent == directory {
        True ->
          Error("GMU2002: no gleam.toml found in this directory or its parents")
        False -> discover_workspace(parent)
      }
    }
  }
}

fn init(
  workspace: String,
  dry_run: Bool,
  check: Bool,
  update_ignore: Bool,
) -> Nil {
  let target = path.join(workspace, "gleam.toml")
  case simplifile.read(target) {
    Error(error) ->
      fail("could not read gleam.toml: " <> simplifile.describe_error(error))
    Ok(source) ->
      case config.initialise(source) {
        Error(error) -> fail(config.describe_error(error))
        Ok(#(updated, changed)) -> {
          let ignore_changed = case update_ignore {
            True -> gitignore_needs_update(workspace, "reports/mutation")
            False -> False
          }
          case check, dry_run, changed || ignore_changed {
            True, _, True -> {
              io.println_error("gleam.toml configuration is not up to date.")
              platform.exit(1)
            }
            True, _, False ->
              io.println("gleam.toml configuration is up to date.")
            False, True, _ -> io.print(updated)
            False, False, False ->
              io.println(
                "gleam.toml mutation configuration is already up to date.",
              )
            False, False, True -> {
              case changed {
                True ->
                  case atomic_replace_preserving(target, updated) {
                    Ok(Nil) -> Nil
                    Error(error) ->
                      fail("could not write gleam.toml: " <> error)
                  }
                False -> Nil
              }
              case update_ignore && ignore_changed {
                True -> update_gitignore(workspace, "reports/mutation")
                False -> Nil
              }
              io.println("Updated mutation configuration.")
            }
          }
        }
      }
  }
}

fn atomic_replace_preserving(
  target: String,
  contents: String,
) -> Result(Nil, String) {
  let temporary = target <> ".tmp-" <> platform.random_nonce()
  use info <- result.try(
    simplifile.file_info(target) |> result.map_error(simplifile.describe_error),
  )
  use _ <- result.try(
    simplifile.write(temporary, contents)
    |> result.map_error(simplifile.describe_error),
  )
  use _ <- result.try(
    simplifile.set_permissions_octal(
      temporary,
      simplifile.file_info_permissions_octal(info),
    )
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

fn gitignore_needs_update(workspace: String, directory: String) -> Bool {
  let entry = "/" <> directory <> "/"
  case simplifile.read(path.join(workspace, ".gitignore")) {
    Ok(source) -> !list.contains(string.split(source, "\n"), entry)
    Error(simplifile.Enoent) -> True
    Error(_) -> True
  }
}

fn update_gitignore(workspace: String, directory: String) -> Nil {
  let target = path.join(workspace, ".gitignore")
  let source = case simplifile.read(target) {
    Ok(source) -> source
    Error(simplifile.Enoent) -> ""
    Error(error) -> {
      fail("could not read .gitignore: " <> simplifile.describe_error(error))
      ""
    }
  }
  let separator = case source == "" || string.ends_with(source, "\n") {
    True -> ""
    False -> "\n"
  }
  let updated = source <> separator <> "/" <> directory <> "/\n"
  case simplifile.is_file(target) {
    Ok(True) ->
      case atomic_replace_preserving(target, updated) {
        Ok(Nil) -> Nil
        Error(error) -> fail("could not write .gitignore: " <> error)
      }
    _ ->
      case simplifile.write(target, updated) {
        Ok(Nil) -> Nil
        Error(error) ->
          fail(
            "could not write .gitignore: " <> simplifile.describe_error(error),
          )
      }
  }
}

fn doctor(workspace: String, json_output: Bool, all_runtimes: Bool) -> Nil {
  let decoded =
    simplifile.read(path.join(workspace, "gleam.toml"))
    |> result.map_error(simplifile.describe_error)
    |> result.try(fn(source) {
      config.decode(source, platform.cpu_count())
      |> result.map_error(config.describe_error)
    })
  let tools = case all_runtimes, decoded {
    True, _ -> ["gleam", "erl", "node", "deno", "bun", "git"]
    False, Ok(config) ->
      [
        "gleam",
        "git",
        required_runtime(config),
        config.test_command |> list.first |> result.unwrap("gleam"),
      ]
      |> list.unique
    False, Error(_) -> ["gleam", "git"]
  }
  let checks =
    list.map(tools, fn(tool) {
      case child_process.find_executable(tool) {
        Ok(found) -> #(tool, True, found, tool_version(tool, found, workspace))
        Error(_) -> #(tool, False, "", "")
      }
    })
  let config_ok = case decoded {
    Ok(decoded) ->
      project_report.validate_destination(workspace, decoded.report.directory)
      == Ok(Nil)
    Error(_) -> False
  }
  let workspace_writable = writable_probe(workspace)
  let cache_writable = writable_probe(platform.cache_directory())
  let temporary_writable = writable_probe(platform.temporary_directory())
  case json_output {
    True ->
      io.println(
        json.object([
          #("schema_version", json.int(1)),
          #("workspace", json.string(workspace)),
          #("config_ok", json.bool(config_ok)),
          #("workspace_writable", json.bool(workspace_writable)),
          #("cache_writable", json.bool(cache_writable)),
          #("temporary_writable", json.bool(temporary_writable)),
          #(
            "tools",
            json.array(checks, fn(check) {
              json.object([
                #("name", json.string(check.0)),
                #("ok", json.bool(check.1)),
                #("executable", json.string(check.2)),
                #("version", json.string(check.3)),
              ])
            }),
          ),
        ])
        |> json.to_string,
      )
    False -> {
      list.each(checks, fn(check) {
        case check.1 {
          True ->
            io.println("ok  " <> check.0 <> "  " <> check.2 <> "  " <> check.3)
          False -> io.println("missing  " <> check.0)
        }
      })
      case config_ok {
        True ->
          io.println("ok  gleam.toml configuration and report destination")
        False ->
          io.println("invalid  gleam.toml configuration or report destination")
      }
      io.println(case workspace_writable {
        True -> "ok  workspace writable"
        False -> "invalid  workspace is not writable"
      })
      io.println(case cache_writable {
        True -> "ok  cache directory writable"
        False -> "invalid  cache directory is not writable"
      })
      io.println(case temporary_writable {
        True -> "ok  temporary directory writable"
        False -> "invalid  temporary directory is not writable"
      })
    }
  }
  case
    config_ok
    && workspace_writable
    && cache_writable
    && temporary_writable
    && list.all(checks, fn(value) { value.1 })
  {
    True -> Nil
    False -> platform.exit(2)
  }
}

fn required_runtime(config: config.Config) -> String {
  case config.test_runtime, config.test_target {
    config.ErlangRuntime, _ | config.AutoRuntime, config.ErlangTarget -> "erl"
    config.NodeRuntime, _ | config.AutoRuntime, config.JavaScriptTarget ->
      "node"
    config.DenoRuntime, _ -> "deno"
    config.BunRuntime, _ -> "bun"
    config.AutoRuntime, config.AutoTarget -> "erl"
  }
}

fn tool_version(tool: String, executable: String, workspace: String) -> String {
  let arguments = case tool {
    "erl" -> ["-version"]
    _ -> ["--version"]
  }
  let process =
    platform.run_process(executable, arguments, workspace, [], 10_000)
  process.stdout
  <> process.stderr
  |> string.replace("\r", "")
  |> string.split("\n")
  |> list.first
  |> result.unwrap("")
}

fn writable_probe(directory: String) -> Bool {
  let target =
    path.join(directory, ".gleam-mutants-doctor-" <> platform.random_nonce())
  case simplifile.write(target, "") {
    Error(_) -> False
    Ok(Nil) ->
      case simplifile.delete_file(at: target) {
        Ok(Nil) -> True
        Error(_) -> False
      }
  }
}

fn render_list(
  mutants: List(Mutant),
  rejected: List(RejectedMutant),
  validated: Bool,
  explain: Bool,
) -> String {
  let row_prefix = case validated {
    True -> "compiler-valid "
    False -> "unvalidated "
  }
  let rows =
    mutants
    |> list.map(fn(mutant) {
      row_prefix
      <> mutant.path
      <> ":"
      <> int.to_string(mutant.line)
      <> ":"
      <> int.to_string(mutant.column)
      <> " ["
      <> mutant.display_id
      <> "] "
      <> operator.name(mutant.operator)
      <> " "
      <> compact(mutant.original)
      <> " -> "
      <> compact(mutant.replacement)
      <> "\n"
    })
    |> string.concat
  let rejected_rows = case explain {
    False -> ""
    True ->
      rejected
      |> list.map(fn(item) {
        "compiler-rejected "
        <> item.mutant.path
        <> ":"
        <> int.to_string(item.mutant.line)
        <> " "
        <> item.reason
        <> "\n"
      })
      |> string.concat
  }
  let summary = case validated {
    False ->
      int.to_string(list.length(mutants))
      <> " unvalidated mutation candidates.\n"
    True ->
      int.to_string(list.length(mutants))
      <> " compiler-valid mutants, "
      <> int.to_string(list.length(rejected))
      <> " compiler-rejected.\n"
  }
  rows <> rejected_rows <> summary
}

fn catalog_json(
  mutants: List(Mutant),
  rejected: List(RejectedMutant),
  validated: Bool,
) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #("validated", json.bool(validated)),
    #(
      "mutants",
      json.array(mutants, fn(mutant) {
        json.object([
          #("id", json.string(mutant.id)),
          #("display_id", json.string(mutant.display_id)),
          #("path", json.string(mutant.path)),
          #("operator", json.string(operator.name(mutant.operator))),
          #("start_byte", json.int(span.start(mutant.span))),
          #("end_byte", json.int(span.end(mutant.span))),
          #("line", json.int(mutant.line)),
          #("column", json.int(mutant.column)),
          #("original", json.string(mutant.original)),
          #("replacement", json.string(mutant.replacement)),
        ])
      }),
    ),
    #(
      "rejected",
      json.array(rejected, fn(item) {
        json.object([
          #("id", json.string(item.mutant.id)),
          #("reason", json.string(item.reason)),
          #("diagnostic", json.string(item.diagnostic)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn compact(value: String) -> String {
  value |> string.replace("\r", "") |> string.replace("\n", " ") |> string.trim
}

fn help_text() -> String {
  let command = fn(description) {
    glint.command_help(description, fn() { glint.command(fn(_, _, _) { Nil }) })
  }
  let app =
    glint.new()
    |> glint.with_name("gleam-mutants")
    |> glint.global_help(
      "Mutation testing for Gleam on Erlang, Node, Deno, and Bun.",
    )
    |> glint.add(
      at: [],
      do: command("Show help. Mutation testing starts only with run."),
    )
    |> glint.add(at: ["run"], do: command("Run mutation testing."))
    |> glint.add(
      at: ["list"],
      do: command(
        "List mutation candidates; optionally compiler-validate them.",
      ),
    )
    |> glint.add(
      at: ["doctor"],
      do: command("Check project configuration and runtimes."),
    )
    |> glint.add(
      at: ["init"],
      do: command("Add [tools.gleam_mutants] to gleam.toml."),
    )
    |> glint.add(
      at: ["report", "latest"],
      do: command("Print the latest stored JSON report."),
    )
    |> glint.add(
      at: ["report", "list"],
      do: command("List native report history for this workspace."),
    )
    |> glint.add(
      at: ["report", "validate"],
      do: command("Validate the latest native report."),
    )
    |> glint.add(
      at: ["report", "clean"],
      do: command("Remove native report history for this workspace."),
    )
    |> glint.add(at: ["cache", "status"], do: command("Show cache status."))
    |> glint.add(
      at: ["cache", "clean"],
      do: command("Remove the outcome cache for this workspace."),
    )
  let generated = case glint.execute(app, ["--help"]) {
    Ok(glint.Help(text)) -> text
    _ -> "gleam-mutants"
  }
  generated
  <> "\nGlobal options (before or after the command):\n"
  <> "  --root <dir>          select a package root (otherwise search parents)\n"
  <> "  --quiet | -v | -vv    control human diagnostics\n"
  <> "  --log-format <value>  text or json diagnostics\n"
  <> "\nRun/list options:\n"
  <> "  --changed <git-ref>   limit mutations to files changed from ref\n"
  <> "  --matrix              test Erlang, Node, Deno, and Bun\n"
  <> "  --strict | --no-strict\n"
  <> "  --json | --explain\n"
  <> "  --mutant <id-prefix>  execute exactly one unambiguous mutant\n"
  <> "  --jobs <n>            parallel isolated worker count (1-32)\n"
  <> "  --timeout <duration>  100ms through 24h (for example 1.5s)\n"
  <> "  --report <formats>    none, json, html, or json,html\n"
  <> "  --include <glob>      override mutation includes (repeatable)\n"
  <> "  --operator <name>     select an operator (repeatable)\n"
  <> "  --test-command <argv...>\n"
  <> "\nList options:\n"
  <> "  --validate            compiler-validate discovered candidates\n"
  <> "\nDoctor options:\n"
  <> "  --json                emit one doctor JSON v1 value\n"
  <> "  --all-runtimes        require all four supported runtimes\n"
  <> "\nInit options:\n"
  <> "  --dry-run | --check   preview migration or check it is current\n"
  <> "  --gitignore           explicitly add the report directory\n"
  <> "\nPrivacy: native/project reports may contain source and diagnostics;\n"
  <> "treat reports uploaded as CI artifacts as potentially sensitive.\n"
}
