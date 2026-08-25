// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The four commands a user can invoke, the one the code action keeps to
// itself, and the table `extension.ts` registers them all from.
//
// A command handler is given whatever VS Code passes it, which is nothing
// at all from the palette: every one of them falls back to the file the
// editor is showing, and says so rather than guessing when there is none.

import { buildArgs } from "../core/cli";
import type { MutantSite } from "../core/stryker";
import { parseSuggestOutput } from "../core/suggest";
import type { Suggestion } from "../core/suggest";
import type { Host, HostQuickPickItem } from "../vscode/host";

import { refreshDiagnostics, summariseRefresh } from "./diagnostics";
import { invoke, readJson, reasonOf, report } from "./invoke";
import { applySuggestion, generateTest } from "./quickfix";
import { displayPrefix, loadReport, locationOf } from "./report";

export type CommandHandler = (...args: readonly unknown[]) => Promise<void>;

/** Command id to handler, exactly as `registerCommand` wants them. */
export type CommandTable = Readonly<Record<string, CommandHandler>>;

/** One suggestion, as the list a user chooses from shows it. */
interface SuggestionItem extends HostQuickPickItem {
  readonly suggestion: Suggestion;
}

/** One surviving mutant, as the list a user chooses from shows it. */
interface MutantItem extends HostQuickPickItem {
  readonly id: string;
}

/**
 * Every command this extension registers, by id.
 *
 * The table is the wiring: `extension.ts` walks it rather than naming
 * commands itself, so a command that is contributed and not handled is a
 * failing test rather than an error a user finds.
 *
 * @param host - The editor the handlers act on.
 * @returns The handlers, keyed by the id they are registered under.
 */
export function commandTable(host: Host): CommandTable {
  return {
    "gleam_mutants.refreshDiagnostics": async () => {
      await host.info(summariseRefresh(await refreshDiagnostics(host)));
    },
    "gleam_mutants.runFile": async (file) => {
      await runFile(host, asText(file));
    },
    "gleam_mutants.suggestFile": async (file) => {
      await suggestFile(host, asText(file));
    },
    "gleam_mutants.explainMutant": async (mutantId) => {
      await explainMutant(host, asText(mutantId));
    },
    // Not contributed: the quick fix is the only caller that has a mutant
    // id to give it.
    "gleam_mutants.generateTest": async (file, mutantId) => {
      const target = asText(file) ?? host.activeFile() ?? "";
      const id = asText(mutantId);
      if (target === "" || id === undefined) {
        host.log(
          "gleam_mutants: the quick fix needs both a file and a mutant id",
        );
        return;
      }
      await generateTest(host, { file: target, mutantId: id });
    },
  };
}

/**
 * Mutation-tests one file, in a terminal the user can watch.
 *
 * A `run` is minutes rather than seconds and prints as it goes, so it is
 * the one command that is not run behind the user's back. The report it
 * writes is picked up by the watcher, which republishes the diagnostics.
 *
 * @param host - The editor.
 * @param file - The file, or nothing to use the active editor's.
 */
export async function runFile(host: Host, file?: string): Promise<void> {
  const target = await targetFile(host, file);
  if (target === null) return;

  const settings = host.settings();
  let args: string[];
  try {
    args = buildArgs(settings.command, "run", {
      root: host.root,
      include: target,
    });
  } catch (error) {
    await report(host, `Could not run \`run\`: ${reasonOf(error)}`);
    return;
  }

  host.runInTerminal("gleam_mutants: run", args);
}

/**
 * Offers every test one file's survivors could be killed by, and writes the
 * one that is picked.
 *
 * @param host - The editor.
 * @param file - The file, or nothing to use the active editor's.
 */
