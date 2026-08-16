// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import flag
import unitest

pub fn main() {
  unitest.main()
}

pub fn enabled_test() {
  assert flag.enabled()
}
