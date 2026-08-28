// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import glance
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/catalog
import gleam_mutants/core/mutant.{type Mutant, Mutant}
import gleam_mutants/core/operator
import gleam_mutants/engine
import gleam_mutants/platform
import gleam_mutants/suggest/compile_lane
import gleam_mutants/suggest/diff_runner
import gleam_mutants/suggest/probe_result
import gleam_mutants/suggest/select

const source = "const limit = 10\n\npub fn over(value: Int) -> Bool { value > limit }\n"

fn outside_mutants() -> #(glance.Module, List(Mutant)) {
  let assert Ok(module) = glance.module(source)
  let assert Ok(discovered) =
    catalog.discover("src/demo.gleam", source, operator.all())
  let #(_, outside) = select.assign(module, discovered.mutants)
  #(module, outside)
}

fn first_job() -> compile_lane.Job {
  let #(module, outside) = outside_mutants()
  let assert [job, ..] =
    compile_lane.plan(module, outside, "erlang", "gleam-1.18.0", "workspace-a").jobs
  job
}

pub fn smartest_module_constant_mutants_use_the_compile_lane_test() {
  let #(module, outside) = outside_mutants()
  assert outside != []
  let planned =
    compile_lane.plan(module, outside, "erlang", "gleam-1.18.0", "workspace-a")

  assert planned.unsupported == []
  assert list.length(planned.jobs) == list.length(outside)
  assert list.all(planned.jobs, fn(job) {
    job.site == compile_lane.ModuleConstant("limit")
    && job.mutant.id != ""
    && job.cache_key != ""
  })
}

pub fn smartest_compile_lane_keys_include_target_and_compiler_test() {
  let #(module, outside) = outside_mutants()
  let assert [mutation, ..] = outside
  let assert [erlang] =
    compile_lane.plan(
      module,
      [mutation],
      "erlang",
      "gleam-1.18.0",
      "workspace-a",
    ).jobs
  let assert [javascript] =
    compile_lane.plan(
      module,
      [mutation],
      "javascript",
      "gleam-1.18.0",
      "workspace-a",
    ).jobs
  let assert [new_compiler] =
    compile_lane.plan(
      module,
      [mutation],
      "erlang",
      "gleam-1.19.0",
      "workspace-a",
    ).jobs
  let assert [new_workspace] =
    compile_lane.plan(
      module,
      [mutation],
      "erlang",
      "gleam-1.18.0",
      "workspace-b",
    ).jobs
  let assert [same] =
    compile_lane.plan(
      module,
      [mutation],
      "erlang",
      "gleam-1.18.0",
      "workspace-a",
    ).jobs

  assert erlang.cache_key != javascript.cache_key
  assert erlang.cache_key != new_compiler.cache_key
  assert erlang.cache_key != new_workspace.cache_key
  assert erlang.cache_key == same.cache_key
}

pub fn smartest_runner_exposes_constant_compile_jobs_without_unassigning_them_test() {
  let assert Ok(discovered) =
    catalog.discover("src/demo.gleam", source, operator.all())
  let catalog =
    engine.SourceCatalog(
      "src/demo.gleam",
      source,
      discovered.mutants,
      discovered.rejected,
    )
  let assert Ok(preview) =
    diff_runner.preview_plan(
      diff_runner.defaults("/workspace", ["src/demo.gleam"]),
      catalog,
      "/snapshot",
      "constant01",
      "gleam_mutants_pbt_constant01",
    )

  assert preview.unassigned == 0
  let assert [job] = preview.compile_jobs
  let assert [verdict] = preview.unsupported
  assert verdict.status == probe_result.Unsupported
  assert verdict.reason == diff_runner.compile_lane_reason
  assert verdict.mutant == job.mutant.id
}

pub fn smartest_compile_identity_is_stable_and_trimmed_test() {
  assert diff_runner.compiler_identity(platform.ProcessResult(
      0,
      "gleam 1.18.0\n",
      "",
      False,
    ))
    == Ok("gleam 1.18.0")
}

pub fn smartest_compile_identity_fails_closed_when_version_cannot_run_test() {
  let assert Error(timed_out) =
    diff_runner.compiler_identity(platform.ProcessResult(-1, "", "", True))
  assert timed_out == "GMU8007: identifying the Gleam compiler timed out"

  let assert Error(failed) =
    diff_runner.compiler_identity(platform.ProcessResult(
      127,
      "",
      "gleam: not found\n",
      False,
    ))
  assert failed
    == "GMU8007: could not identify the Gleam compiler: gleam: not found"
}

