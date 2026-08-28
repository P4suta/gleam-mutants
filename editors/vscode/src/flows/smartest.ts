// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Smartest's evidence inbox as three editor flows: inspect, review, replay.
// The line protocol and every decision remain testable without VS Code; only
// the Host decides how a picker, input box, process, or terminal is realised.

import { buildArgs } from "../core/cli";
import { parseFindings } from "../core/smartest";
import type { EvidenceState, Finding } from "../core/smartest";
import type { Host, HostQuickPickItem } from "../vscode/host";

import { invokeCommand, reasonOf, report } from "./invoke";

const ACCEPT = "Accept";
const REJECT = "Reject";

const REVIEWABLE = new Set<EvidenceState>([
  "provisional",
  "unjudged",
  "stale",
  "unsafe",
  "unsupported",
]);

interface FindingItem extends HostQuickPickItem {
  readonly finding: Finding;
}

/** Lists the evidence ledger and explains the finding the user chooses. */
export async function smartestFindings(host: Host): Promise<void> {
  const finding = await pickFinding(host, undefined, () => true, "Which Smartest finding?");
  if (finding === undefined) return;
  await explainFinding(host, finding.id);
}

/** Reviews one inbox finding without granting trust implicitly. */
export async function smartestReview(
  host: Host,
  findingId?: string,
): Promise<void> {
  const finding = await pickFinding(
    host,
    findingId,
    (candidate) => REVIEWABLE.has(candidate.state),
    "Which Smartest finding should be reviewed?",
  );
  if (finding === undefined) return;

  if (!(await explainFinding(host, finding.id))) return;

  const decision = await host.info(
    `Review ${finding.testId} (${finding.state})`,
    ACCEPT,
    REJECT,
  );
  if (decision !== ACCEPT && decision !== REJECT) return;

  const note = await host.input({
    prompt: decision === ACCEPT
      ? "Review note required to accept this evidence"
      : "Reason required to reject this evidence",
    placeHolder: decision === ACCEPT
      ? "What independent contract or behaviour did you check?"
      : "Why should this finding not enter the corpus?",
  });
  if (note === undefined) return;
  const reviewed = note.trim();
  if (reviewed === "") {
    await host.warn(
      decision === ACCEPT
        ? "Smartest requires a non-empty review note before accepting evidence"
        : "Smartest requires a non-empty reason before rejecting evidence",
    );
    return;
  }

  if (decision === REJECT) {
    await finishReview(
      host,
      ["reject", finding.id],
      ["--reason", reviewed],
      "reject",
    );
    return;
  }

  const flags = ["--review", reviewed];
  if (finding.state === "unjudged") {
    const oracle = await host.input({
      prompt: "Independent oracle (optional; empty keeps this evidence unjudged)",
      placeHolder: "Specification, reference implementation, or reviewed rule",
    });
    if (oracle === undefined) return;
    if (oracle.trim() !== "") flags.push("--oracle", oracle.trim());
  }
  await finishReview(host, ["accept", finding.id], flags, "accept");
}

/** Replays one accepted or inbox witness in a foreground terminal. */
export async function smartestReplay(
  host: Host,
  findingId?: string,
): Promise<void> {
  const finding = await pickFinding(
    host,
    findingId,
    (candidate) => candidate.state !== "rejected",
    "Which Smartest witness should be replayed?",
  );
  if (finding === undefined) return;

  const command = host.settings().smartestCommand;
  let args: string[];
  try {
    args = buildArgs(command, ["replay", finding.id], { root: host.root });
  } catch (error) {
    await report(host, `Could not run \`Smartest replay\`: ${reasonOf(error)}`);
    return;
  }
  host.runInTerminalWith(
    `Smartest: replay ${finding.id}`,
    command,
    args,
  );
}

async function pickFinding(
  host: Host,
  requested: string | undefined,
  eligible: (finding: Finding) => boolean,
  placeHolder: string,
): Promise<Finding | undefined> {
  const findings = await loadFindings(host);
  if (findings === undefined) return undefined;

  const offered = findings.filter(eligible);
  if (requested !== undefined) {
    const found = offered.find((finding) => finding.id === requested);
    if (found !== undefined) return found;
    await host.warn(`Smartest finding ${requested} is not available for this action`);
    return undefined;
  }

  if (offered.length === 0) {
    await host.info("No Smartest findings are available for this action");
    return undefined;
  }

  const chosen = await host.pick<FindingItem>(
    offered.map((finding) => ({
      label: finding.testId,
      description: finding.state,
      detail: finding.id,
      finding,
    })),
    { placeHolder },
  );
  return chosen?.finding;
}

async function loadFindings(host: Host): Promise<Finding[] | undefined> {
  const command = host.settings().smartestCommand;
  const invoked = await invokeCommand(host, command, "findings", {}, "Smartest findings");
  if (invoked.kind === "failed") return undefined;

  try {
    return parseFindings(invoked.result.stdout);
  } catch (error) {
    await report(
      host,
      `\`Smartest findings\` printed an invalid evidence ledger: ${reasonOf(error)}`,
    );
    return undefined;
  }
}

async function explainFinding(host: Host, id: string): Promise<boolean> {
  const invoked = await invokeCommand(
    host,
    host.settings().smartestCommand,
    ["explain", id],
    {},
    "Smartest explain",
  );
  if (invoked.kind === "failed") return false;

  for (const line of invoked.result.stdout.trimEnd().split("\n")) {
    if (line !== "") host.log(line);
  }
  host.showOutput();
  return true;
}

async function finishReview(
  host: Host,
  subcommand: readonly string[],
  flags: readonly string[],
  name: string,
): Promise<void> {
  const invoked = await invokeCommand(
    host,
    host.settings().smartestCommand,
    subcommand,
    { extra: flags },
    `Smartest ${name}`,
  );
  if (invoked.kind === "failed") return;
  const message = invoked.result.stdout.trim();
  await host.info(message === "" ? `Smartest ${name} completed` : message);
}
