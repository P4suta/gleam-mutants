// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/cache
import gleam_mutants/config.{
  type CacheMode, type Config, type DiagnosticsMode, CacheAuto, CacheOff,
  CacheReadWrite, Config, DiagnosticsAll, DiagnosticsErrors, DiagnosticsNone,
}
import gleam_mutants/core/bytes
import gleam_mutants/core/catalog.{
  type RejectedCandidate, type RejectedMutant, RejectedMutant,
}
import gleam_mutants/core/exit_policy
import gleam_mutants/core/interval_tree
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator.{type Operator}
import gleam_mutants/core/outcome.{
  type Outcome, type Runtime, type RuntimeOutcome, Bun, Deno, Erlang, Killed,
  Node, RuntimeOutcome, Survived, TestError, TimedOut,
}
import gleam_mutants/core/path
import gleam_mutants/core/plan
import gleam_mutants/core/score
import gleam_mutants/pipeline
import gleam_mutants/platform
import gleam_mutants/project_report
import gleam_mutants/report.{
  type MutantResult, type RunReport, MutantResult, PolicySummary, RunReport,
  SelectionSummary,
}
import gleam_mutants/runtime.{type RuntimeModule}
import gleam_mutants/snapshot.{type Snapshot}
import gleam_mutants/stryker_html
import gleam_mutants/stryker_report.{SourceFile}
import gleam_mutants/workspace_lock
import simplifile
import tomlet

/// Everything one run of the engine was asked for.
///
/// Every `Option` field overrides the workspace's own configuration when it is
/// `Some`: `report_formats` replaces `report.formats` and `report_history`
/// replaces `report.history`, so a caller that only wants a verdict — `apply
/// --verify` is the one in this package — can run without writing a project
/// report or storing a run the reader never asked for.
pub type Options {
  Options(
    root: Option(String),
    matrix: Bool,
    changed: Option(String),
    includes: List(String),
    operators: Option(List(Operator)),
    strict: Option(Bool),
    jobs: Option(Int),
    timeout_ms: Option(Int),
    test_command: Option(List(String)),
    mutant_prefix: Option(String),
    report_formats: Option(List(String)),
    report_history: Option(Bool),
    json: Bool,
    explain: Bool,
    quiet: Bool,
    verbosity: Int,
    log_format: String,
    help_requested: Bool,
    version_requested: Bool,
    suggest: Bool,
  )
}

pub type RunOutput {
  RunOutput(
    report: RunReport,
    report_path: String,
    stryker_json_path: String,
    html_report_path: String,
    exit_code: Int,
  )
}

pub type ListOutput {
  ListOutput(
    mutants: List(Mutant),
    rejected: List(RejectedMutant),
    validated: Bool,
  )
}

type ValidationError {
  CandidateInvalid(String)
  ValidationInfrastructure(String)
}

/// A source file paired with the mutants and rejected candidates found in it.
pub type SourceCatalog {
  SourceCatalog(
    path: String,
    source: String,
    mutants: List(Mutant),
    rejected: List(RejectedCandidate),
  )
}

type Preflight {
  Preflight(files: List(String), catalogs: List(SourceCatalog), candidates: Int)
}

type ExecutionContext {
  ExecutionContext(
    mutant: Mutant,
    worker: Snapshot,
    outcomes: List(RuntimeOutcome),
  )
}

type PendingRun {
  PendingRun(mutant: Mutant, runtime: Runtime, request: platform.ProcessRequest)
}

type Prepared {
  Prepared(
    config: Config,
    snapshot: Snapshot,
    catalogs: List(SourceCatalog),
    mutation_plan: plan.MutationPlan,
    rejected: List(RejectedMutant),
    runtimes: List(Runtime),
    runtime_module: RuntimeModule,
    timeout_ms: Int,
    phase: pipeline.Pipeline(pipeline.Instrumented),
  )
}

pub fn default_options() -> Options {
  Options(
    root: None,
    matrix: False,
    changed: None,
    includes: [],
    operators: None,
    strict: None,
    jobs: None,
    timeout_ms: None,
    test_command: None,
    mutant_prefix: None,
    report_formats: None,
    report_history: None,
    json: False,
    explain: False,
    quiet: False,
    verbosity: 0,
    log_format: "text",
    help_requested: False,
    version_requested: False,
    suggest: False,
  )
}

pub fn run(workspace: String, options: Options) -> Result(RunOutput, String) {
  use lock <- result.try(workspace_lock.acquire(workspace))
  let run_result = run_locked(workspace, options, workspace_lock.run_id(lock))
  case run_result, workspace_lock.release(lock) {
    Ok(output), Ok(Nil) -> Ok(output)
    Error(error), Ok(Nil) -> Error(error)
    Ok(_), Error(error) ->
      Error("GMU7003: workspace lock release failed: " <> error)
    Error(error), Error(release_error) ->
      Error(error <> "; workspace lock release failed: " <> release_error)
  }
}

fn run_locked(
  workspace: String,
  options: Options,
  run_id: String,
) -> Result(RunOutput, String) {
  use source <- result.try(read_project_config(workspace))
  use decoded <- result.try(
    config.decode(source, platform.cpu_count())
    |> result.map_error(config.describe_error),
  )
  let configured = apply_options(decoded, options)
  use _ <- result.try(validate_effective_config(configured))
  use _ <- result.try(validate_report_configuration(workspace, configured))
  use changed_paths <- result.try(resolve_changed(workspace, options.changed))
  use snapshot <- result.try(
    snapshot.create_excluding(workspace, [
      configured.report.directory,
    ]),
  )
  let result = case preflight(snapshot, configured, changed_paths) {
    Error(error) -> Error(error)
    Ok(Preflight([], _, _)) ->
      case changed_paths {
        Some([]) ->
          complete_empty(
            snapshot,
            workspace,
            configured,
            options,
            run_id,
            [],
            True,
            "no changed Gleam files",
            0,
          )
        _ -> Error("GMU4001: selection did not match any Gleam source files")
      }
    Ok(Preflight(_, catalogs, 0)) ->
      complete_empty(
        snapshot,
        workspace,
        configured,
        options,
        run_id,
        catalogs,
        False,
        "selected files contain no applicable mutation sites",
        case configured.require_mutants {
          True -> 1
          False -> 0
        },
      )
    Ok(_) ->
      execute(
        snapshot,
        workspace,
        source,
        configured,
        options,
        run_id,
        changed_paths,
      )
  }
  case result, snapshot.dispose(snapshot) {
    Ok(output), Ok(Nil) -> Ok(output)
    Error(error), Ok(Nil) -> Error(error)
    Ok(_), Error(error) -> Error("GMU7002: snapshot cleanup failed: " <> error)
    Error(error), Error(cleanup_error) ->
      Error(error <> "; snapshot cleanup failed: " <> cleanup_error)
  }
}

