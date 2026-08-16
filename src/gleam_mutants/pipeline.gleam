// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam_mutants/core/catalog.{type RejectedMutant}
import gleam_mutants/core/mutant.{type Mutant}

pub type Discovered {
  Discovered
}

pub type Snapshotted {
  Snapshotted
}

pub type BaselinePassed {
  BaselinePassed
}

pub type Validated {
  Validated
}

pub type Instrumented {
  Instrumented
}

pub type Completed {
  Completed
}

pub type State {
  State(
    workspace: String,
    snapshot_root: String,
    files: List(String),
    baseline_ms: Int,
    mutants: List(Mutant),
    rejected: List(RejectedMutant),
  )
}

pub opaque type Pipeline(phase) {
  Pipeline(state: State)
}

pub fn discovered(
  workspace: String,
  files: List(String),
) -> Pipeline(Discovered) {
  Pipeline(State(workspace, "", files, 0, [], []))
}

pub fn snapshotted(
  pipeline: Pipeline(Discovered),
  root: String,
) -> Pipeline(Snapshotted) {
  Pipeline(State(..pipeline.state, snapshot_root: root))
}

pub fn baseline_passed(
  pipeline: Pipeline(Snapshotted),
  duration_ms: Int,
) -> Pipeline(BaselinePassed) {
  Pipeline(State(..pipeline.state, baseline_ms: duration_ms))
}

pub fn validated(
  pipeline: Pipeline(BaselinePassed),
  mutants: List(Mutant),
  rejected: List(RejectedMutant),
) -> Pipeline(Validated) {
  Pipeline(State(..pipeline.state, mutants: mutants, rejected: rejected))
}

pub fn instrumented(pipeline: Pipeline(Validated)) -> Pipeline(Instrumented) {
  Pipeline(pipeline.state)
}

pub fn completed(pipeline: Pipeline(Instrumented)) -> Pipeline(Completed) {
  Pipeline(pipeline.state)
}

pub fn state(pipeline: Pipeline(phase)) -> State {
  pipeline.state
}
