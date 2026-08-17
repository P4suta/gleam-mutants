// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = process.cwd();
const version = "3.9.0";
const vendor = path.join(root, "vendor", "mutation-testing-elements", version);
const provenance = JSON.parse(fs.readFileSync(path.join(vendor, "PROVENANCE.json"), "utf8"));
const assetSource = fs.readFileSync(path.join(root, "src", "gleam_mutants", "mte_asset.gleam"), "utf8");
const chunkSource = assetSource.slice(assetSource.indexOf("fn chunks()"));
const chunks = [...chunkSource.matchAll(/^\s+"([A-Za-z0-9+/=]+)",$/gm)].map(match => Buffer.from(match[1], "base64"));
if (chunks.length === 0) throw new Error("No Base64 MTE chunks found in generated Gleam module");
const bundle = Buffer.concat(chunks);
const sha256 = crypto.createHash("sha256").update(bundle).digest("hex");
if (provenance.version !== version || provenance.bundleSha256 !== sha256) {
  throw new Error("Vendored MTE version or bundle SHA-256 mismatch");
}
if (!assetSource.includes(`pub const npm_integrity = "${provenance.npmIntegrity}"`)) {
  throw new Error("Generated MTE module integrity metadata mismatch");
}
if (bundle.toString("utf8").toLowerCase().includes("</script")) {
  throw new Error("Vendored MTE IIFE contains an inline script terminator");
}

const lock = JSON.parse(fs.readFileSync(path.join(root, "package-lock.json"), "utf8"));
for (const [name, integrity] of [
  ["mutation-testing-elements", provenance.npmIntegrity],
  ["mutation-testing-report-schema", provenance.reportSchema.npmIntegrity],
]) {
  const locked = lock.packages?.[`node_modules/${name}`];
  if (locked?.version !== version || locked?.integrity !== integrity) {
    throw new Error(`${name} lockfile metadata mismatch`);
  }
}

const upstreamBundle = fs.readFileSync(path.join(root, "node_modules", "mutation-testing-elements", "dist", "mutation-test-elements.js"));
const upstreamSchema = fs.readFileSync(path.join(root, "node_modules", "mutation-testing-report-schema", "src", "mutation-testing-report-schema.json"));
const vendoredSchema = fs.readFileSync(path.join(root, "schema", `mutation-testing-report-schema-${version}.json`));
const upstreamLicense = fs.readFileSync(path.join(root, "node_modules", "mutation-testing-elements", "LICENSE"));
const vendoredLicense = fs.readFileSync(path.join(vendor, "LICENSE"));
if (!bundle.equals(upstreamBundle)) throw new Error("Generated MTE module differs from official IIFE");
if (!vendoredSchema.equals(upstreamSchema)) throw new Error("Vendored report schema differs from official package");
if (!vendoredLicense.equals(upstreamLicense)) throw new Error("Vendored MTE LICENSE differs from official package");

const distributionRoot = path.join(root, "priv", "gleam_mutants");
const distributionPairs = [
  [path.join(distributionRoot, "LICENSE-MIT"), path.join(root, "LICENSE-MIT")],
  [path.join(distributionRoot, "LICENSE-APACHE"), path.join(root, "LICENSE-APACHE")],
  [path.join(distributionRoot, "THIRD_PARTY_NOTICES.md"), path.join(root, "THIRD_PARTY_NOTICES.md")],
  [path.join(distributionRoot, "schema", `mutation-testing-report-schema-${version}.json`), path.join(root, "schema", `mutation-testing-report-schema-${version}.json`)],
  [path.join(distributionRoot, "vendor", "mutation-testing-elements", version, "LICENSE"), path.join(vendor, "LICENSE")],
  [path.join(distributionRoot, "vendor", "mutation-testing-elements", version, "PROVENANCE.json"), path.join(vendor, "PROVENANCE.json")],
];
for (const name of ["run-report-v1.schema.json", "list-v1.schema.json", "doctor-v1.schema.json"]) {
  distributionPairs.push([
    path.join(distributionRoot, "schema", name),
    path.join(root, "schema", name),
  ]);
}
for (const [distribution, canonical] of distributionPairs) {
  if (!fs.readFileSync(distribution).equals(fs.readFileSync(canonical))) {
    throw new Error(`Hex distribution copy differs from canonical vendor file: ${path.relative(root, distribution)}`);
  }
}

console.log(`Verified Mutation Testing Elements ${version}, npm integrity, bundle SHA-256 ${sha256}, schema, and LICENSE`);
