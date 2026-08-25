// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The `suggest` and `explain` use case, with no command line anywhere in it.
//
// The CLI is one caller; a later `suggest --apply` and the `run` command are
// meant to be others, so everything here works in terms of a workspace path
// and a plain options record rather than argument vectors and exit codes.
//
// The interesting work is deliberately split into seams a test can drive
// without a real probe run: which mutants a `--mutant` prefix names, which of
// them the latest report saw survive, and which of a probe's verdicts are
// worth writing a test for once the redundant ones are covered by another.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam_mutants/config.{type Config}
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator
import gleam_mutants/core/path
import gleam_mutants/core/plan
import gleam_mutants/engine
import gleam_mutants/platform
import gleam_mutants/report
import gleam_mutants/suggest/diff_runner
import gleam_mutants/suggest/minimize
import gleam_mutants/suggest/probe_result.{type ProbeResult, type Status}
import gleam_mutants/suggest/render
import simplifile

/// One `suggest` or `explain` run, as the caller asked for it.
///
/// Every field that is `None` or empty leaves the workspace's own
/// configuration alone: `[tools.gleam_mutants.suggest]` supplies the seed and
/// the budgets, and the mutation `includes` supply the files. `changed`,
/// `includes`, `function` and `mutant_prefix` each narrow the selection
/// further, and `survivors_only` narrows it to the mutants the latest stored
/// report saw survive. `operators` narrows the selection to the named mutation
/// operators, exactly as `run --operator` and `list --operator` do, and an
/// empty list leaves every configured operator in play. `budget_ms` bounds one
/// whole probe process, and `style` picks the form the generated tests are
/// written in.
pub type SuggestOptions {
  SuggestOptions(
    changed: Option(String),
    includes: List(String),
    function: Option(String),
    mutant_prefix: Option(String),
    survivors_only: Bool,
    operators: List(operator.Operator),
    seed: Option(Int),
    max_cases: Option(Int),
    max_shrinks: Option(Int),
    budget_ms: Option(Int),
    style: Option(render.AssertStyle),
  )
}

/// One mutant no input told apart, and how hard the probe looked.
///
/// A mutant that survives the whole search is either equivalent to the
/// original or one the search was too weak to reach, so `cases` is reported
/// beside it: a verdict reached in the full budget says something a verdict
/// reached in ten cases does not.
pub type Indistinguishable {
  Indistinguishable(mutant: Mutant, function: String, cases: Int)
}

/// One mutant no test can be written for, and which wall was hit.
///
/// The function is carried beside the mutant because that is what a reader
/// acts on: `applies` cannot be probed at all, whichever of its mutants is
/// being reported.
pub type Unsupported {
  Unsupported(mutant: Mutant, function: String, reason: String)
}

/// Everything one `suggest` run found.
///
/// Every mutant the run selected is accounted for exactly once: either a
/// suggestion's `kills` names it, or `indistinguishable` says no input told it
/// apart, or `nondeterministic` says the original disagreed with itself, or
/// `unsupported` says why nothing can be written for it — a mutant outside
/// every function of its module included, which no probe can call.
///
/// `suggestions` is the fewest tests that still kill every mutant any single
/// test in the run could kill, so a suggestion's `kills` names more than the
/// mutant it was found from. `indistinguishable` and `unsupported` name the
/// mutants no suggestion covers and why, `nondeterministic` the mutants whose
/// original disagreed with itself so that no verdict was possible at all,
/// `skipped` the functions the probe walked past, and `survivors_missing` the
/// selected files the latest report has nothing to say about — which is the
/// difference between "this file has no survivors" and "this file was never
/// run". `distinguishable` names every mutant an input told apart, writable
/// test or not — the ones refused as unwritable, as inexpressible or as bound
/// to this machine included — so a caller can say how many of them the kept
/// suggestions really kill. `style` is the form the tests are meant to be written in,
/// resolved from the flag and the configuration once, so that every caller
/// renders the same run the same way.
/// `snapshot_root` is the copy the run worked in, already deleted by the time
/// the report is answered, and empty when there was nothing to probe.
/// `unmatched_function` holds the `--function` name the probe never saw, which
/// is the difference between a function with nothing left to kill and a
/// mistyped one: every count below is zero either way.
pub type Report {
  Report(
    suggestions: List(render.Suggestion),
    indistinguishable: List(Indistinguishable),
    nondeterministic: List(Unsupported),
    unsupported: List(Unsupported),
    skipped: List(diff_runner.Skipped),
    survivors_missing: List(String),
    distinguishable: List(String),
    style: render.AssertStyle,
    snapshot_root: String,
    unmatched_function: Option(String),
  )
}

