// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import process from "node:process";

function render(module, target, runtime) {
  const args = ["run", "-m", module, "--target", target];
  if (runtime) args.push("--runtime", runtime);
  const result = childProcess.spawnSync("gleam", args, {
    cwd: process.cwd(),
    encoding: "utf8",
    shell: false,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    process.stderr.write((result.stdout || "") + (result.stderr || ""));
    throw new Error(`${module} failed on ${runtime || target}`);
  }
  return result.stdout;
}

for (const module of ["stryker_schema_fixture", "stryker_html_fixture"]) {
  const outputs = new Map([
    ["erlang", render(module, "erlang")],
    ["node", render(module, "javascript", "node")],
    ["deno", render(module, "javascript", "deno")],
    ["bun", render(module, "javascript", "bun")],
  ]);
  const expected = outputs.get("erlang");
  for (const [runtime, output] of outputs) {
    if (output !== expected) throw new Error(`${module} differs byte-for-byte on ${runtime}`);
  }
}

console.log("Stryker JSON and offline HTML are byte-identical on Erlang, Node, Deno, and Bun");
