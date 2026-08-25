// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Driving the differential probe end to end: snapshot the workspace,
// instrument the mutants of every function worth probing, generate one probe
// module per source file, build the snapshot once and run each probe inside a
// single BEAM VM.
//
// Only the Erlang target is supported: the probe isolates each call in a
// spawned process through an Erlang FFI module, which has no JavaScript
// counterpart. The rejection is a run-time error rather than a `@target`
// annotation so that this module still compiles on both targets.

import glance
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mutants/config.{type Config}
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/outcome
import gleam_mutants/core/path
import gleam_mutants/engine.{type SourceCatalog}
import gleam_mutants/platform
import gleam_mutants/runtime
import gleam_mutants/snapshot.{type Snapshot}
import gleam_mutants/suggest/harness.{
  type ProbeFunction, type ProbeSpec, ProbeFunction, ProbeSpec,
}
import gleam_mutants/suggest/pbt_source
import gleam_mutants/suggest/probe_result.{
  type ProbeResult, ProbeResult, Unsupported,
}
import gleam_mutants/suggest/select
import gleam_mutants/suggest/typederive
import simplifile
import tomlet

// --- The request -------------------------------------------------------------

/// One differential run: which sources to probe and how hard to look.
///
/// `files` are workspace-relative paths of `.gleam` sources that the
/// workspace's mutation `includes` already cover. `function_filter` narrows
/// the run to the one function of that exact name, dropping every other
/// function from both the results and the skipped list; `None` probes them
/// all. `exclude_functions` names functions the probe leaves alone: they are
/// never compiled into it, never called and never timed, and each of their
/// mutants comes back `Unsupported` with the function among the skipped ones.
/// `seed`, `max_cases` and `max_shrinks` are handed to the property
/// search inside the probe, `call_timeout_ms` bounds one call of the function
/// under test and `probe_timeout_ms` bounds a whole probe process.
/// `nondeterminism_checks` is how many inputs the original is replayed on
/// before any mutant is judged.
pub type Request {
  Request(
    workspace: String,
    files: List(String),
    function_filter: Option(String),
    seed: Int,
    max_cases: Int,
    max_shrinks: Int,
    call_timeout_ms: Int,
    probe_timeout_ms: Int,
    nondeterminism_checks: Int,
    exclude_functions: List(String),
  )
}

/// Why a function `exclude_functions` names has no test written for it.
///
/// The one configuration key that fills that field is
/// `[tools.gleam_mutants.suggest] exclude_functions`, and the reader who set
/// it is the one reading this reason back.
pub const excluded_reason = "excluded by suggest.exclude_functions"

/// A function the runner walked past, and why.
pub type Skipped {
  Skipped(module: String, function: String, reason: String)
}

/// Why one differential run stopped, in the pieces a caller needs.
///
/// `code` is the `GMU` code of the failure and `message` the text that
/// follows it; a wall with no code of its own — a manifest that cannot be
/// read, a snapshot that cannot be made — leaves `code` empty. `snapshot_root`
/// names the snapshot the run left on disk, which the caller owns and is
/// expected to delete once it has read it. It is `None` when there is nothing
/// to delete: a failure raised before anything was generated takes its copy
/// with it.
pub type RunError {
  RunError(code: String, message: String, snapshot_root: Option(String))
}

/// The text a failure is printed as: the code, its message and — when the run
/// left one behind — the snapshot that holds what it generated.
pub fn describe(error: RunError) -> String {
  let named = case error.code {
    "" -> error.message
    code -> code <> ": " <> error.message
  }
  case error.snapshot_root {
    None -> named
    Some(root) -> named <> "\nthe snapshot was left at " <> root
  }
}

/// Splits the `GMU` code off the front of a message a check built.
///
/// Every wall a run can hit names itself in front of its message, and that is
/// how the message has always been printed; holding the code in its own field
/// spares a caller from reading text to tell one failure from another, and
/// `describe` puts it back where it was. A message that names no code keeps
/// all of itself.
fn coded(message: String, snapshot_root: Option(String)) -> RunError {
  let #(code, rest) = case string.split_once(message, ": ") {
    Ok(#(head, tail)) ->
      case is_code(head) {
        True -> #(head, tail)
        False -> #("", message)
      }
    Error(Nil) -> #("", message)
  }
  RunError(code: code, message: rest, snapshot_root: snapshot_root)
}

