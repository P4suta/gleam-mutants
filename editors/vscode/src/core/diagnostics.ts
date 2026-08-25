// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// One surviving mutant as one diagnostic, in a shape that owes nothing to
// the `vscode` module: the glue turns this into a diagnostic the editor
// understands, and the wording is pinned by tests rather than by a
// screenshot.

import type { MutantRange, MutantSite } from "./stryker";

export interface DiagnosticModel {
  readonly message: string;
  readonly code: string;
  // A survivor is a gap in the tests, not a broken build.
  readonly severity: "warning";
  readonly range: MutantRange;
}

// How much of either side of the rewrite fits in a tooltip before it stops
// being read. Longer snippets are cut with an ellipsis.
const MAX_SNIPPET = 40;

// The code a user filters on, and that the glue hangs a quick fix off.
const CODE = "surviving-mutant";

/**
 * One surviving mutant as the diagnostic an editor should show for it.
 *
 * The message names the mutant by the eight-character prefix the CLI prints,
 * so that what a user reads in the editor is what they can paste into
 * `explain` or `suggest --mutant`.
 *
 * @param site - A surviving mutant from `survivingMutants`.
 * @returns The message, code, severity and range, all editor-agnostic.
 */
export function toDiagnosticModel(site: MutantSite): DiagnosticModel {
  const message = `Surviving mutant ${displayPrefix(site.id)} ` +
    `(${site.operator}): ` +
    `\`${snippet(site.original)}\` -> \`${snippet(site.replacement)}\``;

  return { message, code: CODE, severity: "warning", range: site.range };
}

/** The first eight characters of an id, upper case, as the CLI prints it. */
function displayPrefix(id: string): string {
  return id.slice(0, 8).toUpperCase();
}

/**
 * One side of the rewrite, on one line and short enough to read. A mutant
 * that spans a pipeline is folded to a single space per break, so the
 * message stays a sentence rather than becoming a listing.
 */
function snippet(source: string): string {
  const flat = source.replace(/\s*\n\s*/g, " ");
  return flat.length <= MAX_SNIPPET
    ? flat
    : `${flat.slice(0, MAX_SNIPPET - 1)}…`;
}
