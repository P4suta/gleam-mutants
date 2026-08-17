// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";

const gleamToml = fs.readFileSync("gleam.toml", "utf8");
const match = gleamToml.match(/^version\s*=\s*"([^"]+)"/m);
if (!match) throw new Error("gleam.toml package version is missing");
const version = match[1];

const expectations = [
  ["src/gleam_mutants/version.gleam", `pub const current = "${version}"`],
  ["CHANGELOG.md", `## ${version} - Unreleased`],
  ["RELEASE_NOTES.md", `# ${version} release notes (draft)`],
  [".github/workflows/ci.yml", `gleam-mutants-${version}-unpublished`],
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
console.log(`Version ${version} matches CLI, source, artifacts, changelog, and release notes`);