/// Whether a fragment is one of the `GMUnnnn` codes a message begins with.
fn is_code(candidate: String) -> Bool {
  case string.starts_with(candidate, "GMU") {
    False -> False
    True -> result.is_ok(int.parse(string.drop_start(candidate, 3)))
  }
}

/// Everything one differential run produced.
///
/// `results` holds exactly one entry per mutant of every function the run
/// considered — a verdict for the functions that were probed, an `Unsupported`
/// entry for the mutants of the functions in `skipped`. `mutants` carries the
/// discovered mutant of every one of those ids, so a caller can name an
/// operator, a location and the source a verdict is about without discovering
/// the catalogue a second time. `unassigned_mutants` counts the mutants that
/// fall outside every function, such as those in module constants.
/// `snapshot_root` is left on disk for the caller to read and then delete.
pub type RunOutput {
  RunOutput(
    results: List(ProbeResult),
    mutants: List(Mutant),
    skipped: List(Skipped),
    unassigned_mutants: Int,
    snapshot_root: String,
  )
}

/// A request with the standard budgets: seed 1, 200 cases, 500 shrinks, a
/// second per call, two minutes per probe and three determinism replays.
pub fn defaults(workspace: String, files: List(String)) -> Request {
  Request(
    workspace: workspace,
    files: files,
    function_filter: None,
    seed: 1,
    max_cases: 200,
    max_shrinks: 500,
    call_timeout_ms: 1000,
    probe_timeout_ms: 120_000,
    nondeterminism_checks: 3,
    exclude_functions: [],
  )
}

// --- Running -----------------------------------------------------------------

/// Probes every mutant of `request.files` against its original.
///
/// A request is judged before anything is copied: the workspace's tests have
/// to run on the Erlang target, and no two sources may flatten to the same
/// probe module. Once generation has begun the snapshot is deliberately *not*
/// deleted, on success or on failure — its generated probe modules and
/// compiler output are the only way to see what a broken probe did, and every
/// such error carries the directory holding them, which the caller then owns.
/// A failure raised before anything was generated takes the copy with it, so
/// a mistyped path does not leave a workspace behind and is reported with no
/// snapshot to delete.
pub fn run(request: Request) -> Result(RunOutput, RunError) {
  use gleam_toml <- result.try(unstarted(read_manifest(request.workspace)))
  use configured <- result.try(unstarted(load_config(gleam_toml)))
  use _ <- result.try(unstarted(check_target(configured, gleam_toml)))
  use files <- result.try(unstarted(distinct_sources(request.files)))
  use snapshot <- result.try(
    unstarted(
      snapshot.create_excluding(request.workspace, [
        configured.report.directory,
      ]),
    ),
  )
  run_snapshot(Request(..request, files: files), configured, snapshot)
}

/// A failure with no snapshot behind it: either nothing had been copied yet,
/// or the copy held nothing worth reading and has just been thrown away.
fn unstarted(attempt: Result(a, String)) -> Result(a, RunError) {
  result.map_error(attempt, fn(message) { coded(message, None) })
}

fn read_manifest(workspace: String) -> Result(String, String) {
  simplifile.read(path.join(workspace, "gleam.toml"))
  |> result.map_error(fn(error) {
    "could not read gleam.toml: " <> simplifile.describe_error(error)
  })
}

fn load_config(gleam_toml: String) -> Result(Config, String) {
  config.decode(gleam_toml, platform.cpu_count())
  |> result.map_error(config.describe_error)
}

/// Rejects a workspace whose tests do not run on the Erlang target.
///
/// The probe isolates every call in an Erlang process through an FFI module,
/// which has no JavaScript counterpart. `configured` on its own does not
/// settle the question: a project that sets a top-level `target = "javascript"`
/// and leaves `[tools.gleam_mutants.test]` alone keeps `AutoTarget`, and the
/// engine resolves exactly that to a JavaScript runtime — so the manifest is
/// consulted the same way `engine` resolves one.
pub fn check_target(
  configured: Config,
  gleam_toml: String,
) -> Result(Nil, String) {
  case javascript_bound(configured, gleam_toml) {
    True -> Error("GMU8001: suggest supports the Erlang target only")
    False -> Ok(Nil)
  }
}

