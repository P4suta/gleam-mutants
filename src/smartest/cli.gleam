//// Smartest command tree and testable command execution.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import smartest/corpus.{type Envelope}
import smartest/evidence
import smartest/storage

pub type Command {
  DiscoverCommand
  TestCommand(root: Option(String), arguments: List(String))
  WatchCommand(root: Option(String), arguments: List(String))
  StrengthenCommand(root: Option(String), arguments: List(String))
  CiCommand(root: Option(String), arguments: List(String))
  DeepCommand(root: Option(String), arguments: List(String))
  StatusCommand(root: Option(String))
  FindingsCommand(root: Option(String))
  ExplainCommand(root: Option(String), id: String)
  ReplayCommand(root: Option(String), id: String)
  AcceptCommand(
    root: Option(String),
    id: String,
    review: String,
    oracle: Option(String),
  )
  RejectCommand(root: Option(String), id: String, reason: String)
  CorpusMoveCommand(root: Option(String), old: String, new: String)
  CorpusMigrateCommand(root: Option(String))
  CorpusPruneCommand(root: Option(String), confirmed: Bool)
  DoctorCommand(root: Option(String))
  MutantsCommand(arguments: List(String))
  HelpCommand
  VersionCommand
}

pub type Output {
  Output(exit_code: Int, stdout: String, stderr: String)
}

pub fn parse(arguments: List(String)) -> Result(Command, String) {
  use extracted <- result.try(extract_root(arguments, None, []))
  let #(arguments, root) = extracted
  case arguments {
    [] -> Ok(DiscoverCommand)
    ["help"] | ["--help"] | ["-h"] -> Ok(HelpCommand)
    ["version"] | ["--version"] | ["-V"] -> Ok(VersionCommand)
    ["status"] -> Ok(StatusCommand(root))
    ["findings"] -> Ok(FindingsCommand(root))
    ["doctor"] -> Ok(DoctorCommand(root))
    ["explain", id] -> Ok(ExplainCommand(root, id))
    ["replay", id] -> Ok(ReplayCommand(root, id))
    ["accept", id, ..flags] -> parse_accept(root, id, flags, None, None)
    ["reject", id, ..flags] -> parse_reject(root, id, flags, None)
    ["corpus", "move", old, new] -> Ok(CorpusMoveCommand(root, old, new))
    ["corpus", "migrate"] -> Ok(CorpusMigrateCommand(root))
    ["corpus", "prune"] -> Ok(CorpusPruneCommand(root, False))
    ["corpus", "prune", "--yes"] -> Ok(CorpusPruneCommand(root, True))
    ["test", ..rest] -> Ok(TestCommand(root, rest))
    ["watch", ..rest] -> Ok(WatchCommand(root, rest))
    ["strengthen", ..rest] -> Ok(StrengthenCommand(root, rest))
    ["ci", ..rest] -> Ok(CiCommand(root, rest))
    ["deep", ..rest] -> Ok(DeepCommand(root, rest))
    ["mutants", ..rest] -> Ok(MutantsCommand(with_root(rest, root)))
    ["accept"] -> Error("accept requires a finding id and --review")
    ["reject"] -> Error("reject requires a finding id and --reason")
    ["replay"] -> Error("replay requires a finding id")
    ["corpus", ..] -> Error("expected corpus move, migrate, or prune")
    [unknown, ..] -> Error("unknown command " <> string.inspect(unknown))
  }
}

