// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The one test here that does not fake anything.
//
// Everything else in this package runs against captured CLI output: the
// parsers are pinned to `fixtures/`, and the flows are pinned to a `Host`
// that never starts a process. That leaves one question open — is this
// still what the CLI prints? — and this script is the answer to it.
//
// It mutation-tests `fixtures/boundary_project` with the real engine on the
// Erlang target, reads the report with the built core, and asks the real
// `suggest` for a test that kills the first mutant that survived. What it
// creates under the fixture it removes again.
//
// Run it from anywhere; the CLI is always run from the repository root:
//
//     npm run build && npm run smoke

import { spawn } from "node:child_process";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// The built core, not the sources: what this proves is that the parsers the
// extension ships still read what the CLI still prints.
const core = await load();

const { buildArgs, runCli } = core.cli;
const { parseMutationReport, survivingMutants } = core.stryker;
const { outcomeForMutant, parseSuggestOutput } = core.suggest;

/** Imports `dist/core`, or says which command writes it. */
async function load() {
  try {
    const [cli, stryker, suggest] = await Promise.all([
      import("../dist/core/cli.mjs"),
      import("../dist/core/stryker.mjs"),
      import("../dist/core/suggest.mjs"),
    ]);
    return { cli, stryker, suggest };
  } catch (error) {
    process.stderr.write(
      "smoke: the built core is not there. Run `npm run build` first.\n" +
        `smoke: ${error instanceof Error ? error.message : String(error)}\n`,
    );
    process.exit(1);
  }
}

const REPO = fileURLToPath(new URL("../../../", import.meta.url));
const WORKSPACE = join(REPO, "fixtures", "boundary_project");
const REPORTS = join(WORKSPACE, "reports");
const REPORT = join(REPORTS, "mutation", "mutation.json");

// The workspace this runs on is tiny, but the engine still compiles a
// snapshot per mutant on a cold cache.
const BUDGET_MS = 900_000;

const SOURCE = "src/boundary.gleam";

// What a generated test for this fixture asserts on. The module is
// `boundary`, so every test it writes calls into it by that qualifier.
const ASSERTION = "assert boundary.";

// `gleam run` rather than the packaged binary: the repository is the
// workspace that defines the CLI, and this way the smoke tests the tree it
// is run from.
const COMMAND = ["gleam", "run", "--target", "erlang", "-m", "gleam_mutants", "--"];

/** Spawns the configured command, as `runCli` wants it spawned. */
function spawnCli(args, options) {
  return spawn(COMMAND[0], args, { cwd: options.cwd, windowsHide: true });
}

/** Runs one subcommand of the real CLI from the repository root. */
async function cli(subcommand, options) {
  const args = buildArgs(COMMAND, subcommand, { root: WORKSPACE, ...options });
  say(`$ ${[COMMAND[0], ...args].join(" ")}`);
  return await runCli(spawnCli, args, { cwd: REPO, timeoutMs: BUDGET_MS });
}

/** One line of progress, on stderr, where it cannot be mistaken for output. */
function say(line) {
  process.stderr.write(`smoke: ${line}\n`);
}

/** Fails the smoke, loudly, with what was expected. */
function check(condition, message) {
  if (condition) return;
  throw new Error(message);
}

/** Both streams of a run that went wrong, cut short. */
function streams(result) {
  return `exit ${result.code}${result.timedOut ? " (timed out)" : ""}\n` +
    `stdout: ${result.stdout.slice(0, 800)}\n` +
    `stderr: ${result.stderr.slice(0, 800)}`;
}

// Only what this run creates is removed again: a report that was already
// there is somebody's, and is reused rather than rewritten.
let created = false;

async function main() {
  created = !existsSync(REPORTS);

  if (existsSync(REPORT)) {
    say(`reusing the report already at ${REPORT}`);
  } else {
    say("mutation-testing fixtures/boundary_project with the real engine");
    const run = await cli("run", {});
    // `run` exits 1 when a mutant survives, which is the whole point here.
    check(
      run.code === 0 || run.code === 1,
      `\`run\` did not finish: ${streams(run)}`,
    );
    check(existsSync(REPORT), `\`run\` wrote no report at ${REPORT}`);
  }

  const report = parseMutationReport(readFileSync(REPORT, "utf8"));
  const survivors = survivingMutants(report).filter(
    (site) => site.file === SOURCE,
  );
  check(
    survivors.length > 0,
    `the report names no surviving mutant in ${SOURCE}; ` +
      `it holds ${Object.keys(report.files).join(", ")}`,
  );
  const target = survivors[0];
  say(
    `${survivors.length} surviving mutant(s) in ${SOURCE}; ` +
      `suggesting a test for ${target.id.slice(0, 8)} (${target.operator})`,
  );

  const suggest = await cli("suggest", { mutant: target.id, json: true });
  check(suggest.code === 0, `\`suggest\` failed: ${streams(suggest)}`);

  const suggested = parseSuggestOutput(suggest.stdout);
  const outcome = outcomeForMutant(suggested, target.id);
  check(
    outcome.kind === "suggestion",
    `suggest called ${target.id.slice(0, 8)} ${outcome.kind}, not a suggestion`,
  );
  check(
    outcome.suggestion.test_source.includes(ASSERTION),
    "the suggested test does not call the module it tests:\n" +
      outcome.suggestion.test_source,
  );

  say(
    `suggest wrote \`${outcome.suggestion.test_name}\`, which asserts on ` +
      `${outcome.suggestion.function}`,
  );
}

try {
  await main();
  say("ok");
} catch (error) {
  say(`FAILED: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
} finally {
  // Whether it passed or failed, the fixture is left as it was found.
  if (created) {
    rmSync(REPORTS, { recursive: true, force: true });
    say(`removed ${REPORTS}`);
  }
}
