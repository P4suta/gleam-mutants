// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/mutant.{type Candidate, type Mutant, Candidate}
import gleam_mutants/core/operator.{type Operator}
import gleam_mutants/core/span

pub type Catalog {
  Catalog(mutants: List(Mutant), rejected: List(RejectedCandidate))
}

/// Describes whether a rule is based only on syntax or on definite type evidence.
pub type AnalysisMode {
  SyntaxBased
  Semantic
}

/// Evidence accepted by the semantic rule layer.
pub type TypeEvidence {
  BooleanLiteralEvidence
  BooleanNegationEvidence
  IntegerLiteralEvidence
  FloatLiteralEvidence
  StringLiteralEvidence
  ListLiteralEvidence
  OptionConstructorEvidence
  BinaryOperatorEvidence(glance.BinaryOperator)
  PipelineEvidence
}

/// The internal rule that connects an operator to its analysis evidence.
pub type MutationRule {
  MutationRule(operator: Operator, mode: AnalysisMode, evidence: TypeEvidence)
}

/// A candidate that was intentionally not emitted because its type evidence was insufficient.
pub type RejectedCandidate {
  RejectedCandidate(path: String, span: glance.Span, reason: String)
}

pub type RejectedMutant {
  RejectedMutant(mutant: Mutant, reason: String, diagnostic: String)
}

pub fn discover(
  path: String,
  source: String,
  enabled: List(Operator),
) -> Result(Catalog, glance.Error) {
  use module_ <- result.map(glance.module(source))
  let scope = option_scope(module_)
  let expressions =
    list.append(
      module_.functions
        |> list.flat_map(fn(definition) {
          expressions_in_statements(definition.definition.body)
        }),
      module_.constants
        |> list.flat_map(fn(definition) {
          expressions(definition.definition.value)
        }),
    )
  let candidates =
    expressions
    |> list.flat_map(expression_candidates(source, path, scope, _))
    |> list.filter(fn(candidate) { list.contains(enabled, candidate.operator) })
  let rejected =
    expressions
    |> list.flat_map(rejected_candidates(path, enabled, _))

  let source_index = mutant.index_source(source)
  candidates
  |> deduplicate_candidates
  |> list.map(mutant.from_candidate_indexed(source, _, source_index))
  |> assign_display_ids
  |> fn(mutants) { Catalog(mutants, rejected) }
}

