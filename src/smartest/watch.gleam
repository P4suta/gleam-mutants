//// Pure scheduling policy for the explicit foreground watch mode.
////
//// Filesystem observation and process control live in the runner shell. This
//// module only turns revision/time events into deterministic actions.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list

const idle_after_ms = 10_000

const cancellation_grace_ms = 250

/// Work that directly answers the current edit, or background exploration.
pub type Lane {
  Foreground
  Exploration
}

/// An instruction for the process-owning shell.
pub type Action {
  Start(job_id: Int, revision: Int, lane: Lane, key: String)
  RequestCancel(job_id: Int, stale_revision: Int, deadline_ms: Int)
  ForceCancel(job_id: Int, stale_revision: Int)
}

type JobState {
  Queued
  Running
  Cancelling(deadline_ms: Int)
}

type Job {
  Job(id: Int, revision: Int, lane: Lane, key: String, state: JobState)
}

/// Immutable scheduler state. Construction never starts a process or watcher.
pub opaque type Scheduler {
  Scheduler(
    revision: Int,
    last_edit_ms: Int,
    cpu_count: Int,
    next_job_id: Int,
    jobs: List(Job),
  )
}

/// A foreground watch session couples the scheduler to the last observed
/// workspace fingerprint. It is still a pure value: constructing or
/// advancing a session never reads files or starts a process.
pub opaque type Session {
  Session(scheduler: Scheduler, fingerprint: String, foreground_key: String)
}

pub fn new(cpu_count cpu_count: Int, at_ms at_ms: Int) -> Scheduler {
  Scheduler(
    revision: 0,
    last_edit_ms: at_ms,
    cpu_count: int.max(1, cpu_count),
    next_job_id: 0,
    jobs: [],
  )
}

pub fn revision(scheduler: Scheduler) -> Int {
  scheduler.revision
}

/// One worker while edits are hot, then half the CPUs capped at four.
pub fn worker_limit(scheduler: Scheduler, at_ms at_ms: Int) -> Int {
  case at_ms - scheduler.last_edit_ms < idle_after_ms {
    True -> 1
    False -> int.min(4, int.max(1, scheduler.cpu_count / 2))
  }
}

/// Adds work for the current revision without executing it.
pub fn enqueue(scheduler: Scheduler, lane: Lane, key: String) -> Scheduler {
  let job =
    Job(
      id: scheduler.next_job_id,
      revision: scheduler.revision,
      lane: lane,
      key: key,
      state: Queued,
    )
  Scheduler(
    ..scheduler,
    next_job_id: scheduler.next_job_id + 1,
    jobs: list.append(scheduler.jobs, [job]),
  )
}

/// Advances to a new source revision and queues its foreground validation.
///
/// Queued work from the old revision is discarded. Running work receives a
/// cancellation request whose hard deadline is 250ms after this edit.
pub fn edited(
  scheduler: Scheduler,
  at_ms at_ms: Int,
  foreground_key foreground_key: String,
) -> #(Scheduler, List(Action)) {
  let #(kept, actions) =
    scheduler.jobs
    |> list.fold(#([], []), fn(accumulator, job) {
      let #(kept, actions) = accumulator
      case job.state {
        Queued -> #(kept, actions)
        Running -> {
          let deadline = at_ms + cancellation_grace_ms
          #([Job(..job, state: Cancelling(deadline)), ..kept], [
            RequestCancel(
              job.id,
              stale_revision: job.revision,
              deadline_ms: deadline,
            ),
            ..actions
          ])
        }
        Cancelling(_) -> #([job, ..kept], actions)
      }
    })
  let next =
    Scheduler(
      ..scheduler,
      revision: scheduler.revision + 1,
      last_edit_ms: at_ms,
      jobs: list.reverse(kept),
    )
  #(next |> enqueue(Foreground, foreground_key), list.reverse(actions))
}

