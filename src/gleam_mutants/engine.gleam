// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/cache
import gleam_mutants/config.{type Config, Config}
import gleam_mutants/core/catalog.{type RejectedMutant, RejectedMutant}
import gleam_mutants/core/exit_policy
import gleam_mutants/core/interval_tree
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator.{type Operator}
import gleam_mutants/core/outcome.{
  type Outcome, type Runtime, type RuntimeOutcome, Bun, Deno, Erlang, Killed,
  Node, RuntimeOutcome, Survived, TestError, TimedOut,
}
import gleam_mutants/core/path
import gleam_mutants/core/score
import gleam_mutants/pipeline
import gleam_mutants/platform
import gleam_mutants/report.{
  type MutantResult, type RunReport, MutantResult, RunReport,
}
import gleam_mutants/runtime.{type RuntimeModule}
import gleam_mutants/snapshot.{type Snapshot}
import simplifile
import tomlet

pub type Options {
  Options(
    matrix: Bool,
    changed: Option(String),
    includes: List(String),
    operators: Option(List(Operator)),
    strict: Option(Bool),
    jobs: Option(Int),
    timeout_ms: Option(Int),
    test_command: Option(List(String)),
    json: Bool,
    explain: Bool,
  )
}

pub type RunOutput {
  RunOutput(report: RunReport, report_path: String, exit_code: Int)
}

pub type ListOutput {
  ListOutput(mutants: List(Mutant), rejected: List(RejectedMutant))
}

type SourceCatalog {
  SourceCatalog(path: String, source: String, mutants: List(Mutant))
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
    mutants: List(Mutant),
    rejected: List(RejectedMutant),
    runtimes: List(Runtime),
    runtime_module: RuntimeModule,
    timeout_ms: Int,
    phase: pipeline.Pipeline(pipeline.Instrumented),
  )
}

pub fn default_options() -> Options {
  Options(False, None, [], None, None, None, None, None, False, False)
}

pub fn run(workspace: String, options: Options) -> Result(RunOutput, String) {
  use source <- result.try(read_project_config(workspace))
  use decoded <- result.try(
    config.decode(source, platform.cpu_count())
    |> result.map_error(config.describe_error),
  )
  let configured = apply_options(decoded, options)
  use changed_paths <- result.try(resolve_changed(workspace, options.changed))
  use snapshot <- result.try(snapshot.create(workspace))
  let result =
    execute(snapshot, workspace, source, configured, options, changed_paths)
  let _ = snapshot.dispose(snapshot)
  result
}

pub fn list_mutants(
  workspace: String,
  options: Options,
) -> Result(ListOutput, String) {
  use source <- result.try(read_project_config(workspace))
  use decoded <- result.try(
    config.decode(source, platform.cpu_count())
    |> result.map_error(config.describe_error),
  )
  let configured = apply_options(decoded, options)
  use changed_paths <- result.try(resolve_changed(workspace, options.changed))
  use snapshot <- result.try(snapshot.create(workspace))
  let result = case
    prepare(snapshot, workspace, source, configured, options, changed_paths)
  {
    Error(error) -> Error(error)
    Ok(prepared) -> Ok(ListOutput(prepared.mutants, prepared.rejected))
  }
  let _ = snapshot.dispose(snapshot)
  result
}

