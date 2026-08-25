// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// End-to-end smoke for the `suggest` and `explain` commands, driven the way a
// user drives them: through the built command line, on a real fixture, with
// nothing stubbed.
//
// `suggest_smoke` already pins what the differential runner finds in
// `fixtures/boundary_project`. This one pins what reaches the terminal: that
// Suggest JSON v1 carries the boundary test a reader can paste, that the
// mutants no input told apart and the functions the probe could not call are
// still reported, that the one mutant nobody can build is reported beside the
// good one on its own line rather than taking the file down, that every mutant
// `list` discovers is accounted for, that a run narrowed to one mutant counts
// only that mutant, that a `--function` name the selection narrowed away is
// reported as the empty selection it is rather than as an empty file, that
// `--operator` narrows a run the way it narrows `run`, that the import hints
// merge into one line per module, that text mode says how many suggestions
// there are, that `explain` can name one mutant and show the input that kills
// it, and that a `run --suggest` whose suggestions are refused says why once
// beside a run that still succeeded.
//
// Four legs work on a throwaway copy of the fixture rather than on the fixture
// itself: `--survivors`, which needs a stored report and so needs a run to
// store one, the exclusion the workspace's own configuration asks for, the
// module a stored report never covered, and the JavaScript test target that
// leaves `run --suggest` with nothing to suggest. Run it with
//
//     gleam run -m suggest_cli_smoke --target erlang

import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import gleam_mutants/cache
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/report
import simplifile

const workspace = "fixtures/boundary_project"

/// The test the boundary mutant of `is_positive` can only be killed by.
const boundary_assertion = "assert boundary.is_positive(0) == False"

pub fn main() {
  let json_run = run_cli(["suggest", "--root", workspace, "--json"])
  let text_run = run_cli(["suggest", "--root", workspace])
  let #(output_problems, boundary_id, equivalent_id) = case
    decode_output(extract_json(json_run.stdout))
  {
    Error(reason) -> #([reason], "", "")
    Ok(output) -> #(
      list.flatten([
        report_problems(output),
        accounting_problems(output),
        import_problems(output, text_run.stdout),
      ]),
      boundary_display_id(output),
      equivalent_display_id(output),
    )
  }
  let narrowed = case boundary_id {
    "" -> []
    id -> list.append(narrowed_problems(id), crossed_filter_problems(id))
  }
  let explained = case boundary_id {
    "" -> [
      "no is_positive boundary suggestion was reported, so `explain` was "
      <> "never run",
    ]
    id -> explain_problems(id)
  }
  let equivalent = case equivalent_id {
    "" -> [
      "no indistinguishable mutant was reported, so `explain` was never "
      <> "asked about one",
    ]
    id -> explain_indistinguishable_problems(id)
  }
  let found =
    list.flatten([
      status_problems("suggest --json", json_run),
      output_problems,
      text_problems(text_run),
      narrowed,
      explained,
      equivalent,
      unknown_function_problems(),
      operator_problems(),
      exclusion_problems(),
      survivors_problems(),
      javascript_target_problems(),
    ])

  list.each(found, io.println)
  assert found == []
  io.println(
    "suggest cli smoke: JSON, text and explain agree on "
    <> workspace
    <> "; boundary mutant "
    <> string.slice(boundary_id, 0, 8),
  )
}

// --- The checks --------------------------------------------------------------

/// A command that has to succeed, and the output it left when it did not.
fn status_problems(label: String, run: platform.ProcessResult) -> List(String) {
  expect(
    run.status == 0,
    label
      <> " exited "
      <> int.to_string(run.status)
      <> ", expected 0\nstdout:\n"
      <> run.stdout
      <> "\nstderr:\n"
      <> run.stderr,
  )
}

/// Everything Suggest JSON v1 has to say about the fixture.
fn report_problems(output: SuggestOutput) -> List(String) {
  list.flatten([
    expect(
      output.schema_version == 1,
      "schema_version is "
        <> int.to_string(output.schema_version)
        <> ", expected 1",
    ),
    boundary_problems(output),
    indistinguishable_problems(output),
    unsupported_problems(output),
    uncompilable_problems(output),
    expect(
      output.nondeterministic == [],
      "nondeterministic is "
        <> string.inspect(
        list.map(output.nondeterministic, fn(entry) { entry.function }),
      )
        <> ", expected nothing: every function of the fixture is a function of "
        <> "its arguments",
    ),
    expect(
      output.survivors_missing == [],
      "survivors_missing is "
        <> string.inspect(output.survivors_missing)
        <> ", expected nothing: --survivors was never asked for",
    ),
  ])
}

