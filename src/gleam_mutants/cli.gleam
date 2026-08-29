// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import child_process
import gleam/dict
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam_mutants/cache
import gleam_mutants/config
import gleam_mutants/core/catalog.{type RejectedMutant}
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator
import gleam_mutants/core/outcome
import gleam_mutants/core/path
import gleam_mutants/core/span
import gleam_mutants/engine.{type Options, Options}
import gleam_mutants/platform
import gleam_mutants/project_report
import gleam_mutants/report
import gleam_mutants/suggest/apply
import gleam_mutants/suggest/command as suggest_command
import gleam_mutants/suggest/probe_result
import gleam_mutants/suggest/render
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
  SuggestCommand(
    options: Options,
    suggest: suggest_command.SuggestOptions,
    json: Bool,
  )
  ExplainCommand(
    options: Options,
    display_id: String,
    suggest: suggest_command.SuggestOptions,
    json: Bool,
  )
  ApplyCommand(
    options: Options,
    suggest: suggest_command.SuggestOptions,
    yes: Bool,
    verify: Bool,
    reuse: Bool,
    json: Bool,
  )
  HelpCommand
  VersionCommand
}

pub fn main() -> Nil {
  run(platform.arguments())
}

/// Runs the compatibility CLI with an explicit argument list.
///
/// Smartest uses this entrypoint for its `mutants ...` namespace without
/// changing any existing parsing, diagnostics, or exit codes.
pub fn run(arguments: List(String)) -> Nil {
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
    _, _, ["run", ..rest] -> parse_run(rest, options)
    _, _, ["list", ..rest] -> parse_list(rest, options)
    _, _, ["doctor", ..rest] -> parse_doctor(rest, options)
    _, _, ["init", ..rest] -> parse_init(rest, options, False, False, False)
    _, _, ["suggest", ..rest] -> parse_suggest(rest, options)
    _, _, ["explain", ..rest] -> parse_explain(rest, options)
    _, _, ["apply", ..rest] -> parse_apply(rest, options)
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

/// `suggest [selection] [budget] [--style ...] [--json]`.
fn parse_suggest(
  arguments: List(String),
  options: Options,
) -> Result(Command, String) {
  use parsed <- result.map(parse_suggest_options(
    arguments,
    "suggest",
    suggest_command.default_options(),
    False,
  ))
  SuggestCommand(options, parsed.0, parsed.1)
}

/// `explain <id-prefix>` and then exactly the flags `suggest` takes.
///
/// The id is positional and comes first: an `explain` whose first argument
/// looks like a flag has named no mutant, and guessing which one was meant
/// would probe the whole workspace to answer a question nobody asked.
fn parse_explain(
  arguments: List(String),
  options: Options,
) -> Result(Command, String) {
  case arguments {
    [display_id, ..rest] ->
      case string.starts_with(display_id, "-") {
        False -> {
          use parsed <- result.try(parse_suggest_options(
            rest,
            "explain",
            suggest_command.default_options(),
            False,
          ))
          // `explain` narrows the run to the mutant its argument names, so a
          // `--mutant` beside it either repeats that argument or contradicts
          // it. Either way the flag has no effect, and taking it silently
          // answers a question nobody asked.
          case parsed.0.mutant_prefix {
            Some(_) -> Error(explain_owns_its_mutant)
            None -> Ok(ExplainCommand(options, display_id, parsed.0, parsed.1))
          }
        }
        True -> Error(explain_needs_an_id)
      }
    [] -> Error(explain_needs_an_id)
  }
}

/// `run [the flags list takes] [--suggest]`.
///
/// `--suggest` is taken out before the shared option parser sees it, so that
/// `list --suggest` stays the unknown option it is.
fn parse_run(
  arguments: List(String),
  options: Options,
) -> Result(Command, String) {
  let #(rest, suggest) = extract_suggest(arguments, [], False)
  use parsed <- result.try(parse_options(
    rest,
    Options(..options, suggest: suggest),
  ))
  case parsed.suggest && parsed.json {
    True -> Error(suggest_needs_text)
    False -> Ok(RunCommand(parsed))
  }
}

fn extract_suggest(
  arguments: List(String),
  kept: List(String),
  suggest: Bool,
) -> #(List(String), Bool) {
  case arguments {
    [] -> #(list.reverse(kept), suggest)
    // Everything after these belongs to the test command, verbatim.
    ["--", ..] | ["--test-command", ..] -> #(
      list.append(list.reverse(kept), arguments),
      suggest,
    )
    ["--suggest", ..rest] -> extract_suggest(rest, kept, True)
    [argument, ..rest] -> extract_suggest(rest, [argument, ..kept], suggest)
  }
}

/// `apply [the flags suggest takes] [--yes] [--verify] [--no-reuse] [--json]`.
///
/// `--verify` writes and then checks what it wrote, so it implies `--yes`:
/// there is nothing to verify about a run that changed no file. `--no-reuse`
/// is about the run `--verify` takes *before* the write: it refuses the
/// workspace's last stored run as a baseline and measures one instead.
fn parse_apply(
  arguments: List(String),
  options: Options,
) -> Result(Command, String) {
  let #(rest, yes, verify, reuse) =
    extract_apply(arguments, [], False, False, True)
  use parsed <- result.map(parse_suggest_options(
    rest,
    "apply",
    suggest_command.default_options(),
    False,
  ))
  ApplyCommand(options, parsed.0, yes || verify, verify, reuse, parsed.1)
}

fn extract_apply(
  arguments: List(String),
  kept: List(String),
  yes: Bool,
  verify: Bool,
  reuse: Bool,
) -> #(List(String), Bool, Bool, Bool) {
  case arguments {
    [] -> #(list.reverse(kept), yes, verify, reuse)
    ["--yes", ..rest] -> extract_apply(rest, kept, True, verify, reuse)
    ["--verify", ..rest] -> extract_apply(rest, kept, yes, True, reuse)
    ["--no-reuse", ..rest] -> extract_apply(rest, kept, yes, verify, False)
    [argument, ..rest] ->
      extract_apply(rest, [argument, ..kept], yes, verify, reuse)
  }
}

const suggest_needs_text = "GMU1002: --suggest cannot be combined with --json; run `suggest --survivors` instead"

const explain_needs_an_id = "GMU1002: explain requires a mutant id prefix"

const explain_owns_its_mutant = "GMU1002: explain takes its mutant id as an argument, not with --mutant"

/// The flags that take a value, so that a missing one is named as missing
/// rather than reported as an option nobody has heard of.
const suggest_value_flags = [
  "--changed", "--include", "--function", "--mutant", "--operator", "--seed",
  "--max-cases", "--max-shrinks", "--budget", "--style",
]

