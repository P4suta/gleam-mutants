// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The tests above can run in a plain Node process only because the editor
// is reached through one interface and touched from one directory. That is
// a property of the source tree, so it is checked as one.

import { readFileSync, readdirSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { extensionHas, extensionPath, modulesOf } from "./repo";

/** Every `.ts` file under `src/`, as a path relative to `src/`. */
function sources(directory = ""): string[] {
  const entries = readdirSync(extensionPath(`src/${directory}`), {
    withFileTypes: true,
  });
  const found: string[] = [];
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const relative = directory === "" ? entry.name : `${directory}/${entry.name}`;
    if (entry.isDirectory()) found.push(...sources(relative));
    else if (entry.name.endsWith(".ts")) found.push(relative);
  }
  return found;
}

function source(relative: string): string {
  return readFileSync(extensionPath(`src/${relative}`), "utf8");
}

/** True when a module reaches for `name`, however it spells the import. */
function imports(text: string, name: string): boolean {
  const quoted = name.replace(/[/]/g, "\\/");
  return new RegExp(
    `(from\\s*["']${quoted}["'])|(require\\(\\s*["']${quoted}["']\\s*\\))` +
      `|(import\\(\\s*["']${quoted}["']\\s*\\))`,
  ).test(text);
}

const all = sources();

describe("src/flows", () => {
  it("holds the flows the commands and the squiggles are made of", () => {
    const flows = modulesOf("src/flows");

    expect(flows).toContain("code-actions.ts");
    expect(flows).toContain("commands.ts");
    expect(flows).toContain("diagnostics.ts");
    expect(flows).toContain("quickfix.ts");
  });

  it.each(modulesOf("src/flows"))("reaches the editor only through the host, in %s", (name) => {
    const text = source(`flows/${name}`);

    expect(imports(text, "vscode")).toBe(false);
    // A flow that spawned its own process, or read its own file, would be a
    // flow no test could run.
    expect(imports(text, "node:child_process")).toBe(false);
    expect(imports(text, "child_process")).toBe(false);
    expect(imports(text, "node:fs")).toBe(false);
    expect(imports(text, "fs")).toBe(false);
  });
});

describe("src/vscode", () => {
  it("declares the host interface", () => {
    expect(extensionHas("src/vscode/host.ts")).toBe(true);
  });

  it("keeps that interface free of the thing it abstracts", () => {
    expect(imports(source("vscode/host.ts"), "vscode")).toBe(false);
  });

  it("holds the adapter that does import the editor", () => {
    const adapters = modulesOf("src/vscode")
      .filter((name) => name !== "host.ts")
      .filter((name) => imports(source(`vscode/${name}`), "vscode"));

    expect(adapters.length).toBeGreaterThan(0);
  });
});

describe("src/extension.ts", () => {
  const text = () => source("extension.ts");

  it("registers the commands from the table rather than naming them again", () => {
    expect(text()).toContain("commandTable");
  });

  it("offers the quick fixes on Gleam files", () => {
    expect(text()).toContain("registerCodeActionsProvider");
  });

  it("publishes into a diagnostic collection", () => {
    expect(text()).toContain("createDiagnosticCollection");
  });

  it("rereads the report when the report is written", () => {
    expect(text()).toContain("createFileSystemWatcher");
  });
});

describe("every module under src", () => {
  it("imports the editor from the editor directory alone", () => {
    const reaching = all.filter((name) => imports(source(name), "vscode"));

    for (const name of reaching) {
      expect(
        name === "extension.ts" || name.startsWith("vscode/"),
        `${name} imports vscode`,
      ).toBe(true);
    }
  });

  it.each(all)("carries the licence header, in %s", (name) => {
    const text = source(name);

    // REUSE-IgnoreStart
    expect(text.startsWith("// SPDX-FileCopyrightText:")).toBe(true);
    expect(text).toContain("// SPDX-License-Identifier: MIT OR Apache-2.0");
    // REUSE-IgnoreEnd
  });
});