/// The one suggestion a reader is meant to paste into `boundary_test.gleam`.
fn boundary_problems(output: SuggestOutput) -> List(String) {
  case boundary_suggestion(output) {
    [] -> [
      "no comparison-boundary suggestion was reported for is_positive; the "
      <> "suggestions are "
      <> string.inspect(
        list.map(output.suggestions, fn(suggestion) {
          suggestion.function <> " " <> suggestion.operator
        }),
      ),
    ]
    [_, _, ..] -> [
      "more than one comparison-boundary suggestion was reported for "
      <> "is_positive, expected exactly one",
    ]
    [suggestion] ->
      list.flatten([
        expect(
          suggestion.inputs == ["0"],
          "the is_positive boundary suggestion calls with "
            <> string.inspect(suggestion.inputs)
            <> ", expected [\"0\"]",
        ),
        expect(
          suggestion.expected == Some("False"),
          "the is_positive boundary suggestion expects "
            <> string.inspect(suggestion.expected)
            <> ", wanted Some(\"False\")",
        ),
        expect(
          string.contains(suggestion.test_source, boundary_assertion),
          "the generated test never states `"
            <> boundary_assertion
            <> "`:\n"
            <> suggestion.test_source,
        ),
        expect(
          suggestion.module_path == "boundary",
          "the suggestion names module_path "
            <> string.inspect(suggestion.module_path)
            <> ", expected \"boundary\"",
        ),
        expect(
          list.contains(suggestion.imports, "import boundary"),
          "the suggestion's imports are "
            <> string.inspect(suggestion.imports)
            <> ", which never import the module under test",
        ),
        expect(
          list.contains(suggestion.kills, suggestion.mutant_id),
          "the suggestion's kills are "
            <> string.inspect(suggestion.kills)
            <> ", which never mention the mutant it was found from",
        ),
        expect(
          suggestion.location == "src/boundary.gleam:18:3",
          "the suggestion is located at "
            <> suggestion.location
            <> ", expected src/boundary.gleam:18:3",
        ),
        expect(
          suggestion.original == "value > 0"
            && suggestion.replacement == "value >= 0",
          "the suggestion rewrites `"
            <> suggestion.original
            <> "` to `"
            <> suggestion.replacement
            <> "`, expected `value > 0` to `value >= 0`",
        ),
      ])
  }
}

/// `abs` holds the two mutants no input tells apart, and nothing else does.
fn indistinguishable_problems(output: SuggestOutput) -> List(String) {
  let functions =
    output.indistinguishable
    |> list.map(fn(entry) { entry.function })
    |> list.sort(string.compare)
  expect(
    functions == ["abs", "abs"],
    "the mutants no input told apart belong to "
      <> string.inspect(functions)
      <> ", expected the two equivalent `abs` mutants",
  )
}

/// A function-typed parameter is reported, with a reason that says so.
fn unsupported_problems(output: SuggestOutput) -> List(String) {
  let applies =
    list.filter(output.unsupported, fn(entry) { entry.function == "applies" })
  list.flatten([
    expect(
      applies != [],
      "no `applies` mutant was reported as unsupported; the unsupported "
        <> "functions are "
        <> string.inspect(
        list.map(output.unsupported, fn(entry) { entry.function }),
      ),
    ),
    expect(
      list.all(applies, fn(entry) { string.contains(entry.reason, "function") }),
      "an `applies` mutant gives a reason that never mentions `function`: "
        <> string.inspect(list.map(applies, fn(entry) { entry.reason })),
    ),
  ])
}

