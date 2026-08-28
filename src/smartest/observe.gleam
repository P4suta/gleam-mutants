//// Explicit observations and renderings for opaque application values.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

pub opaque type Observer(a, b) {
  Observer(run: fn(a) -> b)
}

pub opaque type Renderer(a) {
  Renderer(run: fn(a) -> String)
}

pub fn observer(run: fn(a) -> b) -> Observer(a, b) {
  Observer(run)
}

pub fn renderer(run: fn(a) -> String) -> Renderer(a) {
  Renderer(run)
}

pub fn observe(observer: Observer(a, b), value: a) -> b {
  let run = observer.run
  run(value)
}

pub fn render(renderer: Renderer(a), value: a) -> String {
  let run = renderer.run
  run(value)
}

pub fn then(first: Observer(a, b), second: Observer(b, c)) -> Observer(a, c) {
  Observer(fn(value) { observe(second, observe(first, value)) })
}

pub fn map(observer: Observer(a, b), transform: fn(b) -> c) -> Observer(a, c) {
  Observer(fn(value) { transform(observe(observer, value)) })
}

pub fn contramap(renderer: Renderer(a), transform: fn(b) -> a) -> Renderer(b) {
  Renderer(fn(value) { render(renderer, transform(value)) })
}