/// Whether the workspace's tests would be run on a JavaScript runtime.
///
/// The question is settled in `engine.detect_runtime`'s order, because that is
/// the order the tests are really run in: a configured runtime decides on its
/// own, whatever target is written beside it, and only `runtime = "auto"`
/// leaves the decision to the target — first the configured one, then the
/// manifest's.
fn javascript_bound(configured: Config, gleam_toml: String) -> Bool {
  case configured.test_runtime {
    config.NodeRuntime | config.DenoRuntime | config.BunRuntime -> True
    config.ErlangRuntime -> False
    config.AutoRuntime ->
      case configured.test_target {
        config.JavaScriptTarget -> True
        config.ErlangTarget -> False
        config.AutoTarget -> javascript_manifest(gleam_toml)
      }
  }
}

/// Whether `gleam.toml` names JavaScript as the project's default target.
fn javascript_manifest(gleam_toml: String) -> Bool {
  case tomlet.parse(gleam_toml) {
    Ok(document) ->
      case tomlet.get_string(document, ["target"]) {
        Ok("javascript") -> True
        _ -> False
      }
    Error(_) -> False
  }
}

/// The distinct sources of a request, in the order they were asked for.
///
/// A path repeated in the request is dropped: probing one module twice would
/// instrument its mutants twice and report every verdict twice. Two *different*
/// paths whose module names flatten to the same probe module — `app_util` is
/// both `src/app_util.gleam` and `src/app/util.gleam` flattened — are rejected
/// instead, because the second generated probe would overwrite the first and
/// one module's verdicts would silently stand in for the other's.
pub fn distinct_sources(files: List(String)) -> Result(List(String), String) {
  list.unique(files)
  |> list.try_fold([], fn(taken, file) {
    let flattened = flatten(module_name(file))
    case list.key_find(taken, flattened) {
      Ok(earlier) ->
        Error(
          "GMU8006: "
          <> earlier
          <> " and "
          <> file
          <> " both generate the probe module `gleam_mutants_probe_<tag>_"
          <> flattened
          <> "`: probe them in separate runs",
        )
      Error(Nil) -> Ok([#(flattened, file), ..taken])
    }
  })
  |> result.map(fn(taken) {
    taken
    |> list.map(fn(entry) { entry.1 })
    |> list.reverse
  })
}

fn run_snapshot(
  request: Request,
  configured: Config,
  snapshot: Snapshot,
) -> Result(RunOutput, RunError) {
  let root = snapshot.root(snapshot)
  case prepare(request, configured, snapshot) {
    // Nothing has been generated yet, so the copy holds nothing worth reading:
    // throw it away rather than leak a workspace over a mistyped path, and
    // hand the caller a failure with no snapshot in it.
    Error(reason) -> {
      let _ = platform.delete_tree(root)
      Error(coded(reason, None))
    }
    Ok(prepared) -> {
      use reported <- result.try(
        probe(
          request,
          snapshot,
          prepared.catalogs,
          prepared.plans,
          prepared.pbt_module,
        )
        |> located(root),
      )
      let plans = prepared.plans
      Ok(RunOutput(
        results: list.flat_map(plans, fn(plan) {
          let probed = case list.key_find(reported, plan.probe_module) {
            Ok(results) -> results
            Error(Nil) -> []
          }
          list.append(probed, plan.unsupported)
        }),
        mutants: list.flat_map(prepared.catalogs, fn(source_catalog) {
          source_catalog.mutants
        }),
        skipped: list.flat_map(plans, fn(plan) { plan.skipped }),
        unassigned_mutants: list.fold(plans, 0, fn(total, plan) {
          total + plan.unassigned
        }),
        snapshot_root: root,
      ))
    }
  }
}

/// What one run needs from the snapshot before anything is generated in it.
type Prepared {
  Prepared(
    catalogs: List(SourceCatalog),
    plans: List(ModulePlan),
    pbt_module: String,
  )
}

/// Reads the requested sources and decides what each module's probe covers.
///
/// Nothing is generated in the snapshot here, so a failure leaves a copy with
/// nothing in it worth reading, and `run_snapshot` throws that copy away.
fn prepare(
  request: Request,
  configured: Config,
  snapshot: Snapshot,
) -> Result(Prepared, String) {
  let root = snapshot.root(snapshot)
  let tag = string.lowercase(string.slice(snapshot.digest(snapshot), 0, 12))
  let pbt_module = "gleam_mutants_pbt_" <> tag
  use _ <- result.try(check_covered(
    request.files,
    snapshot.source_files(snapshot, configured.includes, configured.excludes),
  ))
  use catalogs <- result.try(engine.discover_catalogs(
    root,
    request.files,
    configured.operators,
  ))
  use plans <- result.try(
    list.try_map(catalogs, fn(source_catalog) {
      plan_module(request, source_catalog, tag, pbt_module)
    }),
  )
  Ok(Prepared(catalogs: catalogs, plans: plans, pbt_module: pbt_module))
}

/// Hands the snapshot to a failure, so the generated files can be read — and
/// so whoever reads them knows what to delete afterwards.
fn located(attempt: Result(a, String), root: String) -> Result(a, RunError) {
  result.map_error(attempt, fn(message) { coded(message, Some(root)) })
}

/// Rejects a requested file the mutation configuration does not cover.
///
/// `available` is the snapshot's own list of mutable sources, so a path that
/// does not exist, is not a `.gleam` file, or falls outside the configured
/// includes is caught by the same check.
pub fn check_covered(
  requested: List(String),
  available: List(String),
) -> Result(Nil, String) {
  case list.filter(requested, fn(file) { !list.contains(available, file) }) {
    [] -> Ok(Nil)
    unknown ->
      Error(
        "GMU8002: "
        <> string.join(unknown, ", ")
        <> " is not a Gleam source covered by the mutation includes",
      )
  }
}

// --- Planning one module -----------------------------------------------------

/// One source file's share of the run: what to probe and what to give up on.
type ModulePlan {
  ModulePlan(
    module: String,
    probe_module: String,
    ffi_module: String,
    spec: ProbeSpec,
    probed: List(Mutant),
    skipped: List(Skipped),
    unsupported: List(ProbeResult),
    unassigned: Int,
  )
}

/// Plans one module for its guards alone, answering `Ok(Nil)` when it plans.
///
/// `ModulePlan` is private, and so is the planning: this is the seam a test
/// needs to prove that a probe whose helpers would clash is reported to the
/// caller rather than left to fail inside the snapshot.
pub fn check_plan(
  request: Request,
  source_catalog: SourceCatalog,
  tag: String,
  pbt_module: String,
) -> Result(Nil, String) {
  plan_module(request, source_catalog, tag, pbt_module)
  |> result.replace(Nil)
}

fn plan_module(
  request: Request,
  source_catalog: SourceCatalog,
  tag: String,
  pbt_module: String,
) -> Result(ModulePlan, String) {
  use parsed <- result.try(
    glance.module(source_catalog.source)
    |> result.map_error(fn(error) {
      "Glance could not parse "
      <> source_catalog.path
      <> ": "
      <> string.inspect(error)
    }),
  )
  let context = typederive.context(parsed)
  let #(targets, outside) = select.assign(parsed, source_catalog.mutants)
  let module = module_name(source_catalog.path)
  let probe_module = "gleam_mutants_probe_" <> tag <> "_" <> flatten(module)
  let considered = filter_targets(request.function_filter, targets)
  let #(probing, left_alone) =
    split_excluded(request.exclude_functions, considered)
  let judged =
    list.fold(probing, Sorted([], [], [], []), fn(sorted, target) {
      sort_target(sorted, context, module, target)
    })
  // The excluded functions are sorted after the probed ones rather than in
  // source order: they were never a candidate for the probe, so they read as
  // a tail of things left alone rather than as gaps in the walk.
  let sorted =
    list.fold(left_alone, judged, fn(sorted, target) {
      given_up(sorted, module, target, excluded_reason)
    })
  let spec =
    ProbeSpec(
      target_module: module,
      probe_module: probe_module,
      pbt_module: pbt_module,
      // The FFI module lives in its own namespace rather than under the
      // probe's name: `src/app.gleam` and `src/app_ffi.gleam` would otherwise
      // have app's `.erl` and app_ffi's probe both claim
      // `gleam_mutants_probe_<tag>_app_ffi` in the snapshot's `src/`.
      ffi_module: "gleam_mutants_ffi_" <> tag <> "_" <> flatten(module),
      functions: list.reverse(sorted.probes),
      seed: request.seed,
      max_cases: request.max_cases,
      max_shrinks: request.max_shrinks,
      call_timeout_ms: request.call_timeout_ms,
      nondeterminism_checks: request.nondeterminism_checks,
    )
  use _ <- result.try(case spec.functions {
    [] -> Ok(Nil)
    _ -> harness.check_spec(spec)
  })
  Ok(ModulePlan(
    module: module,
    probe_module: probe_module,
    ffi_module: spec.ffi_module,
    spec: spec,
    probed: list.reverse(sorted.mutants),
    skipped: list.reverse(sorted.skipped),
    unsupported: list.reverse(sorted.unsupported),
    unassigned: list.length(outside),
  ))
}

/// The functions of one module split into probed and given up on, reversed.
type Sorted {
  Sorted(
    probes: List(ProbeFunction),
    mutants: List(Mutant),
    skipped: List(Skipped),
    unsupported: List(ProbeResult),
  )
}

fn sort_target(
  sorted: Sorted,
  context: typederive.Context,
  module: String,
  target: select.FunctionTarget,
) -> Sorted {
  case classify(context, target.function) {
    Ok(plan) ->
      Sorted(
        probes: [
          ProbeFunction(
            plan: plan,
            mutant_ids: list.map(target.mutants, fn(item) { item.id }),
          ),
          ..sorted.probes
        ],
        mutants: list.fold(target.mutants, sorted.mutants, fn(all, item) {
          [item, ..all]
        }),
        skipped: sorted.skipped,
        unsupported: sorted.unsupported,
      )
    Error(reason) -> given_up(sorted, module, target, reason)
  }
}

/// One function nothing will be written for: skipped, with every mutant of it
/// reported as unsupported so that none of them is quietly dropped.
fn given_up(
  sorted: Sorted,
  module: String,
  target: select.FunctionTarget,
  reason: String,
) -> Sorted {
  Sorted(
    ..sorted,
    skipped: [Skipped(module, target.function.name, reason), ..sorted.skipped],
    unsupported: list.fold(target.mutants, sorted.unsupported, fn(all, item) {
      [unsupported(target.function.name, item, reason), ..all]
    }),
  )
}

/// The targets a request asks about: every one, or the single named function.
///
/// A filter that matches nothing leaves nothing behind, on purpose: a run
/// narrowed to a name that is not in the module reports no verdict rather than
/// quietly widening back to the whole module.
pub fn filter_targets(
  wanted: Option(String),
  targets: List(select.FunctionTarget),
) -> List(select.FunctionTarget) {
  case wanted {
    None -> targets
    Some(name) ->
      list.filter(targets, fn(target) { target.function.name == name })
  }
}

/// The targets a request probes, and the ones `exclude_functions` names.
///
/// The split happens before anything is classified, generated or compiled, so
/// a function in the second half is never called: that is the whole point of
/// excluding one, which is usually that calling it is unsafe or slow. Its
/// mutants are still reported — as `Unsupported`, under a function the run
/// says it walked past — because a selected mutant that appears nowhere is
/// indistinguishable from one nothing was found for.
pub fn split_excluded(
  excluded: List(String),
  targets: List(select.FunctionTarget),
) -> #(List(select.FunctionTarget), List(select.FunctionTarget)) {
  list.partition(targets, fn(target) {
    !list.contains(excluded, target.function.name)
  })
}

/// Plans random input for one function, or says which wall was hit.
pub fn classify(
  context: typederive.Context,
  function: glance.Function,
) -> Result(typederive.FunctionPlan, String) {
  case function.publicity {
    glance.Private -> Error("private function")
    glance.Public ->
      case typederive.derive_function(context, function) {
        Error(reason) -> Error(reason)
        Ok(plan) ->
          case select.comparable_return(function) {
            False -> Error("return type contains a function")
            True -> Ok(plan)
          }
      }
  }
}

/// The Gleam module path of a source file: `src/app/util.gleam` is `app/util`.
///
/// A Windows separator is normalised to `/` first, and a path that is already
/// rooted outside `src/` is left where it is.
pub fn module_name(relative: String) -> String {
  let normalised = string.replace(relative, "\\", "/")
  let rooted = case string.starts_with(normalised, "src/") {
    True -> string.drop_start(normalised, 4)
    False -> normalised
  }
  case string.ends_with(rooted, ".gleam") {
    True -> string.drop_end(rooted, 6)
    False -> rooted
  }
}

/// A module path as one Gleam identifier: `app/util` is `app_util`.
fn flatten(module: String) -> String {
  string.replace(module, "/", "_")
}

// --- Generating, building and running ----------------------------------------

/// Instruments the snapshot, writes the probes, builds once and runs them.
///
/// Nothing is written when no function is worth probing: there would be no
/// mutant to resolve and no probe to run.
fn probe(
  request: Request,
  snapshot: Snapshot,
  catalogs: List(SourceCatalog),
  plans: List(ModulePlan),
  pbt_module: String,
) -> Result(List(#(String, List(ProbeResult))), String) {
  let root = snapshot.root(snapshot)
  case list.filter(plans, fn(plan) { plan.spec.functions != [] }) {
    [] -> Ok([])
    active -> {
      use module <- result.try(runtime.generate(root, snapshot.digest(snapshot)))
      use _ <- result.try(engine.instrument(
        root,
        catalogs,
        list.flat_map(active, fn(plan) { plan.probed }),
        runtime.name(module),
      ))
      use _ <- result.try(
        engine.write_generated_files(root, [
          #("src/" <> pbt_module <> ".gleam", pbt_source.source()),
          ..list.flat_map(active, fn(plan) {
            [
              #(
                "src/" <> plan.probe_module <> ".gleam",
                harness.render_probe(plan.spec),
              ),
              #(
                "src/" <> plan.ffi_module <> ".erl",
                harness.render_ffi(plan.spec),
              ),
            ]
          })
        ]),
      )
      use _ <- result.try(
        engine.build_targets(root, [outcome.Erlang])
        |> result.map_error(fn(error) {
          "GMU8003: the instrumented snapshot did not compile:\n" <> error
        }),
      )
      list.try_map(active, fn(plan) { run_probe(request, root, plan) })
    }
  }
}

