// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import crypto from "node:crypto";
import childProcess from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { toList } from "../../gleam.mjs";

export function random_nonce() {
  if (globalThis.crypto?.getRandomValues) {
    const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16));
    return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  }
  return crypto.randomBytes(16).toString("hex");
}

export function arguments$() {
  if (globalThis.Deno?.args) return toList([...globalThis.Deno.args]);
  return toList(globalThis.process?.argv?.slice(2) ?? []);
}

export { arguments$ as arguments };

export function current_directory() {
  try { return globalThis.Deno?.cwd?.() ?? globalThis.process.cwd(); }
  catch (_) { return globalThis.process.cwd(); }
}

export function now_milliseconds() { return Date.now(); }

function watchFiles(root) {
  const files = [];
  const visit = (absolute, relative) => {
    const info = fs.lstatSync(absolute);
    if (info.isSymbolicLink()) {
      files.push([relative, Buffer.from(`symlink:${fs.readlinkSync(absolute)}`)]);
      return;
    }
    if (info.isDirectory()) {
      for (const name of fs.readdirSync(absolute).sort()) {
        visit(path.join(absolute, name), path.posix.join(relative, name));
      }
      return;
    }
    if (info.isFile()) files.push([relative, fs.readFileSync(absolute)]);
  };

  for (const name of ["src", "test"]) {
    const absolute = path.join(root, name);
    if (fs.existsSync(absolute)) visit(absolute, name);
  }
  for (const name of ["gleam.toml", "manifest.toml"]) {
    const absolute = path.join(root, name);
    if (fs.existsSync(absolute)) visit(absolute, name);
  }
  return files.sort(([left], [right]) => left.localeCompare(right));
}

export function workspace_fingerprint(rootValue) {
  try {
    const root = path.resolve(rootValue);
    if (!fs.statSync(root).isDirectory()) {
      return [false, `watch root is not a directory: ${root}`];
    }
    const digest = crypto.createHash("sha256");
    for (const [relative, contents] of watchFiles(root)) {
      const name = Buffer.from(relative, "utf8");
      digest.update(String(name.length)).update(":").update(name);
      digest.update(String(contents.length)).update(":").update(contents);
    }
    return [true, digest.digest("hex")];
  } catch (error) {
    return [false, `could not fingerprint watch workspace: ${error?.message || error}`];
  }
}

function watchEnvironment(name) {
  try {
    if (globalThis.Deno?.env) return globalThis.Deno.env.get(name) ?? "";
  } catch (_) {}
  return globalThis.process?.env?.[name] ?? "";
}

function watchWrite(value, error = false) {
  const text = String(value);
  const bytes = new TextEncoder().encode(text);
  if (globalThis.Deno) {
    (error ? Deno.stderr : Deno.stdout).writeSync(bytes);
  } else {
    fs.writeSync(error ? 2 : 1, text);
  }
}

function watchDescendants(rootPid) {
  if (globalThis.process?.platform === "win32") return [];
  try {
    const result = childProcess.spawnSync("ps", ["-eo", "pid=,ppid="], {
      encoding: "utf8",
      windowsHide: true,
    });
    const rows = String(result.stdout || "").trim().split(/\r?\n/)
      .map((line) => line.trim().split(/\s+/).map(Number));
    const found = [];
    const visit = (pid) => {
      for (const [child, parent] of rows) {
        if (parent === pid && !found.includes(child)) {
          found.push(child);
          visit(child);
        }
      }
    };
    visit(rootPid);
    return found.reverse();
  } catch (_) {
    return [];
  }
}

function signalWatchTree(pid, signal) {
  if (!pid) return;
  if (globalThis.process?.platform === "win32") {
    const arguments_ = ["/PID", String(pid), "/T"];
    if (signal === "SIGKILL") arguments_.push("/F");
    childProcess.spawnSync("taskkill", arguments_, { windowsHide: true });
    return;
  }
  for (const member of [...watchDescendants(pid), pid]) {
    try {
      if (globalThis.Deno) Deno.kill(member, signal);
      else globalThis.process.kill(member, signal);
    } catch (_) {}
  }
}