fn execute(
  snapshot: Snapshot,
  workspace: String,
  gleam_toml: String,
  config: Config,
  options: Options,
  changed_paths: Option(List(String)),
) -> Result(RunOutput, String) {
  let started = platform.now_milliseconds()
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
  let run_report =
    RunReport(
      run_id: int.to_string(started)
        <> "-"
        <> string.slice(snapshot.digest(snapshot), 0, 12),
      started_ms: started,
      duration_ms: platform.now_milliseconds() - started,
      workspace_digest: snapshot.digest(snapshot),
      matrix: options.matrix,
      results: results,
      rejected: prepared.rejected,
      score: mutation_score,
    )
  use report_path <- result.try(report.save(run_report))
  report.emit_github(run_report)
  let policy =
    exit_policy.Context(
      ci: platform.is_ci(),
      tty: platform.is_tty(),
      strict: prepared.config.strict,
      minimum_score: prepared.config.minimum_score,
    )
  let phase = pipeline.completed(prepared.phase)
  let _ = pipeline.state(phase)
  Ok(RunOutput(
    run_report,
    report_path,
    exit_policy.code(mutation_score, policy),
  ))
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
  let phase3 = pipeline.validated(phase2, valid, rejected)
  use _ <- result.try(instrument(
    snapshot.root(snapshot),
    catalogs,
    valid,
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
    valid,
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
      Some(value) -> int.max(1, int.min(value, 256))
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
  )
}

fn resolve_changed(
  workspace: String,
  reference: Option(String),
) -> Result(Option(List(String)), String) {
  case reference {
    None -> Ok(None)
    Some(reference) -> {
      let result =
        platform.run_process(
          "git",
          ["diff", "--name-only", reference, "--"],
          workspace,
          [],
          30_000,
        )
      case result.status {
        0 ->
          result.stdout
          |> string.split("\n")
          |> list.map(fn(path) {
            path |> string.replace("\r", "") |> string.trim
          })
          |> list.filter(fn(path) {
            path != "" && string.ends_with(path, ".gleam")
          })
          |> list.map(mutant.normalize_path)
          |> Some
          |> Ok
        _ ->
          Error(
            "git diff failed for "
            <> reference
            <> ": "
            <> result.stderr
            <> result.stdout,
          )
      }
    }
  }
}

fn discover_catalogs(
  root: String,
  files: List(String),
  operators: List(Operator),
) -> Result(List(SourceCatalog), String) {
  list.try_map(files, fn(relative) {
    use source <- result.try(
      simplifile.read(path.join(root, relative))
      |> result.map_error(simplifile.describe_error),
    )
    use mutants <- result.try(
      catalog.discover(relative, source, operators)
      |> result.map_error(fn(error) {
        "Glance could not parse " <> relative <> ": " <> string.inspect(error)
      }),
    )
    Ok(SourceCatalog(relative, source, mutants))
  })
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
      let started = platform.now_milliseconds()
      let process_result =
        run_test(root, runtime, config.test_command, [], baseline_timeout)
      let duration = platform.now_milliseconds() - started
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
    None -> int.max(10_000, average * 5)
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
        Error(diagnostic) ->
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
) -> Result(Nil, String) {
  use worker <- result.try(snapshot.create(snapshot.root(base)))
  let validation = {
    use _ <- result.try(instrument(
      snapshot.root(worker),
      catalogs,
      mutants,
      runtime_module,
    ))
    build_targets(snapshot.root(worker), runtimes)
  }
  let _ = snapshot.dispose(worker)
  validation
}

fn instrument(
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

fn build_targets(root: String, runtimes: List(Runtime)) -> Result(Nil, String) {
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
    int.max(1, int.min(prepared.config.jobs, list.length(prepared.mutants)))
  let fingerprint =
    cache.fingerprint(
      snapshot.digest(prepared.snapshot),
      prepared.runtimes,
      prepared.config.test_command,
      prepared.timeout_ms,
    )
  use workers <- result.try(create_workers(prepared.snapshot, worker_count))
  let run_result =
    run_mutant_waves(
      prepared,
      prepared.mutants,
      workers,
      worker_count,
      fingerprint,
      [],
    )
  let _ =
    list.each(workers, fn(worker) {
      let _ = snapshot.dispose(worker)
      Nil
    })
  run_result
}

fn run_mutant_waves(
  prepared: Prepared,
  remaining: List(Mutant),
  workers: List(Snapshot),
  worker_count: Int,
  fingerprint: String,
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
      ))
      run_mutant_waves(
        prepared,
        list.drop(remaining, worker_count),
        workers,
        worker_count,
        fingerprint,
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
) -> Result(List(MutantResult), String) {
  use contexts <- result.try(pair_contexts(mutants, workers, []))
  use contexts <- result.try(run_runtime_phases(
    contexts,
    prepared.runtimes,
    prepared.config,
    prepared.timeout_ms,
    fingerprint,
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
) -> Result(List(ExecutionContext), String) {
  case runtimes {
    [] -> Ok(contexts)
    [runtime, ..rest] -> {
      let contexts =
        contexts
        |> list.map(fn(context) {
          case
            cache.read(config.cache_mode, fingerprint, context.mutant, runtime)
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
      let contexts =
        contexts
        |> list.map(fn(context) {
          case
            list.find(completed, fn(item) {
              item.0.mutant.id == context.mutant.id
            })
          {
            Error(_) -> context
            Ok(#(run, timed)) -> {
              let process = timed.process
              let value: Outcome = case process.timed_out, process.status {
                True, _ -> TimedOut
                False, 0 -> Survived
                False, -2 -> TestError(process.stderr)
                False, _ -> Killed
              }
              let runtime_outcome =
                RuntimeOutcome(
                  run.runtime,
                  value,
                  timed.duration_ms,
                  truncate(process.stdout <> process.stderr),
                  False,
                )
              cache.write(
                config.cache_mode,
                fingerprint,
                run.mutant,
                runtime_outcome,
              )
              ExecutionContext(
                ..context,
                outcomes: list.append(context.outcomes, [runtime_outcome]),
              )
            }
          }
        })
      run_runtime_phases(contexts, rest, config, timeout_ms, fingerprint)
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
      use worker <- result.try(snapshot.create(snapshot.root(base)))
      create_workers_loop(base, remaining - 1, [worker, ..workers])
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
  case string.length(output) > 20_000 {
    True -> string.slice(output, 0, 20_000) <> "\n[output truncated]"
    False -> output
  }
}