/// One mutant explained: what it changes, what separates it, and what to write.
///
/// `test_source` holds the generated test when the probe distinguished the
/// mutant; otherwise it is `None` and `reason` says which wall was hit. The
/// two inspects are what the original and the mutant each answered on
/// `inputs`.
pub type Explanation {
  Explanation(
    mutant: Mutant,
    function: String,
    status: Status,
    inputs: List(String),
    expected: Option(String),
    expected_inspect: String,
    actual_inspect: String,
    test_source: Option(String),
    reason: String,
  )
}

/// A request that narrows nothing and overrides nothing.
pub fn default_options() -> SuggestOptions {
  SuggestOptions(
    changed: None,
    includes: [],
    function: None,
    mutant_prefix: None,
    survivors_only: False,
    operators: [],
    seed: None,
    max_cases: None,
    max_shrinks: None,
    budget_ms: None,
    style: None,
  )
}

/// Probes the selected mutants and answers with the tests that kill them.
///
/// The snapshot the run works in is deleted before the report is answered,
/// on success and on failure alike.
pub fn suggest(
  workspace: String,
  options: SuggestOptions,
) -> Result(Report, String) {
  use probed <- result.map(probe(workspace, options, Everything))
  reported(probed)
}

/// Probes exactly the mutants `survivors` names, whatever storage says.
///
/// `run --suggest` has just finished the run whose survivors these are, so
/// asking `--survivors` to read them back out of a stored report could only
/// fail the runs that need it most: `history = false` and `--report none`
/// both leave nothing behind to read. Everything else the options say still
/// applies, the seed and the budgets included.
pub fn suggest_survivors(
  workspace: String,
  options: SuggestOptions,
  survivors: List(String),
) -> Result(Report, String) {
  use probed <- result.map(probe(workspace, options, Only(survivors)))
  reported(probed)
}

/// One probe run split into the report a caller reads.
fn reported(probed: Probed) -> Report {
  Report(
    ..summarise(
      results: probed.results,
      mutants: probed.mutants,
      skipped: probed.skipped,
      survivors_missing: probed.survivors_missing,
      style: probed.style,
      snapshot_root: probed.snapshot_root,
      machine: machine(),
    ),
    unmatched_function: probed.unmatched_function,
  )
}

/// Splits one probe's verdicts into the report a caller reads.
///
/// `mutants` is what the run is accountable for, and every one of them lands
/// in the report: the verdicts settle the ones they mention, and `unreported`
/// settles the rest. Nothing here runs a probe, so this is where the whole
/// shape of a report can be pinned without copying a workspace. Only the run
/// itself knows whether a `--function` name was ever seen, so the report this
/// answers with leaves `unmatched_function` empty for `suggest` to fill in.
pub fn summarise(
  results results: List(ProbeResult),
  mutants mutants: List(Mutant),
  skipped skipped: List(diff_runner.Skipped),
  survivors_missing survivors_missing: List(String),
  style style: render.AssertStyle,
  snapshot_root snapshot_root: String,
  machine machine: render.Machine,
) -> Report {
  let judged = list.append(results, unreported(mutants, results))
  let known = index(mutants)
  // Every mutant an input told apart, before any of the walls below: a mutant
  // separated by an input and then refused is still one the run separated, and
  // a count that dropped it would flatter the run it is reporting on.
  let separated = candidates(judged, mutants)
  let #(statable, alike) = list.partition(judged, statable)
  // A suggestion whose values only hold on this machine is not a suggestion:
  // committed, it fails for everyone else.
  let #(candidates, unportable) =
    list.partition(candidates(statable, mutants), fn(candidate) {
      !render.machine_specific(candidate, machine)
    })
  Report(
    suggestions: minimal(candidates),
    indistinguishable: unseparated(judged, known),
    nondeterministic: unstable(judged, known),
    unsupported: list.flatten([
      unprobed(statable, known),
      inexpressible(alike, known),
      unwritable(candidates, known, style),
      machine_bound(unportable, known),
    ]),
    skipped: skipped,
    survivors_missing: survivors_missing,
    distinguishable: list.map(separated, fn(candidate) { candidate.mutant_id }),
    style: style,
    snapshot_root: snapshot_root,
    unmatched_function: None,
  )
}

