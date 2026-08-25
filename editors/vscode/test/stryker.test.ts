// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// What `reports/mutation/mutation.json` means to the editor: which mutants
// are still alive, where they are in a zero-based buffer, and what source
// they rewrite. Everything here is checked against the real report captured
// in `fixtures/mutation.json`, not against a shape we invented.

import { describe, expect, it } from "vitest";

import { parseMutationReport, survivingMutants } from "../src/core/stryker";
import { fixture, ids } from "./fixtures";

const report = () => parseMutationReport(fixture("mutation.json"));

// A report of our own, for the statuses and the geometry the fixture project
// does not happen to produce.
function syntheticReport(
  source: string,
  mutants: ReadonlyArray<Record<string, unknown>>,
): string {
  return JSON.stringify({
    schemaVersion: "1.0",
    thresholds: { high: 80, low: 60 },
    files: { "src/a.gleam": { language: "gleam", source, mutants } },
  });
}

function mutant(
  id: string,
  status: string,
  location: Record<string, unknown> = {
    start: { line: 1, column: 1 },
    end: { line: 1, column: 2 },
  },
): Record<string, unknown> {
  return {
    id,
    mutatorName: "integer-neutral",
    replacement: "1",
    location,
    status,
  };
}

describe("parseMutationReport", () => {
  it("reads the schema version, thresholds and files of a real report", () => {
    const parsed = report();

    expect(parsed.schemaVersion).toBe("1.0");
    expect(parsed.thresholds).toEqual({ high: 80, low: 60 });
    expect(Object.keys(parsed.files)).toEqual(["src/boundary.gleam"]);

    const file = parsed.files["src/boundary.gleam"]!;
    expect(file.language).toBe("gleam");
    expect(file.mutants).toHaveLength(18);
    expect(file.source).toContain("pub fn is_positive(value: Int) -> Bool {");
  });

  it("keeps the fields it was not told about", () => {
    // `duration` is in the real report and in no type of ours; a reader that
    // dropped it would silently lose whatever the schema grows next.
    const parsed = report();
    const first = parsed.files["src/boundary.gleam"]!.mutants[0]!;

    expect(first.id).toBe(ids.boundary);
    expect((first as unknown as { duration: number }).duration)
      .toBeTypeOf("number");
  });

  it("rejects text that is not JSON, quoting what it was given", () => {
    expect(() => parseMutationReport("   Compiling gleam_mutants\n")).toThrow(
      /not valid JSON/i,
    );
  });

  it("rejects JSON that is not a mutation report", () => {
    expect(() => parseMutationReport("[]")).toThrow(/mutation report/i);
    expect(() => parseMutationReport("null")).toThrow(/mutation report/i);
    expect(() => parseMutationReport('{"schemaVersion":"1.0"}')).toThrow(
      /files/,
    );
    expect(() =>
      parseMutationReport('{"files":{"src/a.gleam":{"language":"gleam"}}}'),
    ).toThrow(/mutants/);
  });

  it("names the mutant it could not read", () => {
    const broken = syntheticReport("x\n", [
      { id: "ABCD", mutatorName: "integer-neutral", status: "Survived" },
    ]);

    expect(() => parseMutationReport(broken)).toThrow(/ABCD/);
    expect(() => parseMutationReport(broken)).toThrow(/location/);
  });
});

