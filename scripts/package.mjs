// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import zlib from "node:zlib";
import Ajv from "ajv";

const root = process.cwd();
const dist = path.join(root, "dist");
const gleamToml = fs.readFileSync(path.join(root, "gleam.toml"), "utf8");
const versionMatch = gleamToml.match(/^version\s*=\s*"([^"]+)"/m);
if (!versionMatch) throw new Error("gleam.toml package version is missing");
const version = versionMatch[1];
const strykerSchema = JSON.parse(fs.readFileSync(path.join(root, "schema", "mutation-testing-report-schema-3.9.0.json"), "utf8"));
const validateStryker = new Ajv({ allErrors: true, strict: false, validateFormats: false }).compile(strykerSchema);
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

function extractHexSource(artifact, destination) {
  const outer = tarEntries(fs.readFileSync(artifact));
  const contents = outer.find(entry => entry.name === "contents.tar.gz");
  if (!contents) throw new Error("Hex artifact has no contents.tar.gz");
  const destinationRoot = path.resolve(destination) + path.sep;
  for (const entry of tarEntries(zlib.gunzipSync(contents.data))) {
    const target = path.resolve(destination, entry.name);
    if (!target.startsWith(destinationRoot)) throw new Error(`Unsafe Hex archive path: ${entry.name}`);
    if (entry.name.endsWith("/") || entry.header[156] === 0x35) {
      fs.mkdirSync(target, { recursive: true });
    } else {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, entry.data);
    }
  }
}

function makeMutationProject(directory, dependency = "") {
  fs.mkdirSync(path.join(directory, "src"), { recursive: true });
  fs.mkdirSync(path.join(directory, "test"), { recursive: true });
  write(path.join(directory, "gleam.toml"), `name = "artifact_smoke"
version = "0.0.0"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
${dependency}
[dev_dependencies]
gleeunit = ">= 1.9.0 and < 2.0.0"

[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.mutation]
include = ["src/calculator.gleam"]

[tools.gleam_mutants.cache]
mode = "off"

[tools.gleam_mutants.report]
directory = "reports/mutation"
high = 80
low = 60
`);
  write(path.join(directory, "src", "calculator.gleam"), "pub fn add_one(value: Int) -> Int { value + 1 }\n");
  write(path.join(directory, "test", "calculator_test.gleam"), `import calculator
import gleeunit/should

pub fn add_one_test() { calculator.add_one(1) |> should.equal(2) }
`);
  write(path.join(directory, "test", "artifact_smoke_test.gleam"), "import gleeunit\npub fn main() { gleeunit.main() }\n");
}

function verifyReports(project, label) {
  const jsonPath = path.join(project, "reports", "mutation", "mutation.json");
  const htmlPath = path.join(project, "reports", "mutation", "mutation.html");
  const report = JSON.parse(fs.readFileSync(jsonPath, "utf8"));
  if (!validateStryker(report)) {
    throw new Error(`${label} report failed official schema validation: ${JSON.stringify(validateStryker.errors)}`);
  }
  const html = fs.readFileSync(htmlPath, "utf8");
  if (!html.includes("<mutation-test-report-app>") || !html.includes("Content-Security-Policy")) {
    throw new Error(`${label} did not generate a self-contained HTML report`);
  }
  return htmlPath;
}

function smokeHexArtifact(artifact, temporaryRoot) {
  const consumer = path.join(temporaryRoot, "hex-smoke");
  const dependency = path.join(consumer, "vendor", "gleam_mutants");
  extractHexSource(artifact, dependency);
  for (const required of [
    "priv/gleam_mutants/LICENSE-MIT",
    "priv/gleam_mutants/LICENSE-APACHE",
    "priv/gleam_mutants/THIRD_PARTY_NOTICES.md",
    "priv/gleam_mutants/schema/run-report-v1.schema.json",
    "priv/gleam_mutants/schema/list-v1.schema.json",
    "priv/gleam_mutants/schema/doctor-v1.schema.json",
    "priv/gleam_mutants/schema/mutation-testing-report-schema-3.9.0.json",
    "priv/gleam_mutants/vendor/mutation-testing-elements/3.9.0/LICENSE",
    "priv/gleam_mutants/vendor/mutation-testing-elements/3.9.0/PROVENANCE.json",
  ]) {
    if (!fs.existsSync(path.join(dependency, required))) {
      throw new Error(`Hex artifact omitted required third-party file: ${required}`);
    }
  }
  makeMutationProject(consumer, "gleam_mutants = { path = \"vendor/gleam_mutants\" }\n");
  write(path.join(consumer, "src", "hex_smoke.gleam"), "import gleam_mutants\npub fn main() { gleam_mutants.main() }\n");
  run("gleam", ["deps", "download"], consumer);
  run("gleam", ["run", "-m", "hex_smoke", "--", "run", "--no-strict", "--jobs", "2"], consumer);
  return verifyReports(consumer, "Hex");
}

