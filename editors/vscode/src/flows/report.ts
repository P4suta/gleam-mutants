// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The last mutation report, read the way both readers of it want it: the
// diagnostics that publish every survivor, and the pick that offers the
// survivors of one file. A report that is not there is an answer, not a
// failure — it is what every workspace looks like before the first `run`.

import { parseMutationReport, survivingMutants } from "../core/stryker";
import type { MutantSite } from "../core/stryker";
import type { Host } from "../vscode/host";

import { reasonOf } from "./invoke";

/** What reading the configured report produced. */
export type LoadedReport =
  | {
    readonly kind: "report";
    readonly path: string;
    readonly survivors: readonly MutantSite[];
  }
  | { readonly kind: "missing"; readonly path: string }
  | {
    readonly kind: "unreadable";
    readonly path: string;
    readonly reason: string;
  };

/**
 * Reads the report `gleam_mutants.reportPath` points at.
 *
 * @param host - The editor.
 * @returns Its surviving mutants, or why there are none to be had.
 */
export async function loadReport(host: Host): Promise<LoadedReport> {
  const path = host.settings().reportPath;
  const text = await host.readFile(path);
  if (text === null) return { kind: "missing", path };

  try {
    return { kind: "report", path, survivors: survivingMutants(parseMutationReport(text)) };
  } catch (error) {
    return { kind: "unreadable", path, reason: reasonOf(error) };
  }
}

/**
 * The eight-character prefix the CLI prints a mutant by.
 *
 * @param id - A full mutant id.
 * @returns Its first eight characters, upper case.
 */
export function displayPrefix(id: string): string {
  return id.slice(0, 8).toUpperCase();
}

/**
 * Where a mutant is, as the CLI spells it: `src/boundary.gleam:18:3`.
 *
 * @param site - A surviving mutant.
 * @returns The file and the one-based position it starts at.
 */
export function locationOf(site: MutantSite): string {
  return `${site.file}:${site.range.startLine + 1}:${site.range.startColumn + 1}`;
}
