// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Suggest JSON v1 as the editor consumes it: parsed once per run, then asked
// about one mutant at a time. The fixture is a real
// `suggest --root fixtures/boundary_project --json`.

import { describe, expect, it } from "vitest";

import { outcomeForMutant, parseSuggestOutput } from "../src/core/suggest";
import { fixture, ids } from "./fixtures";

const report = () => parseSuggestOutput(fixture("suggest.json"));

// The smallest document the schema allows, plus whatever a test needs.
function syntheticSuggest(parts: Record<string, unknown> = {}): string {
  return JSON.stringify({
    schema_version: 1,
    suggestions: [],
    indistinguishable: [],
    nondeterministic: [],
    unsupported: [],
    skipped: [],
    survivors_missing: [],
    ...parts,
  });
}

describe("parseSuggestOutput", () => {
  it("reads every bucket of a real run", () => {
    const parsed = report();

    expect(parsed.schema_version).toBe(1);
    expect(parsed.suggestions).toHaveLength(8);
    expect(parsed.indistinguishable).toHaveLength(2);
    expect(parsed.nondeterministic).toHaveLength(0);
    expect(parsed.unsupported).toHaveLength(5);
    expect(parsed.skipped).toHaveLength(2);
    expect(parsed.survivors_missing).toEqual([]);
  });

  it("carries a suggestion whole, test source and imports included", () => {
    const suggestion = report().suggestions[0]!;

    expect(suggestion.mutant_id).toBe(ids.boundary);
    expect(suggestion.display_id).toBe("CF9769AE183954EDDE01");
    expect(suggestion.module_path).toBe("boundary");
    expect(suggestion.function).toBe("is_positive");
    expect(suggestion.operator).toBe("comparison-boundary");
    expect(suggestion.location).toBe("src/boundary.gleam:18:3");
    expect(suggestion.original).toBe("value > 0");
    expect(suggestion.replacement).toBe("value >= 0");
    expect(suggestion.inputs).toEqual(["0"]);
    expect(suggestion.expected).toBe("False");
    expect(suggestion.expected_inspect).toBe("False");
    expect(suggestion.actual_inspect).toBe("True");
    expect(suggestion.kills).toEqual([ids.boundary]);
    expect(suggestion.test_name).toBe("is_positive_kills_cf9769ae_test");
    expect(suggestion.test_source).toContain(
      "assert boundary.is_positive(0) == False",
    );
    expect(suggestion.imports).toEqual(["import boundary"]);
  });

  it("keeps `expected` null when the original cannot be written as source", () => {
    const parsed = parseSuggestOutput(
      syntheticSuggest({
        suggestions: [
          {
            module_path: "a",
            function: "f",
            mutant_id: "A".repeat(64),
            display_id: "A".repeat(20),
            operator: "integer-neutral",
            location: "src/a.gleam:1:1",
            original: "0",
            replacement: "1",
            inputs: ["0"],
            expected: null,
            expected_inspect: "//fn(a) { ... }",
            actual_inspect: "//fn(a) { ... }",
            kills: ["A".repeat(64)],
            test_name: "f_test",
            test_source: "pub fn f_test() {\n  assert True\n}",
            imports: [],
          },
        ],
      }),
    );

    expect(parsed.suggestions[0]!.expected).toBeNull();
  });

  it("tolerates the whitespace a shell leaves around the value", () => {
    expect(parseSuggestOutput(`\n  ${fixture("suggest.json")}\n\n`))
      .toEqual(report());
  });

  it("refuses a schema version it does not know, naming both versions", () => {
    const two = syntheticSuggest({ schema_version: 2 });

    expect(() => parseSuggestOutput(two)).toThrow(/schema_version/);
    expect(() => parseSuggestOutput(two)).toThrow(/\b2\b/);
    expect(() => parseSuggestOutput(two)).toThrow(/\b1\b/);
  });

  it("refuses a document with no schema version at all", () => {
    expect(() => parseSuggestOutput('{"suggestions":[]}')).toThrow(
      /schema_version/,
    );
  });

  it("refuses text that is not JSON", () => {
    expect(() => parseSuggestOutput("GMU1002: explain requires an id\n"))
      .toThrow(/not valid JSON/i);
  });

  it("refuses a document whose buckets are not arrays", () => {
    expect(() =>
      parseSuggestOutput(syntheticSuggest({ suggestions: {} })),
    ).toThrow(/suggestions/);
    expect(() =>
      parseSuggestOutput(syntheticSuggest({ unsupported: null })),
    ).toThrow(/unsupported/);
  });
});

