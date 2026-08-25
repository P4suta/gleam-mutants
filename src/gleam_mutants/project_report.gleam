// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile

pub type ProjectReports {
  ProjectReports(json_path: String, html_path: String)
}

const json_name = "mutation.json"

const html_name = "mutation.html"

pub fn write(
  workspace: String,
  directory: String,
  json: String,
  html: String,
) -> Result(ProjectReports, String) {
  use _ <- result.try(validate_destination(workspace, directory))
  let report_directory = path.join(workspace, directory)
  use _ <- result.try(
    simplifile.create_directory_all(report_directory)
    |> result.map_error(fn(error) {
      report_error(
        "could not create report directory",
        report_directory,
        simplifile.describe_error(error),
      )
    }),
  )
  use _ <- result.try(validate_destination(workspace, directory))
  let json_path = path.join(report_directory, json_name)
  let html_path = path.join(report_directory, html_name)
  use previous_json <- result.try(read_previous(json_path))
  let nonce = platform.random_nonce()
  let json_temporary =
    path.join(report_directory, "." <> json_name <> "." <> nonce <> ".tmp")
  let html_temporary =
    path.join(report_directory, "." <> html_name <> "." <> nonce <> ".tmp")
  use _ <- result.try(require_absent(json_temporary))
  use _ <- result.try(require_absent(html_temporary))
  use _ <- result.try(stage(json_temporary, json, "Stryker JSON"))
  case stage(html_temporary, html, "HTML") {
    Error(error) -> {
      cleanup(json_temporary)
      Error(error)
    }
    Ok(Nil) ->
      case replace(json_temporary, json_path, "Stryker JSON") {
        Error(error) -> {
          cleanup(json_temporary)
          cleanup(html_temporary)
          Error(error)
        }
        Ok(Nil) ->
          case replace(html_temporary, html_path, "HTML") {
            Error(error) -> {
              cleanup(html_temporary)
              case restore_json(json_path, json_temporary, previous_json) {
                Ok(Nil) -> Error(error)
                Error(rollback_error) ->
                  Error(error <> "; JSON rollback failed: " <> rollback_error)
              }
            }
            Ok(Nil) -> Ok(ProjectReports(json_path, html_path))
          }
      }
  }
}

pub fn write_formats(
  workspace: String,
  directory: String,
  formats: List(String),
  json: String,
  html: String,
) -> Result(ProjectReports, String) {
  case list.contains(formats, "json"), list.contains(formats, "html") {
    False, False -> Ok(ProjectReports("", ""))
    True, True -> write(workspace, directory, json, html)
    True, False ->
      write_single(workspace, directory, json_name, json, "Stryker JSON")
      |> result.map(fn(target) { ProjectReports(target, "") })
    False, True ->
      write_single(workspace, directory, html_name, html, "HTML")
      |> result.map(fn(target) { ProjectReports("", target) })
  }
}

fn write_single(
  workspace: String,
  directory: String,
  name: String,
  contents: String,
  label: String,
) -> Result(String, String) {
  use _ <- result.try(validate_destination(workspace, directory))
  let report_directory = path.join(workspace, directory)
  use _ <- result.try(
    simplifile.create_directory_all(report_directory)
    |> result.map_error(fn(error) {
      report_error(
        "could not create report directory",
        report_directory,
        simplifile.describe_error(error),
      )
    }),
  )
  use _ <- result.try(validate_destination(workspace, directory))
  let target = path.join(report_directory, name)
  let temporary =
    path.join(
      report_directory,
      "." <> name <> "." <> platform.random_nonce() <> ".tmp",
    )
  use _ <- result.try(require_absent(temporary))
  use _ <- result.try(stage(temporary, contents, label))
  replace(temporary, target, label)
  |> result.map(fn(_) { target })
}

fn stage(
  target: String,
  contents: String,
  label: String,
) -> Result(Nil, String) {
  case simplifile.write(target, contents) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      cleanup(target)
      Error(report_error(
        "could not stage " <> label <> " report",
        target,
        simplifile.describe_error(error),
      ))
    }
  }
}

fn read_previous(target: String) -> Result(Option(BitArray), String) {
  case simplifile.read_bits(target) {
    Ok(bits) -> Ok(Some(bits))
    Error(simplifile.Enoent) -> Ok(None)
    Error(error) ->
      Error(report_error(
        "could not preserve previous report for rollback",
        target,
        simplifile.describe_error(error),
      ))
  }
}

