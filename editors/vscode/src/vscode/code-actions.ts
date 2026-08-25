// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The lightbulb, wired up: the editor's diagnostics in, the editor's code
// actions out, and `flows/code-actions` deciding what is offered in between.

import * as vscode from "vscode";

import { codeActionsFor } from "../flows/code-actions";
import type { HostDiagnostic } from "./host";
import { toWorkspacePath } from "./adapter";

// The mark this extension puts on its own diagnostics.
const SOURCE = "gleam_mutants";

/** Offers a test, or an explanation, for the survivor under the cursor. */
export class MutantCodeActionProvider implements vscode.CodeActionProvider {
  static readonly kinds = [vscode.CodeActionKind.QuickFix];

  constructor(private readonly root: string) {}

  /**
   * The actions for the diagnostics VS Code found in range.
   *
   * @param document - The file the cursor is in.
   * @param _range - Where the cursor is; the diagnostics already answer it.
   * @param context - What the editor found there, ours and everyone else's.
   * @returns One "generate" and one "explain" per surviving mutant.
   */
  provideCodeActions(
    document: vscode.TextDocument,
    _range: vscode.Range | vscode.Selection,
    context: vscode.CodeActionContext,
  ): vscode.CodeAction[] {
    const file = toWorkspacePath(this.root, document.uri.fsPath);

    // Both directions of the same pair: the model the flow decides on, and
    // the diagnostic the editor wants tied back to the action.
    const original = new Map<HostDiagnostic, vscode.Diagnostic>();
    const diagnostics: HostDiagnostic[] = [];
    for (const diagnostic of context.diagnostics) {
      if (diagnostic.source !== SOURCE) continue;
      const model = toHostDiagnostic(diagnostic);
      original.set(model, diagnostic);
      diagnostics.push(model);
    }

    return codeActionsFor(file, diagnostics).map((model) => {
      const action = new vscode.CodeAction(
        model.title,
        vscode.CodeActionKind.QuickFix,
      );
      action.command = {
        command: model.command,
        title: model.title,
        arguments: [...model.arguments],
      };
      action.isPreferred = model.preferred;
      const diagnostic = original.get(model.diagnostic);
      if (diagnostic !== undefined) action.diagnostics = [diagnostic];
      return action;
    });
  }
}

/** One of the editor's diagnostics, as the flows read it. */
function toHostDiagnostic(diagnostic: vscode.Diagnostic): HostDiagnostic {
  const { start, end } = diagnostic.range;
  return {
    message: diagnostic.message,
    code: typeof diagnostic.code === "string" ? diagnostic.code : "",
    severity: "warning",
    source: SOURCE,
    range: {
      startLine: start.line,
      startColumn: start.character,
      endLine: end.line,
      endColumn: end.character,
    },
  };
}
