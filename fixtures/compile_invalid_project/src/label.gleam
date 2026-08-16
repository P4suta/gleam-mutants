// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int

pub fn label(value: Int) -> String {
  value |> int.to_string
}
