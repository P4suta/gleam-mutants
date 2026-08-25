// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Writing generated tests into the workspace's own test modules.
//
// A suggestion is only worth anything once it lives in a file the project's
// `gleam test` runs, so this module owns the two halves of that move: `plan`
// says what would change, and `write` changes it. Both work in terms of a
// workspace path and rendered suggestions, so the command line is one caller
// rather than the only one.
//
// The two halves answer from the same resolver, so a plan is never a guess at
// what a write would do: `plan` reports the resolution and `write` stores the
// bytes it resolved to. Everything about a module that already exists is read
// from its own parse tree — the tests it defines, the modules it imports, the
// names it imports them under and the names it declares itself — because the
// reader's file is theirs, and generated code has to arrive on its terms.
// Which name the tests call each module by is settled once per file, against
// that file's own bindings and the ones the generated tests need; a name the
// file already binds is stepped around where the tests can reach what they
// need another way, and refused before anything is written where they cannot,
// because `gleam format` accepts source the compiler does not.

import glance
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/suggest/render
import simplifile

/// How long `gleam format` is given over the files that were written.
const format_timeout_ms = 120_000

/// What one test module would gain, or gained.
///
/// `file` is the workspace-relative test module the tests belong in, and
/// `create` says whether it has to be created first. `imports_added` holds the
/// import lines the module is missing, `tests_added` the names of the tests
/// that would be appended, and `tests_skipped` the names it already defines —
/// a suggestion applied twice must not write the same test twice.
pub type Plan {
  Plan(
    file: String,
    create: Bool,
    imports_added: List(String),
    tests_added: List(String),
    tests_skipped: List(String),
  )
}

/// One test module settled against the workspace: the plan, and the bytes.
///
/// `source` is what the file holds now, so a resolution that changes nothing
/// can be recognised and left alone rather than rewritten and reformatted.
type Resolution {
  Resolution(plan: Plan, contents: String, source: String)
}

/// One import line to add, or one the file already has and has to grow.
///
/// A module the file imports already cannot be imported a second time, so an
/// import that only lacks a constructor is rewritten where it stands.
type ImportEdit {
  ImportEdit(at: Option(glance.Span), line: String)
}

/// What applying `suggestions` to `workspace` would change, without changing
/// it.
///
/// One plan per test module, sorted by file. A suggestion no test can be
/// written for is left out, and a test module that cannot be parsed is
/// refused rather than appended to.
pub fn plan(
  workspace: String,
  suggestions: List(render.Suggestion),
  style: render.AssertStyle,
) -> Result(List(Plan), String) {
  use resolutions <- result.map(resolve(workspace, suggestions, style))
  list.map(resolutions, fn(resolution) { resolution.plan })
}

/// Applies `plans` to `workspace`, answering with the plans it carried out.
///
/// Every file is staged beside its target and atomically renamed, and
/// `gleam format` is then run over the ones that changed: the generated
/// source is deliberately written on long lines, and the reader's file is
/// theirs to read afterwards. A file whose resolution matches what it already
/// holds is left untouched, formatter included.
pub fn write(
  workspace: String,
  plans: List(Plan),
  suggestions: List(render.Suggestion),
  style: render.AssertStyle,
) -> Result(List(Plan), String) {
  use resolutions <- result.try(resolve(workspace, suggestions, style))
  let wanted = set.from_list(list.map(plans, fn(item) { item.file }))
  let changed =
    list.filter(resolutions, fn(resolution) {
      set.contains(wanted, resolution.plan.file)
      && resolution.contents != resolution.source
    })
  use _ <- result.try(list.try_map(changed, store(workspace, _)))
  use _ <- result.map(format(
    workspace,
    list.map(changed, fn(resolution) { resolution.plan.file }),
  ))
  plans
}

// --- Where a verified kill came from -----------------------------------------

