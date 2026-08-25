// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// An extension nobody can find, install or run is not shipped. What the
// repository has to say about this one — the gate that runs its tests, and
// the three documents that point at it — is part of the deliverable.

import { describe, expect, it } from "vitest";

import { extensionFile, repoFile } from "./repo";

/** The `run` of one mise task, as written in `mise.toml`. */
function task(name: string): string {
  const toml = repoFile("mise.toml");
  const start = toml.indexOf(`[tasks.${name}]`);
  if (start === -1) return "";
  const rest = toml.slice(start + 1);
  const end = rest.indexOf("\n[");
  return end === -1 ? rest : rest.slice(0, end);
}

/** True when `text` holds every part, in the order they are given. */
function inOrder(text: string, parts: readonly string[]): boolean {
  let at = 0;
  for (const part of parts) {
    const found = text.indexOf(part, at);
    if (found === -1) return false;
    at = found + part.length;
  }
  return true;
}

describe("the mise gate", () => {
  it("runs the extension's own gates, in the order they get faster to fail", () => {
    const vscode = task("vscode");

    expect(vscode).not.toBe("");
    expect(vscode).toContain("editors/vscode");
    expect(
      inOrder(vscode, [
        "npm ci",
        "npm run lint",
        "npm test",
        "npm run build",
        "npm run smoke",
      ]),
    ).toBe(true);
  });

  it("describes itself, as every other task does", () => {
    expect(task("vscode")).toContain("description");
  });

  it("stays out of `mise run check`, which must work with no network", () => {
    expect(task("check")).not.toContain("vscode");
  });
});

describe("the repository's documentation", () => {
  it("points at the extension from the README", () => {
    const readme = repoFile("README.md");

    expect(readme).toMatch(/editor integration/i);
    expect(readme).toContain("editors/vscode");
  });

  it("points at it from the suggest guide, where the flow is explained", () => {
    const guide = repoFile("docs/suggest.md");

    expect(guide).toMatch(/^## Editors$/m);
    expect(guide).toContain("editors/vscode");
    expect(guide).toContain("VS Code");
  });
});

describe("the extension's README", () => {
  const readme = extensionFile("README.md");

  it("says how to install it without a marketplace", () => {
    expect(readme).toContain("npm ci");
    expect(readme).toContain("npm run build");
    expect(readme).toMatch(/Install Extension from Location|vsce package/);
  });

  it("documents every setting a user can write", () => {
    expect(readme).toContain("gleam_mutants.command");
    expect(readme).toContain("gleam_mutants.reportPath");
    expect(readme).toContain("gleam_mutants.timeoutMs");
  });

  it("documents every command a user can invoke", () => {
    expect(readme).toContain("gleam_mutants.refreshDiagnostics");
    expect(readme).toContain("gleam_mutants.runFile");
    expect(readme).toContain("gleam_mutants.suggestFile");
    expect(readme).toContain("gleam_mutants.explainMutant");
  });

  it("warns that suggesting a test calls the code for real", () => {
    expect(readme).toMatch(/side effect/i);
    expect(readme).toContain("docs/suggest.md");
  });

  it("says that suggesting and applying are Erlang-only", () => {
    expect(readme).toContain("Erlang");
  });

  it("says how to run the gates, the real-CLI smoke among them", () => {
    expect(readme).toContain("npm run smoke");
    expect(readme).toContain("mise run vscode");
  });
});
