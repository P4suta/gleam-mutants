// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import { describe, expect, it } from "vitest";

import { parseFindings } from "../src/core/smartest";

describe("Smartest findings", () => {
  it("parses the stable line protocol and the empty response", () => {
    expect(parseFindings(
      "finding-1 provisional demo/number_test/property_test\n" +
        "finding-2 unjudged demo/api_test/differential_test\n",
    )).toEqual([
      {
        id: "finding-1",
        state: "provisional",
        testId: "demo/number_test/property_test",
      },
      {
        id: "finding-2",
        state: "unjudged",
        testId: "demo/api_test/differential_test",
      },
    ]);
    expect(parseFindings("No findings.\n")).toEqual([]);
  });

  it("rejects malformed or unknown evidence states", () => {
    expect(() => parseFindings("finding-1 equivalent demo/a/b\n"))
      .toThrow(/evidence state/i);
    expect(() => parseFindings("not enough\n")).toThrow(/finding/i);
  });
});