/// What one mutant's death is owed to, once the generated tests are in place.
///
/// `--verify` is worth something only when it can tell a mutant the generated
/// tests killed from one the reader's own suite was already killing. A test
/// whose whole kill set was dead before it was written added nothing, however
/// green the run that followed it; a mutant alive afterwards is the failure
/// the flag exists to catch.
pub type Attribution {
  /// Alive, or never discovered, before the tests were written; dead now.
  NewlyKilled
  /// Dead before the tests were written, and dead now: the test added nothing.
  AlreadyKilled
  /// Alive after the tests were written, whatever it was before.
  StillSurviving
}

/// What became of every mutant in `ids`, from the runs either side of the
/// write.
///
/// `before` and `after` each map a mutant id to whether that run found it
/// dead. A mutant no run discovered is absent from that map, which is not a
/// kill: the file it came from was selected, so its absence is a finding
/// rather than a pass. `after` decides first — a mutant alive now is
/// surviving even if it was dead before the tests were written — and every id
/// is answered in the order it was given.
pub fn attribute(
  ids: List(String),
  before: dict.Dict(String, Bool),
  after: dict.Dict(String, Bool),
) -> List(#(String, Attribution)) {
  list.map(ids, fn(id) {
    case dict.get(after, id), dict.get(before, id) {
      Ok(True), Ok(True) -> #(id, AlreadyKilled)
      Ok(True), _ -> #(id, NewlyKilled)
      _, _ -> #(id, StillSurviving)
    }
  })
}

/// The name one attribution carries in Apply JSON v1.
pub fn attribution_name(value: Attribution) -> String {
  case value {
    NewlyKilled -> "new"
    AlreadyKilled -> "already_killed"
    StillSurviving -> "surviving"
  }
}

// --- Resolving one test module -----------------------------------------------

/// Every test module the writable suggestions touch, sorted by file.
fn resolve(
  workspace: String,
  suggestions: List(render.Suggestion),
  style: render.AssertStyle,
) -> Result(List(Resolution), String) {
  let writable = list.filter(suggestions, render.renderable)
  writable
  |> list.map(fn(suggestion) { test_module(suggestion.module_path) })
  |> list.unique
  |> list.sort(string.compare)
  |> list.try_map(fn(file) {
    resolve_module(
      workspace,
      file,
      list.filter(writable, fn(suggestion) {
        test_module(suggestion.module_path) == file
      }),
      style,
    )
  })
}

/// The flat test module the generated tests of one module belong in.
///
/// Test modules live in one directory, so `app/util` is tested by
/// `test/app_util_test.gleam` rather than by a directory nobody asked for.
fn test_module(module_path: String) -> String {
  "test/" <> string.replace(module_path, "/", "_") <> "_test.gleam"
}

fn resolve_module(
  workspace: String,
  file: String,
  suggestions: List(render.Suggestion),
  style: render.AssertStyle,
) -> Result(Resolution, String) {
  case simplifile.read(path.join(workspace, file)) {
    Error(simplifile.Enoent) -> Ok(created(workspace, file, suggestions, style))
    Error(error) ->
      Error(
        "GMU8015: could not read "
        <> file
        <> ": "
        <> simplifile.describe_error(error),
      )
    Ok(source) -> updated(file, source, suggestions, style)
  }
}

/// A test module that does not exist yet: a licence, imports, tests, and no
/// `main`.
///
/// The project's own test module owns the `gleeunit` entry point; a second
/// one would only give it something to argue with.
fn created(
  workspace: String,
  file: String,
  suggestions: List(render.Suggestion),
  style: render.AssertStyle,
) -> Resolution {
  let scope = render.scope(suggestions, style)
  Resolution(
    plan: Plan(
      file: file,
      create: True,
      imports_added: render.imports(scope, suggestions),
      tests_added: list.map(suggestions, render.test_name),
      tests_skipped: [],
    ),
    contents: licence(workspace, suggestions)
      <> render.file_source(scope, suggestions),
    source: "",
  )
}

