// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Publishing the surviving mutants of the last report as diagnostics, and
// taking them back when the report stops naming them.
//
// The report is the only thing this flow trusts: it does not remember what
// it published last time beyond asking the collection, so a report written
// by someone else — a colleague's `run`, a CI artifact — lands the same way
// as one written here.

import { toDiagnosticModel } from "../core/diagnostics";
import type { MutantSite } from "../core/stryker";
import type { Host, HostDiagnostic } from "../vscode/host";

import { loadReport } from "./report";

/**
 * What one refresh did.
 *
 * `missing` is a workspace that has not been mutation-tested yet, which is
 * every workspace until the first `run`; `unreadable` is a report that is
 * there and is not a report — half-written, most likely, by a run that is
 * still going — and deliberately leaves the last good diagnostics alone.
 */
export type RefreshResult =
  | {
    readonly kind: "published";
    readonly report: string;
    readonly files: readonly string[];
    readonly survivors: number;
    readonly cleared: readonly string[];
  }
  | {
    readonly kind: "missing";
    readonly report: string;
    readonly cleared: readonly string[];
  }
  | {
    readonly kind: "unreadable";
    readonly report: string;
    readonly reason: string;
  };

/**
 * Rereads the configured report and republishes every surviving mutant.
 *
 * Quiet by design: it is called on activation and on every write of the
 * report, so it says what it did to the output channel rather than to the
 * user. The command that a user invoked says it out loud with
 * {@link summariseRefresh}.
 *
 * @param host - The editor.
 * @returns What the report held, and which files stopped carrying
 * diagnostics because it no longer lists them.
 */
export async function refreshDiagnostics(host: Host): Promise<RefreshResult> {
  const loaded = await loadReport(host);
  const published = [...host.diagnostics.keys()];

  if (loaded.kind === "missing") {
    for (const file of published) host.diagnostics.delete(file);
    host.log(
      `gleam_mutants: no mutation report at ${loaded.path}` +
        (published.length === 0 ? "" : `; cleared ${published.length} file(s)`),
    );
    return { kind: "missing", report: loaded.path, cleared: published };
  }

  if (loaded.kind === "unreadable") {
    // The last good squiggles are better than none: a run in progress
    // rewrites this file, and the next write will be readable again.
    host.log(`gleam_mutants: kept the last diagnostics: ${loaded.reason}`);
    return { kind: "unreadable", report: loaded.path, reason: loaded.reason };
  }

  const grouped = groupByFile(loaded.survivors);
  for (const [file, diagnostics] of grouped) host.diagnostics.set(file, diagnostics);

  const cleared = published.filter((file) => !grouped.has(file));
  for (const file of cleared) host.diagnostics.delete(file);

  const files = [...grouped.keys()];
  host.log(
    `gleam_mutants: ${loaded.survivors.length} surviving mutant(s) in ` +
      `${files.length} file(s) from ${loaded.path}`,
  );

  return {
    kind: "published",
    report: loaded.path,
    files,
    survivors: loaded.survivors.length,
    cleared,
  };
}

/**
 * One line for a refresh a user asked for.
 *
 * @param result - What {@link refreshDiagnostics} returned.
 * @returns One sentence, with no trailing punctuation.
 */
export function summariseRefresh(result: RefreshResult): string {
  if (result.kind === "missing") {
    return `No mutation report at ${result.report} yet — run gleam_mutants ` +
      "over this workspace to write one";
  }
  if (result.kind === "unreadable") {
    return `Could not read ${result.report}: ${result.reason}`;
  }
  if (result.survivors === 0) {
    return "No surviving mutants in the last report";
  }
  return `${count(result.survivors, "surviving mutant")} in ` +
    `${count(result.files.length, "file")}`;
}

/** The survivors of one report, as diagnostics, keyed by their file. */
function groupByFile(
  survivors: readonly MutantSite[],
): Map<string, HostDiagnostic[]> {
  const grouped = new Map<string, HostDiagnostic[]>();
  for (const site of survivors) {
    const published = grouped.get(site.file) ?? [];
    published.push(toDiagnostic(site));
    grouped.set(site.file, published);
  }
  return grouped;
}

/**
 * One survivor as one diagnostic.
 *
 * The wording and the range are the core's; the `code` is the mutant's own
 * id, because a quick fix hands it straight back to `--mutant`.
 */
function toDiagnostic(site: MutantSite): HostDiagnostic {
  const model = toDiagnosticModel(site);
  return {
    message: model.message,
    code: site.id,
    severity: "warning",
    source: "gleam_mutants",
    range: model.range,
  };
}

/** "1 file", "8 surviving mutants". */
function count(total: number, noun: string): string {
  return `${total} ${noun}${total === 1 ? "" : "s"}`;
}
