// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Suggest JSON v1 — the one value `gleam-mutants suggest --json` prints —
// and the question the editor asks of it: what became of this one mutant?
// Pinned by `schema/suggest-v1.schema.json` at the root of the repository.

import { describe, parseJsonObject } from "./json";

export interface Suggestion {
  readonly module_path: string;
  readonly function: string;
  readonly mutant_id: string;
  readonly display_id: string;
  readonly operator: string;
  // `src/boundary.gleam:18:3`, one-based, as the CLI prints it.
  readonly location: string;
  readonly original: string;
  readonly replacement: string;
  readonly inputs: readonly string[];
  // The original's answer as Gleam source, or null when it has none.
  readonly expected: string | null;
  readonly expected_inspect: string;
  readonly actual_inspect: string;
  // Every mutant this one test kills, its own included.
  readonly kills: readonly string[];
  readonly test_name: string;
  readonly test_source: string;
  // The import lines this test needs on its own; they are merged per module
  // rather than concatenated.
  readonly imports: readonly string[];
}

export interface Indistinguishable {
  readonly mutant_id: string;
  readonly display_id: string;
  readonly function: string;
  readonly cases: number;
}

export interface Nondeterministic {
  readonly mutant_id: string;
  readonly display_id: string;
  readonly function: string;
  readonly reason: string;
}

export interface Unsupported {
  readonly mutant_id: string;
  readonly display_id: string;
  readonly function: string;
  readonly reason: string;
}

export interface SkippedFunction {
  readonly module: string;
  readonly function: string;
  readonly reason: string;
}

export interface SuggestReport {
  readonly schema_version: 1;
  readonly workspace_digest?: string;
  readonly suggestions: readonly Suggestion[];
  readonly indistinguishable: readonly Indistinguishable[];
  readonly nondeterministic: readonly Nondeterministic[];
  readonly unsupported: readonly Unsupported[];
  readonly skipped: readonly SkippedFunction[];
  readonly survivors_missing: readonly string[];
}

// What one run has to say about one mutant. `absent` is a real answer: the
// run may never have selected it.
export type MutantOutcome =
  | { readonly kind: "suggestion"; readonly suggestion: Suggestion }
  | { readonly kind: "indistinguishable"; readonly cases: number }
  | { readonly kind: "nondeterministic"; readonly reason: string }
  | { readonly kind: "unsupported"; readonly reason: string }
  | { readonly kind: "absent" };

const WHAT = "the suggest output";

const SCHEMA_VERSION = 1;

const BUCKETS = [
  "suggestions",
  "indistinguishable",
  "nondeterministic",
  "unsupported",
  "skipped",
  "survivors_missing",
] as const;

/**
 * Reads the single Suggest JSON v1 value a `suggest --json` run printed.
 *
 * The version is checked and every bucket is required to be a list; the
 * entries themselves are carried through as they came, so a field a newer
 * CLI adds survives the trip.
 *
 * @param stdout - The command's stdout, whitespace around it allowed.
 * @returns The report, typed but not rebuilt.
 * @throws When the text is not JSON, announces a schema version this build
 * does not know, or is missing one of its buckets.
 */
export function parseSuggestOutput(stdout: string): SuggestReport {
  const report = parseJsonObject(stdout.trim(), WHAT);

  const version = report["schema_version"];
  if (version !== SCHEMA_VERSION) {
    throw new Error(
      `${WHAT} announces schema_version ${format(version)}; ` +
        `this build reads ${SCHEMA_VERSION}`,
    );
  }

  for (const bucket of BUCKETS) {
    if (!Array.isArray(report[bucket])) {
      throw new Error(
        `${WHAT}: \`${bucket}\` is ${describe(report[bucket])}, not a list`,
      );
    }
  }

  return report as unknown as SuggestReport;
}

/**
 * What a run made of one mutant.
 *
 * `mutantId` is matched the way the CLI matches `--mutant`: a full id, the
 * twenty-character display id, or any prefix of either, in either case. A
 * mutant that no suggestion is named after is still found when another
 * suggestion's test kills it — that test is the answer for it too.
 *
 * @param report - A report from {@link parseSuggestOutput}.
 * @param mutantId - A full id, a display id, or a prefix of one.
 * @returns The bucket the mutant landed in, or `absent` when this run never
 * mentioned it.
 * @throws When the id is blank, or when the prefix names more than one
 * mutant. The error lists the display prefixes it matched.
 */
export function outcomeForMutant(
  report: SuggestReport,
  mutantId: string,
): MutantOutcome {
  const needle = mutantId.trim().toUpperCase();
  if (needle === "") {
    throw new Error("cannot look a mutant up by an empty id");
  }

  const matched = new Map<string, Candidate>();
  for (const candidate of candidates(report)) {
    if (!candidate.aliases.some((alias) => alias.startsWith(needle))) continue;
    const seen = matched.get(candidate.id);
    // A mutant named both by its own entry and by another test's kill set is
    // one mutant; its own entry is the more specific answer.
    if (seen === undefined || (candidate.own && !seen.own)) {
      matched.set(candidate.id, candidate);
    }
  }

  if (matched.size === 0) return { kind: "absent" };
  if (matched.size > 1) {
    const names = [...matched.keys()].map((id) => id.slice(0, 8)).sort();
    throw new Error(
      `mutant id "${mutantId}" is ambiguous: it matches ` +
        `${names.join(", ")}`,
    );
  }

  return [...matched.values()][0]!.outcome;
}

// One mutant a run mentioned, under every name it mentioned it by. `own` is
// false for a mutant that only appears in some other suggestion's kill set.
interface Candidate {
  readonly id: string;
  readonly own: boolean;
  readonly aliases: readonly string[];
  readonly outcome: MutantOutcome;
}

/** Every mutant the run mentioned, in the order the buckets are printed. */
function* candidates(report: SuggestReport): Generator<Candidate> {
  for (const suggestion of report.suggestions) {
    const outcome: MutantOutcome = { kind: "suggestion", suggestion };
    yield own(suggestion.mutant_id, suggestion.display_id, outcome);
    for (const killed of suggestion.kills ?? []) {
      if (upper(killed) === upper(suggestion.mutant_id)) continue;
      yield {
        id: upper(killed),
        own: false,
        aliases: [upper(killed)],
        outcome,
      };
    }
  }
  for (const entry of report.indistinguishable) {
    yield own(entry.mutant_id, entry.display_id, {
      kind: "indistinguishable",
      cases: entry.cases,
    });
  }
  for (const entry of report.nondeterministic) {
    yield own(entry.mutant_id, entry.display_id, {
      kind: "nondeterministic",
      reason: entry.reason,
    });
  }
  for (const entry of report.unsupported) {
    yield own(entry.mutant_id, entry.display_id, {
      kind: "unsupported",
      reason: entry.reason,
    });
  }
}

/** A mutant under its own entry, findable by its id and its display id. */
function own(
  mutantId: string,
  displayId: string,
  outcome: MutantOutcome,
): Candidate {
  const aliases = [upper(mutantId)];
  if (typeof displayId === "string" && displayId !== "") {
    aliases.push(upper(displayId));
  }
  return { id: upper(mutantId), own: true, aliases, outcome };
}

/** Hex ids are compared without regard to case, as the CLI compares them. */
function upper(value: unknown): string {
  return typeof value === "string" ? value.toUpperCase() : "";
}

/** A JSON value as it should read inside a sentence about the schema. */
function format(value: unknown): string {
  return value === undefined ? "nothing at all" : JSON.stringify(value);
}