/// The licence header the module under test carries, as a file can open with.
///
/// A generated module is a file of the reader's project like any other, and a
/// project that lints its own copyright — this one does — would report one
/// with no header as a violation nobody made. Only the SPDX tags of the
/// module the tests are written for are copied: the rest of its header is
/// prose about that module, which says nothing true about its tests.
fn licence(workspace: String, suggestions: List(render.Suggestion)) -> String {
  case suggestions {
    [] -> ""
    [first, ..] ->
      case
        simplifile.read(path.join(
          workspace,
          "src/" <> first.module_path <> ".gleam",
        ))
      {
        Error(_) -> ""
        Ok(source) ->
          case spdx_tags(source) {
            [] -> ""
            tags -> string.join(tags, "\n") <> "\n\n"
          }
      }
  }
}

/// The SPDX tag lines of the comment header one module opens with.
fn spdx_tags(source: String) -> List(String) {
  source
  |> string.split("\n")
  |> list.take_while(fn(line) { string.starts_with(string.trim(line), "//") })
  |> list.filter(string.contains(_, "SPDX-"))
  |> list.map(string.trim_end)
}

/// A test module the reader already has, with the generated tests added to it.
fn updated(
  file: String,
  source: String,
  suggestions: List(render.Suggestion),
  style: render.AssertStyle,
) -> Result(Resolution, String) {
  use module <- result.try(
    glance.module(source)
    |> result.replace_error(
      "GMU8013: could not parse the test module "
      <> file
      <> "; it is not Gleam this tool can add tests to",
    ),
  )
  let imports =
    list.map(module.imports, fn(definition) { definition.definition })
  let functions =
    list.map(module.functions, fn(definition) { definition.definition.name })
  let defined = set.from_list(functions)
  let #(present, missing) =
    list.partition(suggestions, fn(suggestion) {
      set.contains(defined, render.test_name(suggestion))
    })
  use scope <- result.try(adapted(
    render.scope(missing, style),
    missing,
    file,
    imports,
    declared(module, functions),
  ))
  let edits = import_edits(scope, missing, imports)
  Ok(Resolution(
    plan: Plan(
      file: file,
      create: False,
      imports_added: list.map(edits, fn(edit) { edit.line }),
      tests_added: list.map(missing, render.test_name),
      tests_skipped: list.map(present, render.test_name),
    ),
    contents: source
      |> splice(import_splices(source, imports, edits))
      |> append_tests(scope, missing),
    source: source,
  ))
}

/// Every value name one test module binds by declaring it.
///
/// A constructor is the one that matters: a module holding
/// `pub type Maybe { Some(Int) None }` binds `Some` and `None` as firmly as an
/// import would, and nothing in its import block says so. Functions and
/// constants are gathered beside them because they are as cheap to read and
/// bind names in the same space.
fn declared(module: glance.Module, functions: List(String)) -> set.Set(String) {
  set.from_list(
    list.flatten([
      list.flat_map(module.custom_types, fn(definition) {
        list.map(definition.definition.variants, fn(variant) { variant.name })
      }),
      list.map(module.constants, fn(definition) { definition.definition.name }),
      functions,
    ]),
  )
}

// --- Imports -----------------------------------------------------------------

/// `scope` settled against everything the reader's file already binds.
///
/// One module cannot be imported twice under a name, so the generated tests
/// have to reach a module the file already names under the name it is already
/// reachable by — the module under test as much as `gleam/string` or
/// `gleeunit/should`. A module the file imported under no name at all binds
/// nothing to reuse, and Gleam is content to hold a plain import beside that
/// line, so one is added rather than the file being refused.
///
/// A constructor is the other half. The file may already bind `Some` or `None`
/// to something of its own, and a second binding of one name is a name defined
/// twice, so those constructors are written through their own module instead.
/// What is left — a name two modules would both answer to — is refused here
/// rather than written out as source the compiler will not accept.
fn adapted(
  scope: render.Scope,
  suggestions: List(render.Suggestion),
  file: String,
  imports: List(glance.Import),
  declared: set.Set(String),
) -> Result(render.Scope, String) {
  let bound = rebound(scope, suggestions, imports)
  let spoken_for =
    render.requirements(bound, suggestions)
    |> list.any(already_bound(imports, declared, _))
  let bound = case spoken_for {
    False -> bound
    True -> rebound(render.qualify_option(bound), suggestions, imports)
  }
  use _ <- result.map(unclashed(bound, suggestions, file, imports, declared))
  bound
}

