// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}
import gleam_mutants/core/bytes
import gleam_mutants/core/mutant.{type Mutant}
import gleam_mutants/core/span

pub opaque type Forest {
  Forest(nodes: List(Node))
}

type Node {
  Node(span: span.Span, mutants: List(Mutant), children: List(Node))
}

type FlatNode {
  FlatNode(span: span.Span, mutants: List(Mutant))
}

pub type ForestError {
  PartialOverlap(first: Mutant, second: Mutant)
  SpanOutsideSource(mutant: Mutant)
}

pub fn build(
  source: String,
  mutants: List(Mutant),
) -> Result(Forest, ForestError) {
  let sorted = list.sort(mutants, fn(a, b) { span.compare(a.span, b.span) })
  use _ <- result.try(validate(source, sorted))
  let grouped = group_equal_spans(sorted, [])
  let #(nodes, _) = parse_nodes(grouped, None)
  Ok(Forest(nodes))
}

fn validate(source: String, mutants: List(Mutant)) -> Result(Nil, ForestError) {
  let source_length = string.byte_size(source)
  validate_sorted(mutants, source_length, [])
}

fn validate_sorted(
  remaining: List(Mutant),
  source_length: Int,
  active: List(Mutant),
) -> Result(Nil, ForestError) {
  case remaining {
    [] -> Ok(Nil)
    [mutant, ..rest] -> {
      case
        span.start(mutant.span) < 0 || span.end(mutant.span) > source_length
      {
        True -> Error(SpanOutsideSource(mutant))
        False -> {
          let active = drop_finished(active, span.start(mutant.span))
          case active {
            [parent, ..] ->
              case
                span.equal(parent.span, mutant.span),
                span.end(mutant.span) > span.end(parent.span)
              {
                True, _ -> validate_sorted(rest, source_length, active)
                False, True -> Error(PartialOverlap(parent, mutant))
                False, False ->
                  validate_sorted(rest, source_length, [mutant, ..active])
              }
            _ -> validate_sorted(rest, source_length, [mutant, ..active])
          }
        }
      }
    }
  }
}

fn drop_finished(active: List(Mutant), start: Int) -> List(Mutant) {
  case active {
    [parent, ..rest] ->
      case start >= span.end(parent.span) {
        True -> drop_finished(rest, start)
        False -> active
      }
    _ -> active
  }
}

fn group_equal_spans(
  remaining: List(Mutant),
  grouped: List(FlatNode),
) -> List(FlatNode) {
  case remaining {
    [] -> list.reverse(grouped)
    [mutant, ..rest] -> {
      let #(same, rest) =
        list.split_while(rest, fn(other) { span.equal(mutant.span, other.span) })
      group_equal_spans(rest, [
        FlatNode(mutant.span, [mutant, ..same]),
        ..grouped
      ])
    }
  }
}

fn parse_nodes(
  remaining: List(FlatNode),
  limit: Option(Int),
) -> #(List(Node), List(FlatNode)) {
  case remaining {
    [] -> #([], [])
    [flat, ..rest] ->
      case limit {
        Some(end) ->
          case span.start(flat.span) >= end {
            True -> #([], remaining)
            False -> {
              let #(children, after_children) =
                parse_nodes(rest, Some(span.end(flat.span)))
              let node = Node(flat.span, flat.mutants, children)
              let #(siblings, after_siblings) =
                parse_nodes(after_children, limit)
              #([node, ..siblings], after_siblings)
            }
          }
        None -> {
          let #(children, after_children) =
            parse_nodes(rest, Some(span.end(flat.span)))
          let node = Node(flat.span, flat.mutants, children)
          let #(siblings, after_siblings) = parse_nodes(after_children, limit)
          #([node, ..siblings], after_siblings)
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
  |> string_tree.to_string
}

fn render_nodes(
  source: String,
  nodes: List(Node),
  cursor: Int,
  limit: Int,
  runtime_module: String,
) -> StringTree {
  case nodes {
    [] -> bytes.unsafe_slice(source, cursor, limit) |> string_tree.from_string
    [node, ..rest] ->
      string_tree.concat([
        bytes.unsafe_slice(source, cursor, span.start(node.span))
          |> string_tree.from_string,
        render_node(source, node, runtime_module),
        render_nodes(source, rest, span.end(node.span), limit, runtime_module),
      ])
  }
}

fn render_node(
  source: String,
  node: Node,
  runtime_module: String,
) -> StringTree {
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
    string_tree.concat([
      string_tree.from_string(
        runtime_module <> ".select(" <> string.inspect(mutant.id) <> ", fn() { ",
      ),
      rendered,
      string_tree.from_string(" }, fn() { " <> mutant.replacement <> " })"),
    ])
  })
}

pub fn render_single(source: String, mutant: Mutant) -> String {
  bytes.unsafe_slice(source, 0, span.start(mutant.span))
  <> mutant.replacement
  <> bytes.unsafe_slice(source, span.end(mutant.span), string.byte_size(source))
}
