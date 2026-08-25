// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import glance
import gleam/list
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/operator
import gleam_mutants/core/span
import gleam_mutants/suggest/select

// --- fixtures ---------------------------------------------------------------

const module_source = "const limit = 10

pub fn add(a: Int, b: Int) -> Int {
  a + b
}

fn helper(x: Int) -> Int {
  x * 2
}
"

const return_source = "pub fn plain(x: Int) -> Int {
  x
}

pub fn nested_containers() -> List(Result(#(Int, String), Nil)) {
  todo
}

pub fn unannotated(x: Int) {
  x
}

pub fn returns_function(x: Int) -> fn(Int) -> Int {
  todo
}

pub fn returns_function_list() -> List(fn() -> Nil) {
  todo
}

pub fn returns_function_tuple() -> #(Int, fn() -> Int) {
  todo
}

pub fn returns_function_result() -> Result(Int, fn() -> Nil) {
  todo
}

pub fn returns_function_option() -> Option(fn() -> Int) {
  todo
}
"

// --- helpers ----------------------------------------------------------------

fn parsed(source: String) -> glance.Module {
  let assert Ok(module) = glance.module(source)
  module
}

fn function_named(module: glance.Module, name: String) -> glance.Function {
  let assert Ok(found) =
    list.find(module.functions, fn(candidate) {
      candidate.definition.name == name
    })
  found.definition
}

fn probe_mutant(id: String, start: Int, end: Int) -> Mutant {
  mutant.Mutant(
    id: id,
    display_id: id,
    path: "src/target.gleam",
    operator: operator.IntegerNeutral,
    operator_version: 1,
    source_digest: "source-digest",
    span: span.unsafe_new(start, end),
    original_digest: "original-digest",
    replacement_digest: "replacement-digest",
    original: "1",
    replacement: "0",
    line: 1,
    column: 1,
  )
}

// --- assign -----------------------------------------------------------------

pub fn assign_groups_mutants_by_enclosing_function_test() {
  let module = parsed(module_source)
  let add = function_named(module, "add")
  let helper = function_named(module, "helper")
  let glance.Span(add_start, add_end) = add.location
  let glance.Span(helper_start, _) = helper.location

  let in_constant = probe_mutant("in-constant", 0, 5)
  let add_first = probe_mutant("add-first", add_start, add_start + 3)
  let add_second = probe_mutant("add-second", add_end - 3, add_end)
  let between = probe_mutant("between", add_end, add_end + 1)
  let helper_only =
    probe_mutant("helper-only", helper_start + 2, helper_start + 4)

  assert select.assign(module, [
      in_constant,
      add_first,
      add_second,
      between,
      helper_only,
    ])
    == #(
      [
        select.FunctionTarget(add, [add_first, add_second]),
        select.FunctionTarget(helper, [helper_only]),
      ],
      [in_constant, between],
    )
}

pub fn assign_keeps_private_functions_and_omits_empty_ones_test() {
  let module = parsed(module_source)
  let helper = function_named(module, "helper")
  let glance.Span(helper_start, _) = helper.location
  let only = probe_mutant("only", helper_start, helper_start + 2)

  assert helper.publicity == glance.Private
  assert select.assign(module, [only])
    == #([select.FunctionTarget(helper, [only])], [])
}

pub fn assign_treats_the_function_span_as_inclusive_test() {
  let module = parsed(module_source)
  let add = function_named(module, "add")
  let glance.Span(add_start, add_end) = add.location
  let exact = probe_mutant("exact", add_start, add_end)
  let straddling = probe_mutant("straddling", add_start - 1, add_end)

  assert select.assign(module, [exact, straddling])
    == #([select.FunctionTarget(add, [exact])], [straddling])
}

pub fn assign_returns_nothing_for_an_empty_mutant_list_test() {
  assert select.assign(parsed(module_source), []) == #([], [])
}

// --- comparable_return ------------------------------------------------------

pub fn comparable_return_accepts_value_returns_test() {
  let module = parsed(return_source)
  assert select.comparable_return(function_named(module, "plain"))
  assert select.comparable_return(function_named(module, "nested_containers"))
  assert select.comparable_return(function_named(module, "unannotated"))
}

pub fn comparable_return_rejects_function_returns_test() {
  let module = parsed(return_source)
  assert !select.comparable_return(function_named(module, "returns_function"))
  assert !select.comparable_return(function_named(
    module,
    "returns_function_list",
  ))
  assert !select.comparable_return(function_named(
    module,
    "returns_function_tuple",
  ))
  assert !select.comparable_return(function_named(
    module,
    "returns_function_result",
  ))
  assert !select.comparable_return(function_named(
    module,
    "returns_function_option",
  ))
}
