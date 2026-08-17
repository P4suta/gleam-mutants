// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = process.cwd();
const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "gleam-mutants-benchmark-"));
try {
  const sourceDirectory = path.join(workspace, "src");
  fs.mkdirSync(sourceDirectory, { recursive: true });
  fs.writeFileSync(path.join(workspace, "gleam.toml"), 'name = "benchmark_fixture"\nversion = "1.0.0"\n');
  const body = "pub fn exercise(a: Int, b: Int) { let _ = True let _ = False let _ = !True let _ = True && False let _ = a + b let _ = a - b let _ = a * b let _ = a < b let _ = a <= b let _ = a == b let _ = a != b let _ = 1 let _ = 2 let _ = 3 let _ = \"x\" let _ = [1] a }\n";
  const padding = "//" + "x".repeat(104_700) + "\n";
  for (let index = 0; index < 1_000; index += 1) {
    fs.writeFileSync(path.join(sourceDirectory, `file_${String(index).padStart(4, "0")}.gleam`), padding + body);
  }
  const result = childProcess.spawnSync(
    "gleam",
    ["run", "-m", "benchmark_smoke", "--target", "erlang", "--", workspace],
    { cwd: root, encoding: "utf8", shell: false, maxBuffer: 4 * 1024 * 1024 },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) {
    process.stderr.write((result.stdout || "") + (result.stderr || ""));
    throw new Error("tested-envelope benchmark failed");
  }
  const metrics = JSON.parse(result.stdout.trim().split(/\r?\n/).at(-1));
  console.log(`benchmark passed: ${JSON.stringify(metrics)}`);
} finally {
  fs.rmSync(workspace, { recursive: true, force: true });
}
