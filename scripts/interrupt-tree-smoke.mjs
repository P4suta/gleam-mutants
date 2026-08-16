// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

if (process.platform === "win32") {
  console.log("process-tree SIGINT cleanup skipped on Windows; exit 130 is covered separately");
  process.exit(0);
}

const root = process.cwd();
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "gleam-mutants-interrupt-"));
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function waitFor(predicate, timeoutMs) {
  const started = Date.now();
  while (!predicate()) {
    if (Date.now() - started > timeoutMs) throw new Error("timed out waiting for interrupt fixture");
    await delay(50);
  }
}

function command(runtime, files) {
  const common = ["run", "-m", "interrupt_tree_smoke"];
  if (runtime === "erlang") return ["gleam", [...common, "--target", "erlang", "--", ...files]];
  return ["gleam", [...common, "--target", "javascript", "--runtime", "node", "--", ...files]];
}

try {
  for (const runtime of ["erlang", "node"]) {
    const files = ["ready-a", "ready-b", "marker-a", "marker-b"].map(name => path.join(temporary, `${runtime}-${name}`));
    const [executable, args] = command(runtime, files);
    const child = childProcess.spawn(executable, args, { cwd: root, detached: true, stdio: "ignore" });
    try {
      await waitFor(() => fs.existsSync(files[0]) && fs.existsSync(files[1]), 30_000);
      process.kill(-child.pid, "SIGINT");
      const exit = await Promise.race([
        new Promise(resolve => child.once("exit", (code, signal) => resolve({ code, signal }))),
        delay(10_000).then(() => { throw new Error(`${runtime} ignored SIGINT`); }),
      ]);
      if (exit.code !== 130 && exit.signal !== "SIGINT") throw new Error(`${runtime} returned ${JSON.stringify(exit)}`);
      await delay(2500);
      if (fs.existsSync(files[2]) || fs.existsSync(files[3])) throw new Error(`${runtime} left a worker descendant alive`);
    } finally {
      try { process.kill(-child.pid, "SIGKILL"); } catch (_) {}
    }
  }
  console.log("process-tree SIGINT cleanup passed on Erlang and Node");
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}