/// Parses the flags `suggest` and `explain` share, with the request so far.
///
/// `command` names the command in the unknown-option message, which is the
/// only difference between the two.
fn parse_suggest_options(
  arguments: List(String),
  command: String,
  suggest: suggest_command.SuggestOptions,
  json: Bool,
) -> Result(#(suggest_command.SuggestOptions, Bool), String) {
  case arguments {
    [] -> Ok(#(suggest, json))
    ["--json", ..rest] -> parse_suggest_options(rest, command, suggest, True)
    ["--survivors", ..rest] ->
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(..suggest, survivors_only: True),
        json,
      )
    ["--changed", value, ..rest] ->
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(..suggest, changed: Some(value)),
        json,
      )
    ["--include", value, ..rest] ->
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(
          ..suggest,
          includes: list.append(suggest.includes, [value]),
        ),
        json,
      )
    ["--function", value, ..rest] ->
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(..suggest, function: Some(value)),
        json,
      )
    ["--mutant", value, ..rest] ->
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(..suggest, mutant_prefix: Some(value)),
        json,
      )
    ["--operator", value, ..rest] -> {
      use selected <- result.try(
        operator.from_name(value)
        |> result.replace_error("unknown mutation operator " <> value),
      )
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(
          ..suggest,
          operators: list.append(suggest.operators, [selected]),
        ),
        json,
      )
    }
    ["--seed", value, ..rest] -> {
      use seed <- result.try(parse_seed(value))
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(..suggest, seed: Some(seed)),
        json,
      )
    }
    ["--max-cases", value, ..rest] -> {
      use cases <- result.try(parse_bounded_int("--max-cases", value, 1))
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(..suggest, max_cases: Some(cases)),
        json,
      )
    }
    ["--max-shrinks", value, ..rest] -> {
      use shrinks <- result.try(parse_bounded_int("--max-shrinks", value, 0))
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(..suggest, max_shrinks: Some(shrinks)),
        json,
      )
    }
    ["--budget", value, ..rest] -> {
      use budget <- result.try(parse_duration("--budget", value))
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(..suggest, budget_ms: Some(budget)),
        json,
      )
    }
    ["--style", value, ..rest] -> {
      use style <- result.try(parse_assert_style(value))
      parse_suggest_options(
        rest,
        command,
        suggest_command.SuggestOptions(..suggest, style: Some(style)),
        json,
      )
    }
    [argument, ..rest] ->
      case split_option(argument) {
        // `--name=value` is the same request written the other way round.
        Ok(#(name, value)) ->
          parse_suggest_options(
            ["--" <> name, value, ..rest],
            command,
            suggest,
            json,
          )
        Error(Nil) ->
          case list.contains(suggest_value_flags, argument) {
            True -> Error("GMU1002: " <> argument <> " requires a value")
            False ->
              Error(
                "GMU1002: unknown "
                <> command
                <> " option "
                <> string.inspect(argument),
              )
          }
      }
  }
}

fn parse_seed(value: String) -> Result(Int, String) {
  case int.parse(value) {
    Ok(seed) -> Ok(seed)
    Error(Nil) -> Error("GMU1002: --seed must be an integer")
  }
}

/// A search budget between `least` and the hundred thousand the configuration
/// accepts, so that a flag can never ask for what `gleam.toml` would refuse.
fn parse_bounded_int(
  flag: String,
  value: String,
  least: Int,
) -> Result(Int, String) {
  case int.parse(value) {
    Ok(number) if number >= least && number <= 100_000 -> Ok(number)
    _ ->
      Error(
        "GMU1002: "
        <> flag
        <> " must be between "
        <> int.to_string(least)
        <> " and 100000",
      )
  }
}

fn parse_assert_style(value: String) -> Result(render.AssertStyle, String) {
  case value {
    "assert" -> Ok(render.AssertKeyword)
    "should" -> Ok(render.ShouldEqual)
    _ -> Error("GMU1002: --style must be assert or should")
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
    ["--test-selection", value, ..rest] -> {
      use selection <- result.try(parse_test_selection(value))
      parse_options(rest, Options(..options, test_selection: Some(selection)))
    }
    ["--test-selection"] ->
      Error("GMU1002: --test-selection requires auto or full")
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
        Ok(#("test-selection", value)) -> {
          use selection <- result.try(parse_test_selection(value))
          parse_options(
            rest,
            Options(..options, test_selection: Some(selection)),
          )
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

fn parse_test_selection(value: String) -> Result(config.TestSelection, String) {
  case value {
    "auto" -> Ok(config.TestSelectionAuto)
    "full" -> Ok(config.TestSelectionFull)
    _ -> Error("GMU1002: --test-selection must be auto or full")
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
  parse_duration("--timeout", value)
}

/// A duration between 100ms and 24h, written for whichever flag asked.
///
/// `--timeout` and `--budget` accept exactly the same durations and refuse
/// them with exactly the same sentence, so the flag is a parameter rather
/// than two copies of one parser.
fn parse_duration(flag: String, value: String) -> Result(Int, String) {
  let refuse = flag <> " must be between 100ms and 24h"
  use parts <- result.try(timeout_parts(value) |> result.replace_error(refuse))
  let #(number_text, multiplier, decimal) = parts
  case timeout_number(number_text, decimal) {
    Ok(number) -> {
      let milliseconds = number *. multiplier
      case milliseconds >=. 100.0 && milliseconds <=. 86_400_000.0 {
        True -> Ok(float.round(milliseconds))
        False -> Error(refuse)
      }
    }
    Error(_) -> Error(refuse)
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
    SuggestCommand(options, suggest, json) ->
      with_workspace(options, fn(workspace) {
        case suggest_command.suggest(workspace, suggest) {
          Error(error) -> fail(error)
          Ok(report) -> {
            warn_unmatched_function(options, report)
            case json {
              True -> io.println(suggest_json(report))
              False -> io.print(render_suggestions(report))
            }
          }
        }
      })
    ExplainCommand(options, display_id, suggest, json) ->
      with_workspace(options, fn(workspace) {
        case suggest_command.explain(workspace, display_id, suggest) {
          Error(error) -> fail(error)
          Ok(explanation) ->
            case json {
              True -> io.println(explain_json(explanation))
              False -> io.print(render_explanation(explanation))
            }
        }
      })
    ApplyCommand(options, suggest, yes, verify, reuse, json) ->
      with_workspace(options, fn(workspace) {
        apply_suggestions(workspace, options, suggest, yes, verify, reuse, json)
      })
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
                emit_info(
                  options,
                  "GMU0005",
                  render_execution_summary(output.execution),
                )
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
                      True -> {
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
                        output.execution.details
                        |> list.each(fn(detail) {
                          emit_info(options, "GMU0006", detail)
                        })
                      }
                      False -> Nil
                    }
                  }
                }
                suggest_after_run(workspace, options, output.report)
              }
            }
            platform.exit(output.exit_code)
          }
        }
      })
  }
}