/// The one mutant nobody can build is a verdict, not the end of the file.
///
/// Deleting the pipeline stage of `join` leaves a `List(String)` where the
/// annotation promises a `String`. It used to take every mutant of
/// `src/boundary.gleam` down with it and exit 2 with GMU8003; what has to reach
/// the reader instead is one unsupported entry saying why, with the perfectly
/// good string-neutral mutant on the very same line still proposed as a test.
fn uncompilable_problems(output: SuggestOutput) -> List(String) {
  let rejected =
    list.filter(output.unsupported, fn(entry) { entry.function == "join" })
  list.flatten([
    expect(
      rejected != [],
      "no `join` mutant was reported as unsupported; the unsupported "
        <> "functions are "
        <> string.inspect(
        list.map(output.unsupported, fn(entry) { entry.function }),
      ),
    ),
    expect(
      list.all(rejected, fn(entry) {
        string.contains(entry.reason, "does not compile")
      }),
      "a rejected `join` mutant gives a reason that never says it does not "
        <> "compile: "
        <> string.inspect(list.map(rejected, fn(entry) { entry.reason })),
    ),
    expect(
      list.any(output.suggestions, fn(one) {
        one.function == "join" && one.operator == "string-neutral"
      }),
      "nothing was proposed for the string-neutral mutant of `join`, so the "
        <> "one mutant nobody can build took its neighbour with it",
    ),
  ])
}

/// `--operator` narrows a probe the way it narrows `run` and `list`.
///
/// It is the flag the dogfood report had to reach for as a workaround and
/// could not find; it is worth having on its own, so that a slow probe can be
/// pointed at one operator without weakening `run` through the manifest.
fn operator_problems() -> List(String) {
  let run =
    run_cli([
      "suggest", "--root", workspace, "--operator", "string-neutral", "--json",
    ])
  case decode_output(extract_json(run.stdout)) {
    Error(reason) -> [reason]
    Ok(output) -> {
      let proposed =
        list.map(output.suggestions, fn(one) { one.operator })
        |> list.unique
      list.flatten([
        status_problems("suggest --operator string-neutral", run),
        expect(
          output.suggestions != [],
          "a run narrowed to string-neutral proposed nothing at all",
        ),
        expect(
          proposed == ["string-neutral"],
          "a run narrowed to string-neutral proposed tests for "
            <> string.inspect(proposed),
        ),
        expect(
          list.all(output.unsupported, fn(entry) { entry.function != "join" }),
          "a run narrowed to string-neutral still reported the "
            <> "pipeline-stage-deletion mutant of `join`, which it never "
            <> "selected",
        ),
      ])
    }
  }
}

/// Every mutant `list` discovers is accounted for, and nothing else is.
///
/// A mutant no probe can call — one outside every function of its module —
/// still has to reach the reader, so the report is checked against the
/// catalogue rather than against itself: a bucket that quietly drops a
/// selected mutant would leave `suggest` claiming there was nothing to do.
fn accounting_problems(output: SuggestOutput) -> List(String) {
  let run = run_cli(["list", "--root", workspace, "--json"])
  case json.parse(extract_json(run.stdout), catalogue_decoder()) {
    Error(error) -> [
      "the list --json output could not be read: " <> string.inspect(error),
    ]
    Ok(discovered) -> {
      let accounted = accounted_ids(output)
      list.flatten([
        status_problems("list --json", run),
        expect(
          discovered != [],
          "list --json reported no candidates at all, so nothing was compared",
        ),
        expect(
          list.all(discovered, list.contains(accounted, _)),
          "suggest never accounted for "
            <> string.inspect(
            list.filter(discovered, fn(id) { !list.contains(accounted, id) }),
          )
            <> ", which list --json discovered",
        ),
        expect(
          list.all(accounted, list.contains(discovered, _)),
          "suggest accounted for "
            <> string.inspect(
            list.filter(accounted, fn(id) { !list.contains(discovered, id) }),
          )
            <> ", which list --json never discovered",
        ),
      ])
    }
  }
}

/// A run narrowed to one mutant counts that mutant and nothing else.
///
/// `--mutant` selects one mutant, but the probe still walks the whole module
/// it lives in: every count the report makes has to describe the selection,
/// not the walk, or the summary line and the buckets disagree.
fn narrowed_problems(display_id: String) -> List(String) {
  let run =
    run_cli(["suggest", "--root", workspace, "--mutant", display_id, "--json"])
  case decode_output(extract_json(run.stdout)) {
    Error(reason) -> [reason]
    Ok(output) ->
      list.flatten([
        status_problems("suggest --mutant " <> display_id, run),
        expect(
          list.map(output.suggestions, fn(suggestion) { suggestion.display_id })
            == [display_id],
          "a run narrowed to "
            <> display_id
            <> " proposed "
            <> string.inspect(
            list.map(output.suggestions, fn(suggestion) {
              suggestion.display_id
            }),
          ),
        ),
        expect(
          output.indistinguishable == [] && output.unsupported == [],
          "a run narrowed to one mutant still reported the rest of the module",
        ),
        expect(
          output.skipped == [],
          "a run narrowed to one probeable mutant still counted "
            <> string.inspect(
            list.map(output.skipped, fn(entry) { entry.function }),
          )
            <> " as skipped, which it selected nothing in",
        ),
      ])
  }
}

