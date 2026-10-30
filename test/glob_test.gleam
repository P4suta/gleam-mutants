// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam_mutants/core/glob

pub fn globstar_consumes_complete_directories_test() {
  assert !glob.matches("**/app.gleam", "myapp.gleam")
  assert !glob.matches("src/**/app.gleam", "src/domain/myapp.gleam")
  assert glob.matches("src/**/app.gleam", "src/app.gleam")
  assert glob.matches("src/**/app.gleam", "src/domain/app.gleam")
  assert glob.matches("src/**/app.gleam", "src/domain/nested/app.gleam")
}
