// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = process.cwd();
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "gleam-mutants-tree-"));
const wait = milliseconds => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);

function command(runtime, marker) {
  if (runtime === "erlang") return ["gleam", ["run", "-m", "process_tree_smoke", "--target", "erlang", "--", marker]];
  if (runtime === "node") return ["gleam", ["run", "-m", "process_tree_smoke", "--target", "javascript", "--runtime", "node", "--", marker]];
  const main = path.join(root, "build", "dev", "javascript", "gleam_mutants", "gleam@@private_main_v1.18.1.mjs");
  if (runtime === "deno") return ["deno", ["run", "--allow-read", "--allow-run", "--allow-env=GLEAM_MUTANTS_ACTIVE,GLEAM_MUTANTS_RUNTIME", main, marker]];
  return ["bun", ["run", main, marker]];
}

try {
  for (const runtime of ["erlang", "node", "deno", "bun"]) {
    const marker = path.join(temporary, `${runtime}.txt`);
    const [program, args] = command(runtime, marker);
    const result = childProcess.spawnSync(program, args, { cwd: root, stdio: "inherit", shell: false });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`${runtime} timeout smoke failed`);
    wait(2200);
    if (fs.existsSync(marker)) throw new Error(`${runtime} left a descendant process alive`);
  }
  console.log("process-tree timeout cleanup passed on Erlang, Node, Deno, and Bun");
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
