// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The quick fix, end to end against a faked editor: a squiggle on a
// surviving mutant, a `suggest` run for that mutant alone, and — when there
// is a test to write — an `apply` that writes it and an editor that opens
// on it. Every branch a `suggest` run can take is one test here.

import { beforeEach, describe, expect, it } from "vitest";

import { parseApplyOutput, summariseApply } from "../src/core/apply";
import { parseSuggestOutput } from "../src/core/suggest";
import { applySuggestion, generateTest } from "../src/flows/quickfix";
import { FakeHost } from "./fake-host";
import { fixture, ids } from "./fixtures";

const FILE = "src/boundary.gleam";

// What `apply --yes --json --mutant CF9769AE --include src/boundary.gleam`
// prints: one plan, one test, no verification because none was asked for.
const APPLIED = JSON.stringify({
  schema_version: 1,
  plans: [
    {
      file: "test/boundary_test.gleam",
      create: false,
      imports_added: [],
      tests_added: ["is_positive_kills_cf9769ae_test"],
      tests_skipped: [],
    },
  ],
  verification: null,
});

// The fixture project is deterministic, so nothing in it is ever reported
// nondeterministic. This is the shape the CLI prints when something is.
const NONDETERMINISTIC_ID =
  "A1B2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4B5C6D7E8F90";
const NONDETERMINISTIC = JSON.stringify({
  schema_version: 1,
  suggestions: [],
  indistinguishable: [],
  nondeterministic: [
    {
      mutant_id: NONDETERMINISTIC_ID,
      display_id: NONDETERMINISTIC_ID.slice(0, 20),
      function: "elapsed",
      reason: "the original answered differently on two calls of one input",
    },
  ],
  unsupported: [],
  skipped: [],
  survivors_missing: [],
});

// A mutant of some other file: a report that never mentions it is not a
// failure, it is a report that never mentions it.
const UNMENTIONED_ID =
  "0F0E0D0C0B0A090807060504030201000F0E0D0C0B0A09080706050403020100";

// Real stderr of a `suggest` run that could not get off the ground: the
// progress lines `gleam run` writes are on it too.
const FAILED_STDERR = "   Compiling gleam_mutants\n" +
  "    Running gleam_mutants.main\n" +
  "gleam-mutants: GMU8003: the instrumented snapshot did not compile:\n" +
  "error: Unknown variable\n";

let host: FakeHost;

beforeEach(() => {
  host = new FakeHost();
  host.reply("suggest", { stdout: fixture("suggest.json") });
  host.reply("apply", { stdout: APPLIED });
});

describe("generateTest", () => {
  it("asks suggest about the one mutant the diagnostic named", async () => {
    await generateTest(host, { file: FILE, mutantId: ids.boundary });

    expect(host.runs[0]).toEqual([
      "suggest",
      "--root",
      "/w",
      "--include",
      FILE,
      "--mutant",
      ids.boundary,
      "--json",
    ]);
  });

  it("runs the configured command, prefix and all", async () => {
    host.withGleamRun();

    await generateTest(host, { file: FILE, mutantId: ids.boundary });

    expect(host.runs[0]?.slice(0, 5)).toEqual([
      "run",
      "-m",
      "gleam_mutants",
      "--",
      "suggest",
    ]);
  });

  it("writes the suggested test, for that mutant and that file alone", async () => {
    await generateTest(host, { file: FILE, mutantId: ids.boundary });

    expect(host.runs).toHaveLength(2);
    expect(host.runs[1]).toEqual([
      "apply",
      "--root",
      "/w",
      "--include",
      FILE,
      "--mutant",
      ids.boundary,
      "--json",
      "--yes",
    ]);
  });

  it("opens the test file it wrote, on the test it added", async () => {
    await generateTest(host, { file: FILE, mutantId: ids.boundary });

    expect(host.opened).toEqual([
      {
        file: "test/boundary_test.gleam",
        reveal: "is_positive_kills_cf9769ae_test",
      },
    ]);
  });

  it("says what the write amounted to", async () => {
    await generateTest(host, { file: FILE, mutantId: ids.boundary });

    expect(host.onlyMessage("info").message).toContain(
      summariseApply(parseApplyOutput(APPLIED)),
    );
    expect(host.messagesOf("error")).toEqual([]);
    expect(host.messagesOf("warn")).toEqual([]);
  });

  it("returns the suggestion it applied", async () => {
    const result = await generateTest(host, {
      file: FILE,
      mutantId: ids.boundary,
    });

    expect(result.kind).toBe("applied");
    if (result.kind !== "applied") return;
    expect(result.suggestion.test_name).toBe("is_positive_kills_cf9769ae_test");
    expect(result.suggestion.test_source).toContain("assert boundary.");
    expect(result.file).toBe("test/boundary_test.gleam");
  });

  it("takes the eight-character prefix a user pasted, as the CLI does", async () => {
    const result = await generateTest(host, {
      file: FILE,
      mutantId: ids.boundary.slice(0, 8),
    });

    expect(result.kind).toBe("applied");
    expect(host.runs[0]).toContain(ids.boundary.slice(0, 8));
  });

  it("writes nothing for a mutant no input told apart", async () => {
    const result = await generateTest(host, {
      file: FILE,
      mutantId: ids.absEquivalent,
    });

    expect(result).toEqual({ kind: "indistinguishable", cases: 200 });
    expect(host.runs).toHaveLength(1);
    expect(host.opened).toEqual([]);
  });

  it("says a mutant no input told apart is probably equivalent", async () => {
    await generateTest(host, { file: FILE, mutantId: ids.absEquivalent });

    const shown = host.onlyMessage("info").message;
    expect(shown).toMatch(/probably equivalent/i);
    expect(shown).toContain("200");
    expect(host.messagesOf("warn")).toEqual([]);
  });

  it("warns, with the reason, about a mutant no test could be written for", async () => {
    const result = await generateTest(host, {
      file: FILE,
      mutantId: ids.uncompilable,
    });

    expect(result).toEqual({
      kind: "unsupported",
      reason: "mutant does not compile: error: Type mismatch",
    });
    expect(host.onlyMessage("warn").message).toContain(
      "mutant does not compile",
    );
    expect(host.runs).toHaveLength(1);
  });

  it("warns, with the reason, about a function that does not answer twice alike", async () => {
    host.reply("suggest", { stdout: NONDETERMINISTIC });

    const result = await generateTest(host, {
      file: FILE,
      mutantId: NONDETERMINISTIC_ID,
    });

    expect(result).toEqual({
      kind: "nondeterministic",
      reason: "the original answered differently on two calls of one input",
    });
    expect(host.onlyMessage("warn").message).toContain(
      "answered differently on two calls",
    );
    expect(host.runs).toHaveLength(1);
  });

  it("says so when the run never mentioned the mutant at all", async () => {
    const result = await generateTest(host, {
      file: FILE,
      mutantId: UNMENTIONED_ID,
    });

    expect(result).toEqual({ kind: "absent" });
    expect(host.messagesOf("warn")).toHaveLength(1);
    expect(host.runs).toHaveLength(1);
    expect(host.opened).toEqual([]);
  });
});

