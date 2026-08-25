// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The four commands the manifest contributes, the one the code action keeps
// to itself, and the table `extension.ts` registers them all from.

import { beforeEach, describe, expect, it } from "vitest";

import {
  commandTable,
  explainMutant,
  runFile,
  suggestFile,
} from "../src/flows/commands";
import { FakeHost } from "./fake-host";
import { fixture, ids } from "./fixtures";
import { contributedCommands } from "./repo";

const FILE = "src/boundary.gleam";

// The command the quick fix runs. It is registered but not contributed: it
// takes a mutant id, and a palette entry that cannot be given one would
// only ever fail.
const INTERNAL = "gleam_mutants.generateTest";

interface FixtureSuggestion {
  readonly mutant_id: string;
  readonly function: string;
  readonly location: string;
  readonly test_name: string;
  readonly test_source: string;
}

const suggestions = (
  JSON.parse(fixture("suggest.json")) as {
    suggestions: readonly FixtureSuggestion[];
  }
).suggestions;

const APPLIED = JSON.stringify({
  schema_version: 1,
  plans: [
    {
      file: "test/boundary_test.gleam",
      create: false,
      imports_added: [],
      tests_added: [suggestions[0]?.test_name],
      tests_skipped: [],
    },
  ],
  verification: null,
});

const EMPTY_SUGGEST = JSON.stringify({
  schema_version: 1,
  suggestions: [],
  indistinguishable: [
    {
      mutant_id: ids.absEquivalent,
      display_id: ids.absEquivalent.slice(0, 20),
      function: "abs",
      cases: 200,
    },
  ],
  nondeterministic: [],
  unsupported: [],
  skipped: [],
  survivors_missing: [],
});

let host: FakeHost;

beforeEach(() => {
  host = new FakeHost();
});

describe("commandTable", () => {
  it("handles every command the manifest contributes", () => {
    const table = commandTable(host);

    for (const id of contributedCommands()) {
      expect(typeof table[id]).toBe("function");
    }
    expect(contributedCommands().length).toBeGreaterThan(0);
  });

  it("registers nothing beyond them but the code action's own command", () => {
    const contributed = new Set(contributedCommands());
    const extra = Object.keys(commandTable(host)).filter(
      (id) => !contributed.has(id),
    );

    expect(extra).toEqual([INTERNAL]);
  });

  it("names every command it registers under the extension's prefix", () => {
    for (const id of Object.keys(commandTable(host))) {
      expect(id.startsWith("gleam_mutants.")).toBe(true);
    }
  });

  it("runs the file command through the table the way VS Code will", async () => {
    await commandTable(host)["gleam_mutants.runFile"]!(FILE);

    expect(host.terminals).toHaveLength(1);
  });

  it("runs the quick fix through the table, file and mutant in hand", async () => {
    host.reply("suggest", { stdout: fixture("suggest.json") });
    host.reply("apply", { stdout: APPLIED });

    await commandTable(host)[INTERNAL]!(FILE, ids.boundary);

    expect(host.runs.map((args) => args[0])).toEqual(["suggest", "apply"]);
  });

  it("refreshes the diagnostics through the table, and says what it found", async () => {
    host.files.set("reports/mutation/mutation.json", fixture("mutation.json"));

    await commandTable(host)["gleam_mutants.refreshDiagnostics"]!();

    expect(host.diagnostics.of(FILE)).toHaveLength(8);
    expect(host.onlyMessage("info").message).toContain("8");
  });
});

describe("runFile", () => {
  it("mutation-tests one file in a terminal, where it can be watched", async () => {
    await runFile(host, FILE);

    expect(host.terminals).toHaveLength(1);
    expect(host.terminals[0]?.name).toMatch(/mutants/i);
    expect(host.terminals[0]?.args).toEqual([
      "run",
      "--root",
      "/w",
      "--include",
      FILE,
    ]);
  });

  it("carries the configured command prefix into the terminal", async () => {
    host.withGleamRun();

    await runFile(host, FILE);

    expect(host.terminals[0]?.args.slice(0, 5)).toEqual([
      "run",
      "-m",
      "gleam_mutants",
      "--",
      "run",
    ]);
  });

  it("falls back to the file the editor is showing", async () => {
    host.active = "src/other.gleam";

    await runFile(host);

    expect(host.terminals[0]?.args).toContain("src/other.gleam");
  });

  it("says so rather than guessing when no file is open", async () => {
    host.active = null;

    await runFile(host);

    expect(host.terminals).toEqual([]);
    expect(host.messagesOf("warn")).toHaveLength(1);
  });

  it("does not run the CLI itself: the terminal does", async () => {
    await runFile(host, FILE);

    expect(host.runs).toEqual([]);
  });
});

