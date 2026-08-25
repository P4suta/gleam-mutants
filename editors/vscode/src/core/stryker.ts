// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The mutation report `gleam-mutants run` writes to
// `reports/mutation/mutation.json`, in the Stryker
// mutation-testing-report-schema 3.9.0 shape, and the surviving mutants in
// it. Pure: nothing here knows what an editor is.

import { describe, isRecord, parseJsonObject } from "./json";

// Every status the schema defines, and room for one it grows later: a
// reader that threw on an unknown status would break on a newer CLI.
export type MutantStatus =
  | "Killed"
  | "Survived"
  | "Timeout"
  | "RuntimeError"
  | "CompileError"
  | "NoCoverage"
  | "Ignored"
  | "Pending"
  | (string & {});

export interface ReportPosition {
  readonly line: number;
  readonly column: number;
}

// One-based lines and UTF-16 columns, the end just past the last character.
export interface ReportLocation {
  readonly start: ReportPosition;
  readonly end: ReportPosition;
}

export interface ReportMutant {
  readonly id: string;
  readonly mutatorName: string;
  readonly replacement?: string;
  readonly location: ReportLocation;
  readonly status: MutantStatus;
  readonly [field: string]: unknown;
}

export interface MutationReportFile {
  readonly language: string;
  readonly source: string;
  readonly mutants: readonly ReportMutant[];
  readonly [field: string]: unknown;
}

export interface MutationThresholds {
  readonly high: number;
  readonly low: number;
  readonly break?: number | null;
}

export interface MutationReport {
  readonly schemaVersion: string;
  readonly thresholds: MutationThresholds;
  readonly files: Readonly<Record<string, MutationReportFile>>;
  readonly [field: string]: unknown;
}

// Zero-based, the way a VS Code `Range` counts.
export interface MutantRange {
  readonly startLine: number;
  readonly startColumn: number;
  readonly endLine: number;
  readonly endColumn: number;
}

// One mutant, placed in a buffer and carrying both sides of the rewrite.
export interface MutantSite {
  readonly file: string;
  readonly id: string;
  readonly operator: string;
  readonly original: string;
  readonly replacement: string;
  readonly status: MutantStatus;
  readonly range: MutantRange;
}

const WHAT = "the mutation report";

/**
 * Reads `reports/mutation/mutation.json`.
 *
 * Only what the editor needs is checked — the files, their mutants, and each
 * mutant's id, status and location. Every other field is carried through
 * untouched, so a report from a newer CLI loses nothing on the way in.
 *
 * @param json - The document, leading and trailing whitespace allowed.
 * @returns The report, typed but not rebuilt.
 * @throws When the text is not JSON, is not a mutation report, or holds a
 * mutant with no id, status or location. The error names the mutant.
 */
export function parseMutationReport(json: string): MutationReport {
  const report = parseJsonObject(json, WHAT);
  const files = report["files"];
  if (!isRecord(files)) {
    throw new Error(
      `${WHAT} has no \`files\`: it is ${describe(files)}, not an object`,
    );
  }

  for (const [path, file] of Object.entries(files)) {
    checkFile(path, file);
  }

  return report as unknown as MutationReport;
}

/**
 * Every mutant of a report that is still alive.
 *
 * A survivor is a mutant whose status is exactly `Survived`: a `Timeout`,
 * `RuntimeError` or `CompileError` was caught by something, and everything
 * else was never tried. Sites are ordered by file, then by where they start,
 * then by id, so a rerun over an unchanged workspace lists them the same way.
 *
 * @param report - A report from {@link parseMutationReport}.
 * @returns The surviving mutants, in zero-based editor coordinates, each
 * carrying the source it rewrites.
 */
export function survivingMutants(report: MutationReport): MutantSite[] {
  const sites: MutantSite[] = [];

  for (const [path, file] of Object.entries(report.files)) {
    const lines = (typeof file.source === "string" ? file.source : "").split(
      "\n",
    );
    for (const mutant of file.mutants) {
      if (mutant.status !== "Survived") continue;
      const range = toRange(mutant.location);
      sites.push({
        file: path,
        id: mutant.id,
        operator: mutant.mutatorName,
        original: sliceLines(lines, range),
        replacement:
          typeof mutant.replacement === "string" ? mutant.replacement : "",
        status: mutant.status,
        range,
      });
    }
  }

  return sites.sort(bySourceOrder);
}

