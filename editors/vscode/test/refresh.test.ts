// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Publishing the last mutation report as diagnostics: what a report that is
// there produces, what one that is not there clears, and what a report that
// changed under the editor's feet leaves behind.

import { beforeEach, describe, expect, it } from "vitest";

import { refreshDiagnostics, summariseRefresh } from "../src/flows/diagnostics";
import type { RefreshResult } from "../src/flows/diagnostics";
import { FakeHost } from "./fake-host";
import { fixture, ids } from "./fixtures";

const REPORT = "reports/mutation/mutation.json";

const A_ID = "A".repeat(64);
const B_ID = "B".repeat(64);
const C_ID = "C".repeat(64);

/** A mutation report of exactly the mutants a test cares about. */
function reportOf(
  files: Readonly<Record<string, readonly unknown[]>>,
  source = "pub fn go(x) {\n  x + 1\n}\n",
): string {
  return JSON.stringify({
    schemaVersion: "3.9.0",
    thresholds: { high: 80, low: 60, break: null },
    files: Object.fromEntries(
      Object.entries(files).map(([path, mutants]) => [
        path,
        { language: "gleam", source, mutants },
      ]),
    ),
  });
}

/** One mutant of `x + 1` on line 2, at the column it is given. */
function mutant(id: string, status: string, column = 3): unknown {
  return {
    id,
    mutatorName: "integer-arithmetic",
    replacement: "x - 1",
    location: {
      start: { line: 2, column },
      end: { line: 2, column: column + 5 },
    },
    status,
  };
}

let host: FakeHost;

beforeEach(() => {
  host = new FakeHost();
});

describe("refreshDiagnostics, with a report", () => {
  beforeEach(() => {
    host.files.set(REPORT, fixture("mutation.json"));
  });

  it("publishes every surviving mutant of every file it lists", async () => {
    const result = await refreshDiagnostics(host);

    expect(result).toEqual({
      kind: "published",
      report: REPORT,
      files: ["src/boundary.gleam"],
      survivors: 8,
      cleared: [],
    });
    expect(host.diagnostics.of("src/boundary.gleam")).toHaveLength(8);
  });

  it("publishes the survivors and not the eighteen mutants", async () => {
    await refreshDiagnostics(host);

    const codes = host.diagnostics
      .of("src/boundary.gleam")
      .map((diagnostic) => diagnostic.code);
    expect(codes).toContain(ids.boundary);
    // Killed by the workspace's own tests: not a gap, not a squiggle.
    expect(codes).not.toContain(ids.absArithmetic);
  });

  it("carries the mutant id, this extension's source, and the site", async () => {
    await refreshDiagnostics(host);

    const published = host.diagnostics
      .of("src/boundary.gleam")
      .find((diagnostic) => diagnostic.code === ids.boundary);

    expect(published).toEqual({
      message:
        "Surviving mutant CF9769AE (comparison-boundary): `value > 0` -> " +
        "`value >= 0`",
      code: ids.boundary,
      severity: "warning",
      source: "gleam_mutants",
      // `src/boundary.gleam:18:3`, as the editor counts it.
      range: {
        startLine: 17,
        startColumn: 2,
        endLine: 17,
        endColumn: 11,
      },
    });
  });

  it("reads the report the settings point at", async () => {
    host.files.delete(REPORT);
    host.files.set("build/mutants.json", fixture("mutation.json"));
    host.settingsValue = {
      ...host.settingsValue,
      reportPath: "build/mutants.json",
    };

    const result = await refreshDiagnostics(host);

    expect(result.kind).toBe("published");
    expect(result.report).toBe("build/mutants.json");
  });
});

describe("refreshDiagnostics, with no report", () => {
  it("publishes nothing, and does not mind", async () => {
    const result = await refreshDiagnostics(host);

    expect(result).toEqual({ kind: "missing", report: REPORT, cleared: [] });
    expect(host.diagnostics.keys()).toEqual([]);
    expect(host.messages).toEqual([]);
  });

  it("takes back the diagnostics of a report that has been deleted", async () => {
    host.files.set(REPORT, fixture("mutation.json"));
    await refreshDiagnostics(host);
    host.files.delete(REPORT);

    const result = await refreshDiagnostics(host);

    expect(result).toEqual({
      kind: "missing",
      report: REPORT,
      cleared: ["src/boundary.gleam"],
    });
    expect(host.diagnostics.keys()).toEqual([]);
  });
});