describe("generateTest, when the tool fails", () => {
  it("shows the line the CLI failed on, and not the progress above it", async () => {
    host.reply("suggest", { code: 2, stdout: "", stderr: FAILED_STDERR });

    const result = await generateTest(host, {
      file: FILE,
      mutantId: ids.boundary,
    });

    expect(result.kind).toBe("failed");
    const shown = host.onlyMessage("error").message;
    expect(shown).toContain(
      "GMU8003: the instrumented snapshot did not compile",
    );
    expect(shown).not.toContain("Compiling gleam_mutants");
  });

  it("offers the output channel, and shows it when that is taken", async () => {
    host.reply("suggest", { code: 2, stdout: "", stderr: FAILED_STDERR });
    host.button = "Show output";

    await generateTest(host, { file: FILE, mutantId: ids.boundary });

    expect(host.onlyMessage("error").actions).toContain("Show output");
    expect(host.outputShown).toBe(1);
  });

  it("leaves the output channel alone when the button is not taken", async () => {
    host.reply("suggest", { code: 2, stdout: "", stderr: FAILED_STDERR });

    await generateTest(host, { file: FILE, mutantId: ids.boundary });

    expect(host.outputShown).toBe(0);
  });

  it("logs the whole failed run, both streams, for that button to show", async () => {
    host.reply("suggest", { code: 2, stdout: "", stderr: FAILED_STDERR });

    await generateTest(host, { file: FILE, mutantId: ids.boundary });

    expect(host.output()).toContain("suggest");
    expect(host.output()).toContain("GMU8003");
    expect(host.output()).toContain("error: Unknown variable");
  });

  it("does not write tests off the back of a failed suggest", async () => {
    host.reply("suggest", { code: 2, stdout: "", stderr: FAILED_STDERR });

    await generateTest(host, { file: FILE, mutantId: ids.boundary });

    expect(host.runs).toHaveLength(1);
    expect(host.opened).toEqual([]);
  });

  it("says so when stdout was not the JSON it promised", async () => {
    host.reply("suggest", {
      code: 0,
      stdout: "gleam-mutants: 8 suggestions\n",
      stderr: "",
    });

    const result = await generateTest(host, {
      file: FILE,
      mutantId: ids.boundary,
    });

    expect(result.kind).toBe("failed");
    expect(host.onlyMessage("error").message).toMatch(/JSON/i);
  });

  it("says so, and how long it waited, when the budget ran out", async () => {
    host.reply("suggest", { code: null, timedOut: true });

    const result = await generateTest(host, {
      file: FILE,
      mutantId: ids.boundary,
    });

    expect(result.kind).toBe("failed");
    const shown = host.onlyMessage("error").message;
    expect(shown).toMatch(/timed out/i);
    expect(shown).toMatch(/300/);
  });

  it("spawns nothing at all when the configured command is empty", async () => {
    host.settingsValue = { ...host.settingsValue, command: [] };

    const result = await generateTest(host, {
      file: FILE,
      mutantId: ids.boundary,
    });

    expect(result.kind).toBe("failed");
    expect(host.runs).toEqual([]);
    expect(host.onlyMessage("error").message).toMatch(/command/i);
  });

  it("reports an apply that failed after a suggest that did not", async () => {
    host.reply("apply", {
      code: 2,
      stdout: "",
      stderr: "gleam-mutants: GMU8016: `gleam format` refused the module\n",
    });

    const result = await generateTest(host, {
      file: FILE,
      mutantId: ids.boundary,
    });

    expect(result.kind).toBe("failed");
    expect(host.onlyMessage("error").message).toContain("GMU8016");
    expect(host.opened).toEqual([]);
  });
});

describe("applySuggestion", () => {
  it("writes one already-chosen suggestion and opens it", async () => {
    const suggestion = parseSuggestOutput(fixture("suggest.json"))
      .suggestions[0]!;

    const result = await applySuggestion(host, FILE, suggestion);

    expect(host.runs).toEqual([[
      "apply",
      "--root",
      "/w",
      "--include",
      FILE,
      "--mutant",
      suggestion.mutant_id,
      "--json",
      "--yes",
    ]]);
    expect(host.opened).toEqual([
      { file: "test/boundary_test.gleam", reveal: suggestion.test_name },
    ]);
    expect(result.kind).toBe("applied");
  });
});