fn preflight(
  snapshot: Snapshot,
  config: Config,
  changed_paths: Option(List(String)),
) -> Result(Preflight, String) {
  let files = snapshot.source_files(snapshot, config.includes, config.excludes)
  let files = case changed_paths {
    None -> files
    Some(changed) ->
      list.filter(files, fn(file) { list.contains(changed, file) })
  }
  use catalogs <- result.try(discover_catalogs(
    snapshot.root(snapshot),
    files,
    config.operators,
  ))
  Ok(Preflight(
    files,
    catalogs,
    catalogs
      |> list.flat_map(fn(catalog) { catalog.mutants })
      |> list.length,
  ))
}

pub fn list_mutants(
  workspace: String,
  options: Options,
  validate: Bool,
) -> Result(ListOutput, String) {
  use source <- result.try(read_project_config(workspace))
  use decoded <- result.try(
    config.decode(source, platform.cpu_count())
    |> result.map_error(config.describe_error),
  )
  let configured = apply_options(decoded, options)
  use _ <- result.try(validate_effective_config(configured))
  use _ <- result.try(validate_report_configuration(workspace, configured))
  use changed_paths <- result.try(resolve_changed(workspace, options.changed))
  use snapshot <- result.try(
    snapshot.create_excluding(workspace, [
      configured.report.directory,
    ]),
  )
  let result =
    list_snapshot(
      snapshot,
      source,
      configured,
      options,
      changed_paths,
      validate,
    )
  case result, snapshot.dispose(snapshot) {
    Ok(output), Ok(Nil) -> Ok(output)
    Error(error), Ok(Nil) -> Error(error)
    Ok(_), Error(error) -> Error("GMU7002: snapshot cleanup failed: " <> error)
    Error(error), Error(cleanup_error) ->
      Error(error <> "; snapshot cleanup failed: " <> cleanup_error)
  }
}

fn list_snapshot(
  snapshot: Snapshot,
  gleam_toml: String,
  config: Config,
  options: Options,
  changed_paths: Option(List(String)),
  validate: Bool,
) -> Result(ListOutput, String) {
  let files = snapshot.source_files(snapshot, config.includes, config.excludes)
  let files = case changed_paths {
    None -> files
    Some(changed) ->
      list.filter(files, fn(file) { list.contains(changed, file) })
  }
  use catalogs <- result.try(discover_catalogs(
    snapshot.root(snapshot),
    files,
    config.operators,
  ))
  let candidates = catalogs |> list.flat_map(fn(catalog) { catalog.mutants })
  let changed_selection = case options.changed {
    Some(_) -> True
    None -> False
  }
  case validate {
    False -> {
      use mutation_plan <- result.try(plan.build(
        candidates,
        changed_selection,
        options.mutant_prefix,
      ))
      Ok(ListOutput(plan.mutants(mutation_plan), [], False))
    }
    True -> {
      let runtimes = detect_runtimes(gleam_toml, config, options.matrix)
      use runtime_module <- result.try(runtime.generate(
        snapshot.root(snapshot),
        snapshot.digest(snapshot),
      ))
      use _ <- result.try(build_targets(snapshot.root(snapshot), runtimes))
      use validation <- result.try(delta_validate(
        snapshot,
        catalogs,
        candidates,
        runtimes,
        runtime_module,
      ))
      let #(valid, rejected) = validation
      use mutation_plan <- result.try(plan.build(
        valid,
        changed_selection,
        options.mutant_prefix,
      ))
      Ok(ListOutput(plan.mutants(mutation_plan), rejected, True))
    }
  }
}

