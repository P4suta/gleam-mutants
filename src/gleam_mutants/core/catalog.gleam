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
    |> list.flat_map(expression_candidates(source, path, _))
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
    glance.BinaryOperator(location, binary_operator, left, right) ->
      binary_candidates(source, path, location, binary_operator, left, right)
    _ -> []
  }

  list.append(
    own,
    child_expressions(expression)
      |> list.flat_map(expression_candidates(source, path, _)),
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
