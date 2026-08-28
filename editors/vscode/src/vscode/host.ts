// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Everything the flows are allowed to do to the editor, as one interface.
//
// This file is types and nothing else: it names the effects — running the
// CLI, showing a message, publishing a diagnostic, opening a file — without
// performing any. The adapter in this directory implements it against the
// real `vscode` module; the tests implement it with a recording fake, which
// is why the flows can be tested in a plain Node process.
//
// Every path crossing this boundary is workspace-relative, with forward
// slashes, the way the CLI and the mutation report spell them
// (`src/boundary.gleam`, `test/boundary_test.gleam`). The one absolute path
// is `root`, because `--root` takes one.

import type { CliResult } from "../core/cli";
import type { MutantRange } from "../core/stryker";

export type { CliResult, MutantRange };

/** The `gleam_mutants.*` section of the editor's settings. */
export interface HostSettings {
  // The executable and the arguments it already carries, executable first.
  readonly command: readonly string[];
  // Smartest is a separate CLI with a separate Gleam entry module.
  readonly smartestCommand: readonly string[];
  // Where `run` leaves its report, relative to the workspace root.
  readonly reportPath: string;
  // How long any one CLI invocation may take. Zero means no budget.
  readonly timeoutMs: number;
}

/**
 * One surviving mutant, as the editor shows it.
 *
 * `code` is the mutant's full stable id rather than a category: it is what
 * a code action hands back to `--mutant`, and what a user can paste into
 * `explain`. `source` is what marks the diagnostic as this extension's, and
 * so what the code action provider filters on.
 */
export interface HostDiagnostic {
  readonly message: string;
  readonly code: string;
  readonly severity: "warning";
  readonly source: "gleam_mutants";
  readonly range: MutantRange;
}

/** As much of a `DiagnosticCollection` as publishing survivors needs. */
export interface HostDiagnostics {
  set(file: string, diagnostics: readonly HostDiagnostic[]): void;
  delete(file: string): void;
  clear(): void;
  /** Every file that currently carries diagnostics from this extension. */
  keys(): readonly string[];
}

export interface HostQuickPickItem {
  readonly label: string;
  readonly description?: string;
  readonly detail?: string;
}

export interface HostPickOptions {
  readonly placeHolder: string;
  // Generated test source lands in `detail`; a user filtering on what the
  // test asserts is filtering on the only part worth reading.
  readonly matchOnDetail?: boolean;
}

export interface HostOpenOptions {
  // Put the cursor on the first line holding this text.
  readonly reveal?: string;
}

export interface HostInputOptions {
  readonly prompt: string;
  readonly placeHolder?: string;
}

/**
 * The editor, as far as a flow is concerned.
 *
 * Nothing here throws for a reason the caller could have predicted: a file
 * that is not there reads as `null`, a dismissed pick as `undefined`, and a
 * CLI that exited 2 as a result carrying the code. What is left to throw is
 * what the editor itself refused to do.
 */
export interface Host {
  /** The workspace folder every command runs against. Absolute. */
  readonly root: string;
  /** The collection this extension publishes survivors into. */
  readonly diagnostics: HostDiagnostics;

  /** Read afresh on every use, so a changed setting takes effect at once. */
  settings(): HostSettings;

  /** The file in the active editor, or null when none is open. */
  activeFile(): string | null;

  /** The file's contents, or null when it is not there. */
  readFile(file: string): Promise<string | null>;

  /** Opens the file, revealing the line `options.reveal` names. */
  openFile(file: string, options?: HostOpenOptions): Promise<void>;

  /** Runs the configured command with `args`, capturing both streams. */
  run(args: readonly string[]): Promise<CliResult>;

  /** Runs one explicitly selected configured command with `args`. */
  runWith(
    command: readonly string[],
    args: readonly string[],
  ): Promise<CliResult>;

  /** Runs `args` in a visible terminal, where the user watches it work. */
  runInTerminal(name: string, args: readonly string[]): void;

  /** Runs one explicitly selected command in a visible terminal. */
  runInTerminalWith(
    name: string,
    command: readonly string[],
    args: readonly string[],
  ): void;

  /** The chosen item, or undefined when the user dismissed the list. */
  pick<T extends HostQuickPickItem>(
    items: readonly T[],
    options: HostPickOptions,
  ): Promise<T | undefined>;

  /** A line of user-authored audit text, or undefined when dismissed. */
  input(options: HostInputOptions): Promise<string | undefined>;

  /** A notification, with buttons. Resolves to the button that was hit. */
  info(message: string, ...actions: string[]): Promise<string | undefined>;
  warn(message: string, ...actions: string[]): Promise<string | undefined>;
  error(message: string, ...actions: string[]): Promise<string | undefined>;

  /** Appends one line to the extension's output channel. */
  log(line: string): void;

  /** Brings that output channel to the front. */
  showOutput(): void;
}
