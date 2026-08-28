// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import smartest/watch

pub fn smartest_watch_uses_one_worker_while_the_editor_is_hot_test() {
  let state = watch.new(cpu_count: 16, at_ms: 1000)
  assert watch.worker_limit(state, at_ms: 10_999) == 1
  assert watch.worker_limit(state, at_ms: 11_000) == 4
  assert watch.worker_limit(watch.new(cpu_count: 1, at_ms: 0), at_ms: 20_000)
    == 1
  assert watch.worker_limit(watch.new(cpu_count: 128, at_ms: 0), at_ms: 20_000)
    == 4
}

pub fn smartest_watch_new_edit_cancels_running_stale_revision_by_250ms_test() {
  let state =
    watch.new(cpu_count: 8, at_ms: 0)
    |> watch.enqueue(watch.Exploration, "mutant-old")
  let assert #(state, [watch.Start(job_id, 0, watch.Exploration, "mutant-old")]) =
    watch.dispatch(state, at_ms: 20_000)

  let #(edited, actions) =
    watch.edited(state, at_ms: 20_100, foreground_key: "test-new")
  assert actions
    == [watch.RequestCancel(job_id, stale_revision: 0, deadline_ms: 20_350)]
  assert watch.revision(edited) == 1

  let #(before_deadline, early) =
    watch.force_due_cancellations(edited, at_ms: 20_349)
  assert early == []
  let #(_, forced) =
    watch.force_due_cancellations(before_deadline, at_ms: 20_350)
  assert forced == [watch.ForceCancel(job_id, stale_revision: 0)]
}

pub fn smartest_watch_drops_queued_work_from_the_previous_revision_test() {
  let state =
    watch.new(cpu_count: 2, at_ms: 0)
    |> watch.enqueue(watch.Exploration, "queued-old")
  let #(edited, actions) =
    watch.edited(state, at_ms: 5, foreground_key: "test-new")
  assert actions == []

  let #(_, starts) = watch.dispatch(edited, at_ms: 5)
  assert starts == [watch.Start(1, 1, watch.Foreground, "test-new")]
}

pub fn smartest_watch_always_dispatches_foreground_before_exploration_test() {
  let state =
    watch.new(cpu_count: 8, at_ms: 0)
    |> watch.enqueue(watch.Exploration, "mutant-a")
    |> watch.enqueue(watch.Foreground, "test-a")
    |> watch.enqueue(watch.Exploration, "mutant-b")
    |> watch.enqueue(watch.Foreground, "build-a")
  let #(_, starts) = watch.dispatch(state, at_ms: 20_000)

  assert starts
    == [
      watch.Start(1, 0, watch.Foreground, "test-a"),
      watch.Start(3, 0, watch.Foreground, "build-a"),
      watch.Start(0, 0, watch.Exploration, "mutant-a"),
      watch.Start(2, 0, watch.Exploration, "mutant-b"),
    ]
}

pub fn smartest_watch_completion_releases_a_worker_slot_test() {
  let state =
    watch.new(cpu_count: 2, at_ms: 0)
    |> watch.enqueue(watch.Foreground, "test-a")
    |> watch.enqueue(watch.Exploration, "mutant-a")
  let assert #(running, [watch.Start(first, _, _, _)]) =
    watch.dispatch(state, at_ms: 1)
  let #(still_running, none) = watch.dispatch(running, at_ms: 1)
  assert none == []

  let assert #(_, [watch.Start(_, _, watch.Exploration, "mutant-a")]) =
    still_running
    |> watch.finished(first)
    |> watch.dispatch(at_ms: 1)
}

pub fn smartest_watch_session_runs_the_first_revision_immediately_test() {
  let #(session, actions) =
    watch.start_session(
      cpu_count: 8,
      at_ms: 100,
      fingerprint: "revision-a",
      foreground_key: "gleam test",
    )

  assert watch.session_revision(session) == 0
  assert actions == [watch.Start(0, 0, watch.Foreground, "gleam test")]
}

pub fn smartest_watch_session_cancels_stale_work_before_starting_the_edit_test() {
  let #(session, _) =
    watch.start_session(
      cpu_count: 8,
      at_ms: 100,
      fingerprint: "revision-a",
      foreground_key: "gleam test",
    )

  let #(unchanged, no_actions) =
    watch.observe(session, at_ms: 150, fingerprint: "revision-a")
  assert no_actions == []

  let #(edited, cancelling) =
    watch.observe(unchanged, at_ms: 200, fingerprint: "revision-b")
  assert cancelling == [watch.RequestCancel(0, 0, deadline_ms: 450)]
  assert watch.session_revision(edited) == 1

  let #(before_deadline, early) = watch.tick(edited, at_ms: 449)
  assert early == []

  let #(_, due) = watch.tick(before_deadline, at_ms: 450)
  assert due
    == [
      watch.ForceCancel(0, 0),
      watch.Start(1, 1, watch.Foreground, "gleam test"),
    ]
}

pub fn smartest_watch_session_starts_latest_work_when_cancel_is_acknowledged_test() {
  let #(session, _) =
    watch.start_session(
      cpu_count: 2,
      at_ms: 0,
      fingerprint: "revision-a",
      foreground_key: "gleam test",
    )
  let #(session, _) =
    watch.observe(session, at_ms: 5, fingerprint: "revision-b")

  let #(_, actions) = watch.completed(session, job_id: 0, at_ms: 6)
  assert actions == [watch.Start(1, 1, watch.Foreground, "gleam test")]
}
