// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// What the lightbulb offers on a surviving mutant: write the test that
// kills it, or read what it is first. Both are quick fixes, because both
// answer the squiggle rather than refactoring what is under it.

import type { HostDiagnostic } from "../vscode/host";

/**
 * One offered action, in a shape that owes nothing to the `vscode` module.
 *
 * `command` is a command id and its arguments; the provider in `src/vscode`
 * turns each of these into a `vscode.CodeAction` and nothing more.
 */
export interface CodeActionModel {
  readonly title: string;
  readonly kind: "quickfix";
  readonly preferred: boolean;
  readonly command: string;
  readonly arguments: readonly unknown[];
  readonly diagnostic: HostDiagnostic;
}

// The mark this extension puts on its own diagnostics. A code action that
// trusted the range alone would offer to write a test for a compiler error.
const SOURCE = "gleam_mutants";

// The command the quick fix runs. It is registered but not contributed: it
// takes a mutant id, and a palette entry that cannot be given one would
// only ever fail.
const GENERATE = "gleam_mutants.generateTest";

const EXPLAIN = "gleam_mutants.explainMutant";

/**
 * The actions to offer for the diagnostics under the cursor.
 *
 * Diagnostics from anything but this extension are skipped: a Gleam
 * compiler error is not a mutant, and offering to write a test for it would
 * be a lie.
 *
 * @param file - The file the diagnostics are in, workspace-relative.
 * @param diagnostics - Every diagnostic the editor found in range.
 * @returns Two actions per surviving mutant, generate first.
 */
export function codeActionsFor(
  file: string,
  diagnostics: readonly HostDiagnostic[],
): CodeActionModel[] {
  const actions: CodeActionModel[] = [];

  for (const diagnostic of diagnostics) {
    if (diagnostic.source !== SOURCE) continue;

    actions.push({
      title: "gleam_mutants: Generate a test that kills this mutant",
      kind: "quickfix",
      // Writing the test is what the user came for; explaining it is what
      // they do when they suspect the mutant is equivalent.
      preferred: true,
      command: GENERATE,
      arguments: [file, diagnostic.code],
      diagnostic,
    });

    actions.push({
      title: "gleam_mutants: Explain this mutant",
      kind: "quickfix",
      preferred: false,
      command: EXPLAIN,
      arguments: [diagnostic.code],
      diagnostic,
    });
  }

  return actions;
}