// --- apply and run --suggest -------------------------------------------------

/// One mutant a verification run looked for, and what became of it.
///
/// `outcome` is the name the rest of the tool gives that outcome and `killed`
/// says whether it counts as dead. A mutant that hangs the suite is as dead as
/// one a failing assertion caught, which is how the mutation score counts it
/// too, so a timeout is reported as detected under its own name.
///
/// `attribution` says which side of the write did the killing. `killed` alone
/// cannot: the verification run re-runs the whole suite, so a mutant the
/// reader's own tests were already killing comes back dead whatever the
/// generated test beside them does.
type Verified {
  Verified(
    mutant_id: String,
    display_id: String,
    outcome: String,
    killed: Bool,
    attribution: apply.Attribution,
  )
}

/// What one mutation run made of every mutant it graded.
///
/// A mutant is keyed by the id it ran under and carries the display id the
/// reader saw, the name of its outcome, and whether that outcome counts it
/// dead.
type Graded =
  dict.Dict(String, #(String, String, Bool))

/// Plans the generated tests, writes them when asked, and checks what it wrote.
///
/// Without `--yes` nothing is written: the plans are printed and the command
/// succeeds. With `--verify` the mutation engine is run again over the files
/// the applied suggestions came from, and a mutant that is still alive is a
/// quality failure — exit 1 — rather than a tool failure.
fn apply_suggestions(
  workspace: String,
  options: Options,
  suggest: suggest_command.SuggestOptions,
  yes: Bool,
  verify: Bool,
  reuse: Bool,
  json: Bool,
) -> Nil {
  case suggest_command.suggest(workspace, suggest) {
    Error(error) -> fail(error)
    Ok(found) -> {
      warn_unmatched_function(options, found)
      case apply.plan(workspace, found.suggestions, found.style) {
        Error(error) -> fail(error)
        Ok(plans) ->
          case yes, verify {
            False, _ -> emit_apply(plans, None, None, json, False)
            True, False ->
              case
                apply.write(workspace, plans, found.suggestions, found.style)
              {
                Error(error) -> fail(error)
                Ok(written) -> emit_apply(written, None, None, json, True)
              }
            True, True ->
              case write_and_verify(workspace, options, found, plans, reuse) {
                Error(error) -> fail(error)
                Ok(#(written, checked, baseline)) -> {
                  warn_idle_tests(options, found.suggestions, written, checked)
                  emit_apply(written, Some(checked), baseline, json, True)
                  case list.any(checked, surviving) {
                    True -> platform.exit(1)
                    False -> Nil
                  }
                }
              }
          }
      }
    }
  }
}

/// Whether one verified mutant is the failure `--verify` exists to catch.
fn surviving(entry: Verified) -> Bool {
  entry.attribution == apply.StillSurviving
}

/// Grades the workspace, writes the generated tests, and grades it again.
///
/// Every mutant an applied suggestion claims to kill is looked up in the run
/// that follows the write, its own and everything in its kill set alike: a
/// suggestion that only killed the mutant it was found from has not done what
/// it said it would. Neither run reports anything or stores a project report —
/// the reader asked to have their tests checked, not to have a second report
/// written.
///
/// The run *before* the write is what makes the answer worth anything.
/// Verification re-runs the whole suite, so a mutant the reader's own tests
/// were already killing comes back dead whether or not the generated test
/// beside them does a thing, and a `--verify` that only looked afterwards
/// handed out green lights to tests that add nothing. That costs two mutation
/// runs where it used to cost one, unless the workspace's last stored run
/// already graded every mutant in question.
///
/// A test this run skipped because the module already defined it is checked
/// alongside the ones it wrote. `--verify` is then a standing gate rather than
/// a one-off: run twice over the same workspace it re-checks the generated
/// tests instead of reporting that it had nothing to do.
fn write_and_verify(
  workspace: String,
  options: Options,
  found: suggest_command.Report,
  plans: List(apply.Plan),
  reuse: Bool,
) -> Result(#(List(apply.Plan), List(Verified), Option(Baseline)), String) {
  let applied = applied_suggestions(found.suggestions, plans)
  case verified_ids(applied) {
    [] -> {
      use written <- result.map(apply.write(
        workspace,
        plans,
        found.suggestions,
        found.style,
      ))
      #(written, [], None)
    }
    ids -> {
      use baseline <- result.try(baseline_outcomes(
        workspace,
        options,
        applied,
        ids,
        reuse,
      ))
      let #(source, before) = baseline
      use written <- result.try(apply.write(
        workspace,
        plans,
        found.suggestions,
        found.style,
      ))
      use after <- result.map(measured_outcomes(workspace, options, applied))
      #(written, verified_entries(ids, before, after), Some(source))
    }
  }
}

/// Which run the kills `--verify` reports were attributed against.
///
/// Both answers grade the same thing — the workspace as it stood before the
/// generated tests were written — but only one of them was taken just now, so
/// the reader is told which one they are reading.
type Baseline {
  /// A mutation run taken over these files before the write.
  Measured
  /// The workspace's last stored run, which still describes this tree.
  Reused
}

/// The suggestions whose tests one set of plans put in the workspace.
fn applied_suggestions(
  suggestions: List(render.Suggestion),
  plans: List(apply.Plan),
) -> List(render.Suggestion) {
  let written =
    set.from_list(
      list.flat_map(plans, fn(plan) {
        list.append(plan.tests_added, plan.tests_skipped)
      }),
    )
  list.filter(suggestions, fn(suggestion) {
    set.contains(written, render.test_name(suggestion))
  })
}

/// Every mutant those suggestions claim, each named once.
fn verified_ids(applied: List(render.Suggestion)) -> List(String) {
  applied
  |> list.flat_map(fn(suggestion) { [suggestion.mutant_id, ..suggestion.kills] })
  |> list.unique
}

/// What the workspace killed before the generated tests were written.
///
/// The stored run is preferred where it is still a verdict on this workspace,
/// which halves what `--verify` costs. `--no-reuse` refuses it and measures
/// the baseline whatever the tree says, which is the answer for a checkout
/// whose modification times say nothing true.
fn baseline_outcomes(
  workspace: String,
  options: Options,
  applied: List(render.Suggestion),
  ids: List(String),
  reuse: Bool,
) -> Result(#(Baseline, dict.Dict(String, Bool)), String) {
  let stored = case reuse {
    True -> stored_outcomes(workspace, ids)
    False -> None
  }
  case stored {
    Some(outcomes) -> Ok(#(Reused, outcomes))
    None -> {
      use graded <- result.map(measured_outcomes(workspace, options, applied))
      #(Measured, killed_map(graded))
    }
  }
}

/// The workspace's last stored run, when it still describes this workspace.
///
/// Two things have to hold. The run must have graded every mutant in
/// question: a mutant id carries the digest of the source it was cut from, so
/// an id that run named is a verdict on exactly this source, and nothing
/// partial is accepted because a baseline missing a mutant would credit the
/// generated tests with a kill nobody measured.
///
/// The id says nothing about the *tests*, though, which are the other half of
/// every kill — so the run must also predate everything the suite is made of.
/// Without that second half a run taken before a test was deleted still calls
/// its mutants dead, and `--verify` would report the generated test that now
/// kills one as adding nothing and name it under `GMU8017`: advice that
/// deletes the only test standing.
fn stored_outcomes(
  workspace: String,
  ids: List(String),
) -> Option(dict.Dict(String, Bool)) {
  case report.latest(workspace) {
    Error(_) -> None
    Ok(stored) ->
      case report.graded_outcomes(stored), report.run_started_ms(stored) {
        Ok(graded), Ok(started_ms) ->
          case suite_predates(workspace, started_ms) {
            True -> reusable_outcomes(graded, ids)
            False -> None
          }
        _, _ -> None
      }
  }
}

/// A stored run's verdicts as a baseline, when it graded every id wanted.
///
/// `graded` is what `report.graded_outcomes` answered for the stored run and
/// `ids` is every mutant the applied suggestions claim. One missing id is the
/// end of the shortcut: half a baseline attributes half the kills to nobody.
pub fn reusable_outcomes(
  graded: List(#(String, Bool)),
  ids: List(String),
) -> Option(dict.Dict(String, Bool)) {
  let stored = dict.from_list(graded)
  case list.all(ids, dict.has_key(stored, _)) {
    False -> None
    True -> Some(stored)
  }
}

/// Whether everything a kill depends on was last written before `started_ms`.
///
/// A stored run is a verdict about the sources *and* the tests it ran over,
/// but a mutant id pins only the source. What is left is settled the way
/// `make` settles it: `src/`, `test/`, `gleam.toml` and `manifest.toml` are
/// walked, directories included, and the stored run is trusted only where it
/// started after the last of them was written. A directory's own time is what
/// catches a deleted test module, which is the change that would otherwise
/// have `--verify` blame the test that replaced it.
///
/// A run that started inside the same second as a write is not trusted to
/// have seen it, and an entry that cannot be read at all is treated as
/// changed: the cost of refusing the shortcut is one more mutation run, and
/// the cost of taking it wrongly is a wrong answer.
pub fn suite_predates(workspace: String, started_ms: Int) -> Bool {
  ["src", "test", "gleam.toml", "manifest.toml"]
  |> list.all(fn(relative) {
    entry_predates(path.join(workspace, relative), started_ms)
  })
}

fn entry_predates(target: String, started_ms: Int) -> Bool {
  case simplifile.link_info(target) {
    // Nothing there is nothing that can have changed since.
    Error(simplifile.Enoent) -> True
    Error(_) -> False
    Ok(info) ->
      case { info.mtime_seconds + 1 } * 1000 <= started_ms {
        False -> False
        True ->
          case simplifile.file_info_type(info) {
            simplifile.Directory -> children_predate(target, started_ms)
            _ -> True
          }
      }
  }
}

fn children_predate(directory: String, started_ms: Int) -> Bool {
  case simplifile.read_directory(directory) {
    Error(_) -> False
    Ok(names) ->
      list.all(names, fn(name) {
        entry_predates(path.join(directory, name), started_ms)
      })
  }
}

/// Runs the mutation engine over the files the applied suggestions came from.
fn measured_outcomes(
  workspace: String,
  options: Options,
  applied: List(render.Suggestion),
) -> Result(Graded, String) {
  use output <- result.map(engine.run(
    workspace,
    verification_options(options, applied),
  ))
  output.report.results
  |> list.map(fn(result_) {
    let #(name, killed) = verified_outcome(result_.aggregate)
    #(result_.mutant.id, #(result_.mutant.display_id, name, killed))
  })
  |> dict.from_list
}

/// One run's verdicts reduced to the dead-or-alive `attribute` reads.
fn killed_map(graded: Graded) -> dict.Dict(String, Bool) {
  dict.map_values(graded, fn(_, verdict) { verdict.2 })
}

/// What became of every claimed mutant, and which run is owed the kill.
fn verified_entries(
  ids: List(String),
  before: dict.Dict(String, Bool),
  after: Graded,
) -> List(Verified) {
  apply.attribute(ids, before, killed_map(after))
  |> list.map(fn(entry) {
    let #(id, attribution) = entry
    case dict.get(after, id) {
      Ok(#(display_id, name, killed)) ->
        Verified(id, display_id, name, killed, attribution)
      // A mutant the verification run never discovered cannot be called
      // dead: the source it came from was selected, so its absence is a
      // finding rather than a pass.
      Error(Nil) -> Verified(id, "", "missing", False, attribution)
    }
  })
}

/// Says on stderr which generated tests killed nothing that was still alive.
///
/// A test whose every claimed mutant was already dead adds no coverage: the
/// reader's own suite was catching all of it, and the run that followed the
/// write would have been just as green without the new file. That is the case
/// `--verify` used to pass silently, so it is now said out loud — as a
/// warning, because a redundant test is a quality finding and not a failure.
///
/// Only the tests this run wrote are judged. A test the module already held
/// was in the suite while the baseline ran, so the baseline has nothing to say
/// about what it adds; calling it redundant on the strength of that would
/// libel every test a second `--verify` re-checks.
fn warn_idle_tests(
  options: Options,
  suggestions: List(render.Suggestion),
  plans: List(apply.Plan),
  checked: List(Verified),
) -> Nil {
  let added = set.from_list(list.flat_map(plans, fn(plan) { plan.tests_added }))
  let attributions =
    list.map(checked, fn(entry) { #(entry.mutant_id, entry.attribution) })
  suggestions
  |> list.filter(fn(suggestion) {
    set.contains(added, render.test_name(suggestion))
    && idle(suggestion, attributions)
  })
  |> list.each(fn(suggestion) {
    let message =
      "`"
      <> render.test_name(suggestion)
      <> "` adds nothing: every mutant it claims was already dead before it "
      <> "was written"
    write_diagnostic(
      options.log_format == "json",
      "warning",
      "GMU8017",
      message,
      None,
    )
  })
}

/// Whether every mutant `suggestion` claims was dead before it was written.
fn idle(
  suggestion: render.Suggestion,
  attributions: List(#(String, apply.Attribution)),
) -> Bool {
  [suggestion.mutant_id, ..suggestion.kills]
  |> list.unique
  |> list.all(fn(id) {
    list.key_find(attributions, id) == Ok(apply.AlreadyKilled)
  })
}

/// What one outcome is called, and whether it counts the mutant as dead.
///
/// The verdict is `outcome.detected`, the same predicate the mutation score
/// counts by: a timeout is a mutant the suite noticed, so `--verify` cannot
/// call the same workspace a failure over one.
fn verified_outcome(value: outcome.Outcome) -> #(String, Bool) {
  #(outcome_name(value), outcome.detected(value))
}

fn outcome_name(value: outcome.Outcome) -> String {
  case value {
    outcome.Killed -> "killed"
    outcome.TimedOut -> "timed-out"
    outcome.Survived -> "survived"
    outcome.TestError(_) -> "test-error"
  }
}

/// The mutation run `--verify` asks for: those files, quietly, reporting
/// nothing and storing nothing.
///
/// A verification run covers the files one set of suggestions came from and
/// nothing else, so storing it would leave `report latest`, `report list` and
/// a later `suggest --survivors` answering from a narrowed run the reader
/// never asked for. It writes no project report and no history entry: the
/// last real mutation run stays the last one.
///
/// It annotates nothing either. `apply` owns what it prints — a `--json` run
/// prints one JSON value — and on GitHub Actions the engine's own survivor
/// annotations would go to the same stdout and leave that value unreadable.
fn verification_options(
  options: Options,
  applied: List(render.Suggestion),
) -> Options {
  Options(
    ..options,
    matrix: False,
    changed: None,
    includes: list.unique(
      list.map(applied, fn(suggestion) { source_path(suggestion.location) }),
    ),
    operators: None,
    strict: Some(False),
    mutant_prefix: None,
    report_formats: Some([]),
    report_history: Some(False),
    annotations: False,
    json: False,
    explain: False,
    quiet: True,
    suggest: False,
  )
}

/// The file half of a `path:line:column` location.
fn source_path(location: String) -> String {
  location |> string.split(":") |> list.first |> result.unwrap(location)
}

fn emit_apply(
  plans: List(apply.Plan),
  verification: Option(List(Verified)),
  baseline: Option(Baseline),
  json: Bool,
  applied: Bool,
) -> Nil {
  case json {
    True -> io.println(apply_json(plans, verification))
    False -> io.print(render_plans(plans, verification, baseline, applied))
  }
}

/// One `apply --json` value: Apply JSON v1.
fn apply_json(
  plans: List(apply.Plan),
  verification: Option(List(Verified)),
) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #(
      "plans",
      json.array(plans, fn(plan) {
        json.object([
          #("file", json.string(plan.file)),
          #("create", json.bool(plan.create)),
          #("imports_added", json.array(plan.imports_added, json.string)),
          #("tests_added", json.array(plan.tests_added, json.string)),
          #("tests_skipped", json.array(plan.tests_skipped, json.string)),
        ])
      }),
    ),
    #(
      "verification",
      json.nullable(verification, fn(entries) {
        json.array(entries, fn(entry) {
          json.object([
            #("mutant_id", json.string(entry.mutant_id)),
            #("display_id", json.string(entry.display_id)),
            #("outcome", json.string(entry.outcome)),
            #("killed", json.bool(entry.killed)),
            #(
              "attribution",
              json.string(apply.attribution_name(entry.attribution)),
            ),
          ])
        })
      }),
    ),
  ])
  |> json.to_string
}

