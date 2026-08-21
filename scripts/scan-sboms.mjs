// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const dist = path.resolve("dist");
const sboms = fs.existsSync(dist)
  ? fs.readdirSync(dist)
    .filter(name => name.endsWith(".cdx.json"))
    .sort()
  : [];
if (sboms.length !== 3) {
  throw new Error("expected Hex, escript, and npm CycloneDX SBOMs");
}
for (const name of sboms) {
  const source = `sbom:${path.join(dist, name)}`;
  const result = childProcess.spawnSync(
    "grype",
    [source, "--fail-on", "high", "--output", "table"],
    { cwd: process.cwd(), stdio: "inherit", shell: false },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${name} vulnerability scan failed with exit ${result.status}`);
  }
}
console.log("Hex, escript, and npm SBOMs have no known High/Critical vulnerabilities");
