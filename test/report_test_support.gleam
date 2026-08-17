// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam_mutants/core/path
import simplifile

pub fn cleanup(workspace: String) -> Nil {
  let directory = path.join(workspace, "reports/mutation")
  let _ = simplifile.delete_file(at: path.join(directory, "mutation.json"))
  let _ = simplifile.delete_file(at: path.join(directory, "mutation.html"))
  Nil
}
