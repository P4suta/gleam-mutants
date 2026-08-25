// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The VS Code entry point: the commands, the lightbulb, the squiggles, and
// the watcher that keeps them honest. Everything it does is done by the
// flows under `src/flows`, against the `Host` implemented in `src/vscode`.
//
// Nothing here decides anything. That is deliberate: what this file holds
// is exactly what a unit test cannot reach.

import * as vscode from "vscode";

import { commandTable } from "./flows/commands";
import { refreshDiagnostics } from "./flows/diagnostics";
import { VsCodeHost } from "./vscode/adapter";
import { MutantCodeActionProvider } from "./vscode/code-actions";

const SECTION = "gleam_mutants";

/**
 * Called by VS Code for a Gleam workspace, or the first Gleam file opened.
 *
 * @param context - The extension context every registration is filed under.
 */
export function activate(context: vscode.ExtensionContext): void {
  const channel = vscode.window.createOutputChannel(SECTION);
  const collection = vscode.languages.createDiagnosticCollection(SECTION);
  context.subscriptions.push(channel, collection);

  const folder = vscode.workspace.workspaceFolders?.[0];
  if (folder === undefined) {
    channel.appendLine(
      "gleam_mutants: no workspace folder is open, so there is nothing to " +
        "mutation-test",
    );
    return;
  }

  const host = new VsCodeHost(folder.uri.fsPath, collection, channel);

  for (const [id, handler] of Object.entries(commandTable(host))) {
    context.subscriptions.push(
      vscode.commands.registerCommand(id, (...args: unknown[]) => handler(...args)),
    );
  }

  context.subscriptions.push(
    vscode.languages.registerCodeActionsProvider(
      { language: "gleam", scheme: "file" },
      new MutantCodeActionProvider(folder.uri.fsPath),
      { providedCodeActionKinds: MutantCodeActionProvider.kinds },
    ),
  );

  const refresh = (): void => {
    void refreshDiagnostics(host);
  };

  // The report is written by a `run` in a terminal, by a colleague's push,
  // or by CI: watching the file covers all three, where watching our own
  // invocations would cover one.
  let watcher: vscode.FileSystemWatcher | undefined;
  const watchReport = (): void => {
    watcher?.dispose();
    watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(folder, host.settings().reportPath),
    );
    watcher.onDidCreate(refresh);
    watcher.onDidChange(refresh);
    watcher.onDidDelete(refresh);
    context.subscriptions.push(watcher);
  };

  watchReport();

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (!event.affectsConfiguration(SECTION)) return;
      // A report that moved is a different file to watch, and a different
      // set of survivors to publish.
      watchReport();
      refresh();
    }),
  );

  refresh();
}

/** Called by VS Code on shutdown. The context disposes what was registered. */
export function deactivate(): void {
  // Intentionally empty.
}
