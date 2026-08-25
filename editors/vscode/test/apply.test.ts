// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Apply JSON v1, and the one line the editor shows when the write is done.
// Both fixtures are real: a dry run over `fixtures/boundary_project`, and an
// `apply --yes --verify` over a throwaway copy of it.

import { describe, expect, it } from "vitest";

import { parseApplyOutput, summariseApply } from "../src/core/apply";
import { fixture } from "./fixtures";

const dryRun = () => parseApplyOutput(fixture("apply-dry-run.json"));
const verified = () => parseApplyOutput(fixture("apply-verified.json"));

function syntheticApply(parts: Record<string, unknown> = {}): string {
  return JSON.stringify({
    schema_version: 1,
    plans: [],
    verification: null,
    ...parts,
  });
}

function plan(parts: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    file: "test/boundary_test.gleam",
    create: false,
    imports_added: [],
    tests_added: [],
    tests_skipped: [],
    ...parts,
  };
}

function verifiedMutant(
  id: string,
  attribution: string,
): Record<string, unknown> {
  return {
    mutant_id: id.padEnd(64, "0"),
    display_id: id.padEnd(20, "0"),
    outcome: attribution === "surviving" ? "survived" : "killed",
    killed: attribution !== "surviving",
    attribution,
  };
}

describe("parseApplyOutput", () => {
  it("reads the plan of a real dry run", () => {
    const parsed = dryRun();

    expect(parsed.schema_version).toBe(1);
    expect(parsed.plans).toHaveLength(1);

    const only = parsed.plans[0]!;
    expect(only.file).toBe("test/boundary_test.gleam");
    expect(only.create).toBe(false);
    expect(only.imports_added).toEqual(["import gleam/option.{None, Some}"]);
    expect(only.tests_added).toHaveLength(8);
    expect(only.tests_added[0]).toBe("is_positive_kills_cf9769ae_test");
    expect(only.tests_skipped).toEqual([]);
    expect(parsed.verification).toBeNull();
  });

  it("reads what a real --verify graded, attribution by attribution", () => {
    const parsed = verified();
    const verification = parsed.verification!;

    expect(verification).toHaveLength(11);
    expect(verification[0]).toEqual({
      mutant_id:
        "CF9769AE183954EDDE01DCDA44223126335AA5763AA153644C719EEA99C8D971",
      display_id: "CF9769AE183954EDDE01",
      outcome: "killed",
      killed: true,
      attribution: "new",
    });
    expect(
      verification.filter((entry) => entry.attribution === "new"),
    ).toHaveLength(5);
    expect(
      verification.filter((entry) => entry.attribution === "already_killed"),
    ).toHaveLength(6);
    expect(
      verification.filter((entry) => entry.attribution === "surviving"),
    ).toHaveLength(0);
  });

  it("tolerates the whitespace a shell leaves around the value", () => {
    expect(parseApplyOutput(`\n${fixture("apply-dry-run.json")}  `)).toEqual(
      dryRun(),
    );
  });

  it("refuses text that is not JSON, and versions it does not know", () => {
    expect(() => parseApplyOutput("GMU1002: apply needs --yes\n")).toThrow(
      /not valid JSON/i,
    );
    expect(() => parseApplyOutput(syntheticApply({ schema_version: 2 })))
      .toThrow(/schema_version/);
    expect(() => parseApplyOutput('{"plans":[]}')).toThrow(/schema_version/);
  });

  it("refuses a document whose plans are not a list", () => {
    expect(() => parseApplyOutput(syntheticApply({ plans: null }))).toThrow(
      /plans/,
    );
  });
});

describe("summariseApply", () => {
  it("says what a real dry run would write, and says nothing about kills", () => {
    expect(summariseApply(dryRun())).toBe(
      "8 tests added to test/boundary_test.gleam",
    );
  });

  it("adds what a real --verify found", () => {
    expect(summariseApply(verified())).toBe(
      "8 tests added to test/boundary_test.gleam; " +
        "verified: 5 new kills, 6 already killed",
    );
  });

  it("drops the count when the verification graded one mutant", () => {
    const one = parseApplyOutput(
      syntheticApply({
        plans: [plan({ tests_added: ["is_positive_kills_cf9769ae_test"] })],
        verification: [verifiedMutant("CF9769AE", "new")],
      }),
    );

    expect(summariseApply(one)).toBe(
      "1 test added to test/boundary_test.gleam; verified: new kill",
    );
  });

  it("names a surviving mutant, which is the finding of the three", () => {
    const surviving = parseApplyOutput(
      syntheticApply({
        plans: [plan({ tests_added: ["a_test", "b_test"] })],
        verification: [
          verifiedMutant("AAAAAAAA", "new"),
          verifiedMutant("BBBBBBBB", "surviving"),
        ],
      }),
    );

    expect(summariseApply(surviving)).toBe(
      "2 tests added to test/boundary_test.gleam; " +
        "verified: 1 new kill, 1 still surviving",
    );
  });

  it("reports one file per plan that gained something", () => {
    const many = parseApplyOutput(
      syntheticApply({
        plans: [
          plan({ file: "test/a_test.gleam", tests_added: ["a_test"] }),
          plan({ file: "test/b_test.gleam", tests_added: ["b_test", "c_test"] }),
          plan({ file: "test/c_test.gleam" }),
        ],
      }),
    );

    expect(summariseApply(many)).toBe(
      "1 test added to test/a_test.gleam, 2 tests added to test/b_test.gleam",
    );
  });

  it("says what was already there when nothing was added", () => {
    const nothing = parseApplyOutput(
      syntheticApply({
        plans: [plan({ tests_skipped: ["a_test", "b_test"] })],
      }),
    );

    expect(summariseApply(nothing)).toBe(
      "No tests added; 2 tests already present",
    );
  });

  it("says so when there was nothing to do at all", () => {
    expect(summariseApply(parseApplyOutput(syntheticApply()))).toBe(
      "No tests added",
    );
  });

  it("counts the tests it skipped beside the ones it wrote", () => {
    const both = parseApplyOutput(
      syntheticApply({
        plans: [plan({ tests_added: ["a_test"], tests_skipped: ["b_test"] })],
      }),
    );

    expect(summariseApply(both)).toBe(
      "1 test added to test/boundary_test.gleam; 1 test already present",
    );
  });

  it("distinguishes a verification that graded nothing from none at all", () => {
    const empty = parseApplyOutput(
      syntheticApply({
        plans: [plan({ tests_added: ["a_test"] })],
        verification: [],
      }),
    );

    expect(summariseApply(empty)).toBe(
      "1 test added to test/boundary_test.gleam; verified: no mutants checked",
    );
  });
});