describe("outcomeForMutant", () => {
  it("finds a suggestion by the full mutant id", () => {
    const outcome = outcomeForMutant(report(), ids.boundary);

    expect(outcome.kind).toBe("suggestion");
    if (outcome.kind !== "suggestion") throw new Error("unreachable");
    expect(outcome.suggestion.test_name).toBe("is_positive_kills_cf9769ae_test");
  });

  it("finds it by the twenty-character display id", () => {
    const outcome = outcomeForMutant(report(), "CF9769AE183954EDDE01");

    expect(outcome.kind).toBe("suggestion");
  });

  it("finds it by the eight-character prefix the CLI prints", () => {
    const outcome = outcomeForMutant(report(), "CF9769AE");

    expect(outcome.kind).toBe("suggestion");
    if (outcome.kind !== "suggestion") throw new Error("unreachable");
    expect(outcome.suggestion.mutant_id).toBe(ids.boundary);
  });

  it("matches hex in either case", () => {
    expect(outcomeForMutant(report(), "cf9769ae").kind).toBe("suggestion");
    expect(outcomeForMutant(report(), ids.boundary.toLowerCase()).kind).toBe(
      "suggestion",
    );
  });

  it("finds the suggestion that kills a mutant it is not named after", () => {
    // `E75BC68C` appears only in the kill set of the `abs` suggestion: one
    // test kills it and the mutant the suggestion is named after.
    const outcome = outcomeForMutant(report(), ids.absNeutral);

    expect(outcome.kind).toBe("suggestion");
    if (outcome.kind !== "suggestion") throw new Error("unreachable");
    expect(outcome.suggestion.mutant_id).toBe(ids.absArithmetic);
    expect(outcome.suggestion.kills).toContain(ids.absNeutral);
  });

  it("reports a mutant no input told apart, with the cases tried", () => {
    expect(outcomeForMutant(report(), ids.absEquivalent)).toEqual({
      kind: "indistinguishable",
      cases: 200,
    });
  });

  it("reports why a mutant is unsupported", () => {
    expect(outcomeForMutant(report(), ids.uncompilable)).toEqual({
      kind: "unsupported",
      reason: "mutant does not compile: error: Type mismatch",
    });
    expect(outcomeForMutant(report(), ids.privateFunction)).toEqual({
      kind: "unsupported",
      reason: "private function",
    });
  });

  it("reports a mutant whose original disagreed with itself", () => {
    const parsed = parseSuggestOutput(
      syntheticSuggest({
        nondeterministic: [
          {
            mutant_id: "B".repeat(64),
            display_id: "B".repeat(20),
            function: "now",
            reason: "the original answered differently on the same input",
          },
        ],
      }),
    );

    expect(outcomeForMutant(parsed, "BBBBBBBB")).toEqual({
      kind: "nondeterministic",
      reason: "the original answered differently on the same input",
    });
  });

  it("reports a mutant the run never mentioned as absent", () => {
    expect(outcomeForMutant(report(), "DEADBEEF")).toEqual({ kind: "absent" });
    expect(outcomeForMutant(report(), "F".repeat(64))).toEqual({
      kind: "absent",
    });
  });

  it("refuses a prefix that names two different mutants", () => {
    // `CF9769AE…` and `CF4568E0…` are both suggestions.
    expect(() => outcomeForMutant(report(), "CF")).toThrow(/ambiguous/i);
    expect(() => outcomeForMutant(report(), "CF")).toThrow(/CF9769AE/);
    expect(() => outcomeForMutant(report(), "CF")).toThrow(/CF4568E0/);
  });

  it("refuses a prefix that spans two different buckets", () => {
    // `3F143616…` is indistinguishable and `3F089A69…` unsupported: a
    // prefix cannot be answered by picking whichever bucket comes first.
    expect(() => outcomeForMutant(report(), "3F")).toThrow(/ambiguous/i);
  });

  it("does not call one mutant ambiguous with itself", () => {
    // A prefix of the display id is also a prefix of the mutant id, and the
    // kill set of the suggestion names the mutant a third time.
    expect(outcomeForMutant(report(), "CF4568E0").kind).toBe("suggestion");
  });

  it("refuses an empty id rather than answering about everything", () => {
    expect(() => outcomeForMutant(report(), "")).toThrow(/empty/i);
    expect(() => outcomeForMutant(report(), "   ")).toThrow(/empty/i);
  });
});
