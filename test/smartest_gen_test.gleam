// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import smartest/gen

pub fn the_same_seed_produces_the_same_value_and_tape_test() {
  let generator = gen.tuple2(gen.int(), gen.list(gen.bool()))
  let assert Ok(gen.Generated(first, first_seed)) = gen.generate(generator, 42)
  let assert Ok(gen.Generated(again, again_seed)) = gen.generate(generator, 42)
  assert gen.tree_value(first) == gen.tree_value(again)
  assert gen.tree_tape(first) == gen.tree_tape(again)
  assert first_seed == again_seed
}

pub fn every_generated_value_round_trips_through_its_tape_test() {
  let generator = gen.list(gen.tuple2(gen.int_range(-7, 9), gen.bool()))
  let assert Ok(gen.Generated(tree, _)) = gen.generate(generator, 24_301)
  let assert Ok(replayed) = gen.replay(generator, gen.tree_tape(tree))
  assert gen.tree_value(replayed) == gen.tree_value(tree)
  assert gen.tree_tape(replayed) == gen.tree_tape(tree)
}

pub fn every_direct_shrink_candidate_has_a_portable_replay_tape_test() {
  let generator = gen.list(gen.int_range(-100, 100))
  let assert Ok(gen.Generated(tree, _)) = gen.generate(generator, 8)
  let children = gen.tree_children(tree)
  assert children != []
  assert list.all(children, fn(child) {
    case gen.replay(generator, gen.tree_tape(child)) {
      Ok(replayed) -> gen.tree_value(replayed) == gen.tree_value(child)
      Error(_) -> False
    }
  })
}

pub fn shrinking_is_deterministic_test() {
  let generator = gen.list(gen.int())
  let assert Ok(gen.Generated(first, _)) = gen.generate(generator, 91)
  let assert Ok(gen.Generated(again, _)) = gen.generate(generator, 91)
  assert list.map(gen.tree_children(first), gen.tree_tape)
    == list.map(gen.tree_children(again), gen.tree_tape)
}

pub fn malformed_and_trailing_tapes_are_never_silently_accepted_test() {
  assert gen.replay(gen.int_range(0, 2), [])
    == Error(gen.TapeExhausted(0, "int(0,2)"))
  assert gen.replay(gen.int_range(0, 2), [3])
    == Error(gen.InvalidChoice(0, 3, 3, "int(0,2)"))
  assert gen.replay(gen.int_range(0, 2), [1, 0])
    == Error(gen.TrailingChoices(1))
}

pub fn generator_schema_is_stable_and_mapping_names_are_distinct_test() {
  let first = gen.int() |> gen.named("domain-v1")
  let again = gen.int() |> gen.named("domain-v1")
  let changed = gen.int() |> gen.named("domain-v2")
  assert gen.schema_fingerprint(first) == gen.schema_fingerprint(again)
  assert gen.schema_fingerprint(first) != gen.schema_fingerprint(changed)
}

pub fn portable_draw_tape_has_a_cross_target_golden_value_test() {
  let generator = gen.tuple2(gen.int(), gen.list(gen.bool()))
  let assert Ok(gen.Generated(tree, next_seed)) = gen.generate(generator, 42)
  assert gen.tree_value(tree) == #(-4, [True, True, False])
  assert gen.tree_tape(tree) == [96, 3, 1, 1, 0]
  assert next_seed == 1_404_753_842
}

pub fn hinted_generators_replay_dictionary_values_through_the_common_tape_test() {
  let generator =
    gen.int_range(0, 2)
    |> gen.hinted([99, -7], schema: "boundary-literals-v1")
  let assert Ok(first_hint) = gen.replay(generator, [1])
  let assert Ok(second_hint) = gen.replay(generator, [2])
  assert gen.tree_value(first_hint) == 99
  assert gen.tree_value(second_hint) == -7
  assert gen.render(generator, gen.tree_value(first_hint)) == "99"
}

pub fn hint_dictionary_schema_changes_invalidate_old_tapes_visibly_test() {
  let first =
    gen.int()
    |> gen.hinted([0, 1], schema: "accepted-corpus-v1")
  let same =
    gen.int()
    |> gen.hinted([0, 1], schema: "accepted-corpus-v1")
  let changed =
    gen.int()
    |> gen.hinted([0, 1, 2], schema: "accepted-corpus-v2")
  assert gen.schema_fingerprint(first) == gen.schema_fingerprint(same)
  assert gen.schema_fingerprint(first) != gen.schema_fingerprint(changed)
}
