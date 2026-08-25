// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// One surviving mutant, as one squiggle. The model is pure — no `vscode`
// types, no ranges only the editor can build — so the wording is pinned here
// rather than read off a screenshot.

import { describe, expect, it } from "vitest";

import { toDiagnosticModel } from "../src/core/diagnostics";
import type { MutantSite } from "../src/core/stryker";
import { parseMutationReport, survivingMutants } from "../src/core/stryker";
import { fixture } from "./fixtures";

function site(parts: Partial<MutantSite> = {}): MutantSite {
  return {
    file: "src/boundary.gleam",
    id: "CF9769AE183954EDDE01DCDA44223126335AA5763AA153644C719EEA99C8D971",
    operator: "comparison-boundary",
    original: "value > 0",
    replacement: "value >= 0",
    status: "Survived",
    range: { startLine: 17, startColumn: 2, endLine: 17, endColumn: 11 },
    ...parts,
  };
}

describe("toDiagnosticModel", () => {
  it("says which mutant survived, and what it rewrote", () => {
    const first = survivingMutants(
      parseMutationReport(fixture("mutation.json")),
    )[0]!;

    expect(toDiagnosticModel(first)).toEqual({
      message:
        "Surviving mutant CF9769AE (comparison-boundary): " +
        "`value > 0` -> `value >= 0`",
      code: "surviving-mutant",
      severity: "warning",
      range: { startLine: 17, startColumn: 2, endLine: 17, endColumn: 11 },
    });
  });

  it("shows the eight-character prefix the CLI displays, in upper case", () => {
    const model = toDiagnosticModel(
      site({ id: "abcdef0123456789abcdef0123456789" }),
    );

    expect(model.message).toContain("Surviving mutant ABCDEF01 (");
    expect(model.message).not.toContain("abcdef01");
  });

  it("carries the range through untouched", () => {
    const range = {
      startLine: 3,
      startColumn: 4,
      endLine: 5,
      endColumn: 6,
    };

    expect(toDiagnosticModel(site({ range })).range).toEqual(range);
  });

  it("keeps a multi-line original on one line", () => {
    const model = toDiagnosticModel(
      site({
        operator: "pipeline-stage-deletion",
        original: "parts\n  |> string.join(\"; \")",
        replacement: "parts",
      }),
    );

    expect(model.message).toBe(
      "Surviving mutant CF9769AE (pipeline-stage-deletion): " +
        '`parts |> string.join("; ")` -> `parts`',
    );
  });

  it("shortens an original too long to read in a tooltip", () => {
    const model = toDiagnosticModel(
      site({ original: "x".repeat(50), replacement: "y".repeat(50) }),
    );

    expect(model.message).toBe(
      "Surviving mutant CF9769AE (comparison-boundary): " +
        `\`${"x".repeat(39)}…\` -> \`${"y".repeat(39)}…\``,
    );
  });

  it("leaves the shortening alone at exactly forty characters", () => {
    const model = toDiagnosticModel(
      site({ original: "x".repeat(40), replacement: "" }),
    );

    expect(model.message).toContain(`\`${"x".repeat(40)}\``);
    expect(model.message).not.toContain("…");
  });

  it("renders an empty side as empty rather than as a hole", () => {
    // A block removal replaces its source with nothing; the message still
    // has to read as a sentence.
    const model = toDiagnosticModel(
      site({ operator: "block-removal", original: "{ do() }", replacement: "" }),
    );

    expect(model.message).toBe(
      "Surviving mutant CF9769AE (block-removal): `{ do() }` -> ``",
    );
  });

  it("is a warning, always: a survivor is a gap, not a broken build", () => {
    expect(toDiagnosticModel(site()).severity).toBe("warning");
    expect(toDiagnosticModel(site({ operator: "string-neutral" })).severity)
      .toBe("warning");
  });
});
