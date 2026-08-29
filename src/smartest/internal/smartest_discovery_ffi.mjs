// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import { Metadata, metadata } from "./plan.mjs";
import { with_test_context } from "./smartest_runtime_ffi.mjs";
import { toList } from "../../gleam.mjs";
import * as evidence from "../evidence.mjs";
import * as runner from "../runner.mjs";
import * as storage from "../storage.mjs";
import * as evidenceReport from "../report.mjs";

async function readDirectory(directory) {
  if (globalThis.Deno) {
    const names = [];
    for await (const entry of Deno.readDir(directory)) names.push(entry.name);
    return names.sort();
  }
  const { readdir } = await import("node:fs/promises");
  return (await readdir(directory)).sort();
}

async function* gleamFiles(directory) {
  for (const entry of await readDirectory(directory)) {
    const candidate = `${directory}/${entry}`;
    if (candidate.endsWith(".gleam")) {
      yield candidate;
      continue;
    }
    try {
      yield* gleamFiles(candidate);
    } catch (_) {
      // A non-directory entry is not a Gleam test module.
    }
  }
}

async function readText(path) {
  if (globalThis.Deno) return Deno.readTextFile(path);
  const { readFile } = await import("node:fs/promises");
  return String(await readFile(path));
}

async function packageName() {
  const source = await readText("gleam.toml");
  return source.match(/^\s*name\s*=\s*"([a-z][a-z0-9_]*)"/m)?.[1]
    ?? "unknown-package";
}

function selected(moduleName, functionName, filter) {
  return !filter || `${moduleName}/${functionName}`.includes(filter);
}

function environment(name) {
  try {
    if (globalThis.Deno) return Deno.env.get(name) ?? "";
  } catch (_) {
    return "";
  }
  return globalThis.process?.env?.[name] ?? "";
}

function print(value) {
  if (globalThis.Deno) Deno.stdout.writeSync(new TextEncoder().encode(value));
  else globalThis.process.stdout.write(value);
}

function finish(code) {
  if (globalThis.Deno) Deno.exit(code);
  globalThis.process.exit(code);
}

const impactSymbol = Symbol.for("gleam-mutants.test-impact");

function runtimeName() {
  return environment("GLEAM_MUTANTS_RUNTIME")
    || (globalThis.Deno ? "deno" : globalThis.Bun ? "bun" : "node");
}

async function validProtocolPath(candidate) {
  const path = await import("node:path");
  const absolute = path.resolve(candidate);
  const base = path.resolve(".gleam_mutants");
  return absolute.startsWith(`${base}${path.sep}`);
}

async function loadSelection() {
  const file = environment("GLEAM_MUTANTS_TEST_SELECTION_FILE");
  if (!file) return null;
  if (!(await validProtocolPath(file))) {
    throw new Error("selection file must be below .gleam_mutants");
  }
  const value = JSON.parse(await readText(file));
  if (value?.schema_version !== 1
    || value?.runner !== "smartest"
    || value?.runtime !== runtimeName()
    || !Array.isArray(value?.selectors)
    || !value.selectors.every(selector => typeof selector === "string")
    || new Set(value.selectors).size !== value.selectors.length) {
    throw new Error("invalid or incompatible test selection file");
  }
  return value.selectors;
}

function rootTestId(package_, moduleName, functionName) {
  return evidence.test_id_to_string(
    evidence.test_id(package_, moduleName, functionName),
  );
}

function selectedExport(root, selectors) {
  return selectors === null
    || selectors.some(selector => selector === root || selector.startsWith(`${root}/`));
}

