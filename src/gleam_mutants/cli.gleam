// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import child_process
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam_mutants/config
import gleam_mutants/core/catalog.{type RejectedMutant}
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator
import gleam_mutants/core/path
import gleam_mutants/core/span
import gleam_mutants/engine.{type Options, Options}
import gleam_mutants/platform
import gleam_mutants/report
import glint
import simplifile

pub type Command {
  RunCommand(Options)
  ListCommand(Options)
  DoctorCommand
  InitCommand
  ReportLatestCommand(json: Bool)
  HelpCommand
  VersionCommand
}

pub fn main() -> Nil {
  case parse(platform.arguments()) {
    Error(message) -> {
      io.println("error: " <> message <> "\n\n" <> help_text())
      platform.exit(2)
    }
    Ok(command) -> execute(command)
  }
}

pub fn parse(arguments: List(String)) -> Result(Command, String) {
  case arguments {
    [] -> parse_options([], engine.default_options()) |> result.map(RunCommand)
    ["run", ..rest] ->
      parse_options(rest, engine.default_options()) |> result.map(RunCommand)
    ["list", ..rest] ->
      parse_options(rest, engine.default_options()) |> result.map(ListCommand)
    ["doctor"] -> Ok(DoctorCommand)
    ["init"] -> Ok(InitCommand)
    ["report", "latest"] -> Ok(ReportLatestCommand(False))
    ["report", "latest", "--json"] -> Ok(ReportLatestCommand(True))
    ["--help"] | ["-h"] | ["help"] -> Ok(HelpCommand)
    ["--version"] | ["-V"] | ["version"] -> Ok(VersionCommand)
    [first, ..] ->
      case string.starts_with(first, "-") {
        True ->
          parse_options(arguments, engine.default_options())
          |> result.map(RunCommand)
        False -> Error("unknown command " <> string.inspect(first))
      }
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
        Ok(#(name, _)) -> Error("unknown option --" <> name)
        Error(_) -> Error("unexpected argument " <> string.inspect(argument))
      }
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
    Ok(number) if number > 0 -> Ok(number)
    _ -> Error(flag <> " expects a positive integer")
  }
}

fn parse_timeout(value: String) -> Result(Int, String) {
  let value = case string.ends_with(value, "s") {
    True -> string.drop_end(value, 1)
    False -> value
  }
  case float.parse(value), int.parse(value) {
    Ok(seconds), _ if seconds >. 0.0 -> Ok(float.round(seconds *. 1000.0))
    _, Ok(seconds) if seconds > 0 -> Ok(seconds * 1000)
    _, _ -> Error("--timeout expects positive seconds, for example 10 or 1.5s")
  }
}

fn execute(command: Command) -> Nil {
  let workspace = platform.current_directory()
  case command {
    HelpCommand -> io.println(help_text())
    VersionCommand -> io.println("gleam-mutants 0.1.0")
    DoctorCommand -> doctor(workspace)
    InitCommand -> init(workspace)
    ReportLatestCommand(_) ->
      case report.latest() {
        Ok(text) -> io.print(text)
        Error(error) -> fail("could not read latest report: " <> error)
      }
    ListCommand(options) ->
      case engine.list_mutants(workspace, options) {
        Error(error) -> fail(error)
        Ok(output) -> {
          case options.json {
            True -> io.println(catalog_json(output.mutants, output.rejected))
            False ->
              io.print(render_list(
                output.mutants,
                output.rejected,
                options.explain,
              ))
          }
        }
      }
    RunCommand(options) ->
      case engine.run(workspace, options) {
        Error(error) -> fail(error)
        Ok(output) -> {
          case options.json {
            True -> io.println(report.to_json(output.report))
            False -> {
              io.print(report.render(output.report, options.explain))
              io.println("Report: " <> output.report_path)
            }
          }
          platform.exit(output.exit_code)
        }
      }
  }
}

fn fail(message: String) -> Nil {
  io.println("gleam-mutants: " <> message)
  platform.exit(2)
}

fn init(workspace: String) -> Nil {
  let target = path.join(workspace, "gleam.toml")
  case simplifile.read(target) {
    Error(error) ->
      fail("could not read gleam.toml: " <> simplifile.describe_error(error))
    Ok(source) ->
      case config.initialise(source) {
        Error(error) -> fail(config.describe_error(error))
        Ok(#(_, False)) ->
          io.println(
            "gleam.toml already contains [tools.gleam_mutants]; unchanged.",
          )
        Ok(#(updated, True)) ->
          case simplifile.write(target, updated) {
            Ok(Nil) -> io.println("Added [tools.gleam_mutants] to gleam.toml.")
            Error(error) ->
              fail(
                "could not write gleam.toml: "
                <> simplifile.describe_error(error),
              )
          }
      }
  }
}

fn doctor(workspace: String) -> Nil {
  let tools = ["gleam", "erl", "node", "deno", "bun", "git"]
  let checks =
    list.map(tools, fn(tool) {
      case child_process.find_executable(tool) {
        Ok(found) -> {
          io.println("ok  " <> tool <> "  " <> found)
          True
        }
        Error(_) -> {
          io.println("missing  " <> tool)
          False
        }
      }
    })
  case simplifile.read(path.join(workspace, "gleam.toml")) {
    Ok(source) ->
      case config.decode(source, platform.cpu_count()) {
        Ok(_) -> io.println("ok  gleam.toml configuration")
        Error(error) -> io.println("invalid  " <> config.describe_error(error))
      }
    Error(_) -> io.println("missing  gleam.toml")
  }
  case list.all(checks, fn(value) { value }) {
    True -> Nil
    False -> platform.exit(2)
  }
}

fn render_list(
  mutants: List(Mutant),
  rejected: List(RejectedMutant),
  explain: Bool,
) -> String {
  let rows =
    mutants
    |> list.map(fn(mutant) {
      mutant.path
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
        "rejected "
        <> item.mutant.path
        <> ":"
        <> int.to_string(item.mutant.line)
        <> " "
        <> item.reason
        <> "\n"
      })
      |> string.concat
  }
  rows
  <> rejected_rows
  <> int.to_string(list.length(mutants))
  <> " valid mutants, "
  <> int.to_string(list.length(rejected))
  <> " rejected.\n"
}

fn catalog_json(
  mutants: List(Mutant),
  rejected: List(RejectedMutant),
) -> String {
  json.object([
    #("schema_version", json.int(1)),
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
      do: command("Run mutation testing (the default command)."),
    )
    |> glint.add(at: ["run"], do: command("Run mutation testing."))
    |> glint.add(at: ["list"], do: command("List compiler-valid mutants."))
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
  let generated = case glint.execute(app, ["--help"]) {
    Ok(glint.Help(text)) -> text
    _ -> "gleam-mutants"
  }
  generated
  <> "\nRun/list options:\n"
  <> "  --changed <git-ref>   limit mutations to files changed from ref\n"
  <> "  --matrix              test Erlang, Node, Deno, and Bun\n"
  <> "  --strict | --no-strict\n"
  <> "  --json | --explain\n"
  <> "  --jobs <n>            parallel isolated worker count (max 256)\n"
  <> "  --timeout <seconds>   per-test timeout\n"
  <> "  --include <glob>      override mutation includes (repeatable)\n"
  <> "  --operator <name>     select an operator (repeatable)\n"
  <> "  --test-command <argv...>\n"
}