/// `scope` with every module the reader's file names bound to that name.
fn rebound(
  scope: render.Scope,
  suggestions: List(render.Suggestion),
  imports: List(glance.Import),
) -> render.Scope {
  render.requirements(scope, suggestions)
  |> list.fold(scope, fn(current, requirement) {
    case named_import(imports, requirement.module), requirement.qualifier {
      Ok(existing), Some(_) ->
        case qualifier_of(existing) {
          Some(name) -> render.bind(current, requirement.module, name)
          None -> current
        }
      _, _ -> current
    }
  })
}

/// Whether the file already binds one of the unqualified names a requirement
/// asks for.
fn already_bound(
  imports: List(glance.Import),
  declared: set.Set(String),
  requirement: render.Requirement,
) -> Bool {
  list.any(requirement.names, fn(name) {
    set.contains(declared, name)
    || list.any(imports, shadows(_, requirement.module, name))
  })
}

/// Nothing the generated tests name collides with anything the file binds.
///
/// Two modules cannot answer to one name and neither can two constructors, so
/// every name the tests are about to write is checked against the names the
/// reader's own file binds — its imports and its own declarations alike.
/// `gleam format` would accept the collision and the compiler would not, which
/// is the whole reason to look before writing.
fn unclashed(
  scope: render.Scope,
  suggestions: List(render.Suggestion),
  file: String,
  imports: List(glance.Import),
  declared: set.Set(String),
) -> Result(Nil, String) {
  let required = render.requirements(scope, suggestions)
  use _ <- result.try(
    list.try_each(required, fn(requirement) {
      case binds(imports, requirement) {
        None -> Ok(Nil)
        Some(name) ->
          case competitors(required, imports, requirement.module, name) {
            [] -> Ok(Nil)
            [other, ..] ->
              Error(name_taken(file, imports, requirement.module, other, name))
          }
      }
    }),
  )
  list.try_each(required, fn(requirement) {
    unshadowed(
      file,
      imports,
      declared,
      requirement.module,
      missing_names(imports, requirement),
    )
  })
}

/// The name one import binds in the finished file, if it binds one.
///
/// A module the file already names binds whatever that line binds; one this
/// tool is about to import binds the name its tests call it by, or the last
/// segment of its path when they never name it — `import gleam/option.{None}`
/// writes no `option.` anywhere and takes the name `option` all the same. An
/// import that named nothing binds nothing, so the line added beside it is the
/// one that settles the name.
fn binds(
  imports: List(glance.Import),
  requirement: render.Requirement,
) -> Option(String) {
  case named_import(imports, requirement.module) {
    Ok(existing) -> qualifier_of(existing)
    Error(Nil) ->
      Some(option.unwrap(
        requirement.qualifier,
        last_segment(requirement.module),
      ))
  }
}

/// The other modules that would answer to `name` in the finished file.
fn competitors(
  required: List(render.Requirement),
  imports: List(glance.Import),
  module: String,
  name: String,
) -> List(String) {
  let bound =
    imports
    |> list.filter(fn(current) {
      current.module != module && qualifier_of(current) == Some(name)
    })
    |> list.map(fn(current) { current.module })
  let generated =
    required
    |> list.filter(fn(other) {
      other.module != module && binds(imports, other) == Some(name)
    })
    |> list.map(fn(other) { other.module })
  list.unique(list.append(bound, generated))
}

