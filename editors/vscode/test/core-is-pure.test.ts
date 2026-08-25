// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The core is testable here, in a plain Node process, only because nothing
// in it reaches for the editor. That is a property of the whole directory
// rather than of any one module, so it is checked as one.

import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const core = fileURLToPath(new URL("../src/core", import.meta.url));

const modules = readdirSync(core)
  .filter((name) => name.endsWith(".ts"))
  .sort();

describe("src/core", () => {
  it("is a directory of modules, not an empty promise", () => {
    expect(modules).toEqual([
      "apply.ts",
      "cli.ts",
      "diagnostics.ts",
      "json.ts",
      "stryker.ts",
      "suggest.ts",
    ]);
  });

  it.each(modules)("does not import the editor in %s", (name) => {
    const source = readFileSync(`${core}/${name}`, "utf8");

    expect(source).not.toMatch(/\bfrom\s*["']vscode["']/);
    expect(source).not.toMatch(/\brequire\(\s*["']vscode["']\s*\)/);
    expect(source).not.toMatch(/\bimport\(\s*["']vscode["']\s*\)/);
  });

  // The two tags below are quoted, not declared. `REUSE-Ignore` markers keep
  // the licence linter from reading this file's assertions as its own header.
  it("carries the licence header on every module", () => {
    for (const name of modules) {
      const source = readFileSync(`${core}/${name}`, "utf8");
      // REUSE-IgnoreStart
      expect(source.startsWith("// SPDX-FileCopyrightText:")).toBe(true);
      expect(source).toContain("// SPDX-License-Identifier: MIT OR Apache-2.0");
      // REUSE-IgnoreEnd
    }
  });
});
