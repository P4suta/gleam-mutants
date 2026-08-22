// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";

const version = fs.readFileSync("VERSION", "utf8").trim();
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
  throw new Error(`VERSION is not a valid semantic version: ${version}`);
}
const gleamToml = fs.readFileSync("gleam.toml", "utf8");
const match = gleamToml.match(/^version\s*=\s*"([^"]+)"/m);
if (!match) throw new Error("gleam.toml package version is missing");
if (match[1] !== version) throw new Error(`gleam.toml version drift: expected ${version}`);

const expectations = [
  ["src/gleam_mutants/version.gleam", `pub const current = "${version}"`],
  ["README.md", `The current package version is ${version}.`],
  ["SECURITY.md", `Version ${version} is an unreleased development snapshot`],
  [".github/workflows/ci.yml", `name: gleam-mutants-${version}-development-snapshot`],
  [".github/workflows/release-candidate.yml", `gleam-mutants-${version}-development-snapshot-signed-`],
];
for (const [file, expected] of expectations) {
  if (!fs.readFileSync(file, "utf8").includes(expected)) {
    throw new Error(`${file} version drift: expected ${JSON.stringify(expected)}`);
  }
}

const cli = childProcess.spawnSync(
  "gleam",
  ["run", "-m", "gleam_mutants", "--target", "erlang", "--", "--version"],
  { encoding: "utf8", shell: false },
);
if (cli.error) throw cli.error;
if (cli.status !== 0 || cli.stdout.trim() !== `gleam-mutants ${version}`) {
  throw new Error(`CLI version drift: ${cli.stdout}${cli.stderr}`);
}
console.log(`Version ${version} matches VERSION, gleam.toml, source, and CLI output`);
