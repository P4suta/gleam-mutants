// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// `gleam deps download`, retried past a Hex API that is refusing to answer.
//
// Every checked-in `manifest.toml` pins what to fetch, so a warm package cache
// answers this without a network call at all. What is left is the projects
// that cannot be locked ahead of time -- the throwaway consumers `package.mjs`
// generates to install each artifact into -- and a cold cache. Those still
// reach Hex, and Hex rate-limits by address: a hosted runner shares its
// address with everyone else on that host, so a refusal says nothing about
// this repository and waiting a little answers it. Only that refusal is
// retried: a manifest that does not resolve, or a checksum that does not
// match, fails on the first attempt the way it should.

import childProcess from "node:child_process";
import process from "node:process";
import url from "node:url";

const attempts = 8;
const firstDelayMs = 2000;
const longestDelayMs = 60_000;

/** Whether a failed attempt is worth repeating. */
function transient(output) {
  const text = output.toLowerCase();
  return (
    text.includes("rate limit") ||
    text.includes("hex api failure") ||
    text.includes("connection") ||
    text.includes("timed out") ||
    text.includes("timeout") ||
    text.includes("temporary failure") ||
    text.includes("could not connect")
  );
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

export function download(directory, environment = process.env) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const result = childProcess.spawnSync("gleam", ["deps", "download"], {
      cwd: directory,
      env: environment,
      encoding: "utf8",
      shell: false,
      maxBuffer: 8 * 1024 * 1024,
    });
    if (result.error) throw result.error;
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
    process.stdout.write(output);
    if (result.status === 0) return;
    if (attempt === attempts || !transient(output)) {
      throw new Error(`gleam deps download failed in ${directory} with exit ${result.status}`);
    }
    const delay = Math.min(firstDelayMs * 2 ** (attempt - 1), longestDelayMs);
    process.stdout.write(`gleam deps download: Hex would not answer; retrying in ${delay}ms\n`);
    sleep(delay);
  }
}

if (process.argv[1] && import.meta.url === url.pathToFileURL(process.argv[1]).href) {
  const directories = process.argv.slice(2);
  if (directories.length === 0) directories.push(process.cwd());
  for (const directory of directories) download(directory);
}
