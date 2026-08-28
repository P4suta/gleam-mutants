// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = process.cwd();
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "gleam mutants snapshot "));
const valid = path.join(temporary, "project with spaces");
const rejected = path.join(temporary, "project with junction");
const outside = path.join(temporary, "outside");

function makeProject(directory) {
  fs.mkdirSync(path.join(directory, "src"), { recursive: true });
  fs.mkdirSync(path.join(directory, "build"), { recursive: true });
  fs.mkdirSync(path.join(directory, "priv"), { recursive: true });
  fs.writeFileSync(path.join(directory, "gleam.toml"), "name = \"snapshot_fixture\"\nversion = \"0.0.0\"\n");
  fs.writeFileSync(path.join(directory, "src", "main.gleam"), "pub fn main() { Nil }\n");
  fs.writeFileSync(path.join(directory, "build", "ignored"), "ignored\n");
  fs.writeFileSync(path.join(directory, "priv", "asset.txt"), "asset\n");
}

function run(target, mode, directory) {
  const args = ["run", "-m", "snapshot_safety_smoke", "--target", target];
  if (target === "javascript") args.push("--runtime", "node");
  args.push("--", mode, directory);
  const result = childProcess.spawnSync("gleam", args, { cwd: root, stdio: "inherit", shell: false });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`snapshot ${mode} smoke failed on ${target}`);
}

try {
  makeProject(valid);
  makeProject(rejected);
  fs.mkdirSync(outside, { recursive: true });
  const nestedDependencies = path.join(valid, "editors", "demo", "node_modules", ".bin");
  fs.mkdirSync(nestedDependencies, { recursive: true });
  fs.symlinkSync(
    outside,
    path.join(nestedDependencies, "tool"),
    process.platform === "win32" ? "junction" : "dir",
  );
  fs.symlinkSync(outside, path.join(rejected, "escape"), process.platform === "win32" ? "junction" : "dir");
  for (const target of ["erlang", "javascript"]) {
    run(target, "valid", valid);
    run(target, "generated-links", valid);
    run(target, "reject", rejected);
  }
  console.log("snapshot spaces/exclusion/input-link rejection/generated-link cleanup passed on Erlang and JavaScript");
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
