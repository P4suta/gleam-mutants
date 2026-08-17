// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

if (process.argv[2] !== "--dry-run") throw new Error("only --dry-run is supported; publishing is intentionally absent");
const dist = path.resolve("dist");
const checksumFile = path.join(dist, "SHA256SUMS");
if (!fs.existsSync(checksumFile)) throw new Error("dist/SHA256SUMS is missing; run mise run package first");
const rows = fs.readFileSync(checksumFile, "utf8").trim().split(/\r?\n/);
if (rows.length !== 6) throw new Error("expected three artifacts and three distribution SBOMs");
for (const row of rows) {
  const match = row.match(/^([0-9a-fA-F]{64})  (.+)$/);
  if (!match) throw new Error(`invalid checksum row: ${row}`);
  const file = path.join(dist, ...match[2].split("/"));
  const actual = crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
  if (actual.toLowerCase() !== match[1].toLowerCase()) throw new Error(`checksum mismatch: ${match[2]}`);
}
const sbomFiles = fs.readdirSync(dist).filter(name => name.endsWith(".cdx.json"));
if (sbomFiles.length !== 3) throw new Error("expected Hex, escript, and npm SBOMs");
for (const file of sbomFiles) {
  const sbom = JSON.parse(fs.readFileSync(path.join(dist, file), "utf8"));
  if (sbom.bomFormat !== "CycloneDX") throw new Error(`${file} is not CycloneDX`);
  const application = sbom.metadata?.component;
  const edge = sbom.dependencies?.find(dependency => dependency.ref === application?.["bom-ref"]);
  if (!edge?.dependsOn?.includes("pkg:npm/mutation-testing-elements@3.9.0")) {
    throw new Error(`${file} is missing the application to MTE dependency edge`);
  }
}
console.log("release-candidate dry-run verified unpublished artifacts, checksums, and SBOMs; no publish/tag/release operation exists");
