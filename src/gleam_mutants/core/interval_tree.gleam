// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/span

pub opaque type Forest {
  Forest(nodes: List(Node))
}

type Node {
  Node(span: span.Span, mutants: List(Mutant), children: List(Node))
}

pub type ForestError {
  PartialOverlap(first: Mutant, second: Mutant)
  SpanOutsideSource(mutant: Mutant)
}

pub fn build(
  source: String,
  mutants: List(Mutant),
) -> Result(Forest, ForestError) {
  use _ <- result.try(validate(source, mutants))
  mutants
  |> list.sort(fn(a, b) { span.compare(a.span, b.span) })
  |> list.try_fold([], insert)
  |> result.map(Forest)
}

fn validate(source: String, mutants: List(Mutant)) -> Result(Nil, ForestError) {
  let source_length = string.byte_size(source)
  use mutant <- list.try_each(mutants)
  use <- bool.guard(
    when: span.start(mutant.span) < 0 || span.end(mutant.span) > source_length,
    return: Error(SpanOutsideSource(mutant)),
  )
  use other <- list.try_each(mutants)
  use <- bool.guard(
    when: mutant.id != other.id
      && span.partially_overlaps(mutant.span, other.span),
    return: Error(PartialOverlap(mutant, other)),
  )
  Ok(Nil)
}

fn insert(
  nodes: List(Node),
  mutant: Mutant,
) -> Result(List(Node), ForestError) {
  case nodes {
    [] -> Ok([Node(mutant.span, [mutant], [])])
    [Node(node_span, node_mutants, children) as node, ..rest] ->
      case
        span.equal(node_span, mutant.span),
        span.strictly_contains(node_span, mutant.span),
        span.end(mutant.span) <= span.start(node_span)
      {
        True, _, _ ->
          Ok([Node(node_span, [mutant, ..node_mutants], children), ..rest])
        False, True, _ -> {
          use updated <- result.try(insert(children, mutant))
          Ok([Node(node_span, node_mutants, updated), ..rest])
        }
        False, False, True ->
          Ok([Node(mutant.span, [mutant], []), node, ..rest])
        False, False, False -> {
          use updated <- result.try(insert(rest, mutant))
          Ok([node, ..updated])
        }
      }
  }
}

pub fn render(
  source: String,
  forest: Forest,
  runtime_module: String,
) -> String {
  render_nodes(
    source,
    forest.nodes,
    0,
    string.byte_size(source),
    runtime_module,
  )
}

fn render_nodes(
  source: String,
  nodes: List(Node),
  cursor: Int,
  limit: Int,
  runtime_module: String,
) -> String {
  case nodes {
    [] -> bytes.unsafe_slice(source, cursor, limit)
    [node, ..rest] ->
      bytes.unsafe_slice(source, cursor, span.start(node.span))
      <> render_node(source, node, runtime_module)
      <> render_nodes(source, rest, span.end(node.span), limit, runtime_module)
  }
}

fn render_node(source: String, node: Node, runtime_module: String) -> String {
  let original =
    render_nodes(
      source,
      node.children,
      span.start(node.span),
      span.end(node.span),
      runtime_module,
    )

  node.mutants
  |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
  |> list.fold(original, fn(rendered, mutant) {
    runtime_module
    <> ".select("
    <> string.inspect(mutant.id)
    <> ", fn() { "
    <> rendered
    <> " }, fn() { "
    <> mutant.replacement
    <> " })"
  })
}

pub fn render_single(source: String, mutant: Mutant) -> String {
  bytes.unsafe_slice(source, 0, span.start(mutant.span))
  <> mutant.replacement
  <> bytes.unsafe_slice(source, span.end(mutant.span), string.byte_size(source))
}