function buildHex(temporaryRoot) {
  const project = path.join(temporaryRoot, "hex");
  copyProject(project);
  run("gleam", ["deps", "download"], project);
  const exportDirectory = process.platform === "win32" ? `\\\\?\\${project}` : project;
  run("gleam", ["export", "hex-tarball"], exportDirectory);
  const artifact = findFile(project, file => file.endsWith(`gleam_mutants-${version}.tar`));
  if (!artifact) throw new Error("Gleam did not produce the Hex tarball");
  const target = path.join(dist, "hex", path.basename(artifact));
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(artifact, target);
  canonicalizeHexTarball(target);
  run("tar", ["-tf", target], root, { capture: true });
  return { artifact: target, report: smokeHexArtifact(target, temporaryRoot) };
}

function buildEscript(temporaryRoot) {
  run("gleam", ["export", "escript"]);
  const generated = path.join(root, "gleam_mutants");
  const target = path.join(dist, "escript", "gleam-mutants.escript");
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(generated, target);
  if (process.platform !== "win32") fs.chmodSync(target, 0o755);
  const output = run("escript", [target, "--version"], root, { capture: true });
  if (!output.includes(version)) throw new Error(`Unexpected escript version: ${output}`);
  const smoke = path.join(temporaryRoot, "escript-smoke");
  makeMutationProject(smoke);
  run("gleam", ["deps", "download"], smoke);
  run("escript", [target, "run", "--no-strict", "--jobs", "2"], smoke);
  return { artifact: target, report: verifyReports(smoke, "Escript") };
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
  fs.copyFileSync(path.join(root, "THIRD_PARTY_NOTICES.md"), path.join(stage, "THIRD_PARTY_NOTICES.md"));
  fs.mkdirSync(path.join(stage, "schemas"), { recursive: true });
  for (const name of ["run-report-v1.schema.json", "list-v1.schema.json", "doctor-v1.schema.json"]) {
    fs.copyFileSync(path.join(root, "schema", name), path.join(stage, "schemas", name));
  }
  fs.mkdirSync(path.join(stage, "third-party", "mutation-testing-elements"), { recursive: true });
  fs.copyFileSync(path.join(root, "vendor", "mutation-testing-elements", "3.9.0", "LICENSE"), path.join(stage, "third-party", "mutation-testing-elements", "LICENSE"));
  fs.copyFileSync(path.join(root, "vendor", "mutation-testing-elements", "3.9.0", "PROVENANCE.json"), path.join(stage, "third-party", "mutation-testing-elements", "PROVENANCE.json"));
  fs.copyFileSync(path.join(root, "schema", "mutation-testing-report-schema-3.9.0.json"), path.join(stage, "third-party", "mutation-testing-elements", "mutation-testing-report-schema.json"));
  write(path.join(stage, "bin", "gleam-mutants.mjs"), `#!/usr/bin/env node\nimport { main } from "../runtime/gleam_mutants/gleam_mutants.mjs";\nmain();\n`, 0o755);
  write(path.join(stage, "package.json"), JSON.stringify({
    name: "gleam-mutants",
    version,
    description: "Mutation testing for Gleam across Erlang, Node, Deno, and Bun",
    type: "module",
    bin: { "gleam-mutants": "bin/gleam-mutants.mjs" },
    files: ["bin", "runtime", "schemas", "third-party", "README.md", "THIRD_PARTY_NOTICES.md", "LICENSE-MIT", "LICENSE-APACHE"],
    engines: { node: "^22.0.0 || ^24.0.0" },
    license: "MIT OR Apache-2.0",
    repository: { type: "git", url: "git+https://github.com/P4suta/gleam-mutants.git" },
    bugs: { url: "https://github.com/P4suta/gleam-mutants/issues" },
    homepage: "https://github.com/P4suta/gleam-mutants#readme",
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
  makeMutationProject(smoke);
  write(path.join(smoke, "package.json"), "{\"private\":true}\n");
  run("npm", ["install", "--offline", "--ignore-scripts", artifact], smoke);
  const installed = path.join(smoke, "node_modules", "gleam-mutants", "bin", "gleam-mutants.mjs");
  const output = run(process.execPath, [installed, "--version"], smoke, { capture: true });
  if (!output.includes(version)) throw new Error(`Unexpected npm CLI version: ${output}`);
  run(process.execPath, [installed, "run", "--no-strict", "--jobs", "2"], smoke);
  return { artifact, stage, report: verifyReports(smoke, "npm") };
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

function generateSbom(source, distribution, applicationRef, temporaryRoot) {
  const sbomTemporary = path.join(temporaryRoot, `${distribution}.cdx.json`);
  run("syft", [source, "-o", `cyclonedx-json=${sbomTemporary}`]);
  const sbomData = JSON.parse(fs.readFileSync(sbomTemporary, "utf8"));
  sbomData.components ??= [];
  sbomData.dependencies ??= [];
  for (const component of sbomData.components) {
    if (component.purl) component["bom-ref"] = component.purl;
  }
  if (!sbomData.components.some(component => component["bom-ref"] === applicationRef)) {
    sbomData.components.push({
      "bom-ref": applicationRef,
      type: "application",
      name: "gleam-mutants",
      version,
      licenses: [
        { expression: "MIT OR Apache-2.0" },
      ],
      properties: [
        { name: "gleam-mutants:distribution", value: distribution },
      ],
    });
  }
  sbomData.metadata.component = {
    "bom-ref": applicationRef,
    type: "application",
    name: "gleam-mutants",
    version,
    properties: [
      { name: "gleam-mutants:distribution", value: distribution },
    ],
  };
  const mteRef = "pkg:npm/mutation-testing-elements@3.9.0";
  if (!sbomData.components.some(component => component["bom-ref"] === mteRef)) {
    sbomData.components.push({
      "bom-ref": mteRef,
      type: "library",
      name: "mutation-testing-elements",
      version: "3.9.0",
      purl: mteRef,
      hashes: [{ alg: "SHA-256", content: "751fb010242b0b44e32d84fe7fe0b9ff1da182823b94f59f5c52b001fcfc163b" }],
      licenses: [{ license: { id: "Apache-2.0" } }],
      properties: [{ name: "gleam-mutants:npm-integrity", value: "sha512-3G4GhBO8Wc/ZrqOJ5uT8AbM1h/ew9kfX0MIlpy59gWu/amMZyKH3TreKAOMwwXNibhZMOL7A3n5nFvhYWLdtYQ==" }],
    });
  }
  let applicationDependency = sbomData.dependencies.find(dependency => dependency.ref === applicationRef);
  if (!applicationDependency) {
    applicationDependency = { ref: applicationRef, dependsOn: [] };
    sbomData.dependencies.push(applicationDependency);
  }
  applicationDependency.dependsOn ??= [];
  if (!applicationDependency.dependsOn.includes(mteRef)) applicationDependency.dependsOn.push(mteRef);
  if (!sbomData.dependencies.some(dependency => dependency.ref === mteRef)) {
    sbomData.dependencies.push({ ref: mteRef, dependsOn: [] });
  }
  delete sbomData.serialNumber;
  sbomData.metadata.timestamp = "1970-01-01T00:00:00Z";
  const sbom = path.join(dist, `gleam-mutants-${version}-${distribution}.cdx.json`);
  fs.writeFileSync(sbom, JSON.stringify(sbomData) + "\n", "utf8");
  return sbom;
}

fs.rmSync(dist, { recursive: true, force: true });
fs.mkdirSync(dist, { recursive: true });
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "gleam-mutants-package-"));
try {
  run(process.execPath, ["scripts/check-vendor.mjs"]);
  const hexBuild = buildHex(temporaryRoot);
  const escriptBuild = buildEscript(temporaryRoot);
  const npmBuild = buildNpm(temporaryRoot);
  const hexArtifact = hexBuild.artifact;
  const escriptArtifact = escriptBuild.artifact;
  const npmArtifact = npmBuild.artifact;
  const artifacts = [hexArtifact, escriptArtifact, npmArtifact];
  run(process.execPath, ["scripts/browser-report-smoke.mjs", hexBuild.report, escriptBuild.report, npmBuild.report]);
  const sboms = [
    generateSbom(hexArtifact, "hex", `pkg:hex/gleam_mutants@${version}`, temporaryRoot),
    generateSbom(escriptArtifact, "escript", `pkg:generic/gleam-mutants@${version}?distribution=escript`, temporaryRoot),
    generateSbom(`dir:${npmBuild.stage}`, "npm", `pkg:npm/gleam-mutants@${version}`, temporaryRoot),
  ];

  const checksums = [...artifacts, ...sboms]
    .sort((a, b) => a.localeCompare(b))
    .map(file => `${sha256(file)}  ${path.relative(dist, file).replaceAll(path.sep, "/")}`)
    .join("\n") + "\n";
  fs.writeFileSync(path.join(dist, "SHA256SUMS"), checksums, "utf8");
  console.log(`Verified ${artifacts.length} unpublished artifacts, checksums, and ${sboms.length} CycloneDX SBOMs in ${dist}`);
} finally {
fs.rmSync(temporaryRoot, { recursive: true, force: true });
  for (const generated of ["gleam_mutants", "gleam_mutants.cmd"]) {
    fs.rmSync(path.join(root, generated), { force: true });
  }
}