/// Starts as much current-revision work as the policy permits.
pub fn dispatch(
  scheduler: Scheduler,
  at_ms at_ms: Int,
) -> #(Scheduler, List(Action)) {
  let active =
    list.count(scheduler.jobs, fn(job) {
      case job.state {
        Running | Cancelling(_) -> True
        Queued -> False
      }
    })
  let capacity = int.max(0, worker_limit(scheduler, at_ms: at_ms) - active)
  let current =
    list.filter(scheduler.jobs, fn(job) {
      job.revision == scheduler.revision && job.state == Queued
    })
  let #(foreground, exploration) =
    list.partition(current, fn(job) { job.lane == Foreground })
  let selected =
    list.append(foreground, exploration)
    |> list.take(capacity)
  let selected_ids = list.map(selected, fn(job) { job.id })
  let jobs =
    list.map(scheduler.jobs, fn(job) {
      case list.contains(selected_ids, job.id) {
        True -> Job(..job, state: Running)
        False -> job
      }
    })
  let actions =
    list.map(selected, fn(job) {
      Start(job.id, job.revision, job.lane, job.key)
    })
  #(Scheduler(..scheduler, jobs: jobs), actions)
}

/// Converts cancellation requests at their 250ms deadline into hard stops.
/// Forced jobs are removed, releasing their worker slots deterministically.
pub fn force_due_cancellations(
  scheduler: Scheduler,
  at_ms at_ms: Int,
) -> #(Scheduler, List(Action)) {
  let #(kept, actions) =
    scheduler.jobs
    |> list.fold(#([], []), fn(accumulator, job) {
      let #(kept, actions) = accumulator
      case job.state {
        Cancelling(deadline) if at_ms >= deadline -> #(kept, [
          ForceCancel(job.id, stale_revision: job.revision),
          ..actions
        ])
        _ -> #([job, ..kept], actions)
      }
    })
  #(Scheduler(..scheduler, jobs: list.reverse(kept)), list.reverse(actions))
}

/// Records either normal completion or acknowledgement of cancellation.
/// Unknown/stale completion messages are harmless and idempotent.
pub fn finished(scheduler: Scheduler, job_id: Int) -> Scheduler {
  Scheduler(
    ..scheduler,
    jobs: list.filter(scheduler.jobs, fn(job) { job.id != job_id }),
  )
}

/// Starts revision zero and returns the process actions the shell must apply.
pub fn start_session(
  cpu_count cpu_count: Int,
  at_ms at_ms: Int,
  fingerprint fingerprint: String,
  foreground_key foreground_key: String,
) -> #(Session, List(Action)) {
  let scheduler =
    new(cpu_count: cpu_count, at_ms: at_ms)
    |> enqueue(Foreground, foreground_key)
  let #(scheduler, actions) = dispatch(scheduler, at_ms: at_ms)
  #(Session(scheduler, fingerprint, foreground_key), actions)
}

pub fn session_revision(session: Session) -> Int {
  revision(session.scheduler)
}

/// Observes a content fingerprint. Timestamp-only changes are ignored.
pub fn observe(
  session: Session,
  at_ms at_ms: Int,
  fingerprint fingerprint: String,
) -> #(Session, List(Action)) {
  case fingerprint == session.fingerprint {
    True -> tick(session, at_ms: at_ms)
    False -> {
      let #(scheduler, cancellation) =
        edited(
          session.scheduler,
          at_ms: at_ms,
          foreground_key: session.foreground_key,
        )
      advance(
        Session(..session, scheduler: scheduler, fingerprint: fingerprint),
        at_ms,
        cancellation,
      )
    }
  }
}

/// Advances cancellation deadlines and dispatches newly available work.
pub fn tick(session: Session, at_ms at_ms: Int) -> #(Session, List(Action)) {
  advance(session, at_ms, [])
}

/// Records process completion (including an acknowledged TERM) and starts the
/// highest-priority current-revision job that now fits.
pub fn completed(
  session: Session,
  job_id job_id: Int,
  at_ms at_ms: Int,
) -> #(Session, List(Action)) {
  advance(
    Session(..session, scheduler: finished(session.scheduler, job_id)),
    at_ms,
    [],
  )
}

fn advance(
  session: Session,
  at_ms: Int,
  preceding: List(Action),
) -> #(Session, List(Action)) {
  let #(scheduler, forced) =
    force_due_cancellations(session.scheduler, at_ms: at_ms)
  let #(scheduler, starts) = dispatch(scheduler, at_ms: at_ms)
  #(
    Session(..session, scheduler: scheduler),
    list.flatten([preceding, forced, starts]),
  )
}
