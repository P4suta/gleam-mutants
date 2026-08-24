// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// End-to-end smoke for the differential suggestion runner.
//
// It probes `fixtures/boundary_project`, whose every function is chosen to
// pin one branch of the runner down: a boundary only `0` tells apart, an
// equivalent mutant no input can kill, a custom type the probe has to build,
// an option-in/result-out pair, a private function and a function-typed
// parameter. Run it with
//
//     gleam run -m suggest_smoke --target erlang

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator.{type Operator}
import gleam_mutants/engine
import gleam_mutants/platform
import gleam_mutants/suggest/diff_runner
import gleam_mutants/suggest/probe_result.{
  type ProbeResult, type Status, Distinguished, Indistinguishable, Unsupported,
}

const workspace = "fixtures/boundary_project"

const source_file = "src/boundary.gleam"

pub fn main() {
  // Discovered up front, and outside the snapshot, so that a failure here
  // cannot leave a snapshot behind: mutant ids are stable across the copy.
  let assert Ok([catalog]) =
    engine.discover_catalogs(workspace, [source_file], operator.all())

  let request = diff_runner.defaults(workspace, [source_file])
  // A failure owns whatever snapshot it left behind: read the message, delete
  // the copy, and only then give up.
  let output = case diff_runner.run(request) {
    Ok(output) -> output
    Error(error) -> {
      case error.snapshot_root {
        Some(root) -> {
          let _ = platform.delete_tree(root)
          Nil
        }
        None -> Nil
      }
      io.println(diff_runner.describe(error))
      panic as "the differential run failed"
    }
  }

  let found = problems(request, output, catalog.mutants)
  let _ = platform.delete_tree(output.snapshot_root)

  list.each(found, io.println)
  assert found == []
  io.println(summary(output))
}

// --- The checks --------------------------------------------------------------

fn problems(
  request: diff_runner.Request,
  output: diff_runner.RunOutput,
  mutants: List(Mutant),
) -> List(String) {
  list.flatten([
    coverage_problems(output, mutants),
    survivor_problems(output, mutants),
    is_positive_problems(output, mutants),
    abs_problems(request, output, mutants),
    area_problems(output),
    maybe_double_problems(output, mutants),
    unsupported_problems(output, "helper", "private"),
    unsupported_problems(output, "applies", "function"),
    skipped_problems(output),
  ])
}

/// Every discovered mutant is accounted for exactly once, and nothing else is.
fn coverage_problems(
  output: diff_runner.RunOutput,
  mutants: List(Mutant),
) -> List(String) {
  let ids = list.map(mutants, fn(item) { item.id })
  let reported = list.map(output.results, fn(probe) { probe.mutant })
  let missing =
    list.filter(ids, fn(id) {
      list.count(reported, fn(other) { other == id }) != 1
    })
  let unknown = list.filter(reported, fn(id) { !list.contains(ids, id) })
  list.flatten([
    expect(mutants != [], "no mutants were discovered in " <> source_file),
    expect(
      missing == [],
      int.to_string(list.length(missing))
        <> " of "
        <> int.to_string(list.length(ids))
        <> " mutants are missing from the results or reported twice: "
        <> string.inspect(list.map(missing, short)),
    ),
    expect(
      unknown == [],
      "the results mention mutants that were never discovered: "
        <> string.inspect(list.map(unknown, short)),
    ),
    expect(
      output.unassigned_mutants == 0,
      int.to_string(output.unassigned_mutants)
        <> " mutants fell outside every function, expected none",
    ),
  ])
}

/// The mutants no input told apart, named one by one.
///
/// A mutant surviving the search is either a real equivalent mutant or a
/// search that got weaker, and counting them cannot tell the two apart: a
/// boundary the edge bias stopped reaching would swap places with an
/// equivalent mutant and leave the total where it was. Naming them pins which
/// is which. Both survivors are `abs` deciding on `0`, twice over: `0` is the
/// only value `value <= 0` reaches that `value < 0` does not, and the branch
/// it reaches computes `0 - 0`, which is the `0` the original branch returns
/// anyway. Turning that same literal into `1` says it the other way round.
fn survivor_problems(
  output: diff_runner.RunOutput,
  mutants: List(Mutant),
) -> List(String) {
  let survivors =
    output.results
    |> list.filter(fn(probe) { probe.status == Indistinguishable })
    |> list.map(fn(probe) { name_of(mutants, probe.function, probe.mutant) })
    |> list.sort(string.compare)
  expect(
    survivors == expected_survivors,
    "the mutants no input told apart are "
      <> string.inspect(survivors)
      <> ", expected "
      <> string.inspect(expected_survivors),
  )
}

const expected_survivors = [
  "abs line 22: 0 -> 1", "abs line 22: value < 0 -> value <= 0",
]

