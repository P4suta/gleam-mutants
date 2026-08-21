// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";

const durationSeconds = Number(process.env.GLEAM_MUTANTS_FUZZ_SECONDS || 900);
const deadline = Date.now() + durationSeconds * 1000;
let seed = 1;
let batches = 0;
while (Date.now() < deadline) {
  const result = childProcess.spawnSync(
    "gleam",
    ["run", "-m", "property_smoke", "--target", "erlang", "--", "100000", String(seed)],
    { stdio: "inherit", shell: false },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`property fuzz failed at seed ${seed}`);
  seed = (seed * 48271) % 2147483647;
  batches += 1;
}
console.log(`property fuzz completed ${batches} batches in ${durationSeconds}s`);