/// The names a module has for the two `Option` constructors.
type OptionScope {
  OptionScope(
    /// The local name of `Some`, paired with how to write `None` beside it,
    /// when the module can write both without a qualifier on `Some`.
    unqualified: Option(#(String, String)),
    /// Qualifiers that reach `gleam/option` as a module.
    qualifiers: set.Set(String),
  )
}

const option_module = "gleam/option"

fn option_scope(module_: glance.Module) -> OptionScope {
  let imports =
    module_.imports
    |> list.map(fn(definition) { definition.definition })
    |> list.filter(fn(import_) { import_.module == option_module })

  let qualifiers =
    imports
    |> list.filter_map(fn(import_) {
      case import_.alias {
        Some(glance.Named(alias)) -> Ok(alias)
        // `import gleam/option as _` keeps the module out of reach.
        Some(glance.Discarded(_)) -> Error(Nil)
        None -> Ok(last_segment(import_.module))
      }
    })
    |> set.from_list

  let some =
    list.find_map(imports, fn(import_) {
      local_name(import_.unqualified_values, "Some")
    })
  // `None` is written unqualified when it was imported that way, and through
  // the module otherwise, which is what `import gleam/option.{Some}` leaves.
  let none =
    list.find_map(imports, fn(import_) {
      local_name(import_.unqualified_values, "None")
    })
    |> result.lazy_or(fn() {
      qualifiers
      |> set.to_list
      |> list.sort(string.compare)
      |> list.first
      |> result.map(fn(qualifier) { qualifier <> ".None" })
    })

  let unqualified =
    case some, none {
      Ok(some), Ok(none) -> Ok(#(some, none))
      _, _ -> Error(Nil)
    }
    |> result.lazy_or(fn() { declared_option(module_) })

  OptionScope(option.from_result(unqualified), qualifiers)
}

/// A type declared in this module carrying both variants: `gleam/option`
/// itself when that is what is being scanned, and any module that writes its
/// own option out longhand.
fn declared_option(module_: glance.Module) -> Result(#(String, String), Nil) {
  list.find_map(module_.custom_types, fn(definition) {
    let names =
      definition.definition.variants
      |> list.map(fn(variant) { variant.name })
    case list.contains(names, "Some") && list.contains(names, "None") {
      True -> Ok(#("Some", "None"))
      False -> Error(Nil)
    }
  })
}

/// The name an unqualified import goes by locally, keeping any alias.
fn local_name(
  values: List(glance.UnqualifiedImport),
  name: String,
) -> Result(String, Nil) {
  list.find_map(values, fn(value) {
    case value.name == name {
      True -> Ok(option.unwrap(value.alias, name))
      False -> Error(Nil)
    }
  })
}

fn last_segment(module_name: String) -> String {
  module_name
  |> string.split("/")
  |> list.last
  |> result.unwrap(module_name)
}

fn semantic_rule(operator: Operator, evidence: TypeEvidence) -> MutationRule {
  MutationRule(operator, Semantic, evidence)
}

fn syntax_rule(operator: Operator, evidence: TypeEvidence) -> MutationRule {
  MutationRule(operator, SyntaxBased, evidence)
}

fn rule_operator(rule: MutationRule) -> Operator {
  let MutationRule(operator, _, _) = rule
  operator
}

fn rejected_candidates(
  path: String,
  enabled: List(Operator),
  expression: glance.Expression,
) -> List(RejectedCandidate) {
  let own = case expression {
    glance.Variable(location, name) ->
      case name != "True" && name != "False" && needs_type_evidence(enabled) {
        True -> [RejectedCandidate(path, location, "type-evidence-unavailable")]
        False -> []
      }
    _ -> []
  }
  list.append(
    own,
    child_expressions(expression)
      |> list.flat_map(rejected_candidates(path, enabled, _)),
  )
}

fn needs_type_evidence(enabled: List(Operator)) -> Bool {
  list.any(enabled, fn(kind) {
    kind == operator.IntegerNeutral
    || kind == operator.FloatNeutral
    || kind == operator.StringNeutral
    || kind == operator.ListNeutral
    || kind == operator.OptionNeutral
  })
}

fn deduplicate_candidates(candidates: List(Candidate)) -> List(Candidate) {
  candidates
  |> list.fold(#(set.new(), []), fn(state, candidate) {
    let #(seen, unique) = state
    let key = #(
      mutant.normalize_path(candidate.path),
      span.start(candidate.span),
      span.end(candidate.span),
      candidate.replacement,
    )
    case set.contains(seen, key) {
      True -> state
      False -> #(set.insert(seen, key), [candidate, ..unique])
    }
  })
  |> fn(state) { list.reverse(state.1) }
}

pub fn assign_display_ids(mutants: List(Mutant)) -> List(Mutant) {
  let ids =
    mutants
    |> list.map(fn(item) { item.id })
    |> list.sort(string.compare)
    |> unique_sorted([], None)
  let prefixes = display_prefixes(ids, None, dict.new())
  list.map(mutants, fn(item) {
    mutant.with_display_id(
      item,
      dict.get(prefixes, item.id)
        |> result.unwrap(string.slice(item.id, 0, 20)),
    )
  })
}

fn unique_sorted(
  remaining: List(String),
  collected: List(String),
  previous: Option(String),
) -> List(String) {
  case remaining {
    [] -> list.reverse(collected)
    [id, ..rest] ->
      case previous == Some(id) {
        True -> unique_sorted(rest, collected, previous)
        False -> unique_sorted(rest, [id, ..collected], Some(id))
      }
  }
}

fn display_prefixes(
  ids: List(String),
  previous: Option(String),
  prefixes: dict.Dict(String, String),
) -> dict.Dict(String, String) {
  case ids {
    [] -> prefixes
    [id, ..rest] -> {
      let next = case list.first(rest) {
        Ok(value) -> Some(value)
        Error(_) -> None
      }
      let previous_collision = case previous {
        Some(value) -> common_prefix_length(value, id, 0)
        None -> 0
      }
      let next_collision = case next {
        Some(value) -> common_prefix_length(id, value, 0)
        None -> 0
      }
      let length =
        int.min(
          64,
          int.max(20, int.max(previous_collision, next_collision) + 1),
        )
      display_prefixes(
        rest,
        Some(id),
        dict.insert(prefixes, id, string.slice(id, 0, length)),
      )
    }
  }
}

fn common_prefix_length(left: String, right: String, offset: Int) -> Int {
  case
    offset >= 64
    || string.slice(left, offset, 1) != string.slice(right, offset, 1)
  {
    True -> offset
    False -> common_prefix_length(left, right, offset + 1)
  }
}

fn expression_candidates(
  source: String,
  path: String,
  scope: OptionScope,
  expression: glance.Expression,
) -> List(Candidate) {
  let own = case expression {
    glance.Variable(location, "True") -> [
      make_candidate(
        source,
        path,
        semantic_rule(operator.BooleanLiteral, BooleanLiteralEvidence),
        location,
        "False",
      ),
    ]
    glance.Variable(location, "False") -> [
      make_candidate(
        source,
        path,
        semantic_rule(operator.BooleanLiteral, BooleanLiteralEvidence),
        location,
        "True",
      ),
    ]
    glance.NegateBool(location, value) -> [
      make_candidate(
        source,
        path,
        semantic_rule(operator.BooleanNegation, BooleanNegationEvidence),
        location,
        source_for(source, value.location),
      ),
    ]
    glance.Int(location, value) -> [
      make_candidate(
        source,
        path,
        semantic_rule(operator.IntegerNeutral, IntegerLiteralEvidence),
        location,
        case value == "0" {
          True -> "1"
          False -> "0"
        },
      ),
    ]
    glance.Float(location, value) -> [
      make_candidate(
        source,
        path,
        semantic_rule(operator.FloatNeutral, FloatLiteralEvidence),
        location,
        case value == "0.0" {
          True -> "1.0"
          False -> "0.0"
        },
      ),
    ]
    glance.String(location, value) -> [
      make_candidate(
        source,
        path,
        semantic_rule(operator.StringNeutral, StringLiteralEvidence),
        location,
        case value == "" {
          True -> "\"mutant\""
          False -> "\"\""
        },
      ),
    ]
    glance.List(location, elements, rest) if elements != [] || rest != None -> [
      make_candidate(
        source,
        path,
        semantic_rule(operator.ListNeutral, ListLiteralEvidence),
        location,
        "[]",
      ),
    ]
    // `Some(x)` is definitely an `Option`, so `None` is definitely the same
    // type: the evidence is the constructor itself, not a guess about what
    // the expression around it might be. Nothing similar holds for `Ok` and
    // `Error`, whose two type arguments need not agree, so a `Result` that is
    // built is left alone rather than mutated on a hunch.
    //
    // Which name the module has for each constructor is read off its imports,
    // because `import gleam/option.{Some}` leaves `None` unnameable and a
    // mutant that cannot be written is worth less than no mutant at all.
    glance.Call(location, glance.Variable(_, name), [_]) ->
      case scope.unqualified {
        Some(#(some, none)) if name == some -> [
          make_candidate(
            source,
            path,
            semantic_rule(operator.OptionNeutral, OptionConstructorEvidence),
            location,
            none,
          ),
        ]
        _ -> []
      }
    // The same constructor reached through the module it is declared in. The
    // qualifier is copied from the call so that an alias is kept.
    glance.Call(
      location,
      glance.FieldAccess(_, glance.Variable(_, qualifier), "Some"),
      [_],
    ) ->
      case set.contains(scope.qualifiers, qualifier) {
        True -> [
          make_candidate(
            source,
            path,
            semantic_rule(operator.OptionNeutral, OptionConstructorEvidence),
            location,
            qualifier <> ".None",
          ),
        ]
        False -> []
      }
    glance.BinaryOperator(location, binary_operator, left, right) ->
      binary_candidates(source, path, location, binary_operator, left, right)
    _ -> []
  }

  list.append(
    own,
    child_expressions(expression)
      |> list.flat_map(expression_candidates(source, path, scope, _)),
  )
}

fn binary_candidates(
  source: String,
  path: String,
  location: glance.Span,
  binary_operator: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> List(Candidate) {
  case binary_replacement(binary_operator) {
    Some(#(kind, token, replacement_token)) -> {
      let gap =
        bytes.unsafe_slice(
          source,
          location_end(source, left.location),
          location_start(source, right.location),
        )
      case replace_operator(gap, token, replacement_token) {
        Ok(replacement_gap) -> [
          make_candidate(
            source,
            path,
            semantic_rule(kind, BinaryOperatorEvidence(binary_operator)),
            location,
            source_for(source, left.location)
              <> replacement_gap
              <> source_for(source, right.location),
          ),
        ]
        Error(_) -> []
      }
    }
    None ->
      case binary_operator {
        glance.Pipe -> [
          make_candidate(
            source,
            path,
            syntax_rule(operator.PipelineStageDeletion, PipelineEvidence),
            location,
            source_for(source, left.location),
          ),
        ]
        // `<>` joins two strings, so each half is definitely a string and
        // definitely the same type as the whole: the operator is its own
        // evidence, the way a typed comparison is. Keeping one half asks
        // whether anything checks that the other one reaches the answer.
        glance.Concatenate ->
          [left.location, right.location]
          |> list.map(fn(half) {
            make_candidate(
              source,
              path,
              semantic_rule(
                operator.ConcatenationOperand,
                BinaryOperatorEvidence(binary_operator),
              ),
              location,
              source_for(source, half),
            )
          })
        _ -> []
      }
  }
}

fn binary_replacement(
  binary_operator: glance.BinaryOperator,
) -> Option(#(Operator, String, String)) {
  case binary_operator {
    glance.And -> Some(#(operator.BooleanConnective, "&&", "||"))
    glance.Or -> Some(#(operator.BooleanConnective, "||", "&&"))
    glance.Eq -> Some(#(operator.Equality, "==", "!="))
    glance.NotEq -> Some(#(operator.Equality, "!=", "=="))
    glance.LtInt -> Some(#(operator.ComparisonBoundary, "<", "<="))
    glance.LtEqInt -> Some(#(operator.ComparisonBoundary, "<=", "<"))
    glance.GtInt -> Some(#(operator.ComparisonBoundary, ">", ">="))
    glance.GtEqInt -> Some(#(operator.ComparisonBoundary, ">=", ">"))
    glance.LtFloat -> Some(#(operator.ComparisonBoundary, "<.", "<=."))
    glance.LtEqFloat -> Some(#(operator.ComparisonBoundary, "<=.", "<."))
    glance.GtFloat -> Some(#(operator.ComparisonBoundary, ">.", ">=."))
    glance.GtEqFloat -> Some(#(operator.ComparisonBoundary, ">=.", ">."))
    glance.AddInt -> Some(#(operator.IntegerArithmetic, "+", "-"))
    glance.SubInt -> Some(#(operator.IntegerArithmetic, "-", "+"))
    glance.MultInt -> Some(#(operator.IntegerArithmetic, "*", "/"))
    glance.DivInt -> Some(#(operator.IntegerArithmetic, "/", "*"))
    glance.RemainderInt -> Some(#(operator.IntegerArithmetic, "%", "*"))
    glance.AddFloat -> Some(#(operator.FloatArithmetic, "+.", "-."))
    glance.SubFloat -> Some(#(operator.FloatArithmetic, "-.", "+."))
    glance.MultFloat -> Some(#(operator.FloatArithmetic, "*.", "/."))
    glance.DivFloat -> Some(#(operator.FloatArithmetic, "/.", "*."))
    glance.Pipe | glance.Concatenate -> None
  }
}

fn replace_operator(
  gap: String,
  token: String,
  replacement: String,
) -> Result(String, Nil) {
  replace_operator_lines(string.split(gap, "\n"), token, replacement, [])
}

fn replace_operator_lines(
  lines: List(String),
  token: String,
  replacement: String,
  before: List(String),
) -> Result(String, Nil) {
  case lines {
    [] -> Error(Nil)
    [line, ..rest] -> {
      let code = case string.split_once(line, "//") {
        Ok(#(code, _comment)) -> code
        Error(_) -> line
      }
      case string.split_once(code, token) {
        Ok(#(left, right)) -> {
          let suffix = string.drop_start(line, string.length(code))
          Ok(string.join(
            list.append(list.reverse(before), [
              left <> replacement <> right <> suffix,
              ..rest
            ]),
            "\n",
          ))
        }
        Error(_) ->
          replace_operator_lines(rest, token, replacement, [line, ..before])
      }
    }
  }
}

fn make_candidate(
  source: String,
  path: String,
  rule: MutationRule,
  location: glance.Span,
  replacement: String,
) -> Candidate {
  let start = location_start(source, location)
  let end = location_end(source, location)
  let candidate_span = span.unsafe_new(start, end)
  Candidate(
    path: path,
    operator: rule_operator(rule),
    span: candidate_span,
    original: bytes.unsafe_slice(source, start, end),
    replacement: replacement,
  )
}

fn source_for(source: String, location: glance.Span) -> String {
  bytes.unsafe_slice(
    source,
    location_start(source, location),
    location_end(source, location),
  )
}

fn location_start(source: String, location: glance.Span) -> Int {
  offset_to_byte(source, location.start)
}

fn location_end(source: String, location: glance.Span) -> Int {
  offset_to_byte(source, location.end)
}

@target(erlang)
fn offset_to_byte(_source: String, offset: Int) -> Int {
  offset
}

@target(javascript)
fn offset_to_byte(source: String, offset: Int) -> Int {
  codeunits_to_bytes(string.to_utf_codepoints(source), offset, 0)
}

@target(javascript)
fn codeunits_to_bytes(
  codepoints: List(UtfCodepoint),
  remaining: Int,
  bytes: Int,
) -> Int {
  case codepoints, remaining <= 0 {
    _, True -> bytes
    [], False -> bytes
    [codepoint, ..rest], False -> {
      let value = string.utf_codepoint_to_int(codepoint)
      let codeunits = case value > 0xFFFF {
        True -> 2
        False -> 1
      }
      let byte_length =
        string.byte_size(string.from_utf_codepoints([codepoint]))
      codeunits_to_bytes(rest, remaining - codeunits, bytes + byte_length)
    }
  }
}

fn expressions_in_statements(
  statements: List(glance.Statement),
) -> List(glance.Expression) {
  list.flat_map(statements, fn(statement) {
    case statement {
      glance.Use(_, _, function) -> expressions(function)
      glance.Assignment(_, _, _, _, value) -> expressions(value)
      glance.Assert(_, expression, message) ->
        list.append(expressions(expression), option_expressions(message))
      glance.Expression(expression) -> expressions(expression)
    }
  })
}

fn expressions(expression: glance.Expression) -> List(glance.Expression) {
  [expression]
}

fn option_expressions(
  value: Option(glance.Expression),
) -> List(glance.Expression) {
  case value {
    Some(expression) -> expressions(expression)
    None -> []
  }
}

fn child_expressions(expression: glance.Expression) -> List(glance.Expression) {
  case expression {
    glance.Int(_, _)
    | glance.Float(_, _)
    | glance.String(_, _)
    | glance.Variable(_, _) -> []
    glance.NegateInt(_, value) | glance.NegateBool(_, value) -> [value]
    glance.Block(_, statements) -> expressions_in_statements(statements)
    glance.Panic(_, message) | glance.Todo(_, message) ->
      option_expressions(message)
    glance.Tuple(_, elements) -> elements
    glance.List(_, elements, rest) ->
      list.append(elements, option_expressions(rest))
    glance.Fn(_, _, _, body) -> expressions_in_statements(body)
    glance.RecordUpdate(_, _, _, record, fields) ->
      list.append(record_update_expressions(fields), [record])
    glance.FieldAccess(_, container, _) -> [container]
    glance.Call(_, function, arguments) -> [
      function,
      ..field_expressions(arguments)
    ]
    glance.TupleIndex(_, tuple, _) -> [tuple]
    glance.FnCapture(_, _, function, before, after) -> [
      function,
      ..list.append(field_expressions(before), field_expressions(after))
    ]
    glance.BitString(_, segments) ->
      list.flat_map(segments, fn(segment) {
        let #(value, options) = segment
        [value, ..bit_string_option_expressions(options)]
      })
    glance.Case(_, subjects, clauses) ->
      list.append(subjects, list.flat_map(clauses, clause_expressions))
    glance.BinaryOperator(_, _, left, right) -> [left, right]
    glance.Echo(_, expression, message) ->
      list.append(option_expressions(expression), option_expressions(message))
  }
}

fn field_expressions(
  fields: List(glance.Field(glance.Expression)),
) -> List(glance.Expression) {
  list.flat_map(fields, fn(field) {
    case field {
      glance.LabelledField(_, _, item) | glance.UnlabelledField(item) -> [item]
      glance.ShorthandField(_, _) -> []
    }
  })
}

fn record_update_expressions(
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> List(glance.Expression) {
  list.flat_map(fields, fn(field) {
    let glance.RecordUpdateField(_, item) = field
    option_expressions(item)
  })
}

fn bit_string_option_expressions(
  options: List(glance.BitStringSegmentOption(glance.Expression)),
) -> List(glance.Expression) {
  list.flat_map(options, fn(option) {
    case option {
      glance.SizeValueOption(expression) -> [expression]
      _ -> []
    }
  })
}

fn clause_expressions(clause: glance.Clause) -> List(glance.Expression) {
  list.append(option_expressions(clause.guard), [clause.body])
}
