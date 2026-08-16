// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = process.cwd();
const checksums = path.join(root, "dist", "SHA256SUMS");

function build() {
  const result = childProcess.spawnSync(process.execPath, ["scripts/package.mjs"], {
    cwd: root,
    env: process.env,
    stdio: "inherit",
    shell: false,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`artifact build failed with exit ${result.status}`);
  return fs.readFileSync(checksums, "utf8");
}

const first = build();
const second = build();
if (first !== second) {
  throw new Error(`artifact build is not reproducible\nfirst:\n${first}\nsecond:\n${second}`);
}
console.log("Artifact checksums reproduced exactly across two clean builds");
