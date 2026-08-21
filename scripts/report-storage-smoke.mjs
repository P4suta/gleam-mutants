// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = process.cwd();
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "gleam mutants reports "));

function makeProject(directory) {
  fs.mkdirSync(path.join(directory, "src"), { recursive: true });
  fs.writeFileSync(path.join(directory, "gleam.toml"), "name = \"report_fixture\"\nversion = \"0.0.0\"\n");
  fs.writeFileSync(path.join(directory, "src", "main.gleam"), "pub fn main() { Nil }\n");
}

function run(target, mode, directory) {
  const args = ["run", "-m", "report_storage_smoke", "--target", target];
  if (target === "javascript") args.push("--runtime", "node");
  args.push("--", mode, directory);
  const result = childProcess.spawnSync("gleam", args, { cwd: root, stdio: "inherit", shell: false });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`report storage ${mode} failed on ${target}`);
}

try {
  for (const target of ["erlang", "javascript"]) {
    const valid = path.join(temporary, `valid-${target}`);
    makeProject(valid);
    fs.mkdirSync(path.join(valid, "reports", "mutation"), { recursive: true });
    fs.writeFileSync(path.join(valid, "reports", "mutation", "mutation.json"), "old json\n");
    fs.writeFileSync(path.join(valid, "reports", "mutation", "mutation.html"), "old html\n");
    run(target, "write", valid);
    const names = fs.readdirSync(path.join(valid, "reports", "mutation")).sort();
    if (JSON.stringify(names) !== JSON.stringify(["mutation.html", "mutation.json"])) {
      throw new Error(`temporary report files remained: ${names.join(", ")}`);
    }

    const rejected = path.join(temporary, `rejected-${target}`);
    makeProject(rejected);
    fs.mkdirSync(path.join(rejected, "reports", "mutation", "mutation.json"), { recursive: true });
    fs.writeFileSync(path.join(rejected, "reports", "mutation", "mutation.html"), "old html\n");
    run(target, "reject", rejected);

    const reparse = path.join(temporary, `reparse-${target}`);
    const outside = path.join(temporary, `outside-${target}`);
    makeProject(reparse);
    fs.mkdirSync(path.join(reparse, "reports"), { recursive: true });
    fs.mkdirSync(outside, { recursive: true });
    fs.symlinkSync(outside, path.join(reparse, "reports", "mutation"), process.platform === "win32" ? "junction" : "dir");
    run(target, "reparse", reparse);
  }
  console.log("report atomic replacement, exclusion, and reparse safety passed on Erlang and JavaScript");
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