/// `value > 0` becoming `value >= 0` is told apart by `0` and nothing else.
fn is_positive_problems(
  output: diff_runner.RunOutput,
  mutants: List(Mutant),
) -> List(String) {
  let label = "is_positive `>` -> `>=`"
  case locate(output, mutants, "is_positive", operator.ComparisonBoundary) {
    Error(reason) -> [reason]
    Ok(probe) ->
      list.flatten([
        distinguished(probe, label),
        expect(
          probe.inputs == ["0"],
          label
            <> " shrank to "
            <> string.inspect(probe.inputs)
            <> ", expected [\"0\"]",
        ),
        expect(
          probe.expected == Some("False"),
          label
            <> " expected "
            <> string.inspect(probe.expected)
            <> ", wanted Some(\"False\")",
        ),
        expect(
          string.contains(probe.actual_inspect, "True"),
          label
            <> " reported the mutant as "
            <> probe.actual_inspect
            <> ", which never mentions True",
        ),
        // The one input that tells this mutant apart has to be drawn early
        // rather than stumbled on: a uniform `int` only reaches `0` on case
        // 182 of 200, which is one unlucky seed away from finding nothing.
        expect(
          probe.cases <= 50,
          label
            <> " needed "
            <> int.to_string(probe.cases)
            <> " cases, expected at most 50",
        ),
      ])
  }
}

/// `value < 0` becoming `value <= 0` leaves `abs` unchanged: no input can tell.
fn abs_problems(
  request: diff_runner.Request,
  output: diff_runner.RunOutput,
  mutants: List(Mutant),
) -> List(String) {
  let equivalent = "abs `<` -> `<=`"
  let boundary = case
    locate(output, mutants, "abs", operator.ComparisonBoundary)
  {
    Error(reason) -> [reason]
    Ok(probe) ->
      list.flatten([
        expect(
          probe.status == Indistinguishable,
          equivalent
            <> " is "
            <> probe_result.status_name(probe.status)
            <> ", expected indistinguishable: it is an equivalent mutant",
        ),
        expect(
          probe.cases == request.max_cases,
          equivalent
            <> " gave up after "
            <> int.to_string(probe.cases)
            <> " cases, expected the full "
            <> int.to_string(request.max_cases),
        ),
      ])
  }
  let arithmetic = case
    locate(output, mutants, "abs", operator.IntegerArithmetic)
  {
    Error(reason) -> [reason]
    Ok(probe) -> distinguished(probe, "abs `0 - value` -> `0 + value`")
  }
  list.append(boundary, arithmetic)
}

/// At least one `area` mutant is killed by a value of the custom type.
fn area_problems(output: diff_runner.RunOutput) -> List(String) {
  let witnessed =
    list.filter(output.results, fn(probe) {
      probe.function == "area"
      && probe.status == Distinguished
      && printable(probe.expected)
      && list.any(probe.inputs, constructed)
    })
  expect(
    witnessed != [],
    "no area mutant was distinguished by a `boundary.Circle(...)` or "
      <> "`boundary.Square(...)` input carrying a printable expected value",
  )
}

/// The option-in, result-out function reports source a test can paste.
fn maybe_double_problems(
  output: diff_runner.RunOutput,
  mutants: List(Mutant),
) -> List(String) {
  let doubling = "maybe_double `v + v` -> `v - v`"
  let arithmetic = case
    locate(output, mutants, "maybe_double", operator.IntegerArithmetic)
  {
    Error(reason) -> [reason]
    Ok(probe) ->
      list.flatten([
        distinguished(probe, doubling),
        expect(
          probe.inputs == ["Some(1)"] && probe.expected == Some("Ok(2)"),
          doubling
            <> " reported inputs "
            <> string.inspect(probe.inputs)
            <> " and expected "
            <> string.inspect(probe.expected)
            <> ", wanted [\"Some(1)\"] and Some(\"Ok(2)\")",
        ),
      ])
  }
  let missing = "maybe_double `\"missing\"` -> `\"\"`"
  let neutral = case
    locate(output, mutants, "maybe_double", operator.StringNeutral)
  {
    Error(reason) -> [reason]
    Ok(probe) ->
      list.flatten([
        distinguished(probe, missing),
        expect(
          probe.inputs == ["None"],
          missing
            <> " shrank to "
            <> string.inspect(probe.inputs)
            <> ", expected [\"None\"]",
        ),
        expect(
          probe.expected == Some("Error(\"missing\")"),
          missing
            <> " expected "
            <> string.inspect(probe.expected)
            <> ", wanted Some(\"Error(\\\"missing\\\")\")",
        ),
      ])
  }
  list.append(arithmetic, neutral)
}

