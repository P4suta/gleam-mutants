// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import arithmetic

pub fn keep_test() {
  assert arithmetic.keep(5) == 5
}

pub fn add_test() {
  assert arithmetic.add(2, 3) == 5
}
