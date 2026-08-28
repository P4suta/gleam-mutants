// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile
import smartest/cli
import smartest/corpus
import smartest/evidence
import smartest/storage

pub fn no_arguments_selects_test_discovery_test() {
  assert cli.parse([]) == Ok(cli.DiscoverCommand)
}

pub fn command_tree_parses_review_corpus_and_mutant_namespaces_test() {
  assert cli.parse(["--root", "/workspace", "status"])
    == Ok(cli.StatusCommand(Some("/workspace")))
  assert cli.parse(["findings", "--root=/workspace"])
    == Ok(cli.FindingsCommand(Some("/workspace")))
  assert cli.parse([
      "accept",
      "finding-1",
      "--review",
      "checked against RFC-42",
      "--oracle",
      "RFC-42",
    ])
    == Ok(cli.AcceptCommand(
      None,
      "finding-1",
      "checked against RFC-42",
      Some("RFC-42"),
    ))
  assert cli.parse(["reject", "finding-2", "--reason", "not useful"])
    == Ok(cli.RejectCommand(None, "finding-2", "not useful"))
  assert cli.parse(["replay", "finding-3"])
    == Ok(cli.ReplayCommand(None, "finding-3"))
  assert cli.parse([
      "corpus",
      "move",
      "demo/old_test/property_test",
      "demo/new_test/property_test",
    ])
    == Ok(cli.CorpusMoveCommand(
      None,
      "demo/old_test/property_test",
      "demo/new_test/property_test",
    ))
  assert cli.parse(["mutants", "run", "--strict"])
    == Ok(cli.MutantsCommand(["run", "--strict"]))
}

pub fn accept_requires_review_and_unknown_commands_are_usage_errors_test() {
  let assert Error(review_error) = cli.parse(["accept", "finding-1"])
  assert string.contains(review_error, "--review")
  let assert Error(unknown_error) = cli.parse(["mystery"])
  assert string.contains(unknown_error, "unknown command")
}

pub fn status_and_findings_report_evidence_states_not_a_mutation_score_test() {
  let root = temporary_root("status")
  let item = sample("finding-status")
  let assert Ok(_) = storage.put_inbox(root, item)
  let assert Ok(status) =
    cli.execute(cli.StatusCommand(Some(root)), default_root: ".", now_ms: 20)
  assert string.contains(status.stdout, "Trusted: 0")
  assert string.contains(status.stdout, "Provisional: 1")
  assert !string.contains(status.stdout, "Mutation score")
  let assert Ok(findings) =
    cli.execute(cli.FindingsCommand(Some(root)), default_root: ".", now_ms: 20)
  assert string.contains(findings.stdout, "finding-status")
  assert string.contains(findings.stdout, "provisional")
  cleanup(root)
}

pub fn accept_and_reject_commands_use_the_reviewed_storage_transitions_test() {
  let root = temporary_root("review")
  let trusted = sample("finding-trusted")
  let rejected = sample("finding-rejected")
  let assert Ok(_) = storage.put_inbox(root, trusted)
  let assert Ok(_) = storage.put_inbox(root, rejected)
  let assert Ok(accepted_output) =
    cli.execute(
      cli.AcceptCommand(Some(root), trusted.id, "reviewed", None),
      default_root: ".",
      now_ms: 30,
    )
  assert accepted_output.exit_code == 0
  let assert Ok(accepted) = storage.load_corpus(root, trusted.id)
  assert accepted.state == evidence.TrustedEvidence

  let assert Ok(rejected_output) =
    cli.execute(
      cli.RejectCommand(Some(root), rejected.id, "bad witness"),
      default_root: ".",
      now_ms: 30,
    )
  assert rejected_output.exit_code == 0
  let assert Ok(rejected_item) = storage.load_rejected(root, rejected.id)
  assert rejected_item.state == evidence.RejectedEvidence("bad witness")
  cleanup(root)
}

pub fn doctor_fails_visibly_for_a_corrupt_corpus_test() {
  let root = temporary_root("doctor")
  let item = sample("doctor-good")
  let assert Ok(_) = storage.put_inbox(root, item)
  let assert Ok(healthy) =
    cli.execute(cli.DoctorCommand(Some(root)), default_root: ".", now_ms: 1)
  assert healthy.exit_code == 0
  assert string.contains(healthy.stdout, "corpus is healthy")
  let assert Ok(Nil) =
    simplifile.create_directory_all(
      path.parent(storage.corpus_path(root, "broken")),
    )
  let assert Ok(Nil) =
    simplifile.write(storage.corpus_path(root, "broken"), "{broken")
  let assert Ok(broken) =
    cli.execute(cli.DoctorCommand(Some(root)), default_root: ".", now_ms: 1)
  assert broken.exit_code == 1
  assert string.contains(broken.stderr, "broken.json")
  cleanup(root)
}

pub fn corpus_migrate_then_confirmed_prune_removes_only_stale_evidence_test() {
  let root = temporary_root("corpus-prune")
  let fresh = sample("cli-fresh")
  let stale =
    corpus.Envelope(
      ..sample("cli-stale"),
      test_id: evidence.test_id("demo", "stale_test", "property_test"),
      generator_schema: "old-schema",
    )
  accept_item(root, fresh)
  accept_item(root, stale)
  let assert Ok(_) =
    storage.write_generator_manifest(root, [
      storage.GeneratorBinding(fresh.test_id, fresh.generator_schema),
      storage.GeneratorBinding(stale.test_id, "new-schema"),
    ])

  let assert Ok(migrated) =
    cli.execute(
      cli.CorpusMigrateCommand(Some(root)),
      default_root: ".",
      now_ms: 1,
    )
  assert string.contains(migrated.stdout, "1 stale")
  assert simplifile.is_file(storage.corpus_path(root, stale.id)) == Ok(True)

  let assert Ok(unconfirmed) =
    cli.execute(
      cli.CorpusPruneCommand(Some(root), False),
      default_root: ".",
      now_ms: 1,
    )
  assert unconfirmed.exit_code == 2
  assert simplifile.is_file(storage.corpus_path(root, stale.id)) == Ok(True)

  let assert Ok(pruned) =
    cli.execute(
      cli.CorpusPruneCommand(Some(root), True),
      default_root: ".",
      now_ms: 1,
    )
  assert string.contains(pruned.stdout, "Pruned 1 stale")
  assert simplifile.is_file(storage.corpus_path(root, stale.id)) == Ok(False)
  assert simplifile.is_file(storage.corpus_path(root, fresh.id)) == Ok(True)
  cleanup(root)
}

fn sample(id: String) -> corpus.Envelope {
  corpus.new(
    id: id,
    test_id: evidence.test_id("demo", "number_test", "property_test"),
    draw_tape: [1],
    generator_schema: "smartest-gen-v1-123",
    oracle: evidence.PropertyOracle("number property"),
    targets: [evidence.Erlang],
    rendering: "1",
    created_ms: 10,
  )
}

fn temporary_root(label: String) -> String {
  path.join(
    platform.temporary_directory(),
    "smartest-cli-test-" <> label <> "-" <> platform.random_nonce(),
  )
}

fn cleanup(root: String) -> Nil {
  let _ = platform.delete_tree(root)
  Nil
}

fn accept_item(root: String, item: corpus.Envelope) -> Nil {
  let assert Ok(_) = storage.put_inbox(root, item)
  let assert Ok(_) =
    storage.accept(
      root,
      item.id,
      at_ms: 20,
      review_note: "reviewed",
      human_oracle: None,
    )
  Nil
}
