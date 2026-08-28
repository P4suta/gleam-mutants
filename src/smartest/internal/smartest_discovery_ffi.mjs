// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import { Metadata, metadata } from "./plan.mjs";
import { toList } from "../../gleam.mjs";
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

export async function main() {
  const package_ = await packageName();
  const filter = environment("SMARTEST_FILTER");
  let passed = 0;
  let failed = 0;
  let bindings = [];
  let manifestComplete = true;
  const results = [];

  for await (const path of gleamFiles("test")) {
    const moduleName = path.slice("test/".length, -".gleam".length);
    const moduleUrl = new URL(`../../${moduleName}.mjs`, import.meta.url);
    const module = await import(moduleUrl.href);
    for (const functionName of Object.keys(module).sort()) {
      if (!functionName.endsWith("_test")) continue;
      if (!selected(moduleName, functionName, filter)) continue;
      try {
        const value = await module[functionName]();
        if (value !== undefined && value !== null && metadata(value) instanceof Metadata) {
          const entry = runner.entry(package_, moduleName, functionName, value);
          bindings.push(...runner.generator_bindings(entry));
          const replayId = environment("SMARTEST_REPLAY_ID");
          const options = replayId
            ? runner.replay_options(".", replayId, Date.now())
            : runner.workspace_options(".", Date.now());
          for (const result of runner.run_entry(entry, options)) {
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
          print(".");
          passed += 1;
          results.push(runner.legacy_result(
            package_, moduleName, functionName, true, "opaque legacy test",
          ));
        }
      } catch (error) {
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
  const reportResult = evidenceReport.write(".", new runner.Report(toList(results)));
  if (!reportResult.isOk()) {
    print(`\nFAIL evidence report\n${reportResult[0]}\n`);
    failed += 1;
  }
  if (!filter && manifestComplete) {
    const stored = storage.write_generator_manifest(".", toList(bindings));
    if (!stored.isOk()) {
      print(`\nFAIL generator manifest\n${stored[0]}\n`);
      failed += 1;
    }
  } else if (!filter && !manifestComplete) {
    print("\nGenerator manifest was not replaced because discovery was incomplete.\n");
  }
  print(`\n${passed} passed, ${failed} failed\n`);
  finish(failed === 0 ? 0 : 1);
}
