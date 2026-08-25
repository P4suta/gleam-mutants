// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The editor, faked: a `Host` that records what was asked of it and answers
// from a script. Nothing here starts a process, touches a disk or imports
// `vscode`, which is the whole point of the interface it implements.

import type { CliResult } from "../src/core/cli";
import type {
  Host,
  HostDiagnostic,
  HostDiagnostics,
  HostOpenOptions,
  HostPickOptions,
  HostQuickPickItem,
  HostSettings,
} from "../src/vscode/host";

export interface RecordedMessage {
  readonly level: "info" | "warn" | "error";
  readonly message: string;
  readonly actions: readonly string[];
}

export interface RecordedPick {
  readonly items: readonly HostQuickPickItem[];
  readonly options: HostPickOptions;
}

export interface RecordedOpen {
  readonly file: string;
  readonly reveal: string | null;
}

export interface RecordedTerminal {
  readonly name: string;
  readonly args: readonly string[];
}

/** A scripted CLI answer: everything not given is the successful default. */
export type Reply = Partial<CliResult>;

const SUCCESS: CliResult = {
  code: 0,
  stdout: "",
  stderr: "",
  timedOut: false,
};

export class FakeDiagnostics implements HostDiagnostics {
  readonly entries = new Map<string, readonly HostDiagnostic[]>();
  // Every call, in order, so a test can tell "set to nothing" from "gone".
  readonly operations: string[] = [];

  set(file: string, diagnostics: readonly HostDiagnostic[]): void {
    this.operations.push(`set ${file} (${diagnostics.length})`);
    this.entries.set(file, [...diagnostics]);
  }

  delete(file: string): void {
    this.operations.push(`delete ${file}`);
    this.entries.delete(file);
  }

  clear(): void {
    this.operations.push("clear");
    this.entries.clear();
  }

  keys(): readonly string[] {
    return [...this.entries.keys()];
  }

  /** What a file currently carries, or an empty list when it carries none. */
  of(file: string): readonly HostDiagnostic[] {
    return this.entries.get(file) ?? [];
  }
}

export class FakeHost implements Host {
  root = "/w";

  readonly diagnostics = new FakeDiagnostics();

  // The packaged binary by default, so an asserted argument list reads as
  // the command line it is. `withGleamRun` swaps in the shipped default.
  settingsValue: HostSettings = {
    command: ["gleam-mutants"],
    reportPath: "reports/mutation/mutation.json",
    timeoutMs: 300_000,
  };

  active: string | null = "src/boundary.gleam";

  /** Workspace-relative path to contents. Anything absent reads as null. */
  readonly files = new Map<string, string>();

  /** Subcommand to what running it should look like. */
  readonly replies = new Map<string, Reply>();

  readonly runs: Array<readonly string[]> = [];
  readonly terminals: RecordedTerminal[] = [];
  readonly messages: RecordedMessage[] = [];
  readonly picks: RecordedPick[] = [];
  readonly opened: RecordedOpen[] = [];
  readonly lines: string[] = [];
  outputShown = 0;

  /** The button the user hits, when it is one of the offered ones. */
  button: string | undefined = undefined;

  /** Which item the user picks, if any. */
  chooseIndex: number | null = null;
  chooseWhere: ((item: HostQuickPickItem) => boolean) | null = null;

  settings(): HostSettings {
    return this.settingsValue;
  }

  activeFile(): string | null {
    return this.active;
  }

  readFile(file: string): Promise<string | null> {
    return Promise.resolve(this.files.get(file) ?? null);
  }

  openFile(file: string, options?: HostOpenOptions): Promise<void> {
    this.opened.push({ file, reveal: options?.reveal ?? null });
    return Promise.resolve();
  }

  run(args: readonly string[]): Promise<CliResult> {
    this.runs.push([...args]);
    const subcommand = this.subcommandOf(args);
    const reply = this.replies.get(subcommand);
    if (reply === undefined) {
      throw new Error(
        `the test did not script a \`${subcommand}\` run: ${args.join(" ")}`,
      );
    }
    return Promise.resolve({ ...SUCCESS, ...reply });
  }

  runInTerminal(name: string, args: readonly string[]): void {
    this.terminals.push({ name, args: [...args] });
  }

  pick<T extends HostQuickPickItem>(
    items: readonly T[],
    options: HostPickOptions,
  ): Promise<T | undefined> {
    this.picks.push({ items: [...items], options });
    if (this.chooseWhere !== null) {
      return Promise.resolve(items.find((item) => this.chooseWhere?.(item)));
    }
    if (this.chooseIndex === null) return Promise.resolve(undefined);
    return Promise.resolve(items[this.chooseIndex]);
  }

  info(message: string, ...actions: string[]): Promise<string | undefined> {
    return this.show("info", message, actions);
  }

  warn(message: string, ...actions: string[]): Promise<string | undefined> {
    return this.show("warn", message, actions);
  }

  error(message: string, ...actions: string[]): Promise<string | undefined> {
    return this.show("error", message, actions);
  }

  log(line: string): void {
    this.lines.push(line);
  }

  showOutput(): void {
    this.outputShown += 1;
  }

  // --- what a test asserts on -------------------------------------------

  /** Scripts one subcommand's answer. Chainable. */
  reply(subcommand: string, reply: Reply): this {
    this.replies.set(subcommand, reply);
    return this;
  }

  /** Swaps in the command the extension ships with, prefix and all. */
  withGleamRun(): this {
    this.settingsValue = {
      ...this.settingsValue,
      command: ["gleam", "run", "-m", "gleam_mutants", "--"],
    };
    return this;
  }

  /** Every message shown at one level. */
  messagesOf(level: RecordedMessage["level"]): readonly RecordedMessage[] {
    return this.messages.filter((message) => message.level === level);
  }

  /** The only message shown at one level, or a failure if there are more. */
  onlyMessage(level: RecordedMessage["level"]): RecordedMessage {
    const shown = this.messagesOf(level);
    if (shown.length !== 1) {
      throw new Error(
        `expected exactly one ${level} message, got ${shown.length}: ` +
          shown.map((message) => message.message).join(" | "),
      );
    }
    return shown[0]!;
  }

  /** Everything written to the output channel, as one document. */
  output(): string {
    return this.lines.join("\n");
  }

  /** Records one notification and answers with the scripted button. */
  private show(
    level: RecordedMessage["level"],
    message: string,
    actions: readonly string[],
  ): Promise<string | undefined> {
    this.messages.push({ level, message, actions: [...actions] });
    const hit = this.button;
    return Promise.resolve(
      hit !== undefined && actions.includes(hit) ? hit : undefined,
    );
  }

  /** The subcommand of one argument list, past the configured prefix. */
  private subcommandOf(args: readonly string[]): string {
    const prefix = this.settingsValue.command.slice(1);
    for (const [index, part] of prefix.entries()) {
      if (args[index] !== part) {
        throw new Error(
          `the arguments do not carry the configured command prefix ` +
            `\`${prefix.join(" ")}\`: ${args.join(" ")}`,
        );
      }
    }
    return args[prefix.length] ?? "";
  }
}