/// Explains the one mutant `display_id_prefix` names, without minimising.
///
/// Nothing is dropped as redundant here: the caller asked about this mutant,
/// so the input that separates it is reported even when another suggestion
/// would have killed it too.
pub fn explain(
  workspace: String,
  display_id_prefix: String,
  options: SuggestOptions,
) -> Result(Explanation, String) {
  use probed <- result.try(probe(
    workspace,
    SuggestOptions(..options, mutant_prefix: Some(display_id_prefix)),
    Everything,
  ))
  let known = index(probed.mutants)
  let judged =
    list.append(probed.results, unreported(probed.mutants, probed.results))
  // Read once, and the same way `summarise` reads it: one command must not
  // print the test the other refuses.
  let here = machine()
  case
    list.filter_map(judged, fn(verdict) {
      dict.get(known, verdict.mutant)
      |> result.map(explained(_, verdict, probed.style, here))
    })
  {
    [explanation, ..] -> Ok(explanation)
    // Everything the probe reached is explained, including a mutant it could
    // not call at all, so the only way to arrive here is a mutant this run
    // narrowed away before probing anything.
    [] ->
      Error(
        "GMU8011: mutant "
        <> string.inspect(display_id_prefix)
        <> " was left out of this run by --changed, --include, --function or"
        <> " --survivors",
      )
  }
}

/// One `Unsupported` verdict per selected mutant no verdict mentions.
///
/// The probe is given one target per function, so a mutant that falls outside
/// every function of its module — a module constant's, for instance — is never
/// called and never judged. Reporting it as unsupported is what keeps a run
/// honest: a mutant the caller selected has to appear somewhere, and "nothing
/// to do" and "silently dropped" are not the same answer.
pub fn unreported(
  mutants: List(Mutant),
  results: List(ProbeResult),
) -> List(ProbeResult) {
  let judged = set.from_list(list.map(results, fn(verdict) { verdict.mutant }))
  mutants
  |> list.filter(fn(item) { !set.contains(judged, item.id) })
  |> list.map(fn(item) {
    probe_result.ProbeResult(
      function: "",
      mutant: item.id,
      status: probe_result.Unsupported,
      inputs: [],
      expected: None,
      expected_inspect: "",
      expected_outcome: probe_result.Returned,
      actual_inspect: "",
      actual_outcome: probe_result.Returned,
      cases: 0,
      shrinks: 0,
      reason: outside_every_function,
      kills: [],
    )
  })
}

/// Why a mutant no verdict mentions has no test: nothing can call it.
const outside_every_function = "not inside a function, so the probe has nothing to call"

/// The `--function` name this run asked about and never found, if any.
///
/// `results` are the probe's own verdicts, before the selection narrows them:
/// the probe is told one function at a time, so a name it reports nothing
/// about is a name no selected file has a mutant in — a typo, or a function
/// whose mutants all live somewhere else. A run that narrowed nothing has
/// nothing to report back.
pub fn unmatched_function(
  function: Option(String),
  results: List(ProbeResult),
) -> Option(String) {
  case function {
    None -> None
    Some(name) ->
      case list.any(results, fn(verdict) { verdict.function == name }) {
        True -> None
        False -> Some(name)
      }
  }
}

