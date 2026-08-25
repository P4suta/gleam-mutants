// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Apply JSON v1 — what `gleam-mutants apply --json` wrote, or would write —
// and the single line the editor shows when it is done. Pinned by
// `schema/apply-v1.schema.json` at the root of the repository.

import { describe, parseJsonObject } from "./json";

export interface ApplyPlan {
  // Always under `test/`, workspace-relative.
  readonly file: string;
  readonly create: boolean;
  readonly imports_added: readonly string[];
  readonly tests_added: readonly string[];
  // The generated tests the module already defined.
  readonly tests_skipped: readonly string[];
}

export type ApplyOutcome =
  | "killed"
  | "timed-out"
  | "survived"
  | "test-error"
  | "missing";

// Which side of the write is owed the kill. `surviving` is what exits 1.
export type ApplyAttribution = "new" | "already_killed" | "surviving";

export interface ApplyVerified {
  readonly mutant_id: string;
  // Empty for a mutant the verification run never discovered.
  readonly display_id: string;
  readonly outcome: ApplyOutcome;
  readonly killed: boolean;
  readonly attribution: ApplyAttribution;
}

export interface ApplyReport {
  readonly schema_version: 1;
  readonly plans: readonly ApplyPlan[];
  // Null when `--verify` was not asked for.
  readonly verification: readonly ApplyVerified[] | null;
}

const WHAT = "the apply output";

const SCHEMA_VERSION = 1;

// In the order a reader wants them: what the write bought, what was already
// paid for, and what is still owed.
const ATTRIBUTIONS: ReadonlyArray<{
  readonly attribution: ApplyAttribution;
  readonly one: string;
  readonly many: string;
}> = [
  { attribution: "new", one: "1 new kill", many: "new kills" },
  { attribution: "already_killed", one: "1 already killed", many: "already killed" },
  { attribution: "surviving", one: "1 still surviving", many: "still surviving" },
];

/**
 * Reads the single Apply JSON v1 value an `apply --json` run printed.
 *
 * @param stdout - The command's stdout, whitespace around it allowed.
 * @returns The report, typed but not rebuilt.
 * @throws When the text is not JSON, announces a schema version this build
 * does not know, or holds plans that are not a list.
 */
export function parseApplyOutput(stdout: string): ApplyReport {
  const report = parseJsonObject(stdout.trim(), WHAT);

  const version = report["schema_version"];
  if (version !== SCHEMA_VERSION) {
    throw new Error(
      `${WHAT} announces schema_version ${format(version)}; ` +
        `this build reads ${SCHEMA_VERSION}`,
    );
  }

  if (!Array.isArray(report["plans"])) {
    throw new Error(
      `${WHAT}: \`plans\` is ${describe(report["plans"])}, not a list`,
    );
  }

  const verification = report["verification"];
  if (
    verification !== null && verification !== undefined &&
    !Array.isArray(verification)
  ) {
    throw new Error(
      `${WHAT}: \`verification\` is ${describe(verification)}, ` +
        "not a list or null",
    );
  }

  return report as unknown as ApplyReport;
}

/**
 * The one line an editor notification shows for a finished apply.
 *
 * Reads as "what was written; what was already there; what the verification
 * made of it", with the sections that have nothing to say left out. A
 * verification that graded exactly one mutant drops the count, because
 * "verified: 1 new kill" says nothing "verified: new kill" does not.
 *
 * @param report - A report from {@link parseApplyOutput}.
 * @returns One sentence, with no trailing punctuation.
 */
export function summariseApply(report: ApplyReport): string {
  const sections = [
    writtenSection(report.plans ?? []),
    ...optional(skippedSection(report.plans ?? [])),
    ...optional(verifiedSection(report.verification ?? null)),
  ];
  return sections.join("; ");
}

/** "1 test added to test/a_test.gleam, 2 tests added to test/b_test.gleam". */
function writtenSection(plans: readonly ApplyPlan[]): string {
  const written = plans
    .filter((plan) => count(plan.tests_added) > 0)
    .map((plan) => `${tests(count(plan.tests_added))} added to ${plan.file}`);
  return written.length === 0 ? "No tests added" : written.join(", ");
}

/** What the merge left alone because the module already defined it. */
function skippedSection(plans: readonly ApplyPlan[]): string | null {
  const skipped = plans.reduce(
    (total, plan) => total + count(plan.tests_skipped),
    0,
  );
  return skipped === 0 ? null : `${tests(skipped)} already present`;
}

/** What `--verify` graded, or nothing at all when it was not asked for. */
function verifiedSection(
  verification: readonly ApplyVerified[] | null,
): string | null {
  if (verification === null) return null;
  if (verification.length === 0) return "verified: no mutants checked";

  const parts: string[] = [];
  for (const { attribution, one, many } of ATTRIBUTIONS) {
    const graded = verification.filter(
      (entry) => entry.attribution === attribution,
    ).length;
    if (graded === 0) continue;
    parts.push(graded === 1 ? one : `${graded} ${many}`);
  }

  if (parts.length === 0) return `verified: ${verification.length} checked`;
  // One mutant, one verdict: the count is the only thing it could be.
  const only = parts.length === 1 && verification.length === 1;
  return `verified: ${only ? parts[0]!.replace(/^1 /, "") : parts.join(", ")}`;
}

/** "1 test" or "2 tests". */
function tests(total: number): string {
  return `${total} test${total === 1 ? "" : "s"}`;
}

/** The length of a list that a tolerant parse may have left off. */
function count(list: readonly unknown[] | undefined): number {
  return Array.isArray(list) ? list.length : 0;
}

/** A section, or no section at all, as a spreadable list. */
function optional(section: string | null): string[] {
  return section === null ? [] : [section];
}

/** A JSON value as it should read inside a sentence about the schema. */
function format(value: unknown): string {
  return value === undefined ? "nothing at all" : JSON.stringify(value);
}
