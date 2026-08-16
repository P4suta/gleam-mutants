// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import zlib from "node:zlib";

const root = process.cwd();
const dist = path.join(root, "dist");
const version = "0.1.0";
const fixedEnvironment = {
  ...process.env,
  SOURCE_DATE_EPOCH: process.env.SOURCE_DATE_EPOCH || "0",
  npm_config_audit: "false",
  npm_config_fund: "false",
  npm_config_provenance: "false",
};

function command(name, args) {
  if (name !== "npm") return [name, args];
  const npmCli = path.join(path.dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js");
  return [process.execPath, [npmCli, ...args]];
}

function run(name, args, cwd = root, options = {}) {
  const [program, programArguments] = command(name, args);
  const result = childProcess.spawnSync(program, programArguments, {
    cwd,
    env: fixedEnvironment,
    encoding: "utf8",
    stdio: options.capture ? "pipe" : "inherit",
    shell: false,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    if (options.capture) process.stderr.write((result.stdout || "") + (result.stderr || ""));
    throw new Error(`${name} ${args.join(" ")} failed with exit ${result.status}`);
  }
  return (result.stdout || "").trim();
}

function write(file, text, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text, { encoding: "utf8", mode });
}

function copyProject(destination) {
  const ignored = new Set([".git", "build", "dist", ".gleam_mutants", "node_modules", "gleam_mutants"]);
  fs.cpSync(root, destination, {
    recursive: true,
    preserveTimestamps: true,
    filter(source) {
      const relative = path.relative(root, source);
      if (!relative) return true;
      return !ignored.has(relative.split(path.sep)[0]);
    },
  });
}

function findFile(directory, predicate) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const candidate = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      const nested = findFile(candidate, predicate);
      if (nested) return nested;
    } else if (predicate(candidate)) return candidate;
  }
  return undefined;
}

function tarEntries(archive) {
  const entries = [];
  let offset = 0;
  while (offset + 512 <= archive.length) {
    const header = Buffer.from(archive.subarray(offset, offset + 512));
    if (header.every(byte => byte === 0)) break;
    const name = header.subarray(0, 100).toString("utf8").replace(/\0.*$/, "");
    const sizeText = header.subarray(124, 136).toString("ascii").replace(/\0.*$/, "").trim();
    const size = Number.parseInt(sizeText || "0", 8);
    const dataStart = offset + 512;
    entries.push({ name, header, data: Buffer.from(archive.subarray(dataStart, dataStart + size)) });
    offset = dataStart + Math.ceil(size / 512) * 512;
  }
  return entries;
}

function writeTarNumber(header, offset, length, value, checksum = false) {
  header.fill(0, offset, offset + length);
  const digits = value.toString(8).padStart(length - (checksum ? 2 : 1), "0");
  header.write(digits, offset, "ascii");
  if (checksum) header[offset + length - 1] = 0x20;
}

function canonicalHeader(header, size) {
const result = Buffer.alloc(512);
  header.copy(result, 0, 0, 100);
  header.copy(result, 156, 156, 257);
  Buffer.from("ustar\0", "ascii").copy(result, 257);
  Buffer.from("00", "ascii").copy(result, 263);
  header.copy(result, 345, 345, 500);
  writeTarNumber(result, 100, 8, 0o644);
  writeTarNumber(result, 108, 8, 0);
  writeTarNumber(result, 116, 8, 0);
  writeTarNumber(result, 124, 12, size);
  writeTarNumber(result, 136, 12, 0);
  result.fill(0x20, 148, 156);
  result.fill(0, 265, 329);
  const checksum = result.reduce((sum, byte) => sum + byte, 0);
  writeTarNumber(result, 148, 8, checksum, true);
  return result;
}

function renderTar(entries) {
  const blocks = [];
  for (const entry of entries) {
    blocks.push(canonicalHeader(entry.header, entry.data.length), entry.data);
    const padding = (512 - (entry.data.length % 512)) % 512;
    if (padding) blocks.push(Buffer.alloc(padding));
  }
  blocks.push(Buffer.alloc(1024));
  return Buffer.concat(blocks);
}