/// `--function` and `--mutant` naming different functions leave nothing to
/// probe, and what the run says about that has to be true.
///
/// `abs` has mutants in the selected file, and `--mutant` narrowed every one
/// of them away: the probe therefore never reports a verdict about `abs`, and
/// a warning built from those verdicts must not turn that silence into a claim
/// about the file. It is the selection that holds no `abs` mutant, so the
/// selection is what the warning is about.
fn crossed_filter_problems(display_id: String) -> List(String) {
  let run =
    run_cli([
      "suggest", "--root", workspace, "--function", "abs", "--mutant",
      display_id,
    ])
  list.flatten([
    status_problems("suggest --function abs --mutant " <> display_id, run),
    expect(
      string.contains(
        output(run),
        "GMU8012: this run selected no mutant inside a function named `abs`",
      ),
      "a --function name the selection narrowed away was reported as "
        <> "something else:\n"
        <> output(run),
    ),
  ])
}

/// The import hints merge into one line per module, naming every token used.
///
/// A suggestion's own `imports` cannot be concatenated with another's: two
/// tests of the same module can name different unqualified constructors, and a
/// file holding both needs one merged line. The terminal output is where that
/// merge is performed, so it is where it is checked.
fn import_problems(output: SuggestOutput, text: String) -> List(String) {
  let hinted = import_lines(text)
  let modules = list.map(hinted, import_module)
  let wanted = list.flat_map(output.suggestions, fn(one) { one.imports })
  list.flatten([
    expect(
      list.length(modules) == list.length(list.unique(modules)),
      "the import hints name a module more than once: "
        <> string.inspect(hinted),
    ),
    list.flat_map(list.unique(list.map(wanted, import_module)), fn(module) {
      expect(
        list.contains(modules, module),
        "no import hint covers " <> module <> ": " <> string.inspect(hinted),
      )
    }),
    list.flat_map(list.unique(list.flat_map(wanted, unqualified)), fn(token) {
      expect(
        list.any(hinted, string.contains(_, token)),
        "no import hint names the unqualified "
          <> token
          <> " a suggestion uses: "
          <> string.inspect(hinted),
      )
    }),
  ])
}

/// Text mode succeeds and counts what it found.
fn text_problems(run: platform.ProcessResult) -> List(String) {
  list.flatten([
    status_problems("suggest", run),
    expect(
      string.contains(run.stdout, "suggestion(s)"),
      "text mode never summarised its suggestions:\n" <> run.stdout,
    ),
  ])
}

/// `explain` names one mutant, what it rewrites, and the input that kills it.
fn explain_problems(display_id: String) -> List(String) {
  let run = run_cli(["explain", display_id, "--root", workspace])
  let shows = fn(fragment: String) -> List(String) {
    expect(
      string.contains(run.stdout, fragment),
      "explain " <> display_id <> " never printed `" <> fragment <> "`",
    )
  }
  list.flatten([
    status_problems("explain " <> display_id, run),
    shows("value > 0"),
    shows("value >= 0"),
    shows("boundary.is_positive(0)"),
  ])
}

/// `explain` on a mutant nothing separated says so without an empty gap.
///
/// A verdict that never distinguished its mutant carries no inspect for
/// either side, so the sentence that names what each answered has no values
/// to put in it. It has to be replaced, not printed with the values missing.
fn explain_indistinguishable_problems(display_id: String) -> List(String) {
  let run = run_cli(["explain", display_id, "--root", workspace])
  list.flatten([
    status_problems("explain " <> display_id, run),
    expect(
      string.contains(run.stdout, "status: indistinguishable"),
      "explain " <> display_id <> " never named the verdict:\n" <> run.stdout,
    ),
    expect(
      !string.contains(run.stdout, "the original is ,"),
      "explain "
        <> display_id
        <> " printed the answers sentence with nothing in it:\n"
        <> run.stdout,
    ),
    expect(
      !string.contains(run.stdout, "the mutant answers \n"),
      "explain "
        <> display_id
        <> " printed the answers sentence with nothing in it:\n"
        <> run.stdout,
    ),
    expect(
      string.contains(run.stdout, "no result was recorded for either side"),
      "explain "
        <> display_id
        <> " never said that neither side answered:\n"
        <> run.stdout,
    ),
  ])
}