fn run_probe(
  request: Request,
  root: String,
  plan: ModulePlan,
) -> Result(#(String, List(ProbeResult)), String) {
  let finished =
    platform.run_process(
      "gleam",
      ["run", "--target", "erlang", "-m", plan.probe_module],
      root,
      [],
      request.probe_timeout_ms,
    )
  case finished.timed_out, finished.status {
    True, _ ->
      Error(
        "GMU8004: the probe of `"
        <> plan.module
        <> "` timed out after "
        <> int.to_string(request.probe_timeout_ms)
        <> "ms:\n"
        <> finished.stdout
        <> finished.stderr,
      )
    False, 0 ->
      case probe_result.decode_output(finished.stdout) {
        #(results, []) -> Ok(#(plan.probe_module, results))
        #(_, failures) ->
          Error(
            "GMU8005: the probe of `"
            <> plan.module
            <> "` printed "
            <> int.to_string(list.length(failures))
            <> " lines that are not results:\n"
            <> string.join(failures, "\n"),
          )
      }
    False, status ->
      Error(
        "GMU8004: the probe of `"
        <> plan.module
        <> "` exited "
        <> int.to_string(status)
        <> ":\n"
        <> finished.stdout
        <> finished.stderr,
      )
  }
}

/// The verdict reported for a mutant of a function that could not be probed.
fn unsupported(function: String, item: Mutant, reason: String) -> ProbeResult {
  ProbeResult(
    function: function,
    mutant: item.id,
    status: Unsupported,
    inputs: [],
    expected: None,
    expected_inspect: "",
    expected_outcome: probe_result.Returned,
    actual_inspect: "",
    actual_outcome: probe_result.Returned,
    cases: 0,
    shrinks: 0,
    reason: reason,
    kills: [],
  )
}