/// The mutants a `--mutant` prefix names, or every one of them for `None`.
///
/// The prefix matches a full id or a display id, exactly as `run --mutant`
/// matches one, and an ambiguous prefix is refused rather than resolved to
/// whichever mutant happens to come first.
pub fn matching(
  mutants: List(Mutant),
  prefix: Option(String),
) -> Result(List(Mutant), String) {
  plan.build(mutants, False, prefix)
  |> result.map(plan.mutants)
}

/// Narrows a selection to the mutants the latest stored report saw survive.
///
/// The second element names the selected files that report never mentions:
/// their mutants are dropped along with the killed ones, and a caller that
/// says so is the difference between a file with no survivors and a file the
/// last run never covered.
pub fn keep_survivors(
  mutants: List(Mutant),
  report_json: String,
) -> Result(#(List(Mutant), List(String)), String) {
  use survivors <- result.try(report.survivor_ids(report_json))
  use covered <- result.map(report.covered_paths(report_json))
  let alive = set.from_list(survivors)
  let seen = set.from_list(covered)
  #(
    list.filter(mutants, fn(item) { set.contains(alive, item.id) }),
    files_of(mutants) |> list.filter(fn(file) { !set.contains(seen, file) }),
  )
}

/// The fewest suggestions that still kill every mutant the results kill.
///
/// One candidate is built per distinguished result, keyed by its own mutant
/// and covering the ids in its `kills`, and the candidates are covered
/// greedily one function at a time — a test for `abs` can never kill a mutant
/// of `is_positive`, so minimising across functions would only make the
/// choice worse. A result whose mutant is not in `mutants` is dropped: there
/// is no operator, location or module path to write a test about, and so is
/// one no test can be written from at all.
pub fn suggestions(
  results: List(ProbeResult),
  mutants: List(Mutant),
) -> List(render.Suggestion) {
  minimal(candidates(results, mutants))
}

// --- Running the probe -------------------------------------------------------

/// One probe run, narrowed to the mutants the caller asked about.
///
/// `mutants` is what the run is accountable for, which is every selected
/// mutant — the ones no verdict mentions included, since those are exactly the
/// ones a report would otherwise lose.
/// The mutants one probe run is asked about.
type Selection {
  /// Everything the options select, narrowed by `--survivors` when asked.
  Everything
  /// Exactly these mutant ids, whatever a stored report has to say.
  Only(List(String))
}

type Probed {
  Probed(
    results: List(ProbeResult),
    mutants: List(Mutant),
    skipped: List(diff_runner.Skipped),
    survivors_missing: List(String),
    style: render.AssertStyle,
    snapshot_root: String,
    unmatched_function: Option(String),
  )
}

/// Selects the mutants, probes the files holding them, and throws the copy
/// away.
///
/// The selection is settled before anything is probed, so a mistyped prefix or
/// a `--survivors` run with no stored report fails without copying the
/// workspace at all. A selection that names no mutant is not a failure: there
/// is simply nothing to probe, and the empty run is reported as one.
fn probe(
  workspace: String,
  options: SuggestOptions,
  selection: Selection,
) -> Result(Probed, String) {
  use manifest <- result.try(read_manifest(workspace))
  use configured <- result.try(
    config.decode(manifest, platform.cpu_count())
    |> result.map_error(config.describe_error),
  )
  let style = assert_style(configured, options)
  use listed <- result.try(engine.list_mutants(
    workspace,
    selection_options(options),
    False,
  ))
  use selected <- result.try(matching(listed.mutants, options.mutant_prefix))
  use narrowed <- result.try(narrow(workspace, selected, options, selection))
  let #(chosen, missing) = narrowed
  case files_of(chosen) {
    [] ->
      Ok(Probed(
        results: [],
        mutants: [],
        skipped: [],
        survivors_missing: missing,
        style: style,
        snapshot_root: "",
        // Nothing was probed, so nothing was looked for: a selection that
        // holds no mutant says nothing about whether the function exists.
        unmatched_function: None,
      ))
    files -> {
      use output <- result.map(
        diff_runner.run(request(workspace, files, chosen, configured, options))
        |> result.map_error(discarding),
      )
      let _ = platform.delete_tree(output.snapshot_root)
      let wanted = set.from_list(list.map(chosen, fn(item) { item.id }))
      let reported =
        list.filter(output.results, fn(verdict) {
          set.contains(wanted, verdict.mutant)
        })
      Probed(
        results: reported,
        mutants: accountable(chosen, reported, options.function),
        skipped: walked_past(output.skipped, reported, output.mutants),
        survivors_missing: missing,
        style: style,
        snapshot_root: output.snapshot_root,
        unmatched_function: unmatched_function(options.function, output.results),
      )
    }
  }
}

