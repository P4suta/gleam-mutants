// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/order.{type Order, Eq, Gt, Lt}

pub opaque type Span {
  Span(start: Int, end: Int)
}

pub type SpanError {
  NegativeStart
  EndBeforeStart
}

pub fn new(start: Int, end: Int) -> Result(Span, SpanError) {
  case start < 0, end < start {
    True, _ -> Error(NegativeStart)
    _, True -> Error(EndBeforeStart)
    False, False -> Ok(Span(start, end))
  }
}

pub fn unsafe_new(start: Int, end: Int) -> Span {
  let assert Ok(span) = new(start, end)
  span
}

pub fn start(span: Span) -> Int {
  span.start
}

pub fn end(span: Span) -> Int {
  span.end
}

pub fn length(span: Span) -> Int {
  span.end - span.start
}

pub fn equal(a: Span, b: Span) -> Bool {
  a.start == b.start && a.end == b.end
}

pub fn contains(outer: Span, inner: Span) -> Bool {
  outer.start <= inner.start && outer.end >= inner.end
}

pub fn strictly_contains(outer: Span, inner: Span) -> Bool {
  contains(outer, inner) && !equal(outer, inner)
}

pub fn overlaps(a: Span, b: Span) -> Bool {
  a.start < b.end && b.start < a.end
}

pub fn partially_overlaps(a: Span, b: Span) -> Bool {
  overlaps(a, b) && !contains(a, b) && !contains(b, a)
}

pub fn compare(a: Span, b: Span) -> Order {
  case a.start < b.start, a.start > b.start, a.end > b.end, a.end < b.end {
    True, _, _, _ -> Lt
    _, True, _, _ -> Gt
    _, _, True, _ -> Lt
    _, _, _, True -> Gt
    _, _, _, _ -> Eq
  }
}