/// What `apply` did, or would do, as a terminal reads it.
fn render_plans(
  plans: List(apply.Plan),
  verification: Option(List(Verified)),
  baseline: Option(Baseline),
  applied: Bool,
) -> String {
  case plans {
    [] -> "Nothing to apply: no suggestion had a test that could be written.\n"
    _ ->
      string.concat(list.map(plans, render_plan(_, applied)))
      <> apply_summary(plans, applied)
      <> render_verification(verification)
      <> render_baseline(baseline)
  }
}

/// Which run the attributions above were graded against.
///
/// `newly killed` and `already killed` are claims about a run the reader never
/// saw, and the two baselines are not equally fresh: a measured one was taken
/// moments ago, a reused one is the workspace's last stored run, trusted only
/// because nothing the suite is made of has been written since. Naming it is
/// what lets a reader who knows better disagree — with `--no-reuse`.
fn render_baseline(baseline: Option(Baseline)) -> String {
  case baseline {
    None -> ""
    Some(Measured) ->
      "Baseline: a run of those files taken before the tests were written.\n"
    Some(Reused) ->
      "Baseline: the last stored run, which started after everything in src/\n"
      <> "and test/ was last written; --no-reuse measures one instead.\n"
  }
}

/// What one plan did to one file, or would do to it.
///
/// A file that gains no import and no test is left exactly as it is, formatter
/// included, so it is reported as unchanged rather than as updated: a second
/// `apply` over an applied workspace has nothing to say about it.
fn render_plan(plan: apply.Plan, applied: Bool) -> String {
  plan.file
  <> ": "
  <> case plan.create, applied, plan.imports_added, plan.tests_added {
    True, True, _, _ -> "created"
    True, False, _, _ -> "would be created"
    False, _, [], [] -> "unchanged"
    False, True, _, _ -> "updated"
    False, False, _, _ -> "would be updated"
  }
  <> "\n"
  <> string.concat(
    list.map(plan.imports_added, fn(line) { "  + " <> line <> "\n" }),
  )
  <> string.concat(
    list.map(plan.tests_added, fn(name) { "  + " <> name <> "\n" }),
  )
  <> string.concat(
    list.map(plan.tests_skipped, fn(name) {
      "  = " <> name <> " (already present)\n"
    }),
  )
}

