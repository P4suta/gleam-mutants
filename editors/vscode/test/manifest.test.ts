// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The manifest is the half of the extension VS Code reads before any of the
// code runs: when it activates, what it puts in the palette, and which
// settings a user is offered. It is checked here because nothing else can.

import { describe, expect, it } from "vitest";

import { contributedCommands, extensionHas, manifest } from "./repo";

const COMMANDS = [
  "gleam_mutants.refreshDiagnostics",
  "gleam_mutants.runFile",
  "gleam_mutants.suggestFile",
  "gleam_mutants.explainMutant",
];

const SETTINGS = [
  "gleam_mutants.command",
  "gleam_mutants.reportPath",
  "gleam_mutants.timeoutMs",
];

describe("activation", () => {
  it("wakes for a Gleam workspace and for a Gleam file", () => {
    expect(manifest().activationEvents).toEqual([
      "workspaceContains:gleam.toml",
      "onLanguage:gleam",
    ]);
  });

  it("points VS Code at the bundle the build writes", () => {
    expect(manifest().main).toBe("./dist/extension.js");
  });

  it("says which VS Code it needs", () => {
    expect(manifest().engines?.["vscode"]).toBeTruthy();
  });
});

describe("contributed commands", () => {
  it("contributes the four a user can invoke, and no others", () => {
    expect(contributedCommands().sort()).toEqual([...COMMANDS].sort());
  });

  it("gives every one a title and the extension's category", () => {
    for (const command of manifest().contributes?.commands ?? []) {
      expect(command.title).not.toBe("");
      expect(command.category).toBe("gleam_mutants");
      // The palette prefixes the category itself; a title that repeats it
      // reads as "gleam_mutants: gleam_mutants: ...".
      expect(command.title.startsWith("gleam_mutants")).toBe(false);
    }
  });
});

describe("contributed settings", () => {
  const properties = manifest().contributes?.configuration?.properties ?? {};

  it("offers the three the flows read, and no others", () => {
    expect(Object.keys(properties).sort()).toEqual([...SETTINGS].sort());
  });

  it("defaults to running the CLI through `gleam run`", () => {
    expect(properties["gleam_mutants.command"]).toMatchObject({
      type: "array",
      items: { type: "string" },
      default: ["gleam", "run", "-m", "gleam_mutants", "--"],
    });
  });

  it("defaults to the report `run` writes", () => {
    expect(properties["gleam_mutants.reportPath"]).toMatchObject({
      type: "string",
      default: "reports/mutation/mutation.json",
    });
  });

  it("defaults to a five-minute budget per invocation", () => {
    expect(properties["gleam_mutants.timeoutMs"]).toMatchObject({
      type: "number",
      default: 300_000,
    });
  });

  it("describes every one of them", () => {
    for (const [name, property] of Object.entries(properties)) {
      expect(
        property["description"] ?? property["markdownDescription"] ?? "",
        `${name} has no description`,
      ).not.toBe("");
    }
  });
});

describe("scripts", () => {
  it("registers the gates the repository runs", () => {
    const scripts = manifest().scripts ?? {};

    expect(scripts["lint"]).toBeTruthy();
    expect(scripts["test"]).toBeTruthy();
    expect(scripts["build"]).toBeTruthy();
    expect(scripts["smoke"]).toBe("node scripts/smoke.mjs");
  });

  it("ships the smoke test the gate runs", () => {
    expect(extensionHas("scripts/smoke.mjs")).toBe(true);
  });
});

describe("dependencies", () => {
  it("does not pull VS Code down to run its tests", () => {
    const all = {
      ...manifest().dependencies,
      ...manifest().devDependencies,
    };

    expect(Object.keys(all)).not.toContain("@vscode/test-electron");
    expect(Object.keys(all)).not.toContain("@vscode/test-cli");
  });

  it("pins every version exactly, as the rest of the repository does", () => {
    const all = {
      ...manifest().dependencies,
      ...manifest().devDependencies,
    };

    for (const [name, version] of Object.entries(all)) {
      expect(version, `${name} is not pinned`).toMatch(/^\d+\.\d+\.\d+$/);
    }
  });
});