/// Nothing else in the file binds the names one import is about to add.
///
/// The names a generated test can write plainly are the option constructors
/// and nothing else, and `adapted` steps around those by qualifying them, so
/// this is the guard that catches whatever it could not: a name the file binds
/// that the tests have no other way to reach.
fn unshadowed(
  file: String,
  imports: List(glance.Import),
  declared: set.Set(String),
  module: String,
  names: List(String),
) -> Result(Nil, String) {
  list.try_each(names, fn(name) {
    case
      set.contains(declared, name)
      || list.any(imports, shadows(_, module, name))
    {
      False -> Ok(Nil)
      True -> Error(name_shadowed(file, module, name))
    }
  })
}

/// Whether one import binds `name` to something other than `module`'s own.
fn shadows(current: glance.Import, module: String, name: String) -> Bool {
  list.any(current.unqualified_values, fn(item) {
    option.unwrap(item.alias, item.name) == name
    && !{ current.module == module && item.name == name }
  })
}

/// The import lines `suggestions` need that `imports` does not provide.
///
/// A module the file already names is left alone unless the generated tests
/// name a constructor it does not bind, in which case the line it already has
/// grows rather than gaining a twin the compiler would refuse. A module the
/// file imported under no name is the one case where a second line is right:
/// `import boundary.{is_positive} as _` binds the names it lists and no name
/// for the module, and Gleam holds a plain `import boundary` beside it. The
/// lines are sorted so that a plan reports them in one order however they were
/// found.
fn import_edits(
  scope: render.Scope,
  suggestions: List(render.Suggestion),
  imports: List(glance.Import),
) -> List(ImportEdit) {
  render.requirements(scope, suggestions)
  |> list.filter_map(fn(requirement) {
    let names = missing_names(imports, requirement)
    case named_import(imports, requirement.module), names {
      Ok(_), [] -> Error(Nil)
      Ok(current), _ ->
        Ok(ImportEdit(at: Some(current.location), line: grown(current, names)))
      Error(Nil), [] if requirement.qualifier == None -> Error(Nil)
      Error(Nil), _ ->
        Ok(ImportEdit(
          at: None,
          line: render.import_line(
            render.Requirement(..requirement, names: names),
          ),
        ))
    }
  })
  |> list.sort(fn(left, right) { string.compare(left.line, right.line) })
}

/// The file's own import of `module` that gives it a name, if it has one.
///
/// An `as _` import gives it none, so it is no answer to "what do the
/// generated tests call this module by".
fn named_import(
  imports: List(glance.Import),
  module: String,
) -> Result(glance.Import, Nil) {
  list.find(imports, fn(current) {
    current.module == module && qualifier_of(current) != None
  })
}

/// The names one requirement asks for that no import of its module binds.
///
/// A name a line carries under an alias binds that alias and not this name, so
/// it does not answer for it: `{Some as Just}` leaves `Some` unbound, and
/// Gleam is content to import one constructor under both names. Every import
/// of the module is read, `as _` included, because such a line binds the names
/// it lists even though it binds no name for the module.
fn missing_names(
  imports: List(glance.Import),
  requirement: render.Requirement,
) -> List(String) {
  list.filter(requirement.names, fn(name) {
    !list.any(imports, fn(current) {
      current.module == requirement.module
      && list.any(current.unqualified_values, fn(item) {
        item.name == name && item.alias == None
      })
    })
  })
}

/// One import line grown by the names it was missing.
fn grown(current: glance.Import, names: List(String)) -> String {
  import_line(
    glance.Import(
      ..current,
      unqualified_values: list.append(
        current.unqualified_values,
        list.map(names, glance.UnqualifiedImport(_, None)),
      ),
    ),
  )
}

