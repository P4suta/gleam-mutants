// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam_mutants/stryker_html
import stryker_schema_fixture

pub fn main() {
  let assert Ok(html) =
    stryker_schema_fixture.fixture_json()
    |> stryker_html.render
  io.print(html)
}
