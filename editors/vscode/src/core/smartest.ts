// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/** Evidence states emitted by the stable `smartest findings` line protocol. */
export type EvidenceState =
  | "provisional"
  | "trusted"
  | "unjudged"
  | "stale"
  | "unsafe"
  | "unsupported"
  | "rejected";

export interface Finding {
  readonly id: string;
  readonly state: EvidenceState;
  readonly testId: string;
}

const STATES = new Set<EvidenceState>([
  "provisional",
  "trusted",
  "unjudged",
  "stale",
  "unsafe",
  "unsupported",
  "rejected",
]);

/** Parses `id state package/module/function` records from `smartest findings`. */
export function parseFindings(text: string): Finding[] {
  const trimmed = text.trim();
  if (trimmed === "" || trimmed === "No findings.") return [];

  return trimmed.split(/\r?\n/).map((line, index) => {
    const fields = line.trim().split(/\s+/);
    if (fields.length !== 3) {
      throw new Error(`Smartest finding line ${index + 1} has ${fields.length} fields`);
    }
    const [id, state, testId] = fields;
    if (id === undefined || testId === undefined || id === "" || testId === "") {
      throw new Error(`Smartest finding line ${index + 1} is incomplete`);
    }
    if (!STATES.has(state as EvidenceState)) {
      throw new Error(`Smartest finding line ${index + 1} has unknown evidence state ${state}`);
    }
    return { id, state: state as EvidenceState, testId };
  });
}