function canonicalizeHexMetadata(data) {
  const text = data.toString("utf8");
  const requirement = /  \{<<"([^"]+)"\/utf8>>, \[\n[\s\S]*?\n  \]\}/g;
  const matches = [...text.matchAll(requirement)];
  if (matches.length === 0) return data;
  const first = matches[0];
  const last = matches[matches.length - 1];
  const sorted = matches
    .map(match => ({ name: match[1], text: match[0] }))
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(item => item.text)
    .join(",\n");
  return Buffer.from(
    text.slice(0, first.index) + sorted + text.slice(last.index + last[0].length),
    "utf8",
  );
}
function canonicalizeHexTarball(file) {
  const outer = tarEntries(fs.readFileSync(file));
  const versionEntry = outer.find(entry => entry.name === "VERSION");
  const metadata = outer.find(entry => entry.name === "metadata.config");
  const contents = outer.find(entry => entry.name === "contents.tar.gz");
  const checksum = outer.find(entry => entry.name === "CHECKSUM");
  if (!versionEntry || !metadata || !contents || !checksum) throw new Error("Invalid Hex v3 tarball");
  metadata.data = canonicalizeHexMetadata(metadata.data);
  const inner = tarEntries(zlib.gunzipSync(contents.data)).sort((a, b) => a.name.localeCompare(b.name));
  contents.data = zlib.gzipSync(renderTar(inner), { level: 9, mtime: 0 });
  checksum.data = Buffer.from(
    crypto.createHash("sha256").update(versionEntry.data).update(metadata.data).update(contents.data).digest("hex").toUpperCase(),
    "ascii",
  );
  fs.writeFileSync(file, renderTar(outer));
}
function buildHex(temporaryRoot) {
  const project = path.join(temporaryRoot, "hex");
  copyProject(project);
  run("gleam", ["deps", "download"], project);
  const exportDirectory = process.platform === "win32" ? `\\\\?\\${project}` : project;
  run("gleam", ["export", "hex-tarball"], exportDirectory);
  const artifact = findFile(project, file => /gleam_mutants-0\.1\.0\.tar$/.test(file));
  if (!artifact) throw new Error("Gleam did not produce the Hex tarball");
  const target = path.join(dist, "hex", path.basename(artifact));
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(artifact, target);
  canonicalizeHexTarball(target);
  run("tar", ["-tf", target], root, { capture: true });
  return target;
}

function buildEscript() {
  run("gleam", ["export", "escript"]);
  const generated = path.join(root, "gleam_mutants");
  const target = path.join(dist, "escript", "gleam-mutants.escript");
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(generated, target);
  if (process.platform !== "win32") fs.chmodSync(target, 0o755);
  const output = run("escript", [target, "--version"], root, { capture: true });
  if (!output.includes(version)) throw new Error(`Unexpected escript version: ${output}`);
  return target;
}