fn execute(
  snapshot: Snapshot,
  workspace: String,
  gleam_toml: String,
  config: Config,
  options: Options,
  run_id: String,
  changed_paths: Option(List(String)),
) -> Result(RunOutput, String) {
  let started = platform.now_milliseconds()
  let monotonic_started = platform.monotonic_milliseconds()
  use prepared <- result.try(prepare(
    snapshot,
    workspace,
    gleam_toml,
    config,
    options,
    changed_paths,
  ))
  use results <- result.try(run_mutants(prepared))
  let aggregated = list.map(results, fn(item) { item.aggregate })
  let mutation_score = score.calculate(aggregated)
  let policy =
    exit_policy.Context(
      ci: platform.is_ci(),
      tty: platform.is_tty(),
      strict: prepared.config.strict,
      minimum_score: prepared.config.minimum_score,
    )
  let exit_code = exit_policy.code(mutation_score, policy)
  let run_report =
    RunReport(
      run_id: run_id,
      started_ms: started,
      duration_ms: platform.monotonic_milliseconds() - monotonic_started,
      workspace_digest: snapshot.digest(snapshot),
      matrix: options.matrix,
      selection: SelectionSummary(
        mode: plan.mode(prepared.mutation_plan),
        files_selected: list.length(prepared.catalogs),
        candidates: list.length(plan.mutants(prepared.mutation_plan))
          + list.length(prepared.rejected),
        executed: list.length(results),
        compile_errors: list.length(prepared.rejected),
        skipped: False,
        reason: None,
      ),
      policy: PolicySummary(
        strict: exit_policy.strict(policy),
        minimum_score: prepared.config.minimum_score,
        require_mutants: prepared.config.require_mutants,
        failure: case exit_code {
          1 -> Some("minimum-score")
          _ -> None
        },
      ),
      results: results,
      rejected: prepared.rejected,
      score: mutation_score,
    )
  let source_files =
    list.map(prepared.catalogs, fn(catalog) {
      SourceFile(catalog.path, catalog.source)
    })
  let formats = prepared.config.report.formats
  use projection <- result.try(case formats {
    [] -> Ok(#("", ""))
    _ -> {
      use stryker_json <- result.try(stryker_report.to_json(
        run_report,
        source_files,
        prepared.config.report.high,
        prepared.config.report.low,
      ))
      use html <- result.try(case list.contains(formats, "html") {
        True -> stryker_html.render(stryker_json)
        False -> Ok("")
      })
      Ok(#(stryker_json, html))
    }
  })
  let json_report = case projection.0 {
    "" -> ""
    value -> value <> "\n"
  }
  use project_reports <- result.try(project_report.write_formats(
    workspace,
    prepared.config.report.directory,
    formats,
    json_report,
    projection.1,
  ))
  use report_path <- result.try(case prepared.config.report.history {
    True -> report.save(run_report, workspace)
    False -> Ok("")
  })
  case options.json {
    True -> Nil
    False -> report.emit_github(run_report)
  }
  let phase = pipeline.completed(prepared.phase)
  let _ = pipeline.state(phase)
  Ok(RunOutput(
    run_report,
    report_path,
    project_reports.json_path,
    project_reports.html_path,
    exit_code,
  ))
}

fn complete_empty(
  snapshot: Snapshot,
  workspace: String,
  config: Config,
  options: Options,
  run_id: String,
  catalogs: List(SourceCatalog),
  skipped: Bool,
  reason: String,
  exit_code: Int,
) -> Result(RunOutput, String) {
  let started = platform.now_milliseconds()
  let policy =
    exit_policy.Context(
      ci: platform.is_ci(),
      tty: platform.is_tty(),
      strict: config.strict,
      minimum_score: config.minimum_score,
    )
  let run_report =
    RunReport(
      run_id: run_id,
      started_ms: started,
      duration_ms: 0,
      workspace_digest: snapshot.digest(snapshot),
      matrix: options.matrix,
      selection: SelectionSummary(
        mode: selection_mode(options),
        files_selected: list.length(catalogs),
        candidates: 0,
        executed: 0,
        compile_errors: 0,
        skipped: skipped,
        reason: Some(reason),
      ),
      policy: PolicySummary(
        strict: exit_policy.strict(policy),
        minimum_score: config.minimum_score,
        require_mutants: config.require_mutants,
        failure: case exit_code {
          1 -> Some("require-mutants")
          _ -> None
        },
      ),
      results: [],
      rejected: [],
      score: score.calculate([]),
    )
  let source_files =
    list.map(catalogs, fn(catalog) { SourceFile(catalog.path, catalog.source) })
  let formats = config.report.formats
  use projection <- result.try(case formats {
    [] -> Ok(#("", ""))
    _ -> {
      use stryker_json <- result.try(stryker_report.to_json(
        run_report,
        source_files,
        config.report.high,
        config.report.low,
      ))
      use html <- result.try(case list.contains(formats, "html") {
        True -> stryker_html.render(stryker_json)
        False -> Ok("")
      })
      Ok(#(stryker_json, html))
    }
  })
  let json_report = case projection.0 {
    "" -> ""
    value -> value <> "\n"
  }
  use project_reports <- result.try(project_report.write_formats(
    workspace,
    config.report.directory,
    formats,
    json_report,
    projection.1,
  ))
  use report_path <- result.try(case config.report.history {
    True -> report.save(run_report, workspace)
    False -> Ok("")
  })
  Ok(RunOutput(
    run_report,
    report_path,
    project_reports.json_path,
    project_reports.html_path,
    exit_code,
  ))
}

fn selection_mode(options: Options) -> String {
  case options.mutant_prefix, options.changed {
    Some(_), _ -> "mutant"
    _, Some(_) -> "changed"
    _, _ -> "all"
  }
}

fn validate_report_configuration(
  workspace: String,
  config: Config,
) -> Result(Nil, String) {
  case config.report_overlaps_mutation_sources(config) {
    True ->
      Error(
        "report.directory overlaps mutation target sources: "
        <> config.report.directory,
      )
    False ->
      project_report.validate_destination(workspace, config.report.directory)
  }
}

fn prepare(
  snapshot: Snapshot,
  workspace: String,
  gleam_toml: String,
  config: Config,
  options: Options,
  changed_paths: Option(List(String)),
) -> Result(Prepared, String) {
  let files = snapshot.source_files(snapshot, config.includes, config.excludes)
  let files = case changed_paths {
    None -> files
    Some(changed) ->
      list.filter(files, fn(path) { list.contains(changed, path) })
  }
  let phase0 = pipeline.discovered(workspace, files)
  let phase1 = pipeline.snapshotted(phase0, snapshot.root(snapshot))
  let runtimes = detect_runtimes(gleam_toml, config, options.matrix)
  use _ <- result.try(configure_deno_permissions(
    snapshot.root(snapshot),
    runtimes,
  ))
  use baseline <- result.try(run_baseline(
    snapshot.root(snapshot),
    runtimes,
    config,
  ))
  let phase2 = pipeline.baseline_passed(phase1, baseline.0)
  use catalogs <- result.try(discover_catalogs(
    snapshot.root(snapshot),
    files,
    config.operators,
  ))
  let candidates = catalogs |> list.flat_map(fn(catalog) { catalog.mutants })
  use runtime_module <- result.try(runtime.generate(
    snapshot.root(snapshot),
    snapshot.digest(snapshot),
  ))
  use validation <- result.try(delta_validate(
    snapshot,
    catalogs,
    candidates,
    runtimes,
    runtime_module,
  ))
  let #(valid, rejected) = validation
  use _ <- result.try(case candidates != [] && valid == [] {
    True -> {
      let diagnostic =
        rejected
        |> list.first
        |> result.map(fn(rejected) { truncate(rejected.diagnostic) })
        |> result.unwrap("")
      Error(
        "GMU4003: all mutation candidates failed compiler validation; engine and compiler are incompatible"
        <> case diagnostic {
          "" -> ""
          value -> ":\n" <> value
        },
      )
    }
    False -> Ok(Nil)
  })
  let changed_selection = case options.changed {
    Some(_) -> True
    None -> False
  }
  use mutation_plan <- result.try(plan.build(
    valid,
    changed_selection,
    options.mutant_prefix,
  ))
  let planned_mutants = plan.mutants(mutation_plan)
  let phase3 = pipeline.validated(phase2, planned_mutants, rejected)
  use _ <- result.try(instrument(
    snapshot.root(snapshot),
    catalogs,
    planned_mutants,
    runtime.name(runtime_module),
  ))
  use _ <- result.try(build_targets(snapshot.root(snapshot), runtimes))
  use _ <- result.try(run_instrumented_baseline(
    snapshot.root(snapshot),
    runtimes,
    config,
    baseline.1,
  ))
  let phase4 = pipeline.instrumented(phase3)
  Ok(Prepared(
    config,
    snapshot,
    catalogs,
    mutation_plan,
    rejected,
    runtimes,
    runtime_module,
    baseline.1,
    phase4,
  ))
}

fn read_project_config(workspace: String) -> Result(String, String) {
  simplifile.read(path.join(workspace, "gleam.toml"))
  |> result.map_error(fn(error) {
    "could not read gleam.toml: " <> simplifile.describe_error(error)
  })
}

fn apply_options(config: Config, options: Options) -> Config {
  Config(
    ..config,
    includes: case options.includes {
      [] -> config.includes
      values -> values
    },
    operators: case options.operators {
      Some(values) -> values
      None -> config.operators
    },
    strict: case options.strict {
      Some(value) -> Some(value)
      None -> config.strict
    },
    jobs: case options.jobs {
      Some(value) -> value
      None -> config.jobs
    },
    timeout_ms: case options.timeout_ms {
      Some(value) -> Some(value)
      None -> config.timeout_ms
    },
    test_command: case options.test_command {
      Some(value) -> value
      None -> config.test_command
    },
    report: config.ReportConfig(
      ..config.report,
      formats: case options.report_formats {
        Some(formats) -> formats
        None -> config.report.formats
      },
      history: case options.report_history {
        Some(value) -> value
        None -> config.report.history
      },
    ),
  )
}

fn validate_effective_config(config: Config) -> Result(Nil, String) {
  case
    config.test_command != ["gleam", "test"]
    && config.cache_mode != CacheAuto
    && config.cache_mode != CacheOff
    && config.cache_key == None
  {
    True ->
      Error(
        "GMU3004: cache.key is required when persistent cache is enabled for a custom test command",
      )
    False -> Ok(Nil)
  }
}

/// The workspace-relative `.gleam` paths that changed since a git reference.
///
/// `None` is answered for `None`: nothing was asked about, so nothing narrows
/// the selection. Otherwise every added, copied, modified or renamed path
/// between the merge base and `HEAD` is collected, together with the staged,
/// unstaged and untracked changes on top of it, so that a working tree is
/// judged as it stands rather than as it was committed.
///
/// Private: `--changed` reaches every caller through `run` and `list_mutants`,
/// which own the selection this narrows, and `suggest` asks them for it rather
/// than resolving a git reference of its own.
fn resolve_changed(
  workspace: String,
  reference: Option(String),
) -> Result(Option(List(String)), String) {
  case reference {
    None -> Ok(None)
    Some(reference) -> {
      case reference == "" || string.starts_with(reference, "-") {
        True -> Error("GMU4006: --changed requires a non-option git reference")
        False -> {
          let merge_base =
            platform.run_process(
              "git",
              ["merge-base", "HEAD", reference],
              workspace,
              [],
              30_000,
            )
          use base <- result.try(case merge_base.status {
            0 -> Ok(string.trim(merge_base.stdout))
            _ ->
              Error(
                "GMU4007: git merge-base failed for "
                <> reference
                <> ": "
                <> merge_base.stderr
                <> merge_base.stdout,
              )
          })
          use groups <- result.try(
            list.try_map(
              [
                [
                  "diff",
                  "--name-only",
                  "-z",
                  "--diff-filter=ACMR",
                  base,
                  "HEAD",
                  "--",
                ],
                [
                  "diff",
                  "--cached",
                  "--name-only",
                  "-z",
                  "--diff-filter=ACMR",
                  "--",
                ],
                ["diff", "--name-only", "-z", "--diff-filter=ACMR", "--"],
                ["ls-files", "--others", "--exclude-standard", "-z"],
              ],
              fn(arguments) { git_changed_paths(workspace, arguments) },
            ),
          )
          groups
          |> list.flatten
          |> list.filter(fn(changed_path) {
            changed_path != "" && string.ends_with(changed_path, ".gleam")
          })
          |> list.map(mutant.normalize_path)
          |> list.unique
          |> Some
          |> Ok
        }
      }
    }
  }
}

fn git_changed_paths(
  workspace: String,
  arguments: List(String),
) -> Result(List(String), String) {
  let process = platform.run_process("git", arguments, workspace, [], 30_000)
  case process.status {
    0 -> Ok(string.split(process.stdout, "\u{0}"))
    _ ->
      Error(
        "GMU4008: git changed-file query failed: "
        <> process.stderr
        <> process.stdout,
      )
  }
}

/// Reads each relative source file under `root` and discovers its mutants,
/// assigning stable display ids across the whole selection.
pub fn discover_catalogs(
  root: String,
  files: List(String),
  operators: List(Operator),
) -> Result(List(SourceCatalog), String) {
  use catalogs <- result.try(
    list.try_map(files, fn(relative) {
      use source <- result.try(
        simplifile.read(path.join(root, relative))
        |> result.map_error(simplifile.describe_error),
      )
      use discovered <- result.try(
        catalog.discover(relative, source, operators)
        |> result.map_error(fn(error) {
          "Glance could not parse " <> relative <> ": " <> string.inspect(error)
        }),
      )
      Ok(SourceCatalog(
        relative,
        source,
        discovered.mutants,
        discovered.rejected,
      ))
    }),
  )
  let assigned =
    catalogs
    |> list.flat_map(fn(catalog) { catalog.mutants })
    |> catalog.assign_display_ids
  catalogs
  |> list.map(fn(source_catalog) {
    SourceCatalog(
      ..source_catalog,
      mutants: list.filter(assigned, fn(mutant) {
        mutant.path == source_catalog.path
      }),
    )
  })
  |> Ok
}

fn configure_deno_permissions(
  root: String,
  runtimes: List(Runtime),
) -> Result(Nil, String) {
  case list.contains(runtimes, Deno) {
    False -> Ok(Nil)
    True -> {
      let target = path.join(root, "gleam.toml")
      use source <- result.try(
        simplifile.read(target)
        |> result.map_error(simplifile.describe_error),
      )
      use document <- result.try(
        tomlet.parse(source)
        |> result.map_error(fn(error) {
          "could not parse snapshot gleam.toml for Deno permissions: "
          <> string.inspect(error)
        }),
      )
      use document <- result.try(
        tomlet.set_bool(document, ["javascript", "deno", "allow_read"], True)
        |> result.map_error(fn(_) { "could not set Deno read permission" }),
      )
      use document <- result.try(
        tomlet.set_array(document, ["javascript", "deno", "allow_env"], [
          tomlet.StringValue("GLEAM_MUTANTS_ACTIVE"),
          tomlet.StringValue("GLEAM_MUTANTS_RUNTIME"),
        ])
        |> result.map_error(fn(_) { "could not set Deno env permission" }),
      )
      simplifile.write(target, tomlet.to_string(document))
      |> result.map_error(simplifile.describe_error)
    }
  }
}

fn run_baseline(
  root: String,
  runtimes: List(Runtime),
  config: Config,
) -> Result(#(Int, Int), String) {
  let baseline_timeout = case config.timeout_ms {
    Some(value) -> value
    None -> 300_000
  }
  use durations <- result.try(
    runtimes
    |> list.flat_map(fn(runtime) { list.repeat(runtime, config.baseline_runs) })
    |> list.try_map(fn(runtime) {
      let started = platform.monotonic_milliseconds()
      let process_result =
        run_test(root, runtime, config.test_command, [], baseline_timeout)
      let duration = platform.monotonic_milliseconds() - started
      case process_result.timed_out, process_result.status {
        True, _ ->
          Error("baseline timed out on " <> outcome.runtime_name(runtime))
        False, 0 -> Ok(duration)
        False, _ ->
          Error(
            "baseline failed on "
            <> outcome.runtime_name(runtime)
            <> " (exit "
            <> int.to_string(process_result.status)
            <> "):\n"
            <> process_result.stdout
            <> process_result.stderr,
          )
      }
    }),
  )
  let average = case durations {
    [] -> 0
    _ ->
      list.fold(durations, 0, fn(total, value) { total + value })
      / list.length(durations)
  }
  let timeout = case config.timeout_ms {
    Some(value) -> value
    None -> int.min(1_800_000, int.max(10_000, average * 5))
  }
  Ok(#(average, timeout))
}

fn run_instrumented_baseline(
  root: String,
  runtimes: List(Runtime),
  config: Config,
  timeout_ms: Int,
) -> Result(Nil, String) {
  use runtime <- list.try_each(runtimes)
  let result =
    run_test(
      root,
      runtime,
      config.test_command,
      [#("GLEAM_MUTANTS_ACTIVE", "")],
      timeout_ms,
    )
  case result.timed_out, result.status {
    True, _ ->
      Error(
        "instrumented baseline timed out on " <> outcome.runtime_name(runtime),
      )
    False, 0 -> Ok(Nil)
    False, _ ->
      Error(
        "instrumented baseline failed on "
        <> outcome.runtime_name(runtime)
        <> ":\n"
        <> result.stdout
        <> result.stderr,
      )
  }
}

fn delta_validate(
  base: Snapshot,
  catalogs: List(SourceCatalog),
  mutants: List(Mutant),
  runtimes: List(Runtime),
  runtime_module: RuntimeModule,
) -> Result(#(List(Mutant), List(RejectedMutant)), String) {
  case mutants {
    [] -> Ok(#([], []))
    _ ->
      case
        validate_batch(
          base,
          catalogs,
          mutants,
          runtimes,
          runtime.name(runtime_module),
        )
      {
        Ok(Nil) -> Ok(#(mutants, []))
        Error(ValidationInfrastructure(error)) -> Error(error)
        Error(CandidateInvalid(diagnostic)) ->
          case mutants {
            [mutant] ->
              Ok(#([], [RejectedMutant(mutant, "compile-invalid", diagnostic)]))
            _ -> {
              let middle = list.length(mutants) / 2
              let left = list.take(mutants, middle)
              let right = list.drop(mutants, middle)
              use left_result <- result.try(delta_validate(
                base,
                catalogs,
                left,
                runtimes,
                runtime_module,
              ))
              use right_result <- result.try(delta_validate(
                base,
                catalogs,
                right,
                runtimes,
                runtime_module,
              ))
              Ok(#(
                list.append(left_result.0, right_result.0),
                list.append(left_result.1, right_result.1),
              ))
            }
          }
      }
  }
}

fn validate_batch(
  base: Snapshot,
  catalogs: List(SourceCatalog),
  mutants: List(Mutant),
  runtimes: List(Runtime),
  runtime_module: String,
) -> Result(Nil, ValidationError) {
  use worker <- result.try(
    snapshot.create(snapshot.root(base))
    |> result.map_error(ValidationInfrastructure),
  )
  let validation = {
    use _ <- result.try(
      instrument(snapshot.root(worker), catalogs, mutants, runtime_module)
      |> result.map_error(CandidateInvalid),
    )
    build_targets(snapshot.root(worker), runtimes)
    |> result.map_error(CandidateInvalid)
  }
  let normalize = fn(error) {
    normalize_validation_diagnostic(error, snapshot.root(worker))
  }
  case validation, snapshot.dispose(worker) {
    Ok(Nil), Ok(Nil) -> Ok(Nil)
    Error(CandidateInvalid(error)), Ok(Nil) ->
      Error(CandidateInvalid(normalize(error)))
    Error(ValidationInfrastructure(error)), Ok(Nil) ->
      Error(ValidationInfrastructure(error))
    Ok(Nil), Error(error) ->
      Error(ValidationInfrastructure(
        "validation snapshot cleanup failed: " <> error,
      ))
    Error(CandidateInvalid(error)), Error(cleanup_error) ->
      Error(ValidationInfrastructure(
        normalize(error)
        <> "; validation snapshot cleanup failed: "
        <> cleanup_error,
      ))
    Error(ValidationInfrastructure(error)), Error(cleanup_error) ->
      Error(ValidationInfrastructure(
        error <> "; validation snapshot cleanup failed: " <> cleanup_error,
      ))
  }
}

fn normalize_validation_diagnostic(
  output: String,
  snapshot_root: String,
) -> String {
  // macOS exposes temporary directories through /var while some child
  // processes report the same path through its /private/var real-path alias.
  // Replace the longer alias first so it cannot become /private<snapshot>.
  let private_snapshot_root = "/private" <> snapshot_root
  let output =
    output
    |> string.replace(private_snapshot_root, "<snapshot>")
    |> string.replace(snapshot_root, "<snapshot>")
    |> string.replace(string.replace(snapshot_root, "/", "\\"), "<snapshot>")
    |> normalize_snapshot_location("/", "/gleam-mutants-")
    |> normalize_snapshot_location("\\", "\\gleam-mutants-")
  case string.split_once(output, "error:") {
    Ok(#(_, diagnostic)) -> "error:" <> diagnostic
    Error(_) -> output
  }
}

fn normalize_snapshot_location(
  output: String,
  separator: String,
  snapshot_marker: String,
) -> String {
  case string.split_once(output, "  ┌─ ") {
    Error(_) -> output
    Ok(#(before, location)) ->
      case string.split_once(location, snapshot_marker) {
        Error(_) -> output
        Ok(#(_, nonce_and_path)) ->
          case string.split_once(nonce_and_path, separator) {
            Error(_) -> output
            Ok(#(_, relative)) ->
              before <> "  ┌─ <snapshot>" <> separator <> relative
          }
      }
  }
}

/// Rewrites every catalogued source that owns a selected mutant so each
/// mutation site is wrapped in a `runtime_module.select` call.
pub fn instrument(
  root: String,
  catalogs: List(SourceCatalog),
  mutants: List(Mutant),
  runtime_module: String,
) -> Result(Nil, String) {
  use source_catalog <- list.try_each(catalogs)
  let selected =
    list.filter(mutants, fn(mutant) { mutant.path == source_catalog.path })
  case selected {
    [] -> Ok(Nil)
    _ -> {
      use forest <- result.try(
        interval_tree.build(source_catalog.source, selected)
        |> result.map_error(fn(error) {
          "overlapping mutation spans: " <> string.inspect(error)
        }),
      )
      let rendered =
        interval_tree.render(source_catalog.source, forest, runtime_module)
        |> add_runtime_import(runtime_module)
      simplifile.write(path.join(root, source_catalog.path), rendered)
      |> result.map_error(simplifile.describe_error)
    }
  }
}

fn add_runtime_import(source: String, runtime_module: String) -> String {
  insert_import_lines(
    string.split(source, "\n"),
    runtime_module,
    [],
    string.contains(source, "\r\n"),
  )
}

fn insert_import_lines(
  lines: List(String),
  runtime_module: String,
  leading: List(String),
  crlf: Bool,
) -> String {
  case lines {
    [] ->
      list.reverse(["import " <> runtime_module, ..leading])
      |> string.join("\n")
    [line, ..rest] ->
      case is_leading_comment_or_blank(line) {
        True ->
          insert_import_lines(rest, runtime_module, [line, ..leading], crlf)
        False -> {
          let import_line =
            "import "
            <> runtime_module
            <> case crlf {
              True -> "\r"
              False -> ""
            }
          list.append(list.reverse(leading), [import_line, line, ..rest])
          |> string.join("\n")
        }
      }
  }
}

fn is_leading_comment_or_blank(line: String) -> Bool {
  let trimmed = line |> string.replace("\r", "") |> string.trim
  trimmed == "" || string.starts_with(trimmed, "//")
}

/// Writes generated source files (path relative to root, content) into a
/// snapshot, creating parent directories.
pub fn write_generated_files(
  root: String,
  files: List(#(String, String)),
) -> Result(Nil, String) {
  use #(relative, contents) <- list.try_each(files)
  let target = path.join(root, relative)
  use _ <- result.try(
    simplifile.create_directory_all(path.parent(target))
    |> result.map_error(simplifile.describe_error),
  )
  simplifile.write(target, contents)
  |> result.map_error(simplifile.describe_error)
}

/// Compiles the project at `root` once per distinct target of `runtimes`.
pub fn build_targets(
  root: String,
  runtimes: List(Runtime),
) -> Result(Nil, String) {
  let targets = runtimes |> list.map(runtime_target) |> list.unique
  use target <- list.try_each(targets)
  let process_result =
    platform.run_process(
      "gleam",
      ["build", "--target", target],
      root,
      [],
      300_000,
    )
  case process_result.timed_out, process_result.status {
    True, _ -> Error("candidate validation timed out for " <> target)
    False, 0 -> Ok(Nil)
    False, _ -> Error(process_result.stdout <> process_result.stderr)
  }
}

fn runtime_target(runtime: Runtime) -> String {
  case runtime {
    Erlang -> "erlang"
    Node | Deno | Bun -> "javascript"
  }
}

fn run_mutants(prepared: Prepared) -> Result(List(MutantResult), String) {
  let worker_count =
    int.max(
      1,
      int.min(
        prepared.config.jobs,
        list.length(plan.mutants(prepared.mutation_plan)),
      ),
    )
  use cache_context <- result.try(cache_context(prepared))
  let fingerprint =
    cache.fingerprint_v1(
      snapshot.digest(prepared.snapshot),
      prepared.runtimes,
      prepared.config.test_command,
      prepared.timeout_ms,
      cache_context,
    )
  let pipeline.State(workspace, _, _, _, _, _) = pipeline.state(prepared.phase)
  let workspace_id = cache.workspace_id(workspace)
  use workers <- result.try(create_workers(prepared.snapshot, worker_count))
  let run_result =
    run_mutant_waves(
      prepared,
      plan.mutants(prepared.mutation_plan),
      workers,
      worker_count,
      fingerprint,
      workspace_id,
      [],
    )
  let cleanup_result = dispose_workers(workers)
  case run_result, cleanup_result {
    Ok(results), Ok(Nil) -> Ok(results)
    Error(error), Ok(Nil) -> Error(error)
    Ok(_), Error(error) -> Error("worker snapshot cleanup failed: " <> error)
    Error(error), Error(cleanup_error) ->
      Error(error <> "; worker snapshot cleanup failed: " <> cleanup_error)
  }
}

fn effective_cache_mode(config: Config) -> CacheMode {
  case config.cache_mode, config.test_command {
    CacheAuto, ["gleam", "test"] -> CacheReadWrite
    CacheAuto, _ -> CacheOff
    mode, _ -> mode
  }
}

fn cache_context(prepared: Prepared) -> Result(String, String) {
  use file_inputs <- result.try(
    list.try_map(prepared.config.cache_files, fn(relative) {
      simplifile.read(path.join(snapshot.root(prepared.snapshot), relative))
      |> result.map_error(fn(error) {
        "could not read cache input "
        <> relative
        <> ": "
        <> simplifile.describe_error(error)
      })
      |> result.map(fn(contents) { relative <> "\u{0}" <> contents })
    }),
  )
  let env_inputs =
    list.map(prepared.config.cache_env, fn(name) {
      name <> "\u{0}" <> platform.env(name)
    })
  let runtime_identities =
    list.map(prepared.runtimes, fn(runtime) {
      let executable = outcome.runtime_name(runtime)
      let version =
        platform.run_process(
          executable,
          ["--version"],
          snapshot.root(prepared.snapshot),
          [],
          10_000,
        )
      executable
      <> "\u{0}"
      <> version.stdout
      <> version.stderr
      <> int.to_string(version.status)
    })
  Ok(
    [
      "gleam-mutants-cache-context-v1",
      platform.os_name(),
      platform.architecture(),
      platform.environment(),
      prepared.config.cache_key |> option.unwrap(""),
      ..list.append(runtime_identities, list.append(file_inputs, env_inputs))
    ]
    |> list.map(fn(value) {
      int.to_string(string.byte_size(value)) <> ":" <> value
    })
    |> string.concat
    |> bytes.sha256,
  )
}

fn run_mutant_waves(
  prepared: Prepared,
  remaining: List(Mutant),
  workers: List(Snapshot),
  worker_count: Int,
  fingerprint: String,
  workspace_id: String,
  completed: List(MutantResult),
) -> Result(List(MutantResult), String) {
  case remaining {
    [] -> Ok(completed)
    _ -> {
      let wave = list.take(remaining, worker_count)
      use results <- result.try(run_mutant_wave(
        prepared,
        wave,
        list.take(workers, list.length(wave)),
        fingerprint,
        workspace_id,
      ))
      run_mutant_waves(
        prepared,
        list.drop(remaining, worker_count),
        workers,
        worker_count,
        fingerprint,
        workspace_id,
        list.append(completed, results),
      )
    }
  }
}

fn run_mutant_wave(
  prepared: Prepared,
  mutants: List(Mutant),
  workers: List(Snapshot),
  fingerprint: String,
  workspace_id: String,
) -> Result(List(MutantResult), String) {
  use contexts <- result.try(pair_contexts(mutants, workers, []))
  use contexts <- result.try(run_runtime_phases(
    contexts,
    prepared.runtimes,
    prepared.config,
    prepared.timeout_ms,
    fingerprint,
    workspace_id,
  ))
  contexts
  |> list.map(fn(context) {
    MutantResult(
      context.mutant,
      context.outcomes,
      outcome.aggregate(context.outcomes),
    )
  })
  |> Ok
}

fn pair_contexts(
  mutants: List(Mutant),
  workers: List(Snapshot),
  contexts: List(ExecutionContext),
) -> Result(List(ExecutionContext), String) {
  case mutants, workers {
    [], [] -> Ok(list.reverse(contexts))
    [mutant, ..mutants], [worker, ..workers] ->
      pair_contexts(mutants, workers, [
        ExecutionContext(mutant, worker, []),
        ..contexts
      ])
    _, _ -> Error("worker allocation failed")
  }
}

fn run_runtime_phases(
  contexts: List(ExecutionContext),
  runtimes: List(Runtime),
  config: Config,
  timeout_ms: Int,
  fingerprint: String,
  workspace_id: String,
) -> Result(List(ExecutionContext), String) {
  case runtimes {
    [] -> Ok(contexts)
    [runtime, ..rest] -> {
      let contexts =
        contexts
        |> list.map(fn(context) {
          case
            cache.read(
              effective_cache_mode(config),
              workspace_id,
              fingerprint,
              context.mutant,
              runtime,
            )
          {
            Ok(cached) ->
              ExecutionContext(
                ..context,
                outcomes: list.append(context.outcomes, [cached]),
              )
            Error(_) -> context
          }
        })
      let pending =
        contexts
        |> list.filter_map(fn(context) {
          case
            list.any(context.outcomes, fn(value) { value.runtime == runtime })
          {
            True -> Error(Nil)
            False -> {
              let #(executable, arguments) =
                command_for(runtime, config.test_command)
              Ok(PendingRun(
                context.mutant,
                runtime,
                platform.ProcessRequest(
                  executable,
                  arguments,
                  snapshot.root(context.worker),
                  [
                    #("GLEAM_MUTANTS_ACTIVE", context.mutant.id),
                    #("GLEAM_MUTANTS_RUNTIME", outcome.runtime_name(runtime)),
                  ],
                  timeout_ms,
                ),
              ))
            }
          }
        })
      let results =
        pending
        |> list.map(fn(run) { run.request })
        |> platform.run_process_batch(config.jobs)
      use completed <- result.try(zip_completed(pending, results, []))
      use contexts <- result.try(
        contexts
        |> list.try_map(fn(context) {
          case
            list.find(completed, fn(item) {
              item.0.mutant.id == context.mutant.id
            })
          {
            Error(_) -> Ok(context)
            Ok(#(run, timed)) -> {
              let process = timed.process
              let raw_output = truncate(process.stdout <> process.stderr)
              let value: Outcome = case process.timed_out, process.status {
                True, _ -> TimedOut
                False, 0 -> Survived
                False, -2 -> TestError(raw_output)
                False, 1 -> Killed
                False, _ -> TestError(raw_output)
              }
              let runtime_outcome =
                RuntimeOutcome(
                  run.runtime,
                  value,
                  timed.duration_ms,
                  diagnostic_output(
                    config.report.diagnostics,
                    value,
                    raw_output,
                  ),
                  False,
                )
              use _ <- result.try(cache.write(
                effective_cache_mode(config),
                workspace_id,
                fingerprint,
                run.mutant,
                runtime_outcome,
              ))
              Ok(
                ExecutionContext(
                  ..context,
                  outcomes: list.append(context.outcomes, [runtime_outcome]),
                ),
              )
            }
          }
        }),
      )
      run_runtime_phases(
        contexts,
        rest,
        config,
        timeout_ms,
        fingerprint,
        workspace_id,
      )
    }
  }
}

fn zip_completed(
  pending: List(PendingRun),
  results: List(platform.TimedProcessResult),
  completed: List(#(PendingRun, platform.TimedProcessResult)),
) -> Result(List(#(PendingRun, platform.TimedProcessResult)), String) {
  case pending, results {
    [], [] -> Ok(list.reverse(completed))
    [run, ..pending], [timed, ..results] ->
      zip_completed(pending, results, [#(run, timed), ..completed])
    _, _ -> Error("batch process runner returned an invalid result count")
  }
}

fn create_workers(
  base: Snapshot,
  count: Int,
) -> Result(List(Snapshot), String) {
  create_workers_loop(base, count, [])
}

fn create_workers_loop(
  base: Snapshot,
  remaining: Int,
  workers: List(Snapshot),
) -> Result(List(Snapshot), String) {
  case remaining <= 0 {
    True -> Ok(list.reverse(workers))
    False -> {
      case snapshot.create(snapshot.root(base)) {
        Ok(worker) ->
          create_workers_loop(base, remaining - 1, [worker, ..workers])
        Error(error) ->
          case dispose_workers(workers) {
            Ok(Nil) -> Error(error)
            Error(cleanup_error) ->
              Error(
                error <> "; partial worker cleanup failed: " <> cleanup_error,
              )
          }
      }
    }
  }
}

fn dispose_workers(workers: List(Snapshot)) -> Result(Nil, String) {
  case workers {
    [] -> Ok(Nil)
    [worker, ..rest] ->
      case snapshot.dispose(worker), dispose_workers(rest) {
        Ok(Nil), result -> result
        Error(error), Ok(Nil) -> Error(error)
        Error(error), Error(rest_error) -> Error(error <> "; " <> rest_error)
      }
  }
}

fn run_test(
  root: String,
  runtime: Runtime,
  configured_command: List(String),
  environment: List(#(String, String)),
  timeout_ms: Int,
) -> platform.ProcessResult {
  let #(executable, arguments) = command_for(runtime, configured_command)
  platform.run_process(executable, arguments, root, environment, timeout_ms)
}

fn command_for(
  runtime: Runtime,
  configured: List(String),
) -> #(String, List(String)) {
  case configured {
    ["gleam", "test"] ->
      case runtime {
        Erlang -> #("gleam", ["test", "--target", "erlang"])
        Node -> #("gleam", [
          "test",
          "--target",
          "javascript",
          "--runtime",
          "node",
        ])
        Deno -> #("gleam", [
          "test",
          "--target",
          "javascript",
          "--runtime",
          "deno",
        ])
        Bun -> #("gleam", ["test", "--target", "javascript", "--runtime", "bun"])
      }
    [executable, ..arguments] -> #(executable, arguments)
    [] -> #("gleam", ["test"])
  }
}

fn detect_runtimes(
  gleam_toml: String,
  config: Config,
  matrix: Bool,
) -> List(Runtime) {
  case matrix {
    True -> [Erlang, Node, Deno, Bun]
    False -> [detect_runtime(gleam_toml, config)]
  }
}

fn detect_runtime(gleam_toml: String, config: Config) -> Runtime {
  case config.test_runtime {
    config.ErlangRuntime -> Erlang
    config.NodeRuntime -> Node
    config.DenoRuntime -> Deno
    config.BunRuntime -> Bun
    config.AutoRuntime ->
      case config.test_target {
        config.ErlangTarget -> Erlang
        config.JavaScriptTarget -> detect_javascript_runtime(gleam_toml)
        config.AutoTarget ->
          case tomlet.parse(gleam_toml) {
            Ok(document) ->
              case tomlet.get_string(document, ["target"]) {
                Ok("javascript") -> detect_javascript_runtime(gleam_toml)
                _ -> Erlang
              }
            Error(_) -> Erlang
          }
      }
  }
}

fn detect_javascript_runtime(gleam_toml: String) -> Runtime {
  case tomlet.parse(gleam_toml) {
    Ok(document) ->
      case tomlet.get_string(document, ["javascript", "runtime"]) {
        Ok("deno") -> Deno
        Ok("bun") -> Bun
        _ -> Node
      }
    Error(_) -> Node
  }
}

fn truncate(output: String) -> String {
  let length = string.length(output)
  case length > 65_536 {
    True -> {
      let head = string.slice(output, 0, 32_768)
      let tail = string.drop_start(output, length - 32_768)
      let omitted =
        string.byte_size(output)
        - string.byte_size(head)
        - string.byte_size(tail)
      head
      <> "\n["
      <> int.to_string(omitted)
      <> " diagnostic bytes omitted]\n"
      <> tail
    }
    False -> output
  }
}

fn diagnostic_output(
  mode: DiagnosticsMode,
  outcome: Outcome,
  output: String,
) -> String {
  case mode, outcome {
    DiagnosticsNone, _ -> ""
    DiagnosticsAll, _ -> output
    DiagnosticsErrors, TimedOut | DiagnosticsErrors, TestError(_) -> output
    DiagnosticsErrors, Killed | DiagnosticsErrors, Survived -> ""
  }
}