/// A `--function` name nothing matched is said out loud, not summarised away.
///
/// Every count of the summary is zero either way, so a run that says nothing
/// else leaves a typo looking exactly like a function whose mutants are all
/// dead already.
fn unknown_function_problems() -> List(String) {
  let run = run_cli(["suggest", "--root", workspace, "--function", "nope"])
  list.flatten([
    status_problems("suggest --function nope", run),
    expect(
      string.contains(
        output(run),
        "GMU8012: this run selected no mutant inside a function named `nope`",
      ),
      "a --function name no mutant belongs to was never reported under its "
        <> "code:\n"
        <> output(run),
    ),
    expect(
      string.contains(run.stdout, "0 suggestion(s)"),
      "the run still had something to suggest:\n" <> run.stdout,
    ),
  ])
}

/// `suggest.exclude_functions` reaches the probe: the function is walked past
/// and its mutants are reported as ones nothing can be written for.
///
/// That the probe never *calls* an excluded function is settled by
/// `diff_runner_test`, which watches for the side effect of a call. What is
/// settled here is the wiring: the key is read from the workspace's own
/// `gleam.toml` and is still honoured when the run is driven from the command
/// line.
fn exclusion_problems() -> List(String) {
  let root =
    copy_fixture(
      "\n[tools.gleam_mutants.suggest]\nexclude_functions = [\"is_positive\"]\n",
    )
  let run = run_cli(["suggest", "--root", root, "--json"])
  let found = case decode_output(extract_json(run.stdout)) {
    Error(reason) -> [reason]
    Ok(output) -> {
      let excluded =
        list.filter(output.unsupported, fn(entry) {
          entry.function == "is_positive"
        })
      list.flatten([
        status_problems("suggest with an excluded function", run),
        expect(
          list.all(output.suggestions, fn(suggestion) {
            suggestion.function != "is_positive"
          }),
          "a test was proposed for the excluded is_positive: "
            <> string.inspect(
            list.map(output.suggestions, fn(one) { one.function }),
          ),
        ),
        expect(
          excluded != [],
          "no is_positive mutant was reported as unsupported; the unsupported "
            <> "functions are "
            <> string.inspect(
            list.map(output.unsupported, fn(entry) { entry.function }),
          ),
        ),
        expect(
          list.all(excluded, fn(entry) {
            string.contains(entry.reason, "exclude_functions")
          }),
          "an excluded mutant gives a reason that never names the key: "
            <> string.inspect(list.map(excluded, fn(entry) { entry.reason })),
        ),
        expect(
          list.any(output.skipped, fn(entry) {
            entry.function == "is_positive"
            && string.contains(entry.reason, "exclude_functions")
          }),
          "the excluded function is not among the ones the run walked past: "
            <> string.inspect(
            list.map(output.skipped, fn(entry) { entry.function }),
          ),
        ),
        // The rest of the module is still probed: an exclusion narrows the
        // run, it does not end it.
        expect(
          list.any(output.suggestions, fn(one) { one.function == "area" }),
          "nothing was proposed for area, so the exclusion took more than the "
            <> "function it named",
        ),
      ])
    }
  }
  discard_workspace(root)
  found
}

/// `--survivors` needs a stored report, and reports exactly what it says
/// survived.
///
/// A run stores its report under the workspace it ran in, so this works on a
/// throwaway copy rather than on the checked-in fixture. The copy is asked
/// three things: what `--survivors` does with no report at all, what it does
/// with one, and what it says about a module that report never covered.
fn survivors_problems() -> List(String) {
  let root = copy_fixture("")
  let unstored = run_cli(["suggest", "--root", root, "--survivors", "--json"])
  let ran = run_cli(["run", "--root", root, "--report", "none"])
  let stored = report.latest(root)
  // Added after the run, so the stored report has nothing to say about it.
  let _ = simplifile.write(path.join(root, "src/extra.gleam"), extra_source)
  let narrowed = run_cli(["suggest", "--root", root, "--survivors", "--json"])
  let found =
    list.flatten([
      expect(
        unstored.status == 2,
        "--survivors with no stored report exited "
          <> int.to_string(unstored.status)
          <> ", expected 2",
      ),
      expect(
        string.contains(output(unstored), "GMU8010"),
        "--survivors with no stored report never named GMU8010:\n"
          <> output(unstored),
      ),
      expect(
        ran.status == 0 || ran.status == 1,
        "the run exited "
          <> int.to_string(ran.status)
          <> "; a policy failure is expected, a tool failure is not\n"
          <> output(ran),
      ),
      survivor_problems(stored, narrowed),
    ])
  discard_workspace(root)
  found
}

