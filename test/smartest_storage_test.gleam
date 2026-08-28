// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile
import smartest/corpus
import smartest/corpus_json
import smartest/evidence
import smartest/storage

pub fn corpus_json_is_canonical_and_round_trips_every_contract_field_test() {
  let envelope = sample("round-trip")
  let encoded = corpus_json.encode(envelope)
  let assert Ok(decoded) = corpus_json.decode(encoded)
  assert decoded == envelope
  assert corpus_json.encode(decoded) == encoded
  assert string.starts_with(encoded, "{\"schema_version\":1,")
  assert string.contains(encoded, "\"draw_tape\":[1,2,3]")
}

pub fn nested_ai_oracle_provenance_round_trips_without_trust_escalation_test() {
  let envelope =
    corpus.Envelope(
      ..sample("ai-round-trip"),
      oracle: evidence.AiProposed(
        evidence.AiProposed(evidence.PropertyOracle("reverse twice")),
      ),
      state: evidence.ProvisionalEvidence,
    )
  let assert Ok(decoded) = envelope |> corpus_json.encode |> corpus_json.decode
  assert decoded == envelope
  assert !evidence.oracle_is_independent(decoded.oracle)
}

pub fn forged_trusted_differential_evidence_is_rejected_by_the_codec_test() {
  let forged =
    corpus.Envelope(
      ..sample("forged-trust"),
      oracle: evidence.DifferentialOnly,
      state: evidence.TrustedEvidence,
      lifecycle: corpus.Accepted,
      review: Some("looks plausible"),
      accepted_ms: Some(20),
    )
  let assert Error(message) = forged |> corpus_json.encode |> corpus_json.decode
  assert string.contains(message, "independent oracle")
}

pub fn accepted_artifacts_require_a_non_empty_review_test() {
  let missing =
    corpus.Envelope(
      ..sample("missing-review"),
      state: evidence.TrustedEvidence,
      lifecycle: corpus.Accepted,
      review: None,
      accepted_ms: Some(20),
    )
  let empty = corpus.Envelope(..missing, review: Some("  "))

  let assert Error(_) = corpus.validate(missing)
  let assert Error(_) = corpus.validate(empty)
}

pub fn corrupt_and_future_corpus_documents_are_refused_test() {
  let assert Error(_) = corpus_json.decode("not-json")
  let future =
    corpus_json.encode(sample("future"))
    |> string.replace("\"schema_version\":1", "\"schema_version\":999")
  let assert Error(message) = corpus_json.decode(future)
  assert string.contains(message, "schema")
}

pub fn an_inbox_finding_moves_to_corpus_only_after_acceptance_test() {
  let root = temporary_root("accept")
  let item = sample("accept-me")
  let assert Ok(_) = storage.put_inbox(root, item)
  assert is_file(storage.inbox_path(root, item.id))
  assert !is_file(storage.corpus_path(root, item.id))

  let assert Ok(accepted) =
    storage.accept(
      root,
      item.id,
      at_ms: 20,
      review_note: "property reviewed",
      human_oracle: None,
    )
  assert accepted.lifecycle == corpus.Accepted
  assert accepted.state == evidence.TrustedEvidence
  assert !is_file(storage.inbox_path(root, item.id))
  assert is_file(storage.corpus_path(root, item.id))
  cleanup(root)
}

pub fn storage_refuses_acceptance_without_a_review_note_test() {
  let root = temporary_root("empty-review")
  let item = sample("needs-review")
  let assert Ok(_) = storage.put_inbox(root, item)
  let assert Error(message) =
    storage.accept(
      root,
      item.id,
      at_ms: 20,
      review_note: "  ",
      human_oracle: None,
    )
  assert string.contains(message, "review")
  assert is_file(storage.inbox_path(root, item.id))
  assert !is_file(storage.corpus_path(root, item.id))
  cleanup(root)
}

pub fn accepting_an_unjudged_difference_does_not_silently_trust_it_test() {
  let root = temporary_root("unjudged")
  let item =
    corpus.new(
      id: "unjudged",
      test_id: evidence.test_id("demo", "api_test", "diff_test"),
      draw_tape: [4],
      generator_schema: "schema-v1",
      oracle: evidence.DifferentialOnly,
      targets: [evidence.Erlang],
      rendering: "4",
      created_ms: 1,
    )
  let assert Ok(_) = storage.put_inbox(root, item)
  let assert Ok(accepted) =
    storage.accept(
      root,
      item.id,
      at_ms: 2,
      review_note: "tracked, still needs an oracle",
      human_oracle: None,
    )
  assert accepted.state == evidence.UnjudgedDivergence
  assert !evidence.blocks_ci(accepted.state)
  cleanup(root)
}

pub fn reject_preserves_an_audit_artifact_but_removes_it_from_inbox_test() {
  let root = temporary_root("reject")
  let item = sample("reject-me")
  let assert Ok(_) = storage.put_inbox(root, item)
  let assert Ok(rejected) = storage.reject(root, item.id, "not a useful oracle")
  assert rejected.lifecycle == corpus.Rejected
  assert !is_file(storage.inbox_path(root, item.id))
  assert is_file(storage.rejected_path(root, item.id))
  cleanup(root)
}

pub fn artifact_ids_cannot_escape_the_smartest_directories_test() {
  let root = temporary_root("escape")
  let item = corpus.Envelope(..sample("safe"), id: "../../escape")
  let assert Error(message) = storage.put_inbox(root, item)
  assert string.contains(message, "artifact id")
  assert !is_file(path.join(root, "escape.json"))
  cleanup(root)
}