async function atomicWrite(target, source) {
  if (!(await validProtocolPath(target))) {
    throw new Error("impact file must be below .gleam_mutants");
  }
  const temporary = `${target}.tmp-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const path = await import("node:path");
  try {
    if (globalThis.Deno) {
      await Deno.mkdir(path.dirname(target), { recursive: true });
      await Deno.writeTextFile(temporary, source);
      await Deno.rename(temporary, target);
      return;
    }
    const fs = await import("node:fs/promises");
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(temporary, source, "utf8");
    await fs.rename(temporary, target);
  } catch (error) {
    try {
      if (globalThis.Deno) await Deno.remove(temporary);
      else await (await import("node:fs/promises")).unlink(temporary);
    } catch (_) {
      // Preserve the atomic-write failure; cleanup is best effort.
    }
    throw error;
  }
}

async function writeImpact(descriptors, complete) {
  const target = environment("GLEAM_MUTANTS_TEST_IMPACT_FILE");
  if (!target) return;
  const impacts = globalThis[impactSymbol] instanceof Map
    ? globalThis[impactSymbol]
    : new Map();
  const reaches = descriptors.map(descriptor => ({
    test_id: descriptor.test_id,
    mutant_ids: [...(impacts.get(descriptor.test_id) ?? new Set())].sort(),
  }));
  await atomicWrite(target, JSON.stringify({
    schema_version: 1,
    runner: "smartest",
    runtime: runtimeName(),
    complete,
    tests: descriptors,
    reaches,
  }));
}

export async function main() {
  const protocolEnabled = Boolean(
    environment("GLEAM_MUTANTS_TEST_IMPACT_FILE")
      || environment("GLEAM_MUTANTS_TEST_SELECTION_FILE"),
  );
  if (protocolEnabled) delete globalThis[impactSymbol];
  let selectors;
  try {
    selectors = await loadSelection();
  } catch (error) {
    print(`FAIL test selection protocol\n${String(error?.message ?? error)}\n`);
    finish(2);
    return;
  }
  const package_ = await packageName();
  const filter = environment("SMARTEST_FILTER");
  let passed = 0;
  let failed = 0;
  let bindings = [];
  let manifestComplete = true;
  const results = [];
  const descriptors = [];
  const matchedSelectors = new Set();

  for await (const path of gleamFiles("test")) {
    const moduleName = path.slice("test/".length, -".gleam".length);
    const moduleUrl = new URL(`../../${moduleName}.mjs`, import.meta.url);
    const module = await import(moduleUrl.href);
    for (const functionName of Object.keys(module).sort()) {
      if (!functionName.endsWith("_test")) continue;
      if (!selected(moduleName, functionName, filter)) continue;
      const root = rootTestId(package_, moduleName, functionName);
      if (!selectedExport(root, selectors)) continue;
      try {
        const value = await with_test_context(root, () => module[functionName]());
        if (value !== undefined && value !== null && metadata(value) instanceof Metadata) {
          const entry = runner.entry(package_, moduleName, functionName, value);
          const ids = protocolEnabled
            ? Array.from(runner.test_ids(entry), evidence.test_id_to_string)
            : [];
          if (protocolEnabled) {
            descriptors.push(...ids.map(id => ({
              selector: id, test_id: id, kind: "smartest-leaf",
            })));
          }
          bindings.push(...runner.generator_bindings(entry));
          const replayId = environment("SMARTEST_REPLAY_ID");
          const options = replayId
            ? runner.replay_options(".", replayId, Date.now())
            : runner.workspace_options(".", Date.now());
          const matching = selectors === null
            ? ids
            : ids.filter(id => selectors.includes(id));
          for (const id of matching) matchedSelectors.add(id);
          const runResults = selectors === null
            ? runner.run_entry(entry, options)
            : runner.run_entry_selected(entry, options, toList(matching));
          for (const result of runResults) {
            results.push(result);
            if (runner.succeeded(result)) {
              print(".");
              passed += 1;
            } else {
              print(`\n${runner.render_result(result)}`);
              failed += 1;
            }
          }
        } else {
          if (protocolEnabled) {
            descriptors.push({
              selector: root, test_id: root, kind: "legacy-export",
            });
            matchedSelectors.add(root);
          }
          print(".");
          passed += 1;
          results.push(runner.legacy_result(
            package_, moduleName, functionName, true, "opaque legacy test",
          ));
        }
      } catch (error) {
        if (protocolEnabled) {
          descriptors.push({
            selector: root, test_id: root, kind: "legacy-export",
          });
          matchedSelectors.add(root);
        }
        const message = String(error?.stack ?? error);
        print(`\nFAIL ${moduleName}/${functionName}\n${message}\n`);
        failed += 1;
        manifestComplete = false;
        results.push(runner.legacy_result(
          package_, moduleName, functionName, false, message,
        ));
      }
    }
  }
  if (selectors !== null) {
    const unknown = selectors.filter(selector => !matchedSelectors.has(selector));
    if (unknown.length > 0) {
      print(`\nFAIL unknown test selector\n${JSON.stringify(unknown)}\n`);
      failed += 1;
    }
  }
  const reportResult = evidenceReport.write(".", new runner.Report(toList(results)));
  if (!reportResult.isOk()) {
    print(`\nFAIL evidence report\n${reportResult[0]}\n`);
    failed += 1;
  }
  if (selectors === null && !filter && manifestComplete) {
    const stored = storage.write_generator_manifest(".", toList(bindings));
    if (!stored.isOk()) {
      print(`\nFAIL generator manifest\n${stored[0]}\n`);
      failed += 1;
    }
  } else if (selectors === null && !filter && !manifestComplete) {
    print("\nGenerator manifest was not replaced because discovery was incomplete.\n");
  }
  try {
    await writeImpact(
      descriptors,
      // A filter belongs to this invocation's configured suite. Full-suite
      // confirmations run with the same environment and therefore the same
      // filter.
      manifestComplete && selectors === null,
    );
  } catch (error) {
    print(`\nFAIL test impact manifest\n${String(error?.message ?? error)}\n`);
    failed += 1;
  }
  print(`\n${passed} passed, ${failed} failed\n`);
  finish(failed === 0 ? 0 : 1);
}
