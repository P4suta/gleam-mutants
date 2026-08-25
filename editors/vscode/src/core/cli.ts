// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Running the CLI, without knowing how a process is started: the caller
// injects the spawn, so the tests never start one. `buildArgs` and
// `extractJson` are pure.

import { StringDecoder } from "node:string_decoder";

import { excerpt } from "./json";

// The selection and output flags every subcommand shares. `undefined` and
// `false` mean "not asked for": a VS Code setting that was never written is
// an absent flag, not an empty one.
export interface CliOptions {
  // The workspace `--root` points at. Required: the extension always knows
  // which folder it is running for.
  readonly root: string;
  readonly include?: string | readonly string[] | undefined;
  readonly mutant?: string | undefined;
  readonly function?: string | undefined;
  readonly survivors?: boolean | undefined;
  readonly json?: boolean | undefined;
  readonly yes?: boolean | undefined;
  readonly verify?: boolean | undefined;
  // Anything else the caller wants, appended last.
  readonly extra?: readonly string[] | undefined;
}

/**
 * The argument list for one CLI invocation.
 *
 * `command[0]` is the executable and the rest are the arguments it already
 * carries: `["gleam", "run", "-m", "gleam_mutants", "--"]` or
 * `["gleam-mutants"]`. The returned list is the arguments alone, so it can be
 * handed straight to `spawn` beside `command[0]`.
 *
 * `subcommand` may carry positionals: `explain` takes its mutant id as an
 * argument and refuses `--mutant`, so it is passed as
 * `["explain", "<id-prefix>"]` and the id stays ahead of the flags.
 *
 * Flags are written in one fixed order whatever order they were given in,
 * which is what makes a command line worth showing a user twice. Nothing the
 * caller passed in is written to.
 *
 * @param command - The configured command, executable first.
 * @param subcommand - The subcommand, with any positionals after it.
 * @param options - The selection and output flags.
 * @returns The arguments, without the executable.
 * @throws When the command is empty, the subcommand is missing, or no
 * workspace root was given.
 */
export function buildArgs(
  command: readonly string[],
  subcommand: string | readonly string[],
  options: CliOptions,
): string[] {
  if (command.length === 0) {
    throw new Error("cannot run an empty command: no executable to spawn");
  }

  const positional = (typeof subcommand === "string" ? [subcommand] : [
    ...subcommand,
  ]).filter((part) => part !== "");
  if (positional.length === 0) {
    throw new Error("cannot run the CLI without a subcommand");
  }

  if (options.root === "") {
    throw new Error("cannot run the CLI without a workspace --root");
  }

  const args = [...command.slice(1), ...positional, "--root", options.root];

  for (const glob of globs(options.include)) {
    args.push("--include", glob);
  }
  if (options.mutant !== undefined) args.push("--mutant", options.mutant);
  if (options.function !== undefined) args.push("--function", options.function);
  if (options.survivors === true) args.push("--survivors");
  if (options.json === true) args.push("--json");
  if (options.yes === true) args.push("--yes");
  if (options.verify === true) args.push("--verify");
  args.push(...(options.extra ?? []));

  return args;
}

export interface CliStream {
  on(
    event: "data",
    listener: (chunk: Buffer | Uint8Array | string) => void,
  ): unknown;
}

// As much of a `ChildProcess` as running a command needs, so that a test can
// be a plain object and the glue can pass `child_process.spawn`'s result.
export interface CliProcess {
  readonly stdout: CliStream | null;
  readonly stderr: CliStream | null;
  on(event: string, listener: (...args: any[]) => void): unknown;
  kill(signal?: string | number): unknown;
}

export type SpawnImpl = (
  args: string[],
  options: { readonly cwd: string },
) => CliProcess;

export interface RunOptions {
  readonly cwd: string;
  // Absent or zero means no budget at all.
  readonly timeoutMs?: number | undefined;
}

export interface CliResult {
  // Null when the process was killed rather than exited.
  readonly code: number | null;
  readonly stdout: string;
  readonly stderr: string;
  readonly timedOut: boolean;
}

/**
 * Runs one CLI invocation and collects everything it left behind.
 *
 * A non-zero exit is an answer, not an exception: the CLI exits 1 on a
 * surviving mutant and 2 on its own failure, and the caller wants to read
 * both. The promise rejects only when the process could not be started.
 *
 * When a budget is given and runs out, the process is killed and the result
 * says `timedOut` with whatever output had arrived by then.
 *
 * @param spawnImpl - How to start the process; injected so tests need none.
 * @param args - The arguments from {@link buildArgs}.
 * @param options - The working directory, and an optional millisecond budget.
 * @returns The exit code, both streams decoded as UTF-8, and whether the
 * budget ran out.
 */
export function runCli(
  spawnImpl: SpawnImpl,
  args: string[],
  options: RunOptions,
): Promise<CliResult> {
  return new Promise<CliResult>((resolve, reject) => {
    let child: CliProcess;
    try {
      child = spawnImpl(args, { cwd: options.cwd });
    } catch (error) {
      reject(error instanceof Error ? error : new Error(String(error)));
      return;
    }

    const stdout = collect(child.stdout);
    const stderr = collect(child.stderr);

    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;

    const finish = (code: number | null, timedOut: boolean): void => {
      if (settled) return;
      settled = true;
      if (timer !== undefined) clearTimeout(timer);
      resolve({ code, stdout: stdout(), stderr: stderr(), timedOut });
    };

    child.on("close", (code: number | null) => {
      finish(typeof code === "number" ? code : null, false);
    });

    child.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      if (timer !== undefined) clearTimeout(timer);
      reject(error);
    });

    const budget = options.timeoutMs ?? 0;
    if (budget > 0) {
      timer = setTimeout(() => {
        if (settled) return;
        child.kill("SIGTERM");
        finish(null, true);
      }, budget);
      // A pending timer must not be what keeps the editor's host alive.
      timer.unref?.();
    }
  });
}

/**
 * The single JSON value a `--json` run promises on stdout.
 *
 * @param stdout - The command's stdout.
 * @param stderr - The command's stderr, quoted back when stdout disappoints:
 * a CLI that failed said why there.
 * @returns The parsed value, of whatever shape the command printed.
 * @throws When stdout held nothing, or held something other than exactly one
 * JSON value. The error quotes the start of both streams.
 */
export function extractJson(stdout: string, stderr?: string): unknown {
  const text = stdout.trim();
  if (text === "") {
    throw new Error(
      `the command printed no JSON: stdout was empty.${streams(stdout, stderr)}`,
    );
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new Error(
      `the command printed something that was not JSON.${
        streams(stdout, stderr)
      }`,
    );
  }
}

/** Both streams, quoted and cut short, for an error a user has to read. */
function streams(stdout: string, stderr: string | undefined): string {
  return `\nstdout: ${excerpt(stdout)}\nstderr: ${excerpt(stderr ?? "")}`;
}

/** `--include` may be one glob, many, or none at all. */
function globs(include: string | readonly string[] | undefined): string[] {
  if (include === undefined) return [];
  return typeof include === "string" ? [include] : [...include];
}

/**
 * Accumulates one stream as UTF-8, holding back the bytes of a character a
 * chunk boundary cut in half.
 */
function collect(stream: CliStream | null): () => string {
  if (stream === null) return () => "";
  const decoder = new StringDecoder("utf8");
  let text = "";
  stream.on("data", (chunk) => {
    text += typeof chunk === "string"
      ? chunk
      : decoder.write(Buffer.from(chunk));
  });
  return () => text + decoder.end();
}
