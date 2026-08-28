// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// One CLI invocation, from the flows' point of view: build the arguments,
// run them through the host, and — when it goes wrong — say so once, in the
// one place that knows how to say it.
//
// A failure is reported here rather than by each caller so that every flow
// fails the same way: the line the CLI failed on in a notification, the
// whole run in the output channel, and a button between the two.

import { buildArgs } from "../core/cli";
import type { CliOptions, CliResult } from "../core/cli";
import type { Host } from "../vscode/host";

/** A run that produced output, or one the user has already been told about. */
export type Invoked =
  | { readonly kind: "ok"; readonly result: CliResult }
  | { readonly kind: "failed"; readonly message: string };

/** A document read off a successful run, or the same reported failure. */
export type Read<T> =
  | { readonly kind: "ok"; readonly value: T }
  | { readonly kind: "failed"; readonly message: string };

// The one button every failure offers. The whole run is in the channel it
// opens, progress lines and all.
const SHOW_OUTPUT = "Show output";

// `gleam-mutants: GMU8003: ...` — the prefix is the tool naming itself, and
// a notification that repeats it says nothing twice.
const TOOL_PREFIX = /^gleam[-_]mutants:\s*/;

// The line a failed run is really about, wherever it is in the progress.
const DIAGNOSTIC = /GMU\d{4}/;

/**
 * Runs one subcommand, reporting a failure to the user itself.
 *
 * Nothing is spawned when the configured command cannot make an argument
 * list — an empty `gleam_mutants.command`, say: that is a failure like any
 * other, and is reported like one.
 *
 * @param host - The editor.
 * @param subcommand - The subcommand, with any positionals after it.
 * @param options - The selection and output flags, bar the workspace root.
 * @param name - What to call the run in a message the user reads.
 * @returns The finished run, or the failure they were shown.
 */
export async function invoke(
  host: Host,
  subcommand: string | readonly string[],
  options: Omit<CliOptions, "root">,
  name: string,
): Promise<Invoked> {
  return await invokeCommand(
    host,
    host.settings().command,
    subcommand,
    options,
    name,
  );
}

/** Runs a subcommand through an explicitly selected configured CLI. */
export async function invokeCommand(
  host: Host,
  command: readonly string[],
  subcommand: string | readonly string[],
  options: Omit<CliOptions, "root">,
  name: string,
): Promise<Invoked> {
  const settings = host.settings();

  let args: string[];
  try {
    args = buildArgs(command, subcommand, {
      ...options,
      root: host.root,
    });
  } catch (error) {
    return await report(host, `Could not run \`${name}\`: ${reasonOf(error)}`);
  }

  host.log(`$ ${[command[0] ?? "", ...args].join(" ")}`);

  let result: CliResult;
  try {
    result = await host.runWith(command, args);
  } catch (error) {
    return await report(host, `Could not run \`${name}\`: ${reasonOf(error)}`);
  }

  if (result.timedOut) {
    logRun(host, result);
    return await report(
      host,
      `\`${name}\` timed out after ${budget(settings.timeoutMs)}. ` +
        "Raise `gleam_mutants.timeoutMs` to give it longer.",
    );
  }

  if (result.code !== 0) {
    logRun(host, result);
    return await report(host, `\`${name}\` failed: ${failureLine(result)}`);
  }

  return { kind: "ok", result };
}

/**
 * Reads the JSON a `--json` run promised, reporting a failure to the user.
 *
 * @param host - The editor.
 * @param name - What to call the run in a message the user reads.
 * @param result - The finished run.
 * @param parse - The parser for the document that run prints.
 * @returns The parsed document, or the failure they were shown.
 */
export async function readJson<T>(
  host: Host,
  name: string,
  result: CliResult,
  parse: (stdout: string) => T,
): Promise<Read<T>> {
  try {
    return { kind: "ok", value: parse(result.stdout) };
  } catch (error) {
    logRun(host, result);
    return await report(
      host,
      `\`${name}\` did not print the JSON it promised: ${reasonOf(error)}`,
    );
  }
}

/**
 * Shows one failure, and opens the output channel when that is asked for.
 *
 * @param host - The editor.
 * @param message - What went wrong, in one sentence.
 * @returns The failure, so a caller can return it straight on.
 */
export async function report(
  host: Host,
  message: string,
): Promise<{ readonly kind: "failed"; readonly message: string }> {
  host.log(message);
  const hit = await host.error(message, SHOW_OUTPUT);
  if (hit === SHOW_OUTPUT) host.showOutput();
  return { kind: "failed", message };
}

/** Both streams of a run worth reading afterwards, into the channel. */
function logRun(host: Host, result: CliResult): void {
  for (const [stream, text] of [
    ["stdout", result.stdout],
    ["stderr", result.stderr],
  ] as const) {
    const body = text.trimEnd();
    if (body === "") continue;
    host.log(`--- ${stream} ---`);
    for (const line of body.split("\n")) host.log(line);
  }
}

/**
 * The one line of a failed run worth putting in a notification.
 *
 * `gleam run` writes its own "Compiling…/Running…" progress to the same
 * stream, so the newest line is not the interesting one: the interesting one
 * is the one carrying the `GMUxxxx` code.
 */
function failureLine(result: CliResult): string {
  const lines = `${result.stderr}\n${result.stdout}`
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "");

  const diagnostic = lines.find((line) => DIAGNOSTIC.test(line));
  const chosen = diagnostic ?? lines[lines.length - 1];
  if (chosen === undefined) {
    return `it exited ${result.code ?? "without a code"} and said nothing`;
  }
  return chosen.replace(TOOL_PREFIX, "");
}

/** A millisecond budget as the sentence a user reads it in. */
function budget(timeoutMs: number): string {
  if (timeoutMs <= 0) return "no time at all";
  return timeoutMs % 1000 === 0 ? `${timeoutMs / 1000} s` : `${timeoutMs} ms`;
}

/** Whatever was thrown, as a sentence. */
export function reasonOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