fn apply_summary(plans: List(apply.Plan), applied: Bool) -> String {
  let tests =
    list.fold(plans, 0, fn(total, plan) {
      total + list.length(plan.tests_added)
    })
  int.to_string(tests)
  <> case applied {
    True -> " test(s) written to "
    False -> " test(s) would be written to "
  }
  <> int.to_string(list.length(plans))
  <> " file(s).\n"
}

fn render_verification(verification: Option(List(Verified))) -> String {
  case verification {
    None -> ""
    Some([]) ->
      "No generated test was found in those modules, so nothing was verified.\n"
    Some(entries) ->
      case list.filter(entries, surviving) {
        [] ->
          "Verified "
          <> int.to_string(list.length(entries))
          <> " mutant(s): every one of them is dead"
          <> already_killed_note(entries)
          <> ".\n"
        alive ->
          int.to_string(list.length(alive))
          <> " of "
          <> int.to_string(list.length(entries))
          <> " mutant(s) are still alive after the generated tests: "
          <> string.join(list.map(alive, named_mutant), ", ")
          <> "\n"
      }
  }
}

/// How the dead ones split between the new tests and the suite already there.
///
/// Said only when some of them were dead already, because that is the number
/// the reader cannot see any other way: the run that followed the write counts
/// both alike.
fn already_killed_note(entries: List(Verified)) -> String {
  case counted(entries, apply.AlreadyKilled) {
    0 -> ""
    old ->
      " ("
      <> int.to_string(counted(entries, apply.NewlyKilled))
      <> " newly killed, "
      <> int.to_string(old)
      <> " already killed by your own tests)"
  }
}

