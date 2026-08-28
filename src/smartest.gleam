//// Gleam-first adaptive verification entrypoint.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam/option.{type Option, None, Some}
import gleam_mutants/cli as mutants_cli
import smartest/cli
import smartest/internal/discovery
import smartest/internal/process
import smartest/internal/shell
import smartest/internal/watch_shell
import smartest/runner
import smartest/testing

/// The common lazy value returned by every native Smartest test.
pub type Test =
  testing.Test

/// Discovers and runs public zero-arity `*_test` exports under `test/`.
pub fn main() -> Nil {
  let arguments = shell.arguments()
  case cli.parse(arguments) {
    Ok(cli.DiscoverCommand) -> discovery.main()
    Ok(cli.MutantsCommand(arguments)) -> mutants_cli.run(arguments)
    Ok(cli.TestCommand(root, arguments)) ->
      run_test(root_or(root, shell.current_directory()), arguments, [])
    Ok(cli.WatchCommand(root, arguments)) ->
      watch_shell.spec(root_or(root, shell.current_directory()), arguments)
      |> watch_shell.run
    Ok(cli.CiCommand(root, arguments)) ->
      run_ci(root_or(root, shell.current_directory()), arguments)
    Ok(cli.ReplayCommand(root, id)) ->
      run_replay(root_or(root, shell.current_directory()), id)
    Ok(cli.StrengthenCommand(root, arguments)) ->
      mutants_cli.run(with_root(["run", ..arguments], root))
    Ok(cli.DeepCommand(root, arguments)) ->
      mutants_cli.run(with_root(["run", "--matrix", ..arguments], root))
    Ok(command) ->
      case
        cli.execute(
          command,
          default_root: shell.current_directory(),
          now_ms: shell.now_milliseconds(),
        )
      {
        Ok(output) -> {
          io.print(output.stdout)
          io.print_error(output.stderr)
          shell.exit(output.exit_code)
        }
        Error(reason) -> {
          io.println_error(reason)
          shell.exit(2)
        }
      }
    Error(reason) -> {
      io.println_error(reason)
      io.print_error(cli.help_text())
      shell.exit(2)
    }
  }
}

fn run_test(
  root: String,
  arguments: List(String),
  environment: List(#(String, String)),
) -> Nil {
  case process.gleam_test(root, arguments, environment) {
    Ok(output) -> {
      io.print(output.output)
      shell.exit(output.exit_code)
    }
    Error(reason) -> {
      io.println_error(reason)
      shell.exit(2)
    }
  }
}

fn run_ci(root: String, arguments: List(String)) -> Nil {
  case process.gleam_test(root, arguments, []) {
    Error(reason) -> {
      io.println_error(reason)
      shell.exit(2)
    }
    Ok(output) if output.exit_code != 0 -> {
      io.print(output.output)
      shell.exit(output.exit_code)
    }
    Ok(output) -> {
      io.print(output.output)
      let assert Ok(doctor) =
        cli.execute(
          cli.DoctorCommand(Some(root)),
          default_root: root,
          now_ms: shell.now_milliseconds(),
        )
      io.print(doctor.stdout)
      io.print_error(doctor.stderr)
      shell.exit(doctor.exit_code)
    }
  }
}

fn run_replay(root: String, id: String) -> Nil {
  let options =
    runner.replay_options(root, id, created_ms: shell.now_milliseconds())
  case options.startup_error {
    Some(reason) -> {
      io.println_error(reason)
      shell.exit(2)
    }
    None -> run_test(root, [], [#("SMARTEST_REPLAY_ID", id)])
  }
}

fn root_or(root: Option(String), default: String) -> String {
  case root {
    Some(root) -> root
    None -> default
  }
}

fn with_root(arguments: List(String), root: Option(String)) -> List(String) {
  case root {
    Some(root) -> ["--root", root, ..arguments]
    None -> arguments
  }
}