function watchExit(code) {
  if (globalThis.Deno) Deno.exitCode = code;
  if (globalThis.process) globalThis.process.exitCode = code;
}

export function run_foreground_watch(
  rootValue,
  command,
  argumentList,
  pollMs,
  cancellationGraceMs,
) {
  const root = path.resolve(rootValue);
  const arguments_ = Array.from(argumentList);
  const initial = workspace_fingerprint(root);
  if (!initial[0]) {
    watchWrite(`${initial[1]}\n`, true);
    watchExit(2);
    return;
  }

  const parsedMaximum = Number(watchEnvironment("SMARTEST_WATCH_MAX_REVISIONS"));
  const maximum = Number.isInteger(parsedMaximum) && parsedMaximum > 0
    ? parsedMaximum
    : 0;
  let fingerprint = initial[1];
  let revision = 0;
  let completed = 0;
  let running = null;
  let pending = true;
  let interval = null;
  let stopping = false;

  const shutdown = (code) => {
    if (stopping) return;
    stopping = true;
    if (interval !== null) clearInterval(interval);
    if (running?.forceTimer) clearTimeout(running.forceTimer);
    if (running?.child?.pid) signalWatchTree(running.child.pid, "SIGKILL");
    watchExit(code);
  };

  const startLatest = () => {
    if (stopping || running || !pending) return;
    pending = false;
    const startedRevision = revision;
    watchWrite(`[smartest] revision ${startedRevision}: ${command} ${arguments_.join(" ")}\n`);
    const child = childProcess.spawn(command, arguments_, {
      cwd: root,
      env: { ...globalThis.process?.env },
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const state = { child, revision: startedRevision, cancelling: false, forceTimer: null, finished: false };
    running = state;
    child.stdout?.on("data", (chunk) => watchWrite(chunk));
    child.stderr?.on("data", (chunk) => watchWrite(chunk, true));

    const finish = (code, message = "") => {
      if (state.finished) return;
      state.finished = true;
      if (state.forceTimer) clearTimeout(state.forceTimer);
      if (message) watchWrite(`${message}\n`, true);
      if (running === state) running = null;
      completed += 1;
      if (maximum > 0 && completed >= maximum) {
        shutdown(Number.isInteger(code) ? code : 2);
        return;
      }
      startLatest();
    };
    child.once("error", (error) => finish(2, `could not start watch job: ${error?.message || error}`));
    child.once("close", (code) => finish(code));
  };

  const observe = () => {
    if (stopping) return;
    const observed = workspace_fingerprint(root);
    if (!observed[0]) {
      watchWrite(`${observed[1]}\n`, true);
      shutdown(2);
      return;
    }
    if (observed[1] === fingerprint) return;
    fingerprint = observed[1];
    revision += 1;
    pending = true;
    if (!running) {
      startLatest();
      return;
    }
    if (!running.cancelling) {
      const cancelling = running;
      cancelling.cancelling = true;
      signalWatchTree(cancelling.child.pid, "SIGTERM");
      cancelling.forceTimer = setTimeout(() => {
        if (running === cancelling && !cancelling.finished) {
          signalWatchTree(cancelling.child.pid, "SIGKILL");
        }
      }, cancellationGraceMs);
    }
  };

  const interrupt = () => shutdown(130);
  if (globalThis.process?.once) {
    globalThis.process.once("SIGINT", interrupt);
    globalThis.process.once("SIGTERM", interrupt);
  }
  interval = setInterval(observe, Math.max(25, pollMs));
  startLatest();
}

export function exit(code) {
  if (globalThis.Deno) Deno.exit(code);
  globalThis.process.exit(code);
}