fn counted(entries: List(Verified), attribution: apply.Attribution) -> Int {
  list.count(entries, fn(entry) { entry.attribution == attribution })
}

/// One surviving mutant, named the way the reader saw it, with its outcome.
fn named_mutant(entry: Verified) -> String {
  mutant_name(entry) <> " (" <> entry.outcome <> ")"
}

fn mutant_name(entry: Verified) -> String {
  case entry.display_id {
    "" -> entry.mutant_id
    display_id -> display_id
  }
}

/// Prints the tests that kill whatever a finished run left alive.
///
/// Only a text-mode `run --suggest` asks for this: `run --json` prints exactly
/// one JSON value and a second one after it would break every reader of the
/// first, which is why the two flags are refused together. The survivors are
/// handed over as ids rather than looked up again, so a run that stored no
/// report at all can still be followed by suggestions. A probe that fails is
/// reported as a warning: the mutation result is already on the reader's
/// screen, and the run's own exit code is the one that matters.
fn suggest_after_run(
  workspace: String,
  options: Options,
  run: report.RunReport,
) -> Nil {
  let survivors =
    list.filter(run.results, fn(result_) {
      result_.aggregate == outcome.Survived
    })
  case options.suggest, survivors {
    False, _ -> Nil
    True, [] -> Nil
    True, alive -> {
      let request =
        suggest_command.SuggestOptions(
          ..suggest_command.default_options(),
          includes: list.unique(
            list.map(alive, fn(result_) { result_.mutant.path }),
          ),
        )
      case
        suggest_command.suggest_survivors(
          workspace,
          request,
          list.map(alive, fn(result_) { result_.mutant.id }),
        )
      {
        Error(error) ->
          write_diagnostic(
            options.log_format == "json",
            "warning",
            diagnostic_code(error),
            error,
            None,
          )
        Ok(found) -> {
          io.print("\n")
          io.print(render_suggestions(found))
        }
      }
    }
  }
}

/// Says on stderr that `--function` named something the run never probed.
///
/// The run itself succeeded — a selection with nothing to kill in it is not a
/// failure — but every count of the summary is then zero, which reads exactly
/// like a function whose mutants are all dead already. `--quiet` does not
/// silence it: it reports a probable mistake in the command, not progress.
///
/// What it can say is bounded by what it knows. The name is missing from the
/// probe's verdicts, and `--mutant` or `--survivors` narrowing every mutant of
/// a real function away is as good a way to get there as a typo is; so the
/// warning is about this run's selection, which is the thing that is certainly
/// empty, rather than about the files, which may well hold the function.
fn warn_unmatched_function(
  options: Options,
  report: suggest_command.Report,
) -> Nil {
  case report.unmatched_function {
    None -> Nil
    Some(name) ->
      write_diagnostic(
        options.log_format == "json",
        "warning",
        "GMU8012",
        "this run selected no mutant inside a function named `" <> name <> "`",
        None,
      )
  }
}

fn print_report_path(options: Options, label: String, value: String) -> Nil {
  case value {
    "" -> Nil
    _ -> emit_info(options, "GMU0004", label <> ": " <> value)
  }
}

fn render_execution_summary(summary: engine.ExecutionSummary) -> String {
  "execution: "
  <> int.to_string(summary.narrowed)
  <> " narrowed; "
  <> int.to_string(summary.confirmations)
  <> " full-suite confirmation(s); "
  <> int.to_string(summary.fallbacks)
  <> " fallback(s); "
  <> int.to_string(summary.cache_hits)
  <> " cache hit(s)"
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
    False -> io.println_error(diagnostic_line(level, code, message, usage))
  }
}

