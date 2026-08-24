// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = process.cwd();
const workspace = path.resolve(root, "fixtures", "basic_project");
const normalized = process.platform === "win32"
  ? workspace.replaceAll("\\", "/").toLowerCase()
  : workspace.replaceAll("\\", "/");
const workspaceId = crypto.createHash("sha256").update(normalized).digest("hex").toUpperCase();
const cacheRoot = process.platform === "win32"
  ? process.env.LOCALAPPDATA
  : process.platform === "darwin"
    ? path.join(os.homedir(), "Library", "Caches")
    : process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache");
const lockPath = path.join(cacheRoot, "gleam-mutants", "v1", "workspaces", workspaceId, "run.lock");
const command = mode => ["run", "-m", "workspace_lock_smoke", "--target", "erlang", "--", mode, workspace];

const holder = childProcess.spawn("gleam", command("hold"), {
  cwd: root,
  stdio: "inherit",
  windowsHide: true,
});

const deadline = Date.now() + 15_000;
while (!fs.existsSync(lockPath) && Date.now() < deadline) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
}
if (!fs.existsSync(lockPath)) {
  holder.kill();
  throw new Error("holder did not acquire workspace lock");
}

const contender = childProcess.spawnSync("gleam", command("contend"), {
  cwd: root,
  stdio: "inherit",
  windowsHide: true,
});
if (contender.error) throw contender.error;
if (contender.status !== 0) throw new Error("workspace lock contender smoke failed");

const holderStatus = await new Promise((resolve, reject) => {
  holder.once("error", reject);
  holder.once("exit", resolve);
});
if (holderStatus !== 0) throw new Error("workspace lock holder smoke failed");
if (fs.existsSync(lockPath)) throw new Error("workspace lock was not released");
console.log("workspace lock rejects concurrent runs within three seconds and releases cleanly");
