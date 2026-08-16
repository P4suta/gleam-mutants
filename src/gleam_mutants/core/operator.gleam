// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/result

pub type Operator {
  BooleanLiteral
  BooleanNegation
  BooleanConnective
  Equality
  ComparisonBoundary
  IntegerArithmetic
  FloatArithmetic
  IntegerNeutral
  FloatNeutral
  StringNeutral
  ListNeutral
  PipelineStageDeletion
}

pub fn all() -> List(Operator) {
  [
    BooleanLiteral,
    BooleanNegation,
    BooleanConnective,
    Equality,
    ComparisonBoundary,
    IntegerArithmetic,
    FloatArithmetic,
    IntegerNeutral,
    FloatNeutral,
    StringNeutral,
    ListNeutral,
    PipelineStageDeletion,
  ]
}

pub fn name(operator: Operator) -> String {
  case operator {
    BooleanLiteral -> "boolean-literal"
    BooleanNegation -> "boolean-negation"
    BooleanConnective -> "boolean-connective"
    Equality -> "equality"
    ComparisonBoundary -> "comparison-boundary"
    IntegerArithmetic -> "integer-arithmetic"
    FloatArithmetic -> "float-arithmetic"
    IntegerNeutral -> "integer-neutral"
    FloatNeutral -> "float-neutral"
    StringNeutral -> "string-neutral"
    ListNeutral -> "list-neutral"
    PipelineStageDeletion -> "pipeline-stage-deletion"
  }
}

pub fn version(_operator: Operator) -> Int {
  1
}

pub fn from_name(value: String) -> Result(Operator, Nil) {
  all()
  |> list.find(fn(operator) { name(operator) == value })
  |> result.replace_error(Nil)
}