fn restore_json(
  target: String,
  temporary: String,
  previous: Option(BitArray),
) -> Result(Nil, String) {
  case previous {
    None ->
      case simplifile.delete_file(at: target) {
        Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
        Error(error) -> Error(simplifile.describe_error(error))
      }
    Some(bits) -> {
      use _ <- result.try(
        simplifile.write_bits(bits, to: temporary)
        |> result.map_error(simplifile.describe_error),
      )
      replace(temporary, target, "previous Stryker JSON")
    }
  }
}

pub fn validate_destination(
  workspace: String,
  directory: String,
) -> Result(Nil, String) {
  use _ <- result.try(require_directory(workspace, "workspace"))
  use _ <- result.try(validate_components(
    workspace,
    string.split(directory, "/"),
    "",
  ))
  let report_directory = path.join(workspace, directory)
  use _ <- result.try(
    require_regular_target(path.join(report_directory, json_name)),
  )
  require_regular_target(path.join(report_directory, html_name))
}

fn validate_components(
  workspace: String,
  components: List(String),
  relative: String,
) -> Result(Nil, String) {
  case components {
    [] -> Ok(Nil)
    [component, ..rest] -> {
      let relative = path.join(relative, component)
      let candidate = path.join(workspace, relative)
      case simplifile.link_info(candidate) {
        Error(simplifile.Enoent) -> Ok(Nil)
        Error(error) ->
          Error(
            "could not inspect report directory component "
            <> relative
            <> ": "
            <> simplifile.describe_error(error),
          )
        Ok(info) ->
          case
            simplifile.file_info_type(info),
            platform.is_reparse_point(candidate)
          {
            simplifile.Symlink, _ | _, True ->
              Error("refusing symlink or junction in report path: " <> relative)
            simplifile.Directory, False ->
              validate_components(workspace, rest, relative)
            _, _ ->
              Error("report path component is not a directory: " <> relative)
          }
      }
    }
  }
}

fn require_directory(target: String, label: String) -> Result(Nil, String) {
  case simplifile.link_info(target) {
    Error(error) ->
      Error(
        "could not inspect "
        <> label
        <> ": "
        <> simplifile.describe_error(error),
      )
    Ok(info) ->
      case simplifile.file_info_type(info), platform.is_reparse_point(target) {
        simplifile.Symlink, _ | _, True ->
          Error("refusing symlink or junction in report path: " <> label)
        simplifile.Directory, False -> Ok(Nil)
        _, _ -> Error(label <> " is not a directory")
      }
  }
}

fn require_regular_target(target: String) -> Result(Nil, String) {
  case simplifile.link_info(target) {
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(
        "could not inspect report target: " <> simplifile.describe_error(error),
      )
    Ok(info) ->
      case simplifile.file_info_type(info), platform.is_reparse_point(target) {
        simplifile.File, False -> Ok(Nil)
        _, _ ->
          Error("existing report target is not a regular file: " <> target)
      }
  }
}

fn require_absent(target: String) -> Result(Nil, String) {
  case simplifile.link_info(target) {
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(
        "could not inspect temporary report file: "
        <> simplifile.describe_error(error),
      )
    Ok(_) -> Error("temporary report file already exists: " <> target)
  }
}

fn replace(
  temporary: String,
  target: String,
  label: String,
) -> Result(Nil, String) {
  simplifile.rename(at: temporary, to: target)
  |> result.map_error(fn(error) {
    report_error(
      "could not atomically replace " <> label <> " report",
      target,
      simplifile.describe_error(error),
    )
  })
}

/// One project-report write failure, under its code and at its path.
///
/// A project report is written into the reader's own workspace, so a failure
/// here is theirs to fix — a read-only checkout, a directory they do not own,
/// a full disk. A bare errno names none of that, so every one of these carries
/// `GMU6003` and the path it happened at.
fn report_error(what: String, target: String, reason: String) -> String {
  "GMU6003: " <> what <> " " <> target <> ": " <> reason
}

fn cleanup(target: String) -> Nil {
  let _ = simplifile.delete_file(at: target)
  Nil
}