function buildNpm(temporaryRoot) {
  run("gleam", ["build", "--target", "javascript", "--warnings-as-errors"]);
  const stage = path.join(temporaryRoot, "npm");
  fs.mkdirSync(stage, { recursive: true });
const javascriptBuild = path.join(root, "build", "dev", "javascript");
  fs.cpSync(javascriptBuild, path.join(stage, "runtime"), {
    recursive: true,
    preserveTimestamps: true,
    filter(source) {
      const relative = path.relative(javascriptBuild, source);
      if (!relative) return true;
      const parts = relative.split(path.sep);
      if (parts.includes("_gleam_artefacts") || parts[0] === "gleeunit") return false;
      if (fs.lstatSync(source).isDirectory()) return true;
      if (parts[0] === "gleam_mutants" && /^(core_test|engine_.*_smoke|engine_smoke|gleam_mutants_test|gleam@@private_main)/.test(path.basename(source))) return false;
      return path.extname(source) === ".mjs";
    },
  });
  fs.copyFileSync(path.join(root, "README.md"), path.join(stage, "README.md"));
  fs.copyFileSync(path.join(root, "LICENSE-MIT"), path.join(stage, "LICENSE-MIT"));
  fs.copyFileSync(path.join(root, "LICENSE-APACHE"), path.join(stage, "LICENSE-APACHE"));
  write(path.join(stage, "bin", "gleam-mutants.mjs"), `#!/usr/bin/env node\nimport { main } from "../runtime/gleam_mutants/gleam_mutants.mjs";\nmain();\n`, 0o755);
  write(path.join(stage, "package.json"), JSON.stringify({
    name: "gleam-mutants",
    version,
    description: "Mutation testing for Gleam across Erlang, Node, Deno, and Bun",
    type: "module",
    bin: { "gleam-mutants": "bin/gleam-mutants.mjs" },
    files: ["bin", "runtime", "README.md", "LICENSE-MIT", "LICENSE-APACHE"],
    engines: { node: ">=20" },
    license: "MIT OR Apache-2.0",
    publishConfig: { access: "public" },
  }, null, 2) + "\n");
  write(path.join(stage, "package-lock.json"), JSON.stringify({
    name: "gleam-mutants",
    version,
    lockfileVersion: 3,
    requires: true,
    packages: { "": { name: "gleam-mutants", version, license: "MIT OR Apache-2.0" } },
  }, null, 2) + "\n");
  const npmOut = path.join(dist, "npm");
  fs.mkdirSync(npmOut, { recursive: true });
  run("npm", ["pack", "--silent", "--pack-destination", npmOut], stage);
  const artifact = findFile(npmOut, file => file.endsWith(".tgz"));
  if (!artifact) throw new Error("npm did not produce a tarball");

  const smoke = path.join(temporaryRoot, "npm-smoke");
  fs.mkdirSync(smoke, { recursive: true });
  write(path.join(smoke, "package.json"), "{\"private\":true}\n");
  run("npm", ["install", "--offline", "--ignore-scripts", artifact], smoke);
  const installed = path.join(smoke, "node_modules", "gleam-mutants", "bin", "gleam-mutants.mjs");
  const output = run(process.execPath, [installed, "--version"], smoke, { capture: true });
  if (!output.includes(version)) throw new Error(`Unexpected npm CLI version: ${output}`);
  return { artifact, stage };
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function relativeFiles(directory) {
  const files = [];
  function visit(current) {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const candidate = path.join(current, entry.name);
      if (entry.isDirectory()) visit(candidate);
      else files.push(candidate);
    }
  }
  visit(directory);
  return files.sort((a, b) => a.localeCompare(b));
}

fs.rmSync(dist, { recursive: true, force: true });
fs.mkdirSync(dist, { recursive: true });
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "gleam-mutants-package-"));
try {
  const hexArtifact = buildHex(temporaryRoot);
  const escriptArtifact = buildEscript();
  const npmBuild = buildNpm(temporaryRoot);
  const npmArtifact = npmBuild.artifact;
  const artifacts = [hexArtifact, escriptArtifact, npmArtifact];
  const sbomTemporary = path.join(temporaryRoot, "sbom.cdx.json");
  run("syft", [`dir:${npmBuild.stage}`, "-o", `cyclonedx-json=${sbomTemporary}`]);
  const sbom = path.join(dist, "gleam-mutants-0.1.0.cdx.json");
  fs.copyFileSync(sbomTemporary, sbom);
const sbomData = JSON.parse(fs.readFileSync(sbom, "utf8"));
  if (!sbomData.components?.some(component => component.name === "gleam-mutants" && component.version === version)) {
    throw new Error("Syft SBOM does not contain the npm application component");
  }
  sbomData.metadata.component = {
    "bom-ref": `pkg:npm/gleam-mutants@${version}`,
    type: "application",
    name: "gleam-mutants",
    version,
  };
  for (const component of sbomData.components || []) {
    if (component.purl) component["bom-ref"] = component.purl;
  }
  delete sbomData.serialNumber;
  sbomData.metadata.timestamp = "1970-01-01T00:00:00Z";
  fs.writeFileSync(sbom, JSON.stringify(sbomData) + "\n", "utf8");

  const checksums = [...artifacts, sbom]
    .sort((a, b) => a.localeCompare(b))
    .map(file => `${sha256(file)}  ${path.relative(dist, file).replaceAll(path.sep, "/")}`)
    .join("\n") + "\n";
  fs.writeFileSync(path.join(dist, "SHA256SUMS"), checksums, "utf8");
  console.log(`Verified ${artifacts.length} unpublished artifacts, checksums, and CycloneDX SBOM in ${dist}`);
} finally {
fs.rmSync(temporaryRoot, { recursive: true, force: true });
  for (const generated of ["gleam_mutants", "gleam_mutants.cmd"]) {
    fs.rmSync(path.join(root, generated), { force: true });
  }
}