/// The mutants `--survivors` proposes against the ones the report named.
fn survivor_problems(
  stored: Result(String, String),
  narrowed: platform.ProcessResult,
) -> List(String) {
  case stored, decode_output(extract_json(narrowed.stdout)) {
    Error(error), _ -> ["the run stored no report to narrow to: " <> error]
    _, Error(reason) -> [reason]
    Ok(document), Ok(output) ->
      case report.survivor_ids(document) {
        Error(error) -> ["the stored report could not be read: " <> error]
        Ok(survivors) ->
          list.flatten([
            status_problems("suggest --survivors", narrowed),
            expect(
              survivors != [],
              "the run left no survivors, so --survivors was never narrowed to "
                <> "anything",
            ),
            expect(
              list.sort(accounted_ids(output), string.compare)
                == list.sort(survivors, string.compare),
              "--survivors accounted for "
                <> string.inspect(list.sort(
                accounted_ids(output),
                string.compare,
              ))
                <> ", but the stored report says these survived: "
                <> string.inspect(list.sort(survivors, string.compare)),
            ),
            expect(
              output.survivors_missing == ["src/extra.gleam"],
              "the module the stored report never covered is reported as "
                <> string.inspect(output.survivors_missing)
                <> ", expected [\"src/extra.gleam\"]",
            ),
          ])
      }
  }
}

/// A run that asks for suggestions it cannot have says so once, and succeeds.
///
/// `run --suggest` on a workspace whose tests run on JavaScript grades its
/// mutants normally and is refused only the suggestions, so the refusal is a
/// warning beside a successful run rather than the run's failure. The suggest
/// error carries its own `GMU8001` in front of its message, and the warning
/// line must not put a second one there: it used to print
///
///     gleam-mutants: GMU8001: GMU8001: suggest supports the Erlang target only
///
/// which reads like two failures and matches no code a reader can grep for.
fn javascript_target_problems() -> List(String) {
  let root =
    copy_fixture("\n[tools.gleam_mutants.test]\ntarget = \"javascript\"\n")
  let ran =
    run_cli([
      "run", "--root", root, "--report", "none", "--no-strict", "--suggest",
    ])
  let text = output(ran)
  let found =
    list.flatten([
      expect(
        ran.status == 0,
        "run --suggest on a JavaScript workspace exited "
          <> int.to_string(ran.status)
          <> ", expected 0\n"
          <> text,
      ),
      expect(
        string.contains(
          text,
          "GMU8001: suggest supports the Erlang target only",
        ),
        "the run never said why it had no suggestions:\n" <> text,
      ),
      expect(
        list.length(string.split(text, "GMU8001")) == 2,
        "the warning named GMU8001 more than once:\n" <> text,
      ),
    ])
  discard_workspace(root)
  found
}

// --- A workspace of one's own ------------------------------------------------

/// The files a copy of the fixture is made of.
const fixture_files = [
  "gleam.toml", "src/boundary.gleam", "test/boundary_test.gleam",
  "test/boundary_fixture_test.gleam",
]

/// A module no stored report covers, written after the run that would have.
const extra_source = "pub fn twice(value: Int) -> Int {
  value * 2
}
"

/// A throwaway copy of the fixture, with `extra_toml` appended to its
/// manifest.
///
/// A run writes a report into the cache under the workspace it ran in, and a
/// `suggest` leg that needs one has to be able to change the workspace it asks
/// about. Neither belongs in the checked-in fixture.
fn copy_fixture(extra_toml: String) -> String {
  let root =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-suggest-cli-" <> platform.random_nonce(),
    )
  list.each(fixture_files, fn(relative) {
    let assert Ok(contents) = simplifile.read(path.join(workspace, relative))
    let target = path.join(root, relative)
    let assert Ok(Nil) = simplifile.create_directory_all(path.parent(target))
    let assert Ok(Nil) = simplifile.write(target, contents)
  })
  let assert Ok(Nil) = case extra_toml {
    "" -> Ok(Nil)
    text -> simplifile.append(path.join(root, "gleam.toml"), text)
  }
  root
}

