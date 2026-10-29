// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/string

pub fn valid(value: String) -> Bool {
  value != ""
  && value != "."
  && value != ".."
  && !string.contains(value, "/")
  && !string.contains(value, "\\")
  && !string.contains(value, "\u{0000}")
}