/// Mutants of a function the probe cannot call are still reported, as
/// unsupported, with a reason that says which wall was hit.
fn unsupported_problems(
  output: diff_runner.RunOutput,
  function: String,
  fragment: String,
) -> List(String) {
  let reported =
    list.filter(output.results, fn(probe) { probe.function == function })
  let statuses =
    list.filter(reported, fn(probe) { probe.status != Unsupported })
  let reasons =
    list.filter(reported, fn(probe) { !string.contains(probe.reason, fragment) })
  list.flatten([
    expect(
      reported != [],
      "no results were reported for " <> function <> ", expected unsupported",
    ),
    expect(
      statuses == [],
      int.to_string(list.length(statuses))
        <> " results for "
        <> function
        <> " are not unsupported: "
        <> string.inspect(list.map(statuses, describe)),
    ),
    expect(
      reasons == [],
      int.to_string(list.length(reasons))
        <> " results for "
        <> function
        <> " give a reason that never mentions `"
        <> fragment
        <> "`: "
        <> string.inspect(list.map(reasons, fn(probe) { probe.reason })),
    ),
  ])
}

/// The functions the runner walked past are named in the skipped list.
fn skipped_problems(output: diff_runner.RunOutput) -> List(String) {
  let skipped = fn(name: String) -> Bool {
    list.any(output.skipped, fn(entry) {
      entry.module == "boundary" && entry.function == name
    })
  }
  list.flatten([
    expect(
      skipped("helper"),
      "`helper` is missing from the skipped list: "
        <> string.inspect(output.skipped),
    ),
    expect(
      skipped("applies"),
      "`applies` is missing from the skipped list: "
        <> string.inspect(output.skipped),
    ),
    expect(
      !skipped("is_positive"),
      "`is_positive` was skipped, expected it to be probed",
    ),
  ])
}

// --- Helpers -----------------------------------------------------------------

/// The one result for `function` whose mutant carries `kind`.
///
/// Every operator this smoke asks for appears at most once in the function it
/// asks about, so anything else is itself the failure.
fn locate(
  output: diff_runner.RunOutput,
  mutants: List(Mutant),
  function: String,
  kind: Operator,
) -> Result(ProbeResult, String) {
  let wanted =
    mutants
    |> list.filter(fn(item) { item.operator == kind })
    |> list.map(fn(item) { item.id })
  let matched =
    list.filter(output.results, fn(probe) {
      probe.function == function && list.contains(wanted, probe.mutant)
    })
  case matched {
    [only] -> Ok(only)
    [] ->
      Error(
        "no " <> operator.name(kind) <> " result was reported for " <> function,
      )
    many ->
      Error(
        int.to_string(list.length(many))
        <> " "
        <> operator.name(kind)
        <> " results were reported for "
        <> function
        <> ", expected exactly one",
      )
  }
}

/// One mutant written out: the function it lives in, the line it sits on and
/// the rewrite it makes. Two mutants of one function made by one operator are
/// told apart by that, which naming the operator alone would not do.
///
/// An id that is not one of the discovered mutants is `unknown`, which
/// `coverage_problems` is the one to report.
fn name_of(mutants: List(Mutant), function: String, id: String) -> String {
  case list.find(mutants, fn(item) { item.id == id }) {
    Ok(item) ->
      function
      <> " line "
      <> int.to_string(item.line)
      <> ": "
      <> item.original
      <> " -> "
      <> item.replacement
    Error(Nil) -> function <> " unknown"
  }
}

fn distinguished(probe: ProbeResult, label: String) -> List(String) {
  expect(
    probe.status == Distinguished,
    label
      <> " is "
      <> probe_result.status_name(probe.status)
      <> ", expected distinguished"
      <> case probe.reason {
      "" -> ""
      reason -> " (" <> reason <> ")"
    },
  )
}

fn expect(holds: Bool, message: String) -> List(String) {
  case holds {
    True -> []
    False -> [message]
  }
}

fn constructed(input: String) -> Bool {
  string.starts_with(input, "boundary.Circle(")
  || string.starts_with(input, "boundary.Square(")
}

fn printable(expected: Option(String)) -> Bool {
  case expected {
    Some(_) -> True
    None -> False
  }
}

fn describe(probe: ProbeResult) -> String {
  probe.function <> " " <> probe_result.status_name(probe.status)
}

fn short(id: String) -> String {
  string.slice(id, 0, 8)
}

fn summary(output: diff_runner.RunOutput) -> String {
  let counted = fn(status: Status) -> String {
    int.to_string(
      list.count(output.results, fn(probe) { probe.status == status }),
    )
  }
  "suggest smoke: "
  <> int.to_string(list.length(output.results))
  <> " mutants, "
  <> counted(Distinguished)
  <> " distinguished, "
  <> counted(Indistinguishable)
  <> " indistinguishable, "
  <> counted(Unsupported)
  <> " unsupported, "
  <> int.to_string(list.length(output.skipped))
  <> " functions skipped"
}