/// Deletes a throwaway workspace and the run history it stored.
fn discard_workspace(root: String) -> Nil {
  let _ = platform.delete_tree(root)
  let _ =
    platform.delete_tree(
      platform.cache_directory()
      |> path.join("gleam-mutants/v1/workspaces")
      |> path.join(cache.workspace_id(root)),
    )
  Nil
}

/// Everything a command wrote, whichever stream it chose.
///
/// The Erlang process FFI folds a child's `stderr` into its `stdout`, so a
/// diagnostic is read out of one stream on Erlang and the other on Node. What
/// is being checked is that the command said it at all.
fn output(run: platform.ProcessResult) -> String {
  run.stdout <> "\n" <> run.stderr
}

// --- Running the command line ------------------------------------------------

fn run_cli(arguments: List(String)) -> platform.ProcessResult {
  platform.run_process(
    "gleam",
    list.append(
      ["run", "-m", "gleam_mutants", "--target", "erlang", "--"],
      arguments,
    ),
    ".",
    [],
    900_000,
  )
}

/// The one JSON value a `--json` run prints, picked out of the build chatter.
///
/// `gleam run` writes its own progress to the same stream, so the output is
/// read back the way a shell pipeline would have to read it: the last line
/// that begins a JSON object is the command's answer.
fn extract_json(stdout: String) -> String {
  stdout
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(string.starts_with(_, "{"))
  |> list.last
  |> result.unwrap("")
}

// --- The subset of Suggest JSON v1 this smoke reads ---------------------------

type SuggestOutput {
  SuggestOutput(
    schema_version: Int,
    suggestions: List(Suggestion),
    indistinguishable: List(Entry),
    nondeterministic: List(Unsupported),
    unsupported: List(Unsupported),
    skipped: List(Skipped),
    survivors_missing: List(String),
  )
}

type Suggestion {
  Suggestion(
    module_path: String,
    function: String,
    mutant_id: String,
    display_id: String,
    operator: String,
    location: String,
    original: String,
    replacement: String,
    inputs: List(String),
    expected: Option(String),
    kills: List(String),
    test_source: String,
    imports: List(String),
  )
}

type Entry {
  Entry(function: String, display_id: String, mutant_id: String)
}

type Unsupported {
  Unsupported(function: String, reason: String, mutant_id: String)
}

type Skipped {
  Skipped(function: String, reason: String)
}

fn decode_output(text: String) -> Result(SuggestOutput, String) {
  case json.parse(text, output_decoder()) {
    Ok(decoded) -> Ok(decoded)
    Error(error) ->
      Error(
        "the --json output is not Suggest JSON v1: "
        <> string.inspect(error)
        <> "\n"
        <> text,
      )
  }
}

fn output_decoder() -> decode.Decoder(SuggestOutput) {
  use schema_version <- decode.field("schema_version", decode.int)
  use suggestions <- decode.field(
    "suggestions",
    decode.list(suggestion_decoder()),
  )
  use indistinguishable <- decode.field(
    "indistinguishable",
    decode.list(entry_decoder()),
  )
  use nondeterministic <- decode.field(
    "nondeterministic",
    decode.list(unsupported_decoder()),
  )
  use unsupported <- decode.field(
    "unsupported",
    decode.list(unsupported_decoder()),
  )
  use skipped <- decode.field("skipped", decode.list(skipped_decoder()))
  use survivors_missing <- decode.field(
    "survivors_missing",
    decode.list(decode.string),
  )
  decode.success(SuggestOutput(
    schema_version: schema_version,
    suggestions: suggestions,
    indistinguishable: indistinguishable,
    nondeterministic: nondeterministic,
    unsupported: unsupported,
    skipped: skipped,
    survivors_missing: survivors_missing,
  ))
}

/// The mutant ids of `list --json`, which is the catalogue `suggest` selects
/// from.
fn catalogue_decoder() -> decode.Decoder(List(String)) {
  decode.at(["mutants"], decode.list(decode.at(["id"], decode.string)))
}