/// The stderr line one diagnostic is printed as.
///
/// An error carries its code inside its own message, because that is the text
/// `diagnostic_code` reads it back out of, and so does every warning built out
/// of one — `run --suggest` reports a probe it could not make as a warning
/// under the suggest error's own code. A warning raised here rather than
/// forwarded carries a plain sentence and nothing else, so the code is put in
/// front of it. Either way the line names its code exactly once.
///
/// Pure, and public, because the line is a contract: `docs/suggest.md` tells a
/// reader that a warning names its code once, and that is checkable here
/// without a run to print one.
pub fn diagnostic_line(
  level: String,
  code: String,
  message: String,
  usage: Option(String),
) -> String {
  let prefix = case level, string.starts_with(message, code <> ": ") {
    "warning", False -> "gleam-mutants: " <> code <> ": "
    _, _ -> "gleam-mutants: "
  }
  prefix
  <> message
  <> case usage {
    Some(value) -> "\n\n" <> value
    None -> ""
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

// --- suggest and explain output ---------------------------------------------

/// Everything one `suggest` run found, as a terminal reads it.
///
/// One block per suggestion — what it kills, then the test that kills it —
/// then the import lines each module under test needs, then the one line that
/// says what the whole run came to.
///
/// Public so that the exact text a reader scans can be pinned by a test
/// without a probe run behind it; nothing outside this package calls it.
pub fn render_suggestions(report: suggest_command.Report) -> String {
  let scopes = module_scopes(report.suggestions, report.style)
  report.suggestions
  |> list.map(fn(suggestion) {
    render_suggestion(suggestion, scope_of(scopes, suggestion, report.style))
  })
  |> string.concat
  |> string.append(render_import_hints(report, scopes))
  |> string.append(suggest_summary(report))
}

/// One rendering scope per module under test.
///
/// The generated tests of one module belong in one test module, and one file
/// names one module one way: the import lines a reader is shown and the calls
/// those tests make have to be settled together or they name it two ways.
fn module_scopes(
  suggestions: List(render.Suggestion),
  style: render.AssertStyle,
) -> List(#(String, render.Scope)) {
  suggestions
  |> list.map(fn(suggestion) { suggestion.module_path })
  |> list.unique
  |> list.map(fn(module) {
    #(
      module,
      render.scope(
        list.filter(suggestions, fn(item) { item.module_path == module }),
        style,
      ),
    )
  })
}

/// The scope one suggestion is rendered in.
fn scope_of(
  scopes: List(#(String, render.Scope)),
  suggestion: render.Suggestion,
  style: render.AssertStyle,
) -> render.Scope {
  list.key_find(scopes, suggestion.module_path)
  |> result.unwrap(render.scope([suggestion], style))
}

fn render_suggestion(
  suggestion: render.Suggestion,
  scope: render.Scope,
) -> String {
  suggestion.display_id
  <> " "
  <> suggestion.operator
  <> " at "
  <> suggestion.location
  <> ": "
  <> compact(suggestion.original)
  <> " -> "
  <> compact(suggestion.replacement)
  <> "; kills "
  <> int.to_string(list.length(suggestion.kills))
  <> " mutant(s)\n"
  <> case render.test_source(scope, suggestion) {
    Ok(source) -> source
    Error(reason) -> reason
  }
  <> "\n\n"
}

/// The imports each module under test needs, once per module.
///
/// The generated tests for one module belong in one test module, so the
/// import lines are collected the same way rather than repeated under every
/// suggestion.
fn render_import_hints(
  report: suggest_command.Report,
  scopes: List(#(String, render.Scope)),
) -> String {
  scopes
  |> list.map(fn(entry) {
    let #(module, scope) = entry
    case
      report.suggestions
      |> list.filter(fn(suggestion) { suggestion.module_path == module })
      |> render.imports(scope, _)
    {
      [] -> ""
      lines ->
        "Imports for "
        <> module
        <> ":\n"
        <> string.concat(list.map(lines, fn(line) { "  " <> line <> "\n" }))
        <> "\n"
    }
  })
  |> string.concat
}

/// What the run came to, counted rather than listed.
fn suggest_summary(report: suggest_command.Report) -> String {
  let killed =
    report.suggestions
    |> list.flat_map(fn(suggestion) { suggestion.kills })
    |> set.from_list
  int.to_string(list.length(report.suggestions))
  <> " suggestion(s) kill "
  <> int.to_string(list.count(report.distinguishable, set.contains(killed, _)))
  <> " of "
  <> int.to_string(list.length(report.distinguishable))
  <> " distinguishable mutant(s); "
  <> int.to_string(list.length(report.indistinguishable))
  <> " indistinguishable (possibly equivalent); "
  <> int.to_string(list.length(report.nondeterministic))
  <> " nondeterministic; "
  <> int.to_string(list.length(report.unsupported))
  <> " unsupported; "
  <> int.to_string(list.length(report.skipped))
  <> " function(s) skipped.\n"
  <> case report.survivors_missing {
    [] -> ""
    files ->
      "The latest report never covered " <> string.join(files, ", ") <> ".\n"
  }
}

/// One `suggest --json` value: Suggest JSON v1.
fn suggest_json(report: suggest_command.Report) -> String {
  let scopes = module_scopes(report.suggestions, report.style)
  json.object([
    #("schema_version", json.int(1)),
    #(
      "suggestions",
      json.array(report.suggestions, fn(item) {
        suggestion_json(item, scope_of(scopes, item, report.style))
      }),
    ),
    #(
      "indistinguishable",
      json.array(report.indistinguishable, fn(entry) {
        json.object([
          #("mutant_id", json.string(entry.mutant.id)),
          #("display_id", json.string(entry.mutant.display_id)),
          #("function", json.string(entry.function)),
          #("cases", json.int(entry.cases)),
        ])
      }),
    ),
    #("nondeterministic", json.array(report.nondeterministic, unsupported_json)),
    #("unsupported", json.array(report.unsupported, unsupported_json)),
    #(
      "skipped",
      json.array(report.skipped, fn(entry) {
        json.object([
          #("module", json.string(entry.module)),
          #("function", json.string(entry.function)),
          #("reason", json.string(entry.reason)),
        ])
      }),
    ),
    #("survivors_missing", json.array(report.survivors_missing, json.string)),
  ])
  |> json.to_string
}

/// One mutant of a Suggest JSON v1 document that has no test to show for it.
///
/// `nondeterministic` and `unsupported` are separate buckets carrying the same
/// four fields: one names the mutants whose original disagreed with itself,
/// the other the mutants a wall stopped, and a reader tells them apart by
/// which array they are in rather than by reading a reason.
fn unsupported_json(entry: suggest_command.Unsupported) -> json.Json {
  json.object([
    #("mutant_id", json.string(entry.mutant.id)),
    #("display_id", json.string(entry.mutant.display_id)),
    #("function", json.string(entry.function)),
    #("reason", json.string(entry.reason)),
  ])
}

/// One suggestion of a Suggest JSON v1 document.
///
/// The values are reported the way the generated test names them, so that
/// `inputs`, `expected`, `test_source` and `imports` of one entry all name the
/// module under test by the one name a file importing it can use.
fn suggestion_json(
  candidate: render.Suggestion,
  scope: render.Scope,
) -> json.Json {
  let suggestion = render.rendered(scope, candidate)
  json.object([
    #("module_path", json.string(suggestion.module_path)),
    #("function", json.string(suggestion.function)),
    #("mutant_id", json.string(suggestion.mutant_id)),
    #("display_id", json.string(suggestion.display_id)),
    #("operator", json.string(suggestion.operator)),
    #("location", json.string(suggestion.location)),
    #("original", json.string(suggestion.original)),
    #("replacement", json.string(suggestion.replacement)),
    #("inputs", json.array(suggestion.inputs, json.string)),
    #("expected", json.nullable(suggestion.expected, json.string)),
    #("expected_inspect", json.string(suggestion.expected_inspect)),
    #("actual_inspect", json.string(suggestion.actual_inspect)),
    #("kills", json.array(suggestion.kills, json.string)),
    #("test_name", json.string(render.test_name(suggestion))),
    #(
      "test_source",
      json.string(render.test_source(scope, suggestion) |> result.unwrap("")),
    ),
    #("imports", json.array(render.imports(scope, [suggestion]), json.string)),
  ])
}

