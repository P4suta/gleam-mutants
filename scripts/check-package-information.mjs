// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = process.cwd();
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "gleam-mutants-package-information-"));
const output = path.join(temporary, "package-information.json");

try {
  const result = childProcess.spawnSync(
    "gleam",
    ["export", "package-information", "--out", output],
    { cwd: root, encoding: "utf8", shell: false },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${result.stdout}${result.stderr}`);

  const metadata = JSON.parse(fs.readFileSync(output, "utf8"))["gleam.toml"];
  if (!metadata) throw new Error("package-information has no gleam.toml metadata");
  const assertEqual = (actual, expected, label) => {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      throw new Error(`${label} drift: ${JSON.stringify(actual)}`);
    }
  };
  assertEqual(metadata.gleam, ">= 1.17.0 and < 2.0.0", "minimum Gleam version");
  assertEqual(metadata.internal_modules, ["gleam_mutants/*", "gleam_mutants/core/*"], "internal modules");
  assertEqual(
    (metadata.documentation?.pages || []).map(page => page.path),
    ["configuration.html", "operators.html", "architecture.html"],
    "documentation pages",
  );
  console.log("package-information matches the compiler, internal-module, and documentation contracts");
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