fn extract_root(
  arguments: List(String),
  root: Option(String),
  kept: List(String),
) -> Result(#(List(String), Option(String)), String) {
  case arguments {
    [] -> Ok(#(list.reverse(kept), root))
    ["--root", value, ..rest] -> extract_root(rest, Some(value), kept)
    ["--root"] -> Error("--root requires a directory")
    [argument, ..rest] ->
      case string.split(argument, "=") {
        ["--root", value] -> extract_root(rest, Some(value), kept)
        _ -> extract_root(rest, root, [argument, ..kept])
      }
  }
}

fn parse_accept(
  root: Option(String),
  id: String,
  flags: List(String),
  review: Option(String),
  oracle: Option(String),
) -> Result(Command, String) {
  case flags {
    [] ->
      case review {
        Some(review) -> Ok(AcceptCommand(root, id, review, oracle))
        None -> Error("accept requires --review <note>")
      }
    ["--review", note, ..rest] ->
      parse_accept(root, id, rest, Some(note), oracle)
    ["--oracle", description, ..rest] ->
      parse_accept(root, id, rest, review, Some(description))
    [flag, ..] -> Error("unknown accept option " <> string.inspect(flag))
  }
}

fn parse_reject(
  root: Option(String),
  id: String,
  flags: List(String),
  reason: Option(String),
) -> Result(Command, String) {
  case flags {
    [] ->
      case reason {
        Some(reason) -> Ok(RejectCommand(root, id, reason))
        None -> Error("reject requires --reason <note>")
      }
    ["--reason", note, ..rest] -> parse_reject(root, id, rest, Some(note))
    [flag, ..] -> Error("unknown reject option " <> string.inspect(flag))
  }
}

fn with_root(arguments: List(String), root: Option(String)) -> List(String) {
  case root {
    Some(root) -> ["--root", root, ..arguments]
    None -> arguments
  }
}

pub fn execute(
  command: Command,
  default_root default_root: String,
  now_ms now_ms: Int,
) -> Result(Output, String) {
  case command {
    DiscoverCommand -> Ok(Output(0, "", ""))
    StatusCommand(root) -> status(root_or(root, default_root))
    FindingsCommand(root) -> findings(root_or(root, default_root))
    AcceptCommand(root, id, review, oracle) -> {
      use accepted <- result.map(storage.accept(
        root_or(root, default_root),
        id,
        at_ms: now_ms,
        review_note: review,
        human_oracle: oracle,
      ))
      Output(
        0,
        "Accepted " <> accepted.id <> " as " <> state_name(accepted) <> ".\n",
        "",
      )
    }
    RejectCommand(root, id, reason) -> {
      use rejected <- result.map(storage.reject(
        root_or(root, default_root),
        id,
        reason,
      ))
      Output(0, "Rejected " <> rejected.id <> ".\n", "")
    }
    CorpusMoveCommand(root, old, new) -> {
      use old <- result.try(evidence.test_id_from_string(old))
      use new <- result.try(evidence.test_id_from_string(new))
      use count <- result.map(storage.move_test_id(
        root_or(root, default_root),
        old,
        new,
      ))
      Output(
        0,
        "Migrated " <> int.to_string(count) <> " corpus artifact(s).\n",
        "",
      )
    }
    CorpusMigrateCommand(root) -> {
      use audit <- result.map(
        storage.migrate_generator_manifest(root_or(root, default_root)),
      )
      Output(
        0,
        "Generator manifest: "
          <> int.to_string(audit.fresh)
          <> " fresh, "
          <> int.to_string(audit.stale)
          <> " stale artifact(s).\n",
        "",
      )
    }
    DoctorCommand(root) -> doctor(root_or(root, default_root))
    CorpusPruneCommand(_, False) ->
      Ok(Output(2, "", "corpus prune is destructive and requires --yes\n"))
    CorpusPruneCommand(root, True) -> {
      use count <- result.map(
        storage.prune_stale_corpus(root_or(root, default_root)),
      )
      Output(
        0,
        "Pruned " <> int.to_string(count) <> " stale corpus artifact(s).\n",
        "",
      )
    }
    ExplainCommand(root, id) -> explain(root_or(root, default_root), id)
    ReplayCommand(_, id) ->
      Ok(Output(0, "Replay requested for " <> id <> ".\n", ""))
    TestCommand(_, _)
    | WatchCommand(_, _)
    | StrengthenCommand(_, _)
    | CiCommand(_, _)
    | DeepCommand(_, _)
    | MutantsCommand(_) -> Error("command requires the process shell")
    HelpCommand -> Ok(Output(0, help_text(), ""))
    VersionCommand -> Ok(Output(0, "smartest 0.1.0\n", ""))
  }
}

fn status(root: String) -> Result(Output, String) {
  use inbox <- result.try(storage.list_inbox(root))
  use accepted <- result.try(storage.list_corpus(root))
  use rejected <- result.map(storage.list_rejected(root))
  let all = list.flatten([inbox, accepted, rejected])
  let trusted =
    list.count(all, fn(item) { item.state == evidence.TrustedEvidence })
  let provisional =
    list.count(all, fn(item) { item.state == evidence.ProvisionalEvidence })
  let unjudged =
    list.count(all, fn(item) { item.state == evidence.UnjudgedDivergence })
  let stale =
    list.count(all, fn(item) {
      case item.state {
        evidence.StaleEvidence(_) -> True
        _ -> False
      }
    })
  Output(
    0,
    "Trusted: "
      <> int.to_string(trusted)
      <> "\nProvisional: "
      <> int.to_string(provisional)
      <> "\nUnjudged: "
      <> int.to_string(unjudged)
      <> "\nStale: "
      <> int.to_string(stale)
      <> "\nInbox: "
      <> int.to_string(list.length(inbox))
      <> "\n",
    "",
  )
}

fn findings(root: String) -> Result(Output, String) {
  use inbox <- result.try(storage.list_inbox(root))
  use accepted <- result.try(storage.list_corpus(root))
  use rejected <- result.map(storage.list_rejected(root))
  let all = list.flatten([inbox, accepted, rejected])
  let text = case all {
    [] -> "No findings.\n"
    _ ->
      all
      |> list.map(fn(item) {
        item.id
        <> " "
        <> state_name(item)
        <> " "
        <> evidence.test_id_to_string(item.test_id)
        <> "\n"
      })
      |> string.concat
  }
  Output(0, text, "")
}

fn explain(root: String, id: String) -> Result(Output, String) {
  let loaded = case storage.load_inbox(root, id) {
    Ok(item) -> Ok(item)
    Error(_) -> storage.load_corpus(root, id)
  }
  use item <- result.map(loaded)
  Output(
    0,
    item.id
      <> "\nTest: "
      <> evidence.test_id_to_string(item.test_id)
      <> "\nState: "
      <> state_name(item)
      <> "\nWitness: "
      <> item.rendering
      <> "\n",
    "",
  )
}

fn doctor(root: String) -> Result(Output, String) {
  case
    storage.list_inbox(root),
    storage.list_corpus(root),
    storage.list_rejected(root)
  {
    Ok(_), Ok(_), Ok(_) -> Ok(Output(0, "Smartest corpus is healthy.\n", ""))
    Error(reason), _, _ | _, Error(reason), _ | _, _, Error(reason) ->
      Ok(Output(1, "", reason <> "\n"))
  }
}

fn state_name(item: Envelope) -> String {
  case item.state {
    evidence.ProvisionalEvidence -> "provisional"
    evidence.TrustedEvidence -> "trusted"
    evidence.UnjudgedDivergence -> "unjudged"
    evidence.StaleEvidence(_) -> "stale"
    evidence.UnsafeEvidence(_) -> "unsafe"
    evidence.UnsupportedEvidence(_) -> "unsupported"
    evidence.RejectedEvidence(_) -> "rejected"
  }
}

fn root_or(root: Option(String), default: String) -> String {
  case root {
    Some(root) -> root
    None -> default
  }
}

pub fn help_text() -> String {
  "Smartest — adaptive verification for Gleam\n\n"
  <> "Commands: test, watch, strengthen, ci, deep, status, findings, explain, replay,\n"
  <> "          accept, reject, corpus move|migrate|prune, doctor, mutants\n"
}
