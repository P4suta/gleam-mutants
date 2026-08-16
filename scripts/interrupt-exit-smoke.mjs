// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = process.cwd();
const main = path.join(root, "build", "dev", "javascript", "gleam_mutants", "interrupt_exit_smoke.mjs");
const importMain = `import { main } from ${JSON.stringify(pathToFileURL(main).href)}; main();`;
const commands = [
  ["erlang", "gleam", ["run", "-m", "interrupt_exit_smoke", "--target", "erlang"]],
  ["node", "gleam", ["run", "-m", "interrupt_exit_smoke", "--target", "javascript", "--runtime", "node"]],
  ["deno", "deno", ["eval", importMain]],
  ["bun", "bun", ["-e", importMain]],
];

for (const [runtime, executable, args] of commands) {
  for (const mode of ["sequential", "batch"]) {
    const result = childProcess.spawnSync(executable, args, {
      cwd: root,
      encoding: "utf8",
      env: { ...process.env, GLEAM_MUTANTS_TEST_MODE: mode },
      windowsHide: true,
    });
    if (result.error) throw result.error;
    if (result.status !== 130) {
      throw new Error(`${runtime} ${mode} did not preserve exit 130 (got ${result.status})\n${result.stdout}\n${result.stderr}`);
    }
  }
}

console.log("interrupt exit 130 passed on Erlang, Node, Deno, and Bun");