export async function suggestFile(host: Host, file?: string): Promise<void> {
  const target = await targetFile(host, file);
  if (target === null) return;

  const invoked = await invoke(
    host,
    "suggest",
    { include: target, json: true },
    "suggest",
  );
  if (invoked.kind === "failed") return;

  const read = await readJson(host, "suggest", invoked.result, parseSuggestOutput);
  if (read.kind === "failed") return;

  const suggestions = read.value.suggestions;
  if (suggestions.length === 0) {
    await host.info(`No tests to suggest for ${target}${why(read.value)}`);
    return;
  }

  const chosen = await host.pick<SuggestionItem>(
    suggestions.map((suggestion) => ({
      label: `${suggestion.function}: kills ${displayPrefix(suggestion.mutant_id)}` +
        ` (${suggestion.operator})`,
      description: suggestion.location,
      detail: suggestion.test_source,
      suggestion,
    })),
    {
      placeHolder: `A test for one of ${suggestions.length} surviving mutants in ${target}`,
      // The generated source is the only part worth reading, so it is the
      // part worth filtering on.
      matchOnDetail: true,
    },
  );
  if (chosen === undefined) return;

  await applySuggestion(host, target, chosen.suggestion);
}

/**
 * Explains one mutant into the output channel.
 *
 * @param host - The editor.
 * @param mutantId - The mutant, or nothing to pick from the survivors of
 * the active file.
 */
export async function explainMutant(
  host: Host,
  mutantId?: string,
): Promise<void> {
  const id = mutantId ?? (await pickSurvivor(host));
  if (id === undefined) return;

  const invoked = await invoke(host, ["explain", id], {}, "explain");
  if (invoked.kind === "failed") return;

  for (const line of invoked.result.stdout.trimEnd().split("\n")) {
    host.log(line);
  }
  host.showOutput();
}

/** The file a command was given, the one on screen, or a complaint. */
async function targetFile(
  host: Host,
  file: string | undefined,
): Promise<string | null> {
  const target = file ?? host.activeFile();
  if (target !== null && target !== undefined && target !== "") return target;

  await host.warn(
    "Open the Gleam file you want mutation-tested: this command works on " +
      "the file in the active editor",
  );
  return null;
}

/** The survivor a user picked out of the last report, if they picked one. */
async function pickSurvivor(host: Host): Promise<string | undefined> {
  const loaded = await loadReport(host);
  if (loaded.kind === "missing") {
    await host.warn(
      `No mutation report at ${loaded.path} yet — run gleam_mutants over ` +
        "this workspace to write one",
    );
    return undefined;
  }
  if (loaded.kind === "unreadable") {
    await host.warn(`Could not read ${loaded.path}: ${loaded.reason}`);
    return undefined;
  }

  const active = host.activeFile();
  const offered = active === null
    ? loaded.survivors
    : loaded.survivors.filter((site) => site.file === active);

  if (offered.length === 0) {
    await host.info(
      active === null
        ? "No surviving mutants in the last report"
        : `No surviving mutants in ${active} in the last report`,
    );
    return undefined;
  }

  const chosen = await host.pick<MutantItem>(
    offered.map((site) => ({
      label: `${displayPrefix(site.id)} (${site.operator})`,
      description: locationOf(site),
      detail: describeSite(site),
      id: site.id,
    })),
    { placeHolder: "Which surviving mutant?" },
  );
  return chosen?.id;
}

/** "`value > 0` -> `value >= 0`", for a list a user reads sideways. */
function describeSite(site: MutantSite): string {
  return `${site.original} -> ${site.replacement}`;
}

/** Why a run that suggested nothing suggested nothing, when it said. */
function why(report: {
  readonly indistinguishable: readonly unknown[];
  readonly unsupported: readonly unknown[];
  readonly nondeterministic: readonly unknown[];
}): string {
  const parts: string[] = [];
  if (report.indistinguishable.length > 0) {
    parts.push(`${report.indistinguishable.length} probably equivalent`);
  }
  if (report.unsupported.length > 0) {
    parts.push(`${report.unsupported.length} unsupported`);
  }
  if (report.nondeterministic.length > 0) {
    parts.push(`${report.nondeterministic.length} nondeterministic`);
  }
  return parts.length === 0 ? "" : `: ${parts.join(", ")}`;
}

/** A command argument that is a path or an id, or nothing at all. */
function asText(value: unknown): string | undefined {
  return typeof value === "string" && value !== "" ? value : undefined;
}
