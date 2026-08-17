// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = process.cwd();
const fixture = path.join(root, "fixtures", "basic_project");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "gleam mutants lifecycle "));

function project(mode) {
  const directory = path.join(temporary, mode);
  fs.cpSync(fixture, directory, { recursive: true });
  return directory;
}

function run(mode, directory) {
  const result = childProcess.spawnSync(
    "gleam",
    ["run", "-m", "report_lifecycle_smoke", "--target", "erlang", "--", mode, directory],
    { cwd: root, stdio: "inherit", shell: false },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`report lifecycle ${mode} failed`);
}

try {
  const baseline = project("baseline");
  fs.mkdirSync(path.join(baseline, "reports", "mutation"), { recursive: true });
  fs.writeFileSync(path.join(baseline, "reports", "mutation", "mutation.json"), "old json\n");
  fs.writeFileSync(path.join(baseline, "reports", "mutation", "mutation.html"), "old html\n");
  run("baseline", baseline);

  const zero = project("zero");
  fs.writeFileSync(path.join(zero, "src", "no_sites.gleam"), "pub type Empty { Empty }\n");
  run("zero", zero);
  run("strict", project("strict"));

  const runtime = project("runtime");
  fs.writeFileSync(
    path.join(runtime, "mutant-test-command.mjs"),
    "if (process.env.GLEAM_MUTANTS_ACTIVE) { console.error('runtime boom'); process.exit(2); }\n",
  );
  run("runtime", runtime);
  console.log("report lifecycle covers baseline preservation, zero mutants, strict failure, and RuntimeError");
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
