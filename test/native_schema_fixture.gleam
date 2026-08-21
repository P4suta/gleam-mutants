// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import stryker_schema_fixture

pub fn main() {
  io.print(stryker_schema_fixture.native_fixture_json())
}