/// One explanation, as a terminal reads it.
///
/// Public for the same reason as `render_suggestions`: this block is the whole
/// answer `explain` gives, and it is pinned by a test rather than described.
pub fn render_explanation(explanation: suggest_command.Explanation) -> String {
  let mutant = explanation.mutant
  mutant.display_id
  <> " "
  <> operator.name(mutant.operator)
  <> " at "
  <> mutant.path
  <> ":"
  <> int.to_string(mutant.line)
  <> ":"
  <> int.to_string(mutant.column)
  // A mutant outside every function of its module has no function to name,
  // and `... at src/app.gleam:1:19 in ` leaves the reader an empty gap where
  // one belongs.
  <> case explanation.function {
    "" -> ""
    name -> " in " <> name
  }
  <> "\n"
  <> compact(mutant.original)
  <> " -> "
  <> compact(mutant.replacement)
  <> "\n"
  <> "status: "
  <> probe_result.status_name(explanation.status)
  <> "\n"
  <> "inputs: "
  <> case explanation.inputs {
    [] -> "(none found)"
    inputs -> string.join(inputs, ", ")
  }
  <> "\n"
  <> answers(explanation)
  <> "\n"
  <> case explanation.test_source {
    Some(source) -> source <> "\n"
    None -> "no test can be written: " <> explanation.reason <> "\n"
  }
}

/// What each side answered, or the fact that neither answer was recorded.
///
/// Only a verdict that separated its mutant has a value from both sides. One
/// that did not — every `indistinguishable`, `nondeterministic` and
/// `unsupported` mutant — carries no inspect at all, and a call that panicked
/// or timed out carries none for its own side. Printing the sentence anyway
/// leaves the reader an empty gap where a value belongs, so the sentence says
/// what was missed instead.
fn answers(explanation: suggest_command.Explanation) -> String {
  case
    compact(explanation.expected_inspect),
    compact(explanation.actual_inspect)
  {
    "", "" -> "no result was recorded for either side"
    expected, actual ->
      "the original "
      <> answered("is", expected)
      <> ", the mutant "
      <> answered("answers", actual)
  }
}

/// One side of that sentence: its value, or that it never produced one.
fn answered(verb: String, inspect: String) -> String {
  case inspect {
    "" -> "never answered"
    value -> verb <> " " <> value
  }
}

/// One `explain --json` value.
fn explain_json(explanation: suggest_command.Explanation) -> String {
  let mutant = explanation.mutant
  json.object([
    #("schema_version", json.int(1)),
    #("mutant_id", json.string(mutant.id)),
    #("display_id", json.string(mutant.display_id)),
    #("function", json.string(explanation.function)),
    #("operator", json.string(operator.name(mutant.operator))),
    #(
      "location",
      json.string(
        mutant.path
        <> ":"
        <> int.to_string(mutant.line)
        <> ":"
        <> int.to_string(mutant.column),
      ),
    ),
    #("original", json.string(mutant.original)),
    #("replacement", json.string(mutant.replacement)),
    #("status", json.string(probe_result.status_name(explanation.status))),
    #("inputs", json.array(explanation.inputs, json.string)),
    #("expected", json.nullable(explanation.expected, json.string)),
    #("expected_inspect", json.string(explanation.expected_inspect)),
    #("actual_inspect", json.string(explanation.actual_inspect)),
    #("test_source", json.nullable(explanation.test_source, json.string)),
    #("reason", json.string(explanation.reason)),
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
      at: ["suggest"],
      do: command("Propose tests that kill surviving mutants (Erlang only)."),
    )
    |> glint.add(
      at: ["explain"],
      // The mutant is positional, and glint has no way to render an argument
      // in its own subcommand list, so the description carries it: a reader
      // who only ever runs `--help` still learns that `explain` takes an id.
      do: command(
        "Explain <id-prefix>: one mutant and the input that kills it.",
      ),
    )
    |> glint.add(
      at: ["apply"],
      do: command("Write the suggested tests into the project (Erlang only)."),
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
  <> "  --test-selection <v> auto or full (default: auto)\n"
  <> "  --timeout <duration>  100ms through 24h (for example 1.5s)\n"
  <> "  --report <formats>    none, json, html, or json,html\n"
  <> "  --include <glob>      override mutation includes (repeatable)\n"
  <> "  --operator <name>     select an operator (repeatable)\n"
  <> "  --test-command <argv...>\n"
  <> "\nRun options:\n"
  <> "  --suggest             propose tests for the survivors (text mode)\n"
  <> "\nList options:\n"
  <> "  --validate            compiler-validate discovered candidates\n"
  <> "\nDoctor options:\n"
  <> "  --json                emit one doctor JSON v1 value\n"
  <> "  --all-runtimes        require all four supported runtimes\n"
  <> "\nSuggest/explain options (explain takes <id-prefix> first):\n"
  <> "  --changed <git-ref>   limit suggestions to files changed from ref\n"
  <> "  --include <glob>      override mutation includes (repeatable)\n"
  <> "  --function <name>     probe only the function of that name\n"
  <> "  --mutant <id-prefix>  probe exactly one unambiguous mutant\n"
  <> "  --survivors           keep only the latest report's survivors\n"
  <> "  --operator <name>     select an operator (repeatable)\n"
  <> "  --seed <n>            fix the input search\n"
  <> "  --max-cases <n>       inputs tried per mutant (1-100000)\n"
  <> "  --max-shrinks <n>     shrinking steps taken (0-100000)\n"
  <> "  --budget <duration>   100ms through 24h per probe process\n"
  <> "  --style <value>       assert or should\n"
  <> "  --json                emit one Suggest JSON v1 value\n"
  <> "\nApply options (every suggest flag above, and):\n"
  <> "  --yes                 write the tests; without it nothing is written\n"
  <> "  --verify              write, then re-run the engine over those files\n"
  <> "  --no-reuse            measure --verify's baseline, never reuse a run\n"
  <> "  --json                emit one Apply JSON v1 value\n"
  <> "\nInit options:\n"
  <> "  --dry-run | --check   preview migration or check it is current\n"
  <> "  --gitignore           explicitly add the report directory\n"
  <> "\nPrivacy: native/project reports may contain source and diagnostics;\n"
  <> "treat reports uploaded as CI artifacts as potentially sensitive.\n"
}