describe("survivingMutants", () => {
  it("returns every Survived mutant of the real report, in source order", () => {
    const sites = survivingMutants(report());

    expect(sites.map((site) => site.id)).toEqual([
      ids.boundary,
      ids.boundaryLiteral,
      ids.absEquivalent,
      "3F14361697BAE826E50C1E29EABD68F679535EE839C963B5DE5C2237EA28AEFD",
      "2C096EEA3DB9652EC3D8FEE06012E8241A7B5CCA3D63F36433BE7CEC51089B2A",
      "44146834CB84C415E89F2DD3A24C992B822C6EF901805BFFAF1F597E2BCC520E",
      "008CDC16C2710BECE1321BF2166FF7F26FFC5DB7C9EEDA34545B45669156DEA9",
      "97A27F36520CD96AFA81BD221EBBF7BE32BA74FB9BC78636FE56510C748DF5B9",
    ]);
  });

  it("describes one site completely, in zero-based editor coordinates", () => {
    const [first] = survivingMutants(report());

    // `mutation.json` says line 18, columns 3 to 12, one-based and with the
    // end just past the last character.
    expect(first).toEqual({
      file: "src/boundary.gleam",
      id: ids.boundary,
      operator: "comparison-boundary",
      original: "value > 0",
      replacement: "value >= 0",
      status: "Survived",
      range: {
        startLine: 17,
        startColumn: 2,
        endLine: 17,
        endColumn: 11,
      },
    });
  });

  it("leaves out every status that is not Survived", () => {
    const parsed = parseMutationReport(
      syntheticReport("value > 0\n", [
        mutant("A1", "Killed"),
        mutant("B2", "Timeout"),
        mutant("C3", "RuntimeError"),
        mutant("D4", "CompileError"),
        mutant("E5", "NoCoverage"),
        mutant("F6", "Ignored"),
        mutant("A7", "Pending"),
        mutant("B8", "Survived"),
      ]),
    );

    expect(survivingMutants(parsed).map((site) => site.id)).toEqual(["B8"]);
  });

  it("sorts by file, then by position, then by id", () => {
    const parsed = parseMutationReport(
      JSON.stringify({
        schemaVersion: "1.0",
        thresholds: { high: 80, low: 60 },
        files: {
          "src/z.gleam": {
            language: "gleam",
            source: "a\n",
            mutants: [mutant("Z1", "Survived")],
          },
          "src/a.gleam": {
            language: "gleam",
            source: "aaaa\nbbbb\n",
            mutants: [
              mutant("A3", "Survived", {
                start: { line: 2, column: 1 },
                end: { line: 2, column: 2 },
              }),
              mutant("A2", "Survived", {
                start: { line: 1, column: 3 },
                end: { line: 1, column: 4 },
              }),
              mutant("A1", "Survived", {
                start: { line: 1, column: 1 },
                end: { line: 1, column: 2 },
              }),
              mutant("A0", "Survived", {
                start: { line: 1, column: 1 },
                end: { line: 1, column: 3 },
              }),
            ],
          },
        },
      }),
    );

    expect(survivingMutants(parsed).map((site) => `${site.file} ${site.id}`))
      .toEqual([
        "src/a.gleam A0",
        "src/a.gleam A1",
        "src/a.gleam A2",
        "src/a.gleam A3",
        "src/z.gleam Z1",
      ]);
  });

  it("carries the original across the lines a mutant spans", () => {
    const parsed = parseMutationReport(
      syntheticReport("pub fn f() {\n  one()\n  |> two()\n}\n", [
        mutant("M1", "Survived", {
          start: { line: 2, column: 3 },
          end: { line: 3, column: 12 },
        }),
      ]),
    );

    expect(survivingMutants(parsed)[0]!.original).toBe("one()\n  |> two()");
  });

  it("counts columns in UTF-16 code units, the way VS Code does", () => {
    // `"é"` is one code unit; the emoji is a surrogate pair, so the column
    // after it is two further along than a count of characters would say.
    const parsed = parseMutationReport(
      syntheticReport('let x = "é🙂" <> more\n', [
        mutant("M1", "Survived", {
          start: { line: 1, column: 9 },
          end: { line: 1, column: 14 },
        }),
      ]),
    );

    expect(survivingMutants(parsed)[0]!.original).toBe('"é🙂"');
  });

  it("reports an empty original rather than throwing on a range it cannot cut", () => {
    const parsed = parseMutationReport(
      syntheticReport("short\n", [
        mutant("M1", "Survived", {
          start: { line: 40, column: 1 },
          end: { line: 40, column: 9 },
        }),
      ]),
    );

    expect(survivingMutants(parsed)[0]!.original).toBe("");
  });

  it("treats a missing replacement as an empty one", () => {
    const parsed = parseMutationReport(
      JSON.stringify({
        schemaVersion: "1.0",
        thresholds: { high: 80, low: 60 },
        files: {
          "src/a.gleam": {
            language: "gleam",
            source: "a\n",
            mutants: [
              {
                id: "M1",
                mutatorName: "block-removal",
                location: {
                  start: { line: 1, column: 1 },
                  end: { line: 1, column: 2 },
                },
                status: "Survived",
              },
            ],
          },
        },
      }),
    );

    expect(survivingMutants(parsed)[0]!.replacement).toBe("");
  });

  it("returns nothing for a report whose every mutant died", () => {
    const parsed = parseMutationReport(
      syntheticReport("a\n", [mutant("A1", "Killed")]),
    );

    expect(survivingMutants(parsed)).toEqual([]);
  });
});
