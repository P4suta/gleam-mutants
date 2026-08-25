// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/string
import gleam_mutants/suggest/pbt_source
import simplifile

const spdx_header = "// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0
"

pub fn pbt_source_matches_the_checked_in_module_test() {
  let assert Ok(expected) = simplifile.read("src/gleam_mutants/pbt.gleam")
  assert pbt_source.source() == expected
}

pub fn pbt_source_starts_with_the_spdx_header_test() {
  assert string.starts_with(pbt_source.source(), spdx_header)
}
