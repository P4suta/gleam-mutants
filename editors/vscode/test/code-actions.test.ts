// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// What the lightbulb offers on a surviving mutant, and what it keeps quiet
// about on everything else in the file.

import { describe, expect, it } from "vitest";

import { codeActionsFor } from "../src/flows/code-actions";
import type { HostDiagnostic } from "../src/vscode/host";

const FILE = "src/boundary.gleam";

const GENERATE = "gleam_mutants: Generate a test that kills this mutant";
const EXPLAIN = "gleam_mutants: Explain this mutant";

const range = {
  startLine: 17,
  startColumn: 2,
  endLine: 17,
  endColumn: 11,
};

function survivor(code: string): HostDiagnostic {
  return {
    message: `Surviving mutant ${code.slice(0, 8)} (comparison-boundary)`,
    code,
    severity: "warning",
    source: "gleam_mutants",
    range,
  };
}

// Anything else the editor put on that line: a compiler warning, say.
const foreign = {
  message: "This value is never used",
  code: "unused_value",
  severity: "warning",
  source: "gleam",
  range,
} as unknown as HostDiagnostic;

describe("codeActionsFor", () => {
  it("offers two actions for one surviving mutant, generate first", () => {
    const actions = codeActionsFor(FILE, [survivor("AAAA1111")]);

    expect(actions.map((action) => action.title)).toEqual([GENERATE, EXPLAIN]);
  });

  it("offers both as quick fixes, and prefers writing the test", () => {
    const [generate, explain] = codeActionsFor(FILE, [survivor("AAAA1111")]);

    expect(generate?.kind).toBe("quickfix");
    expect(explain?.kind).toBe("quickfix");
    expect(generate?.preferred).toBe(true);
    expect(explain?.preferred).toBe(false);
  });

  it("hands the file and the mutant to the command that writes the test", () => {
    const [generate] = codeActionsFor(FILE, [survivor("AAAA1111")]);

    expect(generate?.command).toBe("gleam_mutants.generateTest");
    expect(generate?.arguments).toEqual([FILE, "AAAA1111"]);
  });

  it("hands the mutant to the command that explains it", () => {
    const [, explain] = codeActionsFor(FILE, [survivor("AAAA1111")]);

    expect(explain?.command).toBe("gleam_mutants.explainMutant");
    expect(explain?.arguments).toEqual(["AAAA1111"]);
  });

  it("carries the diagnostic back, so the editor can tie the fix to it", () => {
    const diagnostic = survivor("AAAA1111");

    for (const action of codeActionsFor(FILE, [diagnostic])) {
      expect(action.diagnostic).toBe(diagnostic);
    }
  });

  it("offers a pair per mutant, each pair beside its own", () => {
    const actions = codeActionsFor(FILE, [
      survivor("AAAA1111"),
      survivor("BBBB2222"),
    ]);

    expect(actions).toHaveLength(4);
    // The mutant id is the last argument of both commands: the one that
    // explains takes it alone, the one that writes the test takes the file
    // first.
    expect(actions.map((action) => action.arguments.at(-1))).toEqual([
      "AAAA1111",
      "AAAA1111",
      "BBBB2222",
      "BBBB2222",
    ]);
  });

  it("keeps quiet about diagnostics that are not ours", () => {
    expect(codeActionsFor(FILE, [foreign])).toEqual([]);
  });

  it("picks its own out of a line that carries both", () => {
    const actions = codeActionsFor(FILE, [foreign, survivor("AAAA1111")]);

    expect(actions).toHaveLength(2);
    expect(actions[0]?.arguments).toEqual([FILE, "AAAA1111"]);
  });

  it("offers nothing on a line with nothing on it", () => {
    expect(codeActionsFor(FILE, [])).toEqual([]);
  });
});
