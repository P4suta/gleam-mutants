// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The quick fix: one surviving mutant, one `suggest` run scoped to it, and
// — when there is a test to be had — one `apply` that writes it and an
// editor that opens on it.
//
// Every branch ends in something the user has been told. The result it
// returns says which branch it was, for a caller that wants to know and for
// the tests that pin all six.

import { parseApplyOutput, summariseApply } from "../core/apply";
import type { ApplyPlan } from "../core/apply";
import { outcomeForMutant, parseSuggestOutput } from "../core/suggest";
import type { MutantOutcome, Suggestion } from "../core/suggest";
import type { Host } from "../vscode/host";

import { invoke, readJson, reasonOf, report } from "./invoke";
import { displayPrefix } from "./report";

export interface QuickFixRequest {
  // The source file the mutant lives in, workspace-relative.
  readonly file: string;
  // The full id the diagnostic carries, or any unambiguous prefix of it.
  readonly mutantId: string;
}

/**
 * What became of one quick fix.
 *
 * The first five kinds are the five things a `suggest` run can say about a
 * mutant; `failed` is the tool itself giving up, and is the only kind that
 * carries a message the user has already been shown.
 */
export type QuickFixResult =
  | {
    readonly kind: "applied";
    readonly suggestion: Suggestion;
    readonly file: string;
    readonly summary: string;
  }
  | { readonly kind: "indistinguishable"; readonly cases: number }
  | { readonly kind: "nondeterministic"; readonly reason: string }
  | { readonly kind: "unsupported"; readonly reason: string }
  | { readonly kind: "absent" }
  | { readonly kind: "failed"; readonly message: string };

/**
 * Suggests a test for one mutant and, when there is one, writes it.
 *
 * @param host - The editor.
 * @param request - The file and the mutant a diagnostic named.
 * @returns What the run made of the mutant. Every outcome has already been
 * reported to the user by the time this resolves.
 */
export async function generateTest(
  host: Host,
  request: QuickFixRequest,
): Promise<QuickFixResult> {
  const { file, mutantId } = request;

  const invoked = await invoke(
    host,
    "suggest",
    { include: file, mutant: mutantId, json: true },
    "suggest",
  );
  if (invoked.kind === "failed") return invoked;

  const read = await readJson(host, "suggest", invoked.result, parseSuggestOutput);
  if (read.kind === "failed") return read;

  let outcome: MutantOutcome;
  try {
    outcome = outcomeForMutant(read.value, mutantId);
  } catch (error) {
    return await report(host, `Could not look up that mutant: ${reasonOf(error)}`);
  }

  return await announce(host, file, mutantId, outcome);
}

/**
 * Writes one already-chosen suggestion, and opens what it wrote.
 *
 * Shared by the quick fix and by the file-wide pick, which differ only in
 * how the suggestion was chosen.
 *
 * @param host - The editor.
 * @param file - The source file, for the `--include` the write is scoped to.
 * @param suggestion - The suggestion to apply.
 * @returns `applied`, or `failed` with the message the user was shown.
 */
export async function applySuggestion(
  host: Host,
  file: string,
  suggestion: Suggestion,
): Promise<QuickFixResult> {
  const invoked = await invoke(
    host,
    "apply",
    { include: file, mutant: suggestion.mutant_id, json: true, yes: true },
    "apply",
  );
  if (invoked.kind === "failed") return invoked;

  const read = await readJson(host, "apply", invoked.result, parseApplyOutput);
  if (read.kind === "failed") return read;

  const written = planFor(read.value.plans, suggestion.test_name);
  if (written !== undefined) {
    await host.openFile(written.file, { reveal: suggestion.test_name });
  }

  const summary = summariseApply(read.value);
  await host.info(summary);

  return {
    kind: "applied",
    suggestion,
    file: written?.file ?? "",
    summary,
  };
}

/** Tells the user what the run made of their mutant, and acts on it. */
async function announce(
  host: Host,
  file: string,
  mutantId: string,
  outcome: MutantOutcome,
): Promise<QuickFixResult> {
  const named = displayPrefix(mutantId);

  switch (outcome.kind) {
    case "suggestion":
      return await applySuggestion(host, file, outcome.suggestion);

    case "indistinguishable":
      await host.info(
        `Mutant ${named} is probably equivalent: no input told it apart ` +
          `from the original in ${outcome.cases} cases`,
      );
      return { kind: "indistinguishable", cases: outcome.cases };

    case "nondeterministic":
      await host.warn(
        `No test can be written for mutant ${named}: ${outcome.reason}`,
      );
      return { kind: "nondeterministic", reason: outcome.reason };

    case "unsupported":
      await host.warn(
        `No test can be written for mutant ${named}: ${outcome.reason}`,
      );
      return { kind: "unsupported", reason: outcome.reason };

    default:
      await host.warn(
        `The suggest run had nothing to say about mutant ${named}: it may ` +
          "have been killed since the report was written",
      );
      return { kind: "absent" };
  }
}

/**
 * The plan that wrote the test, or the only plan there was.
 *
 * `apply` writes one module per source module, so a run scoped to one
 * mutant plans exactly one file; the search is what keeps that an
 * observation rather than an assumption.
 */
function planFor(
  plans: readonly ApplyPlan[],
  testName: string,
): ApplyPlan | undefined {
  const written = plans.find((plan) => plan.tests_added.includes(testName));
  return written ?? plans[0];
}
