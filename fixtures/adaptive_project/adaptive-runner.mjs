// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import fs from "node:fs";
import path from "node:path";

const active = process.env.GLEAM_MUTANTS_ACTIVE ?? "";
const impactFile = process.env.GLEAM_MUTANTS_TEST_IMPACT_FILE ?? "";
const selectionFile = process.env.GLEAM_MUTANTS_TEST_SELECTION_FILE ?? "";
const runtime = process.env.GLEAM_MUTANTS_RUNTIME ?? "erlang";
const forcedFull = process.argv.includes("full");
const counterIndex = process.argv.indexOf("counter");
const source = fs.readFileSync("src/classifier.gleam", "utf8");
const ids = [...new Set(source.match(/[A-F0-9]{64}/g) ?? [])].sort();
const selectors = [
  "narrow-kill",
  "confirm-with-full",
  "baseline-fails",
  "confirm-error",
  "confirm-timeout",
];

if (counterIndex >= 0) {
  fs.appendFileSync(
    process.argv[counterIndex + 1],
    `${runtime}:${active ? "mutant" : impactFile ? "impact" : selectionFile ? "partial-baseline" : "baseline"}\n`,
  );
}

if (forcedFull && (impactFile || selectionFile)) {
  process.stderr.write("full mode unexpectedly started the impact protocol\n");
  process.exit(2);
}

if (impactFile) {
  if (ids.length !== selectors.length) {
    process.stderr.write(`expected five instrumented mutants, found ${ids.length}\n`);
    process.exit(2);
  }
  const manifest = {
    schema_version: 1,
    runner: "adaptive-fixture",
    runtime,
    complete: true,
    tests: selectors.map(selector => ({
      selector,
      test_id: selector,
      kind: "fixture",
    })),
    reaches: selectors.map((selector, index) => ({
      test_id: selector,
      mutant_ids: [ids[index]],
    })),
  };
  fs.mkdirSync(path.dirname(impactFile), { recursive: true });
  const temporary = `${impactFile}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, JSON.stringify(manifest));
  fs.renameSync(temporary, impactFile);
}

let selected = [];
if (selectionFile) {
  selected = JSON.parse(fs.readFileSync(selectionFile, "utf8")).selectors;
}

if (!active) {
  process.exit(selected.includes("baseline-fails") ? 1 : 0);
}

if (!selectionFile) {
  // Every fixture mutant is killed by the configured full suite.
  process.exit(1);
}

if (selected.includes("narrow-kill")) process.exit(1);
if (selected.includes("confirm-with-full")) process.exit(0);
if (selected.includes("confirm-error")) process.exit(2);
if (selected.includes("confirm-timeout")) {
  setTimeout(() => process.exit(0), 2000);
} else {
  process.exit(2);
}