/// The selection narrowed to the mutants this run is about.
fn narrow(
  workspace: String,
  selected: List(Mutant),
  options: SuggestOptions,
  selection: Selection,
) -> Result(#(List(Mutant), List(String)), String) {
  case selection {
    Everything -> survivors(workspace, selected, options)
    Only(ids) -> {
      let wanted = set.from_list(ids)
      Ok(
        #(list.filter(selected, fn(item) { set.contains(wanted, item.id) }), []),
      )
    }
  }
}

/// The selection narrowed to survivors, with the files the report never saw.
fn survivors(
  workspace: String,
  selected: List(Mutant),
  options: SuggestOptions,
) -> Result(#(List(Mutant), List(String)), String) {
  case options.survivors_only {
    False -> Ok(#(selected, []))
    True -> {
      use stored <- result.try(
        report.latest(workspace)
        |> result.map_error(fn(error) {
          "GMU8010: --survivors needs a stored report for this workspace: "
          <> error
        }),
      )
      keep_survivors(selected, stored)
    }
  }
}

/// Throws away the snapshot a failed run left behind, and says what failed.
///
/// The runner hands its copy to the caller so the generated probes can be
/// read; a command line has nobody to read them, so the copy goes and the
/// message is written as if there had never been one.
fn discarding(error: diff_runner.RunError) -> String {
  let _ = case error.snapshot_root {
    Some(root) -> platform.delete_tree(root)
    None -> Ok(Nil)
  }
  diff_runner.describe(diff_runner.RunError(..error, snapshot_root: None))
}

/// The mutants this run is accountable for reporting on.
///
/// Every selected mutant, unless `--function` narrowed the probe to a single
/// function: that run was never asked about the mutants outside it, and naming
/// every one of them as unprobed would bury the answer it was asked for.
fn accountable(
  selected: List(Mutant),
  reported: List(ProbeResult),
  function: Option(String),
) -> List(Mutant) {
  case function {
    None -> selected
    Some(_) -> {
      let judged =
        set.from_list(list.map(reported, fn(verdict) { verdict.mutant }))
      list.filter(selected, fn(item) { set.contains(judged, item.id) })
    }
  }
}

/// The functions the probe walked past that this selection has a mutant in.
///
/// A skipped function is worth naming because its mutants have no test to
/// kill them; one this run selected nothing in has nothing for the reader to
/// act on, and counting it would describe a wider run than the one asked for.
fn walked_past(
  skipped: List(diff_runner.Skipped),
  reported: List(ProbeResult),
  mutants: List(Mutant),
) -> List(diff_runner.Skipped) {
  let touched = set.from_list(named_functions(reported, mutants))
  list.filter(skipped, fn(entry) {
    set.contains(touched, #(entry.module, entry.function))
  })
}

/// The module-and-function pairs a run's own verdicts name, in their order.
fn named_functions(
  results: List(ProbeResult),
  mutants: List(Mutant),
) -> List(#(String, String)) {
  let known = index(mutants)
  results
  |> list.map(fn(verdict) {
    let module = case dict.get(known, verdict.mutant) {
      Ok(item) -> diff_runner.module_name(item.path)
      Error(Nil) -> ""
    }
    #(module, verdict.function)
  })
  |> list.unique
}

/// The mutation selection a suggest run asks the engine for.
///
/// `--operator` overrides the workspace's own operator list the way it does
/// for `run` and `list`, so that the mutants this run accounts for and the
/// mutants it probes are chosen by one rule rather than two.
fn selection_options(options: SuggestOptions) -> engine.Options {
  engine.Options(
    ..engine.default_options(),
    changed: options.changed,
    includes: options.includes,
    operators: case options.operators {
      [] -> None
      chosen -> Some(chosen)
    },
  )
}

/// The differential request: the configured budgets, with the flags on top.
///
/// `chosen` is the selection itself rather than the flags that made it, so the
/// probe instruments exactly the mutants this run is accountable for: a run
/// narrowed to one mutant or to a report's survivors compiles that much and no
/// more.
fn request(
  workspace: String,
  files: List(String),
  chosen: List(Mutant),
  configured: Config,
  options: SuggestOptions,
) -> diff_runner.Request {
  diff_runner.Request(
    ..diff_runner.defaults(workspace, files),
    function_filter: options.function,
    operators: options.operators,
    mutants: Some(list.map(chosen, fn(item) { item.id })),
    seed: option.unwrap(options.seed, configured.suggest.seed),
    max_cases: option.unwrap(options.max_cases, configured.suggest.max_cases),
    max_shrinks: option.unwrap(
      options.max_shrinks,
      configured.suggest.max_shrinks,
    ),
    call_timeout_ms: configured.suggest.call_timeout_ms,
    probe_timeout_ms: option.unwrap(
      options.budget_ms,
      configured.suggest.probe_timeout_ms,
    ),
    exclude_functions: configured.suggest.exclude_functions,
  )
}

/// The style the generated tests are written in: the flag, else the section.
fn assert_style(
  configured: Config,
  options: SuggestOptions,
) -> render.AssertStyle {
  case options.style {
    Some(chosen) -> chosen
    None ->
      case configured.suggest.assert_style {
        config.AssertKeyword -> render.AssertKeyword
        config.ShouldEqual -> render.ShouldEqual
      }
  }
}

fn read_manifest(workspace: String) -> Result(String, String) {
  simplifile.read(path.join(workspace, "gleam.toml"))
  |> result.map_error(fn(error) {
    "could not read gleam.toml: " <> simplifile.describe_error(error)
  })
}

// --- Reading the verdicts ----------------------------------------------------

/// One candidate suggestion per distinguished verdict of a known mutant.
fn candidates(
  results: List(ProbeResult),
  mutants: List(Mutant),
) -> List(render.Suggestion) {
  let known = index(mutants)
  let selected = set.from_list(list.map(mutants, fn(item) { item.id }))
  results
  |> list.filter(fn(verdict) { verdict.status == probe_result.Distinguished })
  |> list.filter_map(fn(verdict) {
    dict.get(known, verdict.mutant)
    |> result.map(suggestion(_, verdict, selected))
  })
}

/// The candidates worth keeping: writable, and not covered by another.
fn minimal(candidates: List(render.Suggestion)) -> List(render.Suggestion) {
  let written = list.filter(candidates, render.renderable)
  written
  |> list.map(fn(candidate) { candidate.function })
  |> list.unique
  |> list.flat_map(fn(function) {
    written
    |> list.filter(fn(candidate) { candidate.function == function })
    |> list.map(fn(candidate) { #(candidate, candidate.kills) })
    |> minimize.cover
  })
}

/// Everything one generated test needs to know about one verdict.
///
/// `selected` names the mutants this run chose. The probe is told every mutant
/// of the function it probes, so a run narrowed by `--mutant`, `--survivors`
/// or `--include` gets verdicts that also name mutants outside the selection,
/// and `kills` is cut back to the selection before it is reported: a run that
/// says it kills three mutants while accounting for one is a run whose two
/// numbers cannot both be checked against the same report.
fn suggestion(
  item: Mutant,
  verdict: ProbeResult,
  selected: set.Set(String),
) -> render.Suggestion {
  render.Suggestion(
    module_path: diff_runner.module_name(item.path),
    function: verdict.function,
    mutant_id: item.id,
    display_id: item.display_id,
    operator: operator.name(item.operator),
    location: location(item),
    original: item.original,
    replacement: item.replacement,
    inputs: verdict.inputs,
    expected: verdict.expected,
    expected_inspect: verdict.expected_inspect,
    expected_outcome: verdict.expected_outcome,
    actual_inspect: verdict.actual_inspect,
    actual_outcome: verdict.actual_outcome,
    // The probe reports every mutant one input separates, its own included;
    // naming it here as well keeps a suggestion honest about what it kills
    // even when a probe answered with nothing at all.
    kills: list.unique([
      item.id,
      ..list.filter(verdict.kills, set.contains(selected, _))
    ]),
  )
}

/// The mutants no input told apart, and how many inputs were tried.
fn unseparated(
  results: List(ProbeResult),
  known: Dict(String, Mutant),
) -> List(Indistinguishable) {
  list.filter_map(results, fn(verdict) {
    case verdict.status {
      probe_result.Indistinguishable ->
        dict.get(known, verdict.mutant)
        |> result.map(Indistinguishable(_, verdict.function, verdict.cases))
      _ -> Error(Nil)
    }
  })
}

/// The mutants the probe could not judge at all, and why.
fn unprobed(
  results: List(ProbeResult),
  known: Dict(String, Mutant),
) -> List(Unsupported) {
  list.filter_map(results, fn(verdict) {
    case verdict.status {
      probe_result.Unsupported ->
        dict.get(known, verdict.mutant)
        |> result.map(Unsupported(_, verdict.function, wall(verdict)))
      _ -> Error(Nil)
    }
  })
}

/// The mutants whose original disagreed with itself, so no verdict holds.
///
/// This is a status of its own rather than a kind of `unsupported`: nothing is
/// wrong with the mutant, the function under test simply does not answer the
/// same way twice, and a reader who has to string-match a reason to learn that
/// is reading a report that never said it.
fn unstable(
  results: List(ProbeResult),
  known: Dict(String, Mutant),
) -> List(Unsupported) {
  list.filter_map(results, fn(verdict) {
    case verdict.status {
      probe_result.Nondeterministic ->
        dict.get(known, verdict.mutant)
        |> result.map(Unsupported(_, verdict.function, wall(verdict)))
      _ -> Error(Nil)
    }
  })
}

/// Whether a verdict's two sides are told apart by something a test could say.
///
/// The probe already refuses to call a rendering-identical pair a separation;
/// this is the host refusing the same thing on its own account, because a
/// suggestion built from one would assert something the mutant satisfies too.
/// A call that never returned is left alone: it carries no rendering by
/// contract, and `unwritable` is the one that has something to say about it.
fn statable(verdict: ProbeResult) -> Bool {
  verdict.status != probe_result.Distinguished
  || verdict.expected_outcome != probe_result.Returned
  || verdict.actual_outcome != probe_result.Returned
  || verdict.expected_inspect != verdict.actual_inspect
}

/// The mutants an input divided from the original in a way nothing can state.
fn inexpressible(
  results: List(ProbeResult),
  known: Dict(String, Mutant),
) -> List(Unsupported) {
  list.filter_map(results, fn(verdict) {
    dict.get(known, verdict.mutant)
    |> result.map(Unsupported(
      _,
      verdict.function,
      probe_result.inexpressible_reason,
    ))
  })
}

/// The mutants whose separating values only hold on the machine that found
/// them.
///
/// A generated test is committed and then run elsewhere, so an input or an
/// expected value naming this machine's home, cache or temporary directory —
/// or any absolute path — is a test that fails for everyone else. Reporting it
/// beside the mutants nothing could be written for is the honest answer.
fn machine_bound(
  candidates: List(render.Suggestion),
  known: Dict(String, Mutant),
) -> List(Unsupported) {
  list.filter_map(candidates, fn(candidate) {
    dict.get(known, candidate.mutant_id)
    |> result.map(Unsupported(
      _,
      candidate.function,
      render.machine_specific_reason,
    ))
  })
}

/// The mutants an input separated but no assertion can state.
///
/// A call that panicked or ran out of time has no value to compare against, so
/// the verdict is real and the test is not: reporting it beside the mutants
/// the probe never judged is the only way it reaches the reader at all.
fn unwritable(
  candidates: List(render.Suggestion),
  known: Dict(String, Mutant),
  style: render.AssertStyle,
) -> List(Unsupported) {
  candidates
  |> list.filter(fn(candidate) { !render.renderable(candidate) })
  |> list.filter_map(fn(candidate) {
    case
      dict.get(known, candidate.mutant_id),
      render.test_source(render.scope([candidate], style), candidate)
    {
      Ok(item), Error(reason) ->
        Ok(Unsupported(item, candidate.function, reason))
      _, _ -> Error(Nil)
    }
  })
}

/// One mutant written out for a reader, test source and all.
///
/// Public because it is the whole of what `explain` decides once the probe has
/// answered, and because it has to decide it exactly as `summarise` does: the
/// same verdict must not be a refusal in one command and a test to paste in
/// the other. `machine` is what the answer is measured against, so a test can
/// hand it a machine of its own.
pub fn explained(
  item: Mutant,
  verdict: ProbeResult,
  style: render.AssertStyle,
  machine: render.Machine,
) -> Explanation {
  let found = suggestion(item, verdict, set.from_list([item.id]))
  // One explanation is one file's worth of generated test, so the names it
  // reports are settled against a scope holding exactly that one suggestion.
  let scope = render.scope([found], style)
  let candidate = render.rendered(scope, found)
  // The same three walls `summarise` puts in front of a suggestion stand
  // here: `explain` prints the test a reader is invited to paste, so a value
  // only this machine holds has to be refused by both, or the two commands
  // contradict each other about one mutant.
  let written = case verdict.status, statable(verdict) {
    probe_result.Distinguished, True ->
      case render.machine_specific(candidate, machine) {
        True -> Error(render.machine_specific_reason)
        False -> render.test_source(scope, candidate)
      }
    probe_result.Distinguished, False ->
      Error(probe_result.inexpressible_reason)
    _, _ -> Error(wall(verdict))
  }
  Explanation(
    mutant: item,
    function: verdict.function,
    status: verdict.status,
    // The values are named the way the test source names them: an
    // explanation that printed one name above and another below would be
    // reporting two different calls.
    inputs: candidate.inputs,
    expected: candidate.expected,
    expected_inspect: verdict.expected_inspect,
    actual_inspect: verdict.actual_inspect,
    test_source: option.from_result(written),
    reason: case written {
      Ok(_) -> ""
      Error(reason) -> reason
    },
  )
}

/// Why nothing can be written about a verdict: the probe's own words, or the
/// standing meaning of its status when it had none.
fn wall(verdict: ProbeResult) -> String {
  case verdict.reason {
    "" ->
      case verdict.status {
        probe_result.Distinguished -> "an input separated this mutant"
        probe_result.Indistinguishable ->
          "no input told this mutant apart from the original"
        probe_result.Nondeterministic ->
          "the original disagreed with itself, so no verdict is possible"
        probe_result.Unsupported -> "this function could not be probed"
      }
    given -> given
  }
}

// --- Helpers -----------------------------------------------------------------

/// The directories of the machine this run is happening on.
///
/// A generated test that names one of them passes here and fails everywhere
/// else, so `summarise` is told what they are and refuses to write one.
fn machine() -> render.Machine {
  render.Machine(
    home: case platform.env("HOME") {
      "" -> platform.env("USERPROFILE")
      value -> value
    },
    cache: platform.cache_directory(),
    temporary: platform.temporary_directory(),
  )
}

/// The discovered mutants by id, so a verdict is matched in one lookup.
fn index(mutants: List(Mutant)) -> Dict(String, Mutant) {
  mutants
  |> list.map(fn(item) { #(item.id, item) })
  |> dict.from_list
}

/// The distinct files a selection lives in, in the order it names them.
fn files_of(mutants: List(Mutant)) -> List(String) {
  mutants
  |> list.map(fn(item) { item.path })
  |> list.unique
}

/// `path:line:column`, as every other command prints a mutant's location.
fn location(item: Mutant) -> String {
  item.path
  <> ":"
  <> int.to_string(item.line)
  <> ":"
  <> int.to_string(item.column)
}