/// One import written back out as the Gleam line it came from.
///
/// The names are sorted the way `gleam format` sorts them, types first, so
/// that the line a plan reports is the line the file ends up holding.
fn import_line(import_: glance.Import) -> String {
  let names =
    list.append(
      list.map(sorted(import_.unqualified_types), fn(item) {
        "type " <> unqualified_name(item)
      }),
      list.map(sorted(import_.unqualified_values), unqualified_name),
    )
  "import "
  <> import_.module
  <> case names {
    [] -> ""
    _ -> ".{" <> string.join(names, ", ") <> "}"
  }
  <> case import_.alias {
    None -> ""
    Some(glance.Named(name)) -> " as " <> name
    Some(glance.Discarded(name)) -> " as _" <> name
  }
}

// --- Saying why a file cannot be written into --------------------------------

/// One name two modules would both answer to in the finished file.
///
/// The module the reader's file already imports is the one named as holding
/// the name, because it is the import they can edit; the other is what the
/// generated tests need it for.
fn name_taken(
  file: String,
  imports: List(glance.Import),
  module: String,
  other: String,
  name: String,
) -> String {
  case named_import(imports, module), named_import(imports, other) {
    Ok(_), _ -> taken(file, module, other, name)
    _, Ok(_) -> taken(file, other, module, name)
    _, _ ->
      "GMU8014: the generated tests of "
      <> file
      <> " would need the name `"
      <> name
      <> "` for both "
      <> module
      <> " and "
      <> other
      <> "; please report this as a bug"
  }
}

fn taken(file: String, holder: String, other: String, name: String) -> String {
  "GMU8014: "
  <> file
  <> " imports "
  <> holder
  <> " as `"
  <> name
  <> "`, but the generated tests need that name for "
  <> other
  <> "; import "
  <> holder
  <> " under a different alias and re-run"
}

/// One name the file has already bound to something else.
fn name_shadowed(file: String, module: String, name: String) -> String {
  "GMU8014: "
  <> file
  <> " binds `"
  <> name
  <> "` to something other than the "
  <> module
  <> " it names, which the generated tests need; import that name under a "
  <> "different alias and re-run"
}

/// The unqualified imports of one line, in the order the formatter puts them.
fn sorted(
  items: List(glance.UnqualifiedImport),
) -> List(glance.UnqualifiedImport) {
  list.sort(items, fn(left, right) { string.compare(left.name, right.name) })
}

fn unqualified_name(item: glance.UnqualifiedImport) -> String {
  case item.alias {
    None -> item.name
    Some(alias) -> item.name <> " as " <> alias
  }
}