fn suggestion_decoder() -> decode.Decoder(Suggestion) {
  use module_path <- decode.field("module_path", decode.string)
  use function <- decode.field("function", decode.string)
  use mutant_id <- decode.field("mutant_id", decode.string)
  use display_id <- decode.field("display_id", decode.string)
  use operator <- decode.field("operator", decode.string)
  use location <- decode.field("location", decode.string)
  use original <- decode.field("original", decode.string)
  use replacement <- decode.field("replacement", decode.string)
  use inputs <- decode.field("inputs", decode.list(decode.string))
  use expected <- decode.field("expected", decode.optional(decode.string))
  use kills <- decode.field("kills", decode.list(decode.string))
  use test_source <- decode.field("test_source", decode.string)
  use imports <- decode.field("imports", decode.list(decode.string))
  decode.success(Suggestion(
    module_path: module_path,
    function: function,
    mutant_id: mutant_id,
    display_id: display_id,
    operator: operator,
    location: location,
    original: original,
    replacement: replacement,
    inputs: inputs,
    expected: expected,
    kills: kills,
    test_source: test_source,
    imports: imports,
  ))
}

fn entry_decoder() -> decode.Decoder(Entry) {
  use function <- decode.field("function", decode.string)
  use display_id <- decode.field("display_id", decode.string)
  use mutant_id <- decode.field("mutant_id", decode.string)
  decode.success(Entry(
    function: function,
    display_id: display_id,
    mutant_id: mutant_id,
  ))
}

fn unsupported_decoder() -> decode.Decoder(Unsupported) {
  use function <- decode.field("function", decode.string)
  use reason <- decode.field("reason", decode.string)
  use mutant_id <- decode.field("mutant_id", decode.string)
  decode.success(Unsupported(
    function: function,
    reason: reason,
    mutant_id: mutant_id,
  ))
}

fn skipped_decoder() -> decode.Decoder(Skipped) {
  use function <- decode.field("function", decode.string)
  use reason <- decode.field("reason", decode.string)
  decode.success(Skipped(function: function, reason: reason))
}

// --- Helpers -----------------------------------------------------------------

fn boundary_suggestion(output: SuggestOutput) -> List(Suggestion) {
  list.filter(output.suggestions, fn(suggestion) {
    suggestion.function == "is_positive"
    && suggestion.operator == "comparison-boundary"
  })
}

fn boundary_display_id(output: SuggestOutput) -> String {
  case boundary_suggestion(output) {
    [suggestion, ..] -> suggestion.display_id
    [] -> ""
  }
}

/// The first mutant no input told apart, which `explain` has to describe
/// without any answer from either side to describe it with.
fn equivalent_display_id(output: SuggestOutput) -> String {
  case output.indistinguishable {
    [entry, ..] -> entry.display_id
    [] -> ""
  }
}

/// Every mutant the report accounts for, however it accounts for it.
///
/// A mutant is killed by a suggestion, told apart from nothing, or reported as
/// one no test can be written for. Anything else has been dropped.
fn accounted_ids(output: SuggestOutput) -> List(String) {
  list.flatten([
    list.flat_map(output.suggestions, fn(suggestion) { suggestion.kills }),
    list.map(output.indistinguishable, fn(entry) { entry.mutant_id }),
    list.map(output.nondeterministic, fn(entry) { entry.mutant_id }),
    list.map(output.unsupported, fn(entry) { entry.mutant_id }),
  ])
  |> list.unique
}

/// The import lines of the terminal output, which only the hints contain.
fn import_lines(text: String) -> List(String) {
  text
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(string.starts_with(_, "import "))
}

/// The module one import line names: `import gleam/option.{Some}` is
/// `gleam/option`.
fn import_module(line: String) -> String {
  let named = string.drop_start(string.trim(line), 7)
  case string.split_once(named, ".{") {
    Ok(#(module, _)) -> module
    Error(Nil) -> named
  }
}

/// The unqualified names one import line brings in, if any.
fn unqualified(line: String) -> List(String) {
  case string.split_once(line, ".{") {
    Error(Nil) -> []
    Ok(#(_, rest)) -> rest |> string.replace("}", "") |> string.split(", ")
  }
}

fn expect(holds: Bool, message: String) -> List(String) {
  case holds {
    True -> []
    False -> [message]
  }
}
