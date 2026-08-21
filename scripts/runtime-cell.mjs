// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const [host, target] = process.argv.slice(2);
if (!["erlang", "node", "deno", "bun"].includes(host)) throw new Error(`unknown host ${host}`);
if (!["erlang", "node", "deno", "bun"].includes(target)) throw new Error(`unknown target ${target}`);
const root = process.cwd();
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), `gleam-mutants-${host}-${target}-`));

function run(program, args, options = {}) {
  const result = childProcess.spawnSync(program, args, {
    cwd: root,
    encoding: "utf8",
    shell: false,
    maxBuffer: 8 * 1024 * 1024,
    ...options,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    process.stderr.write((result.stdout || "") + (result.stderr || ""));
    throw new Error(`${program} failed for ${host} host / ${target} target with ${result.status}`);
  }
  return result.stdout;
}

try {
  fs.cpSync(path.join(root, "fixtures", "basic_project"), temporary, { recursive: true });
  const targetName = target === "erlang" ? "erlang" : "javascript";
  const config = `\n[tools.gleam_mutants.test]\ntarget = "${targetName}"\nruntime = "${target}"\n\n[tools.gleam_mutants.policy]\nstrict = false\nminimum_score = 100\nrequire_mutants = true\n\n[tools.gleam_mutants.report]\nformats = []\nhistory = false\n`;
  fs.appendFileSync(path.join(temporary, "gleam.toml"), config);
  const cliArguments = ["--root", temporary, "run", "--no-strict", "--report", "none", "--jobs", "2"];
  let output;
  if (host === "erlang") {
    output = run("gleam", ["run", "-m", "gleam_mutants", "--target", "erlang", "--", ...cliArguments]);
  } else if (host === "deno") {
    run("gleam", ["build", "--target", "javascript"]);
    output = run("deno", ["run", "--allow-all", path.join(root, "scripts", "deno-host.mjs"), ...cliArguments]);
  } else {
    output = run("gleam", ["run", "-m", "gleam_mutants", "--target", "javascript", "--runtime", host, "--", ...cliArguments]);
  }
  if (!output.includes("Mutation score:")) throw new Error("runtime cell did not complete a mutation domain result");
  console.log(`runtime cell passed: ${host} host / ${target} target`);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