describe("refreshDiagnostics, with a report that changed", () => {
  it("clears the file the new report no longer lists", async () => {
    host.files.set(
      REPORT,
      reportOf({
        "src/a.gleam": [mutant(A_ID, "Survived")],
        "src/b.gleam": [mutant(B_ID, "Survived")],
      }),
    );
    await refreshDiagnostics(host);
    expect(host.diagnostics.keys()).toEqual(["src/a.gleam", "src/b.gleam"]);

    host.files.set(REPORT, reportOf({ "src/a.gleam": [mutant(A_ID, "Survived")] }));
    const result = await refreshDiagnostics(host);

    expect(result).toMatchObject({
      kind: "published",
      files: ["src/a.gleam"],
      cleared: ["src/b.gleam"],
    });
    expect(host.diagnostics.keys()).toEqual(["src/a.gleam"]);
  });

  it("clears a file whose last survivor has been killed", async () => {
    host.files.set(REPORT, reportOf({ "src/a.gleam": [mutant(A_ID, "Survived")] }));
    await refreshDiagnostics(host);

    host.files.set(REPORT, reportOf({ "src/a.gleam": [mutant(A_ID, "Killed")] }));
    const result = await refreshDiagnostics(host);

    expect(result).toMatchObject({
      kind: "published",
      files: [],
      survivors: 0,
      cleared: ["src/a.gleam"],
    });
    // Not an empty list left behind: the file carries nothing at all.
    expect(host.diagnostics.keys()).toEqual([]);
  });

  it("moves a mutant that moved rather than doubling it", async () => {
    host.files.set(REPORT, reportOf({ "src/a.gleam": [mutant(A_ID, "Survived", 3)] }));
    await refreshDiagnostics(host);

    host.files.set(REPORT, reportOf({ "src/a.gleam": [mutant(A_ID, "Survived", 5)] }));
    await refreshDiagnostics(host);

    const published = host.diagnostics.of("src/a.gleam");
    expect(published).toHaveLength(1);
    expect(published[0]?.range.startColumn).toBe(4);
  });

  it("takes on a file the new report has started listing", async () => {
    host.files.set(REPORT, reportOf({ "src/a.gleam": [mutant(A_ID, "Survived")] }));
    await refreshDiagnostics(host);

    host.files.set(
      REPORT,
      reportOf({
        "src/a.gleam": [mutant(A_ID, "Survived")],
        "src/c.gleam": [mutant(C_ID, "Survived")],
      }),
    );
    const result = await refreshDiagnostics(host);

    expect(result).toMatchObject({
      files: ["src/a.gleam", "src/c.gleam"],
      survivors: 2,
      cleared: [],
    });
  });
});

describe("refreshDiagnostics, with a report it cannot read", () => {
  beforeEach(async () => {
    host.files.set(REPORT, reportOf({ "src/a.gleam": [mutant(A_ID, "Survived")] }));
    await refreshDiagnostics(host);
  });

  it("keeps the last good diagnostics rather than blanking the editor", async () => {
    // What a report being rewritten by a run in progress looks like.
    host.files.set(REPORT, '{"schemaVersion":"3.9.0","files":{"src/a.gl');

    const result = await refreshDiagnostics(host);

    expect(result.kind).toBe("unreadable");
    expect(host.diagnostics.keys()).toEqual(["src/a.gleam"]);
  });

  it("writes down why, without a notification for a file it will reread", async () => {
    host.files.set(REPORT, "not a report at all");

    const result = await refreshDiagnostics(host);

    expect(result.kind).toBe("unreadable");
    if (result.kind !== "unreadable") return;
    expect(result.reason).not.toBe("");
    expect(host.output()).toContain(result.reason);
    expect(host.messages).toEqual([]);
  });
});

describe("summariseRefresh", () => {
  it("counts the survivors and the files they are in", () => {
    const line = summariseRefresh({
      kind: "published",
      report: REPORT,
      files: ["src/boundary.gleam"],
      survivors: 8,
      cleared: [],
    });

    expect(line).toContain("8");
    expect(line).toMatch(/surviving/i);
    expect(line).toMatch(/1 file/);
  });

  it("says a clean report is clean rather than counting to zero", () => {
    const line = summariseRefresh({
      kind: "published",
      report: REPORT,
      files: [],
      survivors: 0,
      cleared: [],
    });

    expect(line).toMatch(/no surviving mutants/i);
  });

  it("names the report that is not there, and what would write it", () => {
    const line = summariseRefresh({
      kind: "missing",
      report: REPORT,
      cleared: [],
    });

    expect(line).toContain(REPORT);
    expect(line).toMatch(/\brun\b/);
  });

  it("passes on why a report could not be read", () => {
    const result: RefreshResult = {
      kind: "unreadable",
      report: REPORT,
      reason: "the mutation report is not valid JSON",
    };

    expect(summariseRefresh(result)).toContain(
      "the mutation report is not valid JSON",
    );
  });
});
