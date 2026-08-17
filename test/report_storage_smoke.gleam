// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/project_report
import gleam_mutants/snapshot
import simplifile

pub fn main() {
  let assert [mode, workspace] = platform.arguments()
  case mode {
    "write" -> {
      let assert Ok(before) =
        snapshot.create_excluding(workspace, [
          "reports/mutation",
        ])
      let before_digest = snapshot.digest(before)
      let assert Ok(Nil) = snapshot.dispose(before)
      let assert Ok(paths) =
        project_report.write(
          workspace,
          "reports/mutation",
          "{\"new\":true}\n",
          "<html>new</html>\n",
        )
      assert paths.json_path
        == path.join(workspace, "reports/mutation/mutation.json")
      assert paths.html_path
        == path.join(workspace, "reports/mutation/mutation.html")
      let assert Ok(json) = simplifile.read(paths.json_path)
      let assert Ok(html) = simplifile.read(paths.html_path)
      assert json == "{\"new\":true}\n"
      assert html == "<html>new</html>\n"
      let assert Ok(after) =
        snapshot.create_excluding(workspace, [
          "reports/mutation",
        ])
      assert snapshot.digest(after) == before_digest
      assert !list.any(snapshot.entries(after), fn(entry) {
        string.starts_with(entry.path, "reports/mutation/")
      })
      let assert Ok(Nil) = snapshot.dispose(after)
      Nil
    }
    "reject" -> {
      let assert Error(_) =
        project_report.write(
          workspace,
          "reports/mutation",
          "new json",
          "new html",
        )
      let assert Ok(old_html) =
        simplifile.read(path.join(workspace, "reports/mutation/mutation.html"))
      assert old_html == "old html\n"
    }
    "reparse" -> {
      let assert Error(message) =
        project_report.write(
          workspace,
          "reports/mutation",
          "new json",
          "new html",
        )
      assert string.contains(message, "symlink or junction")
    }
    _ -> panic as "unknown report storage smoke mode"
  }
}
