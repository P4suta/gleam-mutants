// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The `Host` interface, implemented against the real editor. This is the
// only place where a workspace-relative path becomes a `Uri`, where a
// notification becomes a `window.show*Message`, and where an argument list
// becomes a process — which is why the flows above it need none of those to
// be tested.

import { spawn } from "node:child_process";
import { relative, sep } from "node:path";

import * as vscode from "vscode";

import { runCli } from "../core/cli";
import type { CliResult } from "../core/cli";
import type {
  Host,
  HostDiagnostic,
  HostDiagnostics,
  HostOpenOptions,
  HostPickOptions,
  HostQuickPickItem,
  HostSettings,
} from "./host";

// What the manifest contributes, repeated here for the case VS Code cannot
// answer for: a setting explicitly set to null, or a configuration read
// before the manifest is registered.
const DEFAULTS: HostSettings = {
  command: ["gleam", "run", "-m", "gleam_mutants", "--"],
  reportPath: "reports/mutation/mutation.json",
  timeoutMs: 300_000,
};

const SECTION = "gleam_mutants";

/** A `DiagnosticCollection`, addressed by workspace-relative path. */
class CollectionAdapter implements HostDiagnostics {
  constructor(
    private readonly collection: vscode.DiagnosticCollection,
    private readonly root: string,
  ) {}

  set(file: string, diagnostics: readonly HostDiagnostic[]): void {
    this.collection.set(this.uri(file), diagnostics.map(toVsCode));
  }

  delete(file: string): void {
    this.collection.delete(this.uri(file));
  }

  clear(): void {
    this.collection.clear();
  }

  keys(): readonly string[] {
    const files: string[] = [];
    this.collection.forEach((uri) => {
      files.push(toWorkspacePath(this.root, uri.fsPath));
    });
    return files;
  }

  private uri(file: string): vscode.Uri {
    return vscode.Uri.file(`${this.root}${sep}${file.split("/").join(sep)}`);
  }
}

/** The editor, as the flows are allowed to see it. */
export class VsCodeHost implements Host {
  readonly diagnostics: HostDiagnostics;

  constructor(
    readonly root: string,
    collection: vscode.DiagnosticCollection,
    private readonly channel: vscode.OutputChannel,
  ) {
    this.diagnostics = new CollectionAdapter(collection, root);
  }

  settings(): HostSettings {
    const configuration = vscode.workspace.getConfiguration(SECTION);
    const command = configuration.get<readonly string[]>("command");
    const reportPath = configuration.get<string>("reportPath");
    const timeoutMs = configuration.get<number>("timeoutMs");

    return {
      command: Array.isArray(command) ? [...command] : DEFAULTS.command,
      reportPath: typeof reportPath === "string" && reportPath !== ""
        ? reportPath
        : DEFAULTS.reportPath,
      timeoutMs: typeof timeoutMs === "number" && timeoutMs >= 0
        ? timeoutMs
        : DEFAULTS.timeoutMs,
    };
  }

  activeFile(): string | null {
    const editor = vscode.window.activeTextEditor;
    if (editor === undefined) return null;
    const document = editor.document;
    if (document.uri.scheme !== "file") return null;

    const file = toWorkspacePath(this.root, document.uri.fsPath);
    // A file outside the workspace is not a file `--include` can name.
    return file.startsWith("../") ? null : file;
  }

  async readFile(file: string): Promise<string | null> {
    try {
      const bytes = await vscode.workspace.fs.readFile(this.uri(file));
      return Buffer.from(bytes).toString("utf8");
    } catch {
      return null;
    }
  }

  async openFile(file: string, options?: HostOpenOptions): Promise<void> {
    const document = await vscode.workspace.openTextDocument(this.uri(file));
    const editor = await vscode.window.showTextDocument(document, {
      preview: false,
    });

    const needle = options?.reveal;
    if (needle === undefined || needle === "") return;

    const at = document.getText().indexOf(needle);
    if (at === -1) return;

    const position = document.positionAt(at);
    editor.selection = new vscode.Selection(position, position);
    editor.revealRange(
      new vscode.Range(position, position),
      vscode.TextEditorRevealType.InCenter,
    );
  }

  run(args: readonly string[]): Promise<CliResult> {
    const settings = this.settings();
    const executable = settings.command[0];
    if (executable === undefined) {
      return Promise.reject(
        new Error("cannot run an empty command: no executable to spawn"),
      );
    }

    return runCli(
      (argv, options) =>
        spawn(executable, argv, { cwd: options.cwd, windowsHide: true }),
      [...args],
      { cwd: this.root, timeoutMs: settings.timeoutMs },
    );
  }

  runInTerminal(name: string, args: readonly string[]): void {
    const executable = this.settings().command[0] ?? "";
    const terminal = vscode.window.createTerminal({ name, cwd: this.root });
    terminal.show(true);
    terminal.sendText([executable, ...args].map(quote).join(" "));
  }

  async pick<T extends HostQuickPickItem>(
    items: readonly T[],
    options: HostPickOptions,
  ): Promise<T | undefined> {
    // `HostQuickPickItem` is `QuickPickItem` with the fields nothing here
    // sets left off; the cast is the only place that is worth saying.
    const offered = items as unknown as readonly (T & vscode.QuickPickItem)[];
    return await vscode.window.showQuickPick(offered, {
      placeHolder: options.placeHolder,
      matchOnDetail: options.matchOnDetail ?? false,
      ignoreFocusOut: true,
    });
  }

  async info(message: string, ...actions: string[]): Promise<string | undefined> {
    return await vscode.window.showInformationMessage(message, ...actions);
  }

  async warn(message: string, ...actions: string[]): Promise<string | undefined> {
    return await vscode.window.showWarningMessage(message, ...actions);
  }

  async error(message: string, ...actions: string[]): Promise<string | undefined> {
    return await vscode.window.showErrorMessage(message, ...actions);
  }

  log(line: string): void {
    this.channel.appendLine(line);
  }

  showOutput(): void {
    this.channel.show(true);
  }

  private uri(file: string): vscode.Uri {
    return vscode.Uri.file(`${this.root}${sep}${file.split("/").join(sep)}`);
  }
}

/** One diagnostic of ours, as the editor's own. */
function toVsCode(diagnostic: HostDiagnostic): vscode.Diagnostic {
  const { range } = diagnostic;
  const published = new vscode.Diagnostic(
    new vscode.Range(
      range.startLine,
      range.startColumn,
      range.endLine,
      range.endColumn,
    ),
    diagnostic.message,
    vscode.DiagnosticSeverity.Warning,
  );
  published.source = diagnostic.source;
  // The mutant's own id: what the quick fix hands back to `--mutant`.
  published.code = diagnostic.code;
  return published;
}

/** An absolute path as the workspace-relative one the CLI spells. */
export function toWorkspacePath(root: string, file: string): string {
  return relative(root, file).split(sep).join("/");
}

/** One argument, safe to paste into the shell a terminal is running. */
function quote(argument: string): string {
  if (argument !== "" && !/[\s"'$`\\|&;<>()*?[\]{}!#~]/.test(argument)) {
    return argument;
  }
  return `"${argument.replace(/(["$`\\])/g, "\\$1")}"`;
}