describe("suggestFile", () => {
  beforeEach(() => {
    host.reply("suggest", { stdout: fixture("suggest.json") });
    host.reply("apply", { stdout: APPLIED });
  });

  it("suggests for the whole file, not for one mutant", async () => {
    await suggestFile(host, FILE);

    expect(host.runs[0]).toEqual([
      "suggest",
      "--root",
      "/w",
      "--include",
      FILE,
      "--json",
    ]);
  });

  it("offers every suggestion, with the test it would write as the detail", async () => {
    await suggestFile(host, FILE);

    expect(host.picks).toHaveLength(1);
    const { items, options } = host.picks[0]!;
    expect(items).toHaveLength(suggestions.length);
    expect(items[0]?.detail).toBe(suggestions[0]?.test_source);
    expect(items[0]?.label).toContain(suggestions[0]?.function);
    expect(items[0]?.description).toContain(suggestions[0]?.location);
    // The test source is the part worth filtering on.
    expect(options.matchOnDetail).toBe(true);
    expect(options.placeHolder).not.toBe("");
  });

  it("writes the suggestion that was picked, and opens it", async () => {
    host.chooseIndex = 0;

    await suggestFile(host, FILE);

    expect(host.runs[1]).toEqual([
      "apply",
      "--root",
      "/w",
      "--include",
      FILE,
      "--mutant",
      suggestions[0]?.mutant_id,
      "--json",
      "--yes",
    ]);
    expect(host.opened).toEqual([
      {
        file: "test/boundary_test.gleam",
        reveal: suggestions[0]?.test_name,
      },
    ]);
  });

  it("writes the one that was picked, not the first one", async () => {
    host.chooseIndex = 3;

    await suggestFile(host, FILE);

    expect(host.runs[1]).toContain(suggestions[3]?.mutant_id);
  });

  it("writes nothing when the list is dismissed", async () => {
    await suggestFile(host, FILE);

    expect(host.runs).toHaveLength(1);
    expect(host.opened).toEqual([]);
  });

  it("does not open an empty list when there is nothing to suggest", async () => {
    host.reply("suggest", { stdout: EMPTY_SUGGEST });

    await suggestFile(host, FILE);

    expect(host.picks).toEqual([]);
    const shown = host.onlyMessage("info").message;
    expect(shown).toMatch(/no tests/i);
    expect(shown).toContain(FILE);
  });

  it("reports a failed run instead of an empty list", async () => {
    host.reply("suggest", {
      code: 2,
      stderr: "gleam-mutants: GMU8001: suggest supports the Erlang target only\n",
    });

    await suggestFile(host, FILE);

    expect(host.picks).toEqual([]);
    expect(host.onlyMessage("error").message).toContain("GMU8001");
  });

  it("falls back to the file the editor is showing", async () => {
    host.active = FILE;

    await suggestFile(host);

    expect(host.runs[0]).toContain(FILE);
  });

  it("says so rather than guessing when no file is open", async () => {
    host.active = null;

    await suggestFile(host);

    expect(host.runs).toEqual([]);
    expect(host.messagesOf("warn")).toHaveLength(1);
  });
});

describe("explainMutant", () => {
  const EXPLANATION = "CF9769AE  comparison-boundary  src/boundary.gleam:18:3\n" +
    "  value > 0\n" +
    "  value >= 0\n";

  it("explains the mutant it was given, into the output channel", async () => {
    host.reply("explain", { stdout: EXPLANATION });

    await explainMutant(host, ids.boundary);

    expect(host.runs).toEqual([[
      "explain",
      ids.boundary,
      "--root",
      "/w",
    ]]);
    expect(host.output()).toContain("comparison-boundary");
    expect(host.outputShown).toBe(1);
  });

  it("reports a failure with the line the CLI failed on", async () => {
    host.reply("explain", {
      code: 2,
      stderr: "gleam-mutants: GMU8011: mutant ZZ matches nothing\n",
    });

    await explainMutant(host, "ZZ");

    expect(host.onlyMessage("error").message).toContain("GMU8011");
  });

  it("offers the survivors of the open file when given no mutant", async () => {
    host.files.set("reports/mutation/mutation.json", fixture("mutation.json"));
    host.reply("explain", { stdout: EXPLANATION });
    host.chooseIndex = 0;

    await explainMutant(host);

    expect(host.picks[0]?.items).toHaveLength(8);
    expect(host.picks[0]?.items[0]?.label).toContain("CF9769AE");
    expect(host.runs[0]?.[1]).toBe(ids.boundary);
  });

  it("explains nothing when that list is dismissed", async () => {
    host.files.set("reports/mutation/mutation.json", fixture("mutation.json"));

    await explainMutant(host);

    expect(host.runs).toEqual([]);
  });

  it("says so when there is no report to pick a mutant from", async () => {
    await explainMutant(host);

    expect(host.picks).toEqual([]);
    expect(host.runs).toEqual([]);
    expect(host.messagesOf("warn")).toHaveLength(1);
  });
});
