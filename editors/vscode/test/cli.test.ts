// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Everything about invoking the CLI that can be decided without invoking it:
// which arguments a command gets, what a finished process amounts to, and
// what to say when the output is not the JSON value it promised.

import { afterEach, describe, expect, it, vi } from "vitest";

import type { CliProcess } from "../src/core/cli";
import { buildArgs, extractJson, runCli } from "../src/core/cli";

// The command line the extension is configured with by default, and the one
// a user who installed the packaged binary configures instead.
const viaGleam = ["gleam", "run", "-m", "gleam_mutants", "--"];
const viaBinary = ["gleam-mutants"];

class FakeStream {
  private listeners: Array<(chunk: Buffer | string) => void> = [];

  on(event: "data", listener: (chunk: Buffer | string) => void): this {
    if (event === "data") this.listeners.push(listener);
    return this;
  }

  emit(chunk: Buffer | string): void {
    for (const listener of this.listeners) listener(chunk);
  }
}

class FakeProcess implements CliProcess {
  readonly stdout = new FakeStream();
  readonly stderr = new FakeStream();
  readonly signals: Array<string | number | undefined> = [];
  private listeners = new Map<string, Array<(...args: never[]) => void>>();

  on(event: string, listener: (...args: any[]) => void): this {
    const existing = this.listeners.get(event) ?? [];
    existing.push(listener);
    this.listeners.set(event, existing);
    return this;
  }

  kill(signal?: string | number): boolean {
    this.signals.push(signal);
    return true;
  }

  close(code: number | null, signal: string | null = null): void {
    for (const listener of this.listeners.get("close") ?? []) {
      (listener as (code: number | null, signal: string | null) => void)(
        code,
        signal,
      );
    }
  }

  fail(error: Error): void {
    for (const listener of this.listeners.get("error") ?? []) {
      (listener as (error: Error) => void)(error);
    }
  }
}

afterEach(() => {
  vi.useRealTimers();
});

describe("buildArgs", () => {
  it("puts the subcommand after the arguments the command already carries", () => {
    expect(buildArgs(viaGleam, "suggest", { root: "/w" })).toEqual([
      "run",
      "-m",
      "gleam_mutants",
      "--",
      "suggest",
      "--root",
      "/w",
    ]);
  });

  it("drops nothing but the executable when the binary is the command", () => {
    expect(buildArgs(viaBinary, "run", { root: "/w" })).toEqual([
      "run",
      "--root",
      "/w",
    ]);
  });

  it("writes every option in one order, whatever order they were given in", () => {
    expect(
      buildArgs(viaBinary, "apply", {
        verify: true,
        yes: true,
        json: true,
        survivors: true,
        function: "is_positive",
        mutant: "CF9769AE",
        include: "src/boundary.gleam",
        root: "/w",
      }),
    ).toEqual([
      "apply",
      "--root",
      "/w",
      "--include",
      "src/boundary.gleam",
      "--mutant",
      "CF9769AE",
      "--function",
      "is_positive",
      "--survivors",
      "--json",
      "--yes",
      "--verify",
    ]);
  });

  it("repeats --include once per glob", () => {
    expect(
      buildArgs(viaBinary, "run", {
        root: "/w",
        include: ["src/a.gleam", "src/b/*.gleam"],
      }),
    ).toEqual([
      "run",
      "--root",
      "/w",
      "--include",
      "src/a.gleam",
      "--include",
      "src/b/*.gleam",
    ]);
  });

  it("leaves out the flags that were not asked for", () => {
    expect(
      buildArgs(viaBinary, "suggest", {
        root: "/w",
        include: undefined,
        mutant: undefined,
        function: undefined,
        survivors: false,
        json: false,
        yes: false,
        verify: false,
        extra: [],
      }),
    ).toEqual(["suggest", "--root", "/w"]);
  });

  it("takes an empty include list as no --include at all", () => {
    expect(buildArgs(viaBinary, "run", { root: "/w", include: [] })).toEqual([
      "run",
      "--root",
      "/w",
    ]);
  });

  it("keeps a positional after the subcommand, where `explain` needs it", () => {
    // `explain` takes its id as an argument and refuses `--mutant`, so the
    // id cannot be appended after the flags.
    expect(
      buildArgs(viaGleam, ["explain", "CF9769AE"], { root: "/w", json: true }),
    ).toEqual([
      "run",
      "-m",
      "gleam_mutants",
      "--",
      "explain",
      "CF9769AE",
      "--root",
      "/w",
      "--json",
    ]);
  });

  it("appends whatever else the caller wants, last", () => {
    expect(
      buildArgs(viaBinary, "suggest", {
        root: "/w",
        json: true,
        extra: ["--budget", "30s", "--seed", "7"],
      }),
    ).toEqual([
      "suggest",
      "--root",
      "/w",
      "--json",
      "--budget",
      "30s",
      "--seed",
      "7",
    ]);
  });

  it("refuses a command with no executable in it", () => {
    expect(() => buildArgs([], "suggest", { root: "/w" })).toThrow(/command/i);
  });

  it("refuses a run with no workspace root", () => {
    expect(() => buildArgs(viaBinary, "suggest", { root: "" })).toThrow(
      /root/i,
    );
  });

  it("refuses a subcommand that is not there", () => {
    expect(() => buildArgs(viaBinary, "", { root: "/w" })).toThrow(
      /subcommand/i,
    );
    expect(() => buildArgs(viaBinary, [], { root: "/w" })).toThrow(
      /subcommand/i,
    );
  });

  it("does not write to the arrays it was given", () => {
    const command = [...viaGleam];
    const include = ["src/a.gleam"];
    const extra = ["--seed", "1"];

    buildArgs(command, "suggest", { root: "/w", include, extra });

    expect(command).toEqual(viaGleam);
    expect(include).toEqual(["src/a.gleam"]);
    expect(extra).toEqual(["--seed", "1"]);
  });
});