/** Rejects a file entry the editor could not read a single mutant out of. */
function checkFile(path: string, file: unknown): void {
  if (!isRecord(file)) {
    throw new Error(
      `${WHAT} entry \`${path}\`: expected an object, got ${describe(file)}`,
    );
  }
  const mutants = file["mutants"];
  if (!Array.isArray(mutants)) {
    throw new Error(
      `${WHAT} entry \`${path}\`: \`mutants\` is ${describe(mutants)}, ` +
        "not a list",
    );
  }
  for (const mutant of mutants as unknown[]) {
    checkMutant(path, mutant);
  }
}

/** Rejects a mutant with no id, no status, or no place in the source. */
function checkMutant(path: string, mutant: unknown): void {
  if (!isRecord(mutant)) {
    throw new Error(
      `${WHAT} entry \`${path}\`: a mutant is ${describe(mutant)}, ` +
        "not an object",
    );
  }
  const id = mutant["id"];
  if (typeof id !== "string" || id === "") {
    throw new Error(`${WHAT} entry \`${path}\`: a mutant has no \`id\``);
  }
  if (typeof mutant["status"] !== "string") {
    throw new Error(`mutant ${id} in ${path} has no \`status\``);
  }
  if (!isLocation(mutant["location"])) {
    throw new Error(
      `mutant ${id} in ${path} has no readable \`location\`: ` +
        "expected `start` and `end` positions with a line and a column",
    );
  }
}

/** True when `value` is a `{start, end}` pair of one-based positions. */
function isLocation(value: unknown): value is ReportLocation {
  return isRecord(value) && isPosition(value["start"]) &&
    isPosition(value["end"]);
}

/** True when `value` is a `{line, column}` pair of numbers. */
function isPosition(value: unknown): value is ReportPosition {
  return isRecord(value) && typeof value["line"] === "number" &&
    typeof value["column"] === "number";
}

/**
 * The report's one-based location as the zero-based range an editor wants.
 * The end stays exclusive, which is what both sides mean by it.
 */
function toRange(location: ReportLocation): MutantRange {
  return {
    startLine: location.start.line - 1,
    startColumn: location.start.column - 1,
    endLine: location.end.line - 1,
    endColumn: location.end.column - 1,
  };
}

/**
 * The source a range covers, cut with UTF-16 offsets so that the columns
 * mean what they mean to VS Code. A range the file cannot hold — a report
 * read against an edited buffer — cuts nothing rather than throwing.
 */
function sliceLines(lines: readonly string[], range: MutantRange): string {
  const { startLine, startColumn, endLine, endColumn } = range;
  if (startLine < 0 || endLine < startLine) return "";
  if (startLine >= lines.length || endLine >= lines.length) return "";

  const first = lines[startLine] ?? "";
  if (startLine === endLine) return first.slice(startColumn, endColumn);

  const parts = [first.slice(startColumn)];
  for (let line = startLine + 1; line < endLine; line += 1) {
    parts.push(lines[line] ?? "");
  }
  parts.push((lines[endLine] ?? "").slice(0, endColumn));
  return parts.join("\n");
}

/**
 * File, then start position, then id. Deliberately not the end position: two
 * mutants of the same expression nest, and the shorter one is not the first.
 */
function bySourceOrder(left: MutantSite, right: MutantSite): number {
  if (left.file !== right.file) return left.file < right.file ? -1 : 1;
  if (left.range.startLine !== right.range.startLine) {
    return left.range.startLine - right.range.startLine;
  }
  if (left.range.startColumn !== right.range.startColumn) {
    return left.range.startColumn - right.range.startColumn;
  }
  if (left.id === right.id) return 0;
  return left.id < right.id ? -1 : 1;
}