/// Where the new import lines go, and which existing ones are rewritten.
///
/// New lines join the block the module already has, so that `gleam format`
/// sorts them into it; a module with no import at all takes its first one
/// under whatever header comment the reader wrote.
fn import_splices(
  source: String,
  imports: List(glance.Import),
  edits: List(ImportEdit),
) -> List(#(Int, Int, String)) {
  let #(rewritten, added) = list.partition(edits, fn(edit) { edit.at != None })
  let replacements =
    list.filter_map(rewritten, fn(edit) {
      case edit.at {
        Some(glance.Span(start, end)) -> Ok(#(start, end, edit.line))
        None -> Error(Nil)
      }
    })
  case added {
    [] -> replacements
    _ -> {
      let text = string.join(list.map(added, fn(edit) { edit.line }), "\n")
      let insertion = case last_import_end(imports) {
        Some(offset) -> #(offset, offset, "\n" <> text)
        None ->
          case header_end(source) {
            0 -> #(0, 0, text <> "\n\n")
            offset -> #(offset, offset, "\n" <> text <> "\n")
          }
      }
      [insertion, ..replacements]
    }
  }
}

/// The byte offset just past the module's last import, if it has one.
fn last_import_end(imports: List(glance.Import)) -> Option(Int) {
  imports
  |> list.map(fn(current) { current.location.end })
  |> list.reduce(int.max)
  |> option.from_result
}

/// The byte offset just past the comment header the module opens with.
///
/// Licence headers and file comments are the reader's, so generated imports
/// belong under them rather than in front of them. A blank line between two
/// comment blocks is part of the header rather than the end of it: a licence
/// block and the file comment beneath it are one header a reader wrote, and an
/// import wedged between them splits something nobody meant to be split.
fn header_end(source: String) -> Int {
  source
  |> string.split("\n")
  |> list.take_while(heading)
  |> list.reverse
  |> list.drop_while(fn(line) { string.trim(line) == "" })
  |> list.fold(0, fn(offset, line) { offset + byte_size(line) + 1 })
}

/// Whether one line can be part of a module's opening comment header.
fn heading(line: String) -> Bool {
  let trimmed = string.trim(line)
  trimmed == "" || string.starts_with(trimmed, "//")
}

// --- Editing the file --------------------------------------------------------

/// `source` with every `#(start, end, text)` edit applied, last one first.
///
/// The edits are byte ranges into the source they were measured in, so they
/// are applied from the end backwards and never move each other.
fn splice(source: String, edits: List(#(Int, Int, String))) -> String {
  edits
  |> list.sort(fn(left, right) { int.compare(right.0, left.0) })
  |> list.fold(source, fn(text, edit) {
    let #(start, end, replacement) = edit
    case bytes.slice(text, 0, start), bytes.slice(text, end, byte_size(text)) {
      Ok(head), Ok(tail) -> head <> replacement <> tail
      _, _ -> text
    }
  })
}

/// The generated tests appended to whatever the file already holds.
fn append_tests(
  source: String,
  scope: render.Scope,
  suggestions: List(render.Suggestion),
) -> String {
  let ending = case source == "" || string.ends_with(source, "\n") {
    True -> source
    False -> source <> "\n"
  }
  list.fold(suggestions, ending, fn(text, suggestion) {
    case render.test_source(scope, suggestion) {
      Ok(written) -> text <> "\n" <> written <> "\n"
      Error(_) -> text
    }
  })
}

fn byte_size(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}

/// The name one import makes a module reachable under, if it makes one at all.
fn qualifier_of(import_: glance.Import) -> Option(String) {
  case import_.alias {
    Some(glance.Named(name)) -> Some(name)
    Some(glance.Discarded(_)) -> None
    None -> Some(last_segment(import_.module))
  }
}

fn last_segment(module_path: String) -> String {
  module_path
  |> string.split("/")
  |> list.last
  |> result.unwrap(module_path)
}

// --- Storing what was resolved -----------------------------------------------

/// Stages one resolved module beside its target and renames it into place.
fn store(workspace: String, resolution: Resolution) -> Result(Nil, String) {
  let file = resolution.plan.file
  let target = path.join(workspace, file)
  let directory = path.parent(target)
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(fn(error) {
      write_failed(file, simplifile.describe_error(error))
    }),
  )
  let staged =
    path.join(
      directory,
      "." <> path.base_name(target) <> "." <> platform.random_nonce() <> ".tmp",
    )
  use _ <- result.try(
    simplifile.write(staged, resolution.contents)
    |> result.map_error(fn(error) {
      write_failed(file, simplifile.describe_error(error))
    }),
  )
  case simplifile.rename(at: staged, to: target) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      let _ = simplifile.delete_file(staged)
      Error(write_failed(file, simplifile.describe_error(error)))
    }
  }
}

fn write_failed(file: String, reason: String) -> String {
  "GMU8015: could not write " <> file <> ": " <> reason
}

/// Runs `gleam format` over the files that were written.
///
/// The generated source is written on one line per statement on purpose, so a
/// formatter refusal leaves a file the reader can still read but not one this
/// tool is willing to call applied.
fn format(workspace: String, files: List(String)) -> Result(Nil, String) {
  case files {
    [] -> Ok(Nil)
    _ -> {
      let run =
        platform.run_process(
          "gleam",
          ["format", ..files],
          workspace,
          [],
          format_timeout_ms,
        )
      case run.status {
        0 -> Ok(Nil)
        _ ->
          Error(
            "GMU8016: `gleam format` refused "
            <> string.join(files, ", ")
            <> ": "
            <> string.trim(run.stderr <> run.stdout),
          )
      }
    }
  }
}