describe("runCli", () => {
  it("hands the arguments and the working directory to the spawn it is given", async () => {
    const child = new FakeProcess();
    const spawn = vi.fn(() => child);

    const finished = runCli(spawn, ["suggest", "--json"], { cwd: "/w" });
    child.close(0);
    await finished;

    expect(spawn).toHaveBeenCalledTimes(1);
    expect(spawn).toHaveBeenCalledWith(["suggest", "--json"], { cwd: "/w" });
  });

  it("collects both streams and the exit code", async () => {
    const child = new FakeProcess();

    const finished = runCli(() => child, ["suggest"], { cwd: "/w" });
    child.stdout.emit("{\"schema_version\":");
    child.stderr.emit("   Compiling gleam_mutants\n");
    child.stdout.emit("1}\n");
    child.stderr.emit("    Running gleam_mutants.main\n");
    child.close(0);

    await expect(finished).resolves.toEqual({
      code: 0,
      stdout: '{"schema_version":1}\n',
      stderr: "   Compiling gleam_mutants\n    Running gleam_mutants.main\n",
      timedOut: false,
    });
  });

  it("reports the failure exit code rather than throwing on it", async () => {
    const child = new FakeProcess();

    const finished = runCli(() => child, ["suggest"], { cwd: "/w" });
    child.stderr.emit("gleam-mutants: GMU7001: could not create lock\n");
    child.close(2);

    const result = await finished;
    expect(result.code).toBe(2);
    expect(result.timedOut).toBe(false);
    expect(result.stderr).toContain("GMU7001");
  });

  it("decodes UTF-8 that a chunk boundary cut in half", async () => {
    const child = new FakeProcess();
    const bytes = Buffer.from('{"s":"π🙂"}', "utf8");

    const finished = runCli(() => child, ["suggest"], { cwd: "/w" });
    child.stdout.emit(bytes.subarray(0, 7));
    child.stdout.emit(bytes.subarray(7));
    child.close(0);

    expect((await finished).stdout).toBe('{"s":"π🙂"}');
  });

  it("kills the process when the budget runs out, and says that it did", async () => {
    vi.useFakeTimers();
    const child = new FakeProcess();

    const finished = runCli(() => child, ["suggest"], {
      cwd: "/w",
      timeoutMs: 5000,
    });
    child.stdout.emit("half a rep");
    await vi.advanceTimersByTimeAsync(5000);

    expect(child.signals).toHaveLength(1);
    await expect(finished).resolves.toEqual({
      code: null,
      stdout: "half a rep",
      stderr: "",
      timedOut: true,
    });
  });

  it("does not kill a process that finished inside its budget", async () => {
    vi.useFakeTimers();
    const child = new FakeProcess();

    const finished = runCli(() => child, ["suggest"], {
      cwd: "/w",
      timeoutMs: 5000,
    });
    child.close(0);
    await finished;
    await vi.advanceTimersByTimeAsync(60_000);

    expect(child.signals).toEqual([]);
  });

  it("waits forever when no budget was given", async () => {
    vi.useFakeTimers();
    const child = new FakeProcess();

    const finished = runCli(() => child, ["suggest"], { cwd: "/w" });
    await vi.advanceTimersByTimeAsync(24 * 60 * 60 * 1000);
    expect(child.signals).toEqual([]);

    child.close(0);
    expect((await finished).timedOut).toBe(false);
  });

  it("rejects when the process could not be started at all", async () => {
    const child = new FakeProcess();

    const finished = runCli(() => child, ["suggest"], { cwd: "/w" });
    child.fail(new Error("spawn gleam ENOENT"));

    await expect(finished).rejects.toThrow(/spawn gleam ENOENT/);
  });
});

describe("extractJson", () => {
  it("returns the one value on stdout, whitespace and all", () => {
    expect(extractJson('\n  {"schema_version": 1}\n\n')).toEqual({
      schema_version: 1,
    });
  });

  it("says so when stdout was empty", () => {
    expect(() => extractJson("   \n")).toThrow(/no JSON/i);
  });

  it("quotes both streams when stdout was not JSON", () => {
    let message = "";
    try {
      extractJson(
        "gleam-mutants: 8 suggestions\n",
        "gleam-mutants: GMU8017: adds nothing\n",
      );
    } catch (error) {
      message = (error as Error).message;
    }

    expect(message).toMatch(/not JSON/i);
    expect(message).toContain("gleam-mutants: 8 suggestions");
    expect(message).toContain("gleam-mutants: GMU8017: adds nothing");
  });

  it("quotes the first two hundred characters and no more", () => {
    let message = "";
    try {
      extractJson(`${"x".repeat(250)}TAIL`, `${"y".repeat(250)}TAIL`);
    } catch (error) {
      message = (error as Error).message;
    }

    expect(message).toContain("x".repeat(200));
    expect(message).not.toContain("x".repeat(201));
    expect(message).toContain("y".repeat(200));
    expect(message).not.toContain("TAIL");
    expect(message).toContain("…");
  });

  it("does not claim truncation it did not do", () => {
    let message = "";
    try {
      extractJson("nope", "");
    } catch (error) {
      message = (error as Error).message;
    }

    expect(message).toContain("nope");
    expect(message).not.toContain("…");
  });

  it("refuses two JSON values as firmly as none", () => {
    expect(() => extractJson("{} {}")).toThrow(/not JSON/i);
  });
});