pub fn smartest_compile_lane_applies_exactly_one_verified_source_span_test() {
  let #(_, outside) = outside_mutants()
  let assert [mutation, ..] = outside
  let assert Ok(mutated) = compile_lane.apply_source(source, mutation)

  assert mutated
    == string.replace(source, mutation.original, mutation.replacement)
}

pub fn smartest_compile_lane_rejects_stale_source_before_rewriting_test() {
  let #(_, outside) = outside_mutants()
  let assert [mutation, ..] = outside
  let changed = "// changed elsewhere\n" <> source
  let assert Error(compile_lane.SourceChanged(expected, actual)) =
    compile_lane.apply_source(changed, mutation)

  assert expected == mutation.source_digest
  assert actual == bytes.sha256(changed)
}

pub fn smartest_compile_lane_rejects_a_changed_original_span_test() {
  let #(_, outside) = outside_mutants()
  let assert [mutation, ..] = outside
  let changed = string.replace(source, mutation.original, "99")
  let forged = Mutant(..mutation, source_digest: bytes.sha256(changed))
  let assert Error(compile_lane.OriginalChanged(expected, actual)) =
    compile_lane.apply_source(changed, forged)

  assert expected == mutation.original
  assert actual == "99"
}

pub fn smartest_compile_lane_classifies_process_results_without_oracle_claims_test() {
  assert compile_lane.classify_process(platform.ProcessResult(
      0,
      "compiled\n",
      "",
      False,
    ))
    == compile_lane.Compiled(False)
  assert compile_lane.classify_process(platform.ProcessResult(
      1,
      "",
      "type mismatch\n",
      False,
    ))
    == compile_lane.Rejected("type mismatch", False)
  assert compile_lane.classify_process(platform.ProcessResult(
      -1,
      "partial",
      "",
      True,
    ))
    == compile_lane.CompileTimedOut
}

pub fn smartest_compile_lane_cache_round_trips_success_and_rejection_test() {
  let job = first_job()
  let assert Some(compiled) =
    compile_lane.encode_cache(job, compile_lane.Compiled(False))
  assert compile_lane.decode_cache(job, compiled)
    == Ok(compile_lane.Compiled(True))

  let assert Some(rejected) =
    compile_lane.encode_cache(
      job,
      compile_lane.Rejected("type mismatch\nsecond line", False),
    )
  assert compile_lane.decode_cache(job, rejected)
    == Ok(compile_lane.Rejected("type mismatch\nsecond line", True))
}

pub fn smartest_compile_lane_cache_rejects_timeout_corruption_and_other_keys_test() {
  let job = first_job()
  assert compile_lane.encode_cache(job, compile_lane.CompileTimedOut) == None

  let assert Some(encoded) =
    compile_lane.encode_cache(job, compile_lane.Compiled(False))
  assert compile_lane.decode_cache(
      job,
      string.replace(encoded, "compiled", "rejected"),
    )
    == Error(Nil)

  let #(module, outside) = outside_mutants()
  let assert [other, ..] =
    compile_lane.plan(
      module,
      outside,
      "javascript",
      "gleam-1.18.0",
      "workspace-a",
    ).jobs
  assert compile_lane.decode_cache(other, encoded) == Error(Nil)
}

pub fn smartest_runner_executes_compile_jobs_against_their_catalog_source_test() {
  let assert Ok(discovered) =
    catalog.discover("src/demo.gleam", source, operator.all())
  let source_catalog =
    engine.SourceCatalog(
      "src/demo.gleam",
      source,
      discovered.mutants,
      discovered.rejected,
    )
  let assert Ok(preview) =
    diff_runner.preview_plan(
      diff_runner.defaults("/workspace", ["src/demo.gleam"]),
      source_catalog,
      "/snapshot",
      "constant02",
      "gleam_mutants_pbt_constant02",
    )
  let assert [expected_job] = preview.compile_jobs
  let assert Ok([evidence]) =
    diff_runner.execute_compile_jobs(
      [source_catalog],
      preview.compile_jobs,
      fn(catalog_source, job) {
        assert catalog_source == source
        assert job == expected_job
        Ok(compile_lane.Compiled(False))
      },
    )

  assert evidence.mutant == expected_job.mutant.id
  assert evidence.outcome == compile_lane.Compiled(False)
}

pub fn smartest_runner_fails_closed_when_a_compile_job_has_no_catalog_test() {
  let expected_job = first_job()
  let assert Error(error) =
    diff_runner.execute_compile_jobs([], [expected_job], fn(_, _) {
      panic as "a missing catalog must not execute a compile job"
    })

  assert error
    == "GMU8008: no source catalog for compile-lane mutant "
    <> expected_job.mutant.id
    <> " at src/demo.gleam"
}