pub fn conflicting_artifacts_are_never_overwritten_test() {
  let root = temporary_root("conflict")
  let first = sample("same-id")
  let changed = corpus.Envelope(..first, rendering: "different")
  let assert Ok(_) = storage.put_inbox(root, first)
  let assert Error(message) = storage.put_inbox(root, changed)
  assert string.contains(message, "different artifact")
  let assert Ok(stored) = storage.load_inbox(root, first.id)
  assert stored.rendering == first.rendering
  cleanup(root)
}

pub fn rename_migration_updates_all_tracked_entries_explicitly_test() {
  let root = temporary_root("move")
  let old_id = evidence.test_id("demo", "old_test", "property_test")
  let new_id = evidence.test_id("demo", "new_test", "property_test")
  let item = corpus.Envelope(..sample("move-me"), test_id: old_id)
  let assert Ok(_) = storage.put_inbox(root, item)
  let assert Ok(_) =
    storage.accept(
      root,
      item.id,
      at_ms: 20,
      review_note: "reviewed",
      human_oracle: None,
    )
  let assert Ok(count) = storage.move_test_id(root, old_id, new_id)
  assert count == 1
  let assert Ok(moved) = storage.load_corpus(root, item.id)
  assert moved.test_id == new_id
  cleanup(root)
}

pub fn a_corrupt_tracked_artifact_is_visible_to_doctor_test() {
  let root = temporary_root("corrupt")
  let target = storage.corpus_path(root, "broken")
  let assert Ok(Nil) = simplifile.create_directory_all(path.parent(target))
  let assert Ok(Nil) = simplifile.write(target, "{broken")
  let assert Error(message) = storage.list_corpus(root)
  assert string.contains(message, "broken.json")
  cleanup(root)
}

pub fn lifecycle_directory_mismatches_are_visible_corruption_test() {
  let root = temporary_root("wrong-directory")
  let accepted =
    corpus.accept(
      sample("accepted-in-inbox"),
      at_ms: 20,
      review_note: "reviewed",
      human_oracle: None,
    )
  let target = storage.inbox_path(root, accepted.id)
  let assert Ok(Nil) = simplifile.create_directory_all(path.parent(target))
  let assert Ok(Nil) = simplifile.write(target, corpus_json.encode(accepted))

  let assert Error(message) = storage.list_inbox(root)
  assert string.contains(message, "lifecycle")
  cleanup(root)
}

pub fn prune_refuses_to_guess_without_a_current_generator_manifest_test() {
  let root = temporary_root("prune-no-manifest")
  let item = sample("keep-without-manifest")
  accept_item(root, item)

  let assert Error(reason) = storage.prune_stale_corpus(root)
  assert string.contains(reason, "generator manifest")
  assert is_file(storage.corpus_path(root, item.id))
  cleanup(root)
}

pub fn generator_migration_marks_schema_changes_and_missing_tests_stale_test() {
  let root = temporary_root("generator-migration")
  let fresh = sample("fresh")
  let changed =
    corpus.Envelope(
      ..sample("changed"),
      test_id: evidence.test_id("demo", "changed_test", "property_test"),
      generator_schema: "old-schema",
    )
  let missing =
    corpus.Envelope(
      ..sample("missing"),
      test_id: evidence.test_id("demo", "missing_test", "property_test"),
      generator_schema: "missing-schema",
    )
  accept_item(root, fresh)
  accept_item(root, changed)
  accept_item(root, missing)

  let assert Ok(_) =
    storage.write_generator_manifest(root, [
      storage.GeneratorBinding(fresh.test_id, fresh.generator_schema),
      storage.GeneratorBinding(changed.test_id, "new-schema"),
    ])
  let assert Ok(audit) = storage.migrate_generator_manifest(root)
  assert audit.fresh == 1
  assert audit.stale == 2

  let assert Ok(fresh_after) = storage.load_corpus(root, fresh.id)
  assert fresh_after.state == evidence.TrustedEvidence
  let assert Ok(changed_after) = storage.load_corpus(root, changed.id)
  let assert evidence.StaleEvidence(changed_reason) = changed_after.state
  assert string.contains(changed_reason, "old-schema")
  assert string.contains(changed_reason, "new-schema")
  let assert Ok(missing_after) = storage.load_corpus(root, missing.id)
  let assert evidence.StaleEvidence(missing_reason) = missing_after.state
  assert string.contains(missing_reason, "not present")

  let assert Ok(pruned) = storage.prune_stale_corpus(root)
  assert pruned == 2
  assert is_file(storage.corpus_path(root, fresh.id))
  assert !is_file(storage.corpus_path(root, changed.id))
  assert !is_file(storage.corpus_path(root, missing.id))
  cleanup(root)
}

pub fn generator_manifest_rejects_conflicting_schemas_for_one_test_id_test() {
  let root = temporary_root("manifest-conflict")
  let id = evidence.test_id("demo", "conflict_test", "property_test")
  let assert Error(reason) =
    storage.write_generator_manifest(root, [
      storage.GeneratorBinding(id, "schema-a"),
      storage.GeneratorBinding(id, "schema-b"),
    ])
  assert string.contains(reason, "conflicting generator schemas")
  cleanup(root)
}

fn sample(id: String) -> corpus.Envelope {
  corpus.new(
    id: id,
    test_id: evidence.test_id("demo", "number_test", "property_test"),
    draw_tape: [1, 2, 3],
    generator_schema: "smartest-gen-v1-123",
    oracle: evidence.PropertyOracle("round trip"),
    targets: [evidence.Erlang, evidence.Node],
    rendering: "[1, 2, 3]",
    created_ms: 10,
  )
}

fn temporary_root(label: String) -> String {
  path.join(
    platform.temporary_directory(),
    "smartest-storage-test-" <> label <> "-" <> platform.random_nonce(),
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

fn is_file(target: String) -> Bool {
  simplifile.is_file(target) |> result.unwrap(False)
}
