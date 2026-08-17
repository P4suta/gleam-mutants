// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { toList } from "../gleam.mjs";

function listToArray(list) {
  return Array.from(list);
}

export function arguments$() {
  if (globalThis.Deno?.args) return toList([...globalThis.Deno.args]);
  return toList(process.argv.slice(2));
}

// Gleam escapes the reserved JS identifier in generated calls by using the
// exported source name, so also provide the unescaped property explicitly.
export { arguments$ as arguments };

export function env(name) {
  try {
    if (globalThis.Deno?.env) return globalThis.Deno.env.get(name) ?? "";
  } catch (_) {
    // Deno without env permission: fall through to the Node compatibility API.
  }
  return globalThis.process?.env?.[name] ?? "";
}

export function current_directory() {
  try { return globalThis.Deno?.cwd?.() ?? process.cwd(); }
  catch (_) { return process.cwd(); }
}

export function temporary_directory() {
  return os.tmpdir();
}

export function cache_directory() {
  if (process.platform === "win32") {
    return process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local");
  }
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Caches");
  }
  return process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache");
}

export function cpu_count() {
  return Math.max(1, os.availableParallelism?.() ?? os.cpus().length ?? 1);
}

export function now_milliseconds() { return Date.now(); }
export function monotonic_milliseconds() {
  return Math.trunc(globalThis.performance?.now?.() ?? Number(process.hrtime.bigint() / 1_000_000n));
}
export function resolve_path(value) { return path.resolve(value); }
export function architecture() { return globalThis.Deno?.build?.arch ?? process.arch; }
export function environment() {
  try {
    const entries = globalThis.Deno?.env ? [...globalThis.Deno.env.toObject ? Object.entries(globalThis.Deno.env.toObject()) : []] : Object.entries(process.env);
    return entries.map(([key, value]) => `${key.length}:${key}${String(value ?? "").length}:${value ?? ""}`).sort().join("");
  } catch (_) {
    return Object.entries(globalThis.process?.env ?? {}).map(([key, value]) => `${key.length}:${key}${String(value ?? "").length}:${value ?? ""}`).sort().join("");
  }
}
export function random_nonce() {
  if (globalThis.crypto?.getRandomValues) {
    const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16));
    return [...bytes].map(byte => byte.toString(16).padStart(2, "0")).join("");
  }
  return crypto.randomBytes(16).toString("hex");
}
export function delete_tree(value) {
  try {
    fs.rmSync(path.normalize(value), {
      recursive: true,
      force: true,
      maxRetries: 40,
      retryDelay: 50,
    });
    return "";
  } catch (error) {
    return String(error?.message || error);
  }
}
function synchronousDelay(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}
function lockProcessAlive(pid) {
  try { process.kill(Number(pid), 0); return true; }
  catch (error) { return error?.code === "EPERM"; }
}
function parseLock(value) {
  const [token = "", pid = "", runId = "", started = ""] = String(value).split("\n");
  return { token, pid, runId, started };
}
export function acquire_lock(target, runId, startedMs, waitMs) {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const token = random_nonce();
  const deadline = Date.now() + waitMs;
  while (true) {
    try {
      const descriptor = fs.openSync(target, "wx", 0o600);
      try {
        fs.writeFileSync(descriptor, `${token}\n${process.pid}\n${runId}\n${startedMs}\n`, "utf8");
        fs.fsyncSync(descriptor);
      } finally { fs.closeSync(descriptor); }
      return `ok:${token}`;
    } catch (error) {
      if (error?.code !== "EEXIST") return `error:could not create workspace lock: ${error?.message || error}`;
      let existing = { pid: "unknown", runId: "unknown", started: "unknown" };
      try {
        existing = parseLock(fs.readFileSync(target, "utf8"));
        if (existing.pid && !lockProcessAlive(existing.pid)) {
          fs.unlinkSync(target);
          continue;
        }
      } catch (_) {}
      if (Date.now() >= deadline) {
        return `error:workspace is locked by pid ${existing.pid}, run ${existing.runId}, started ${existing.started}`;
      }
      synchronousDelay(50);
    }
  }
}
export function release_lock(target, token) {
  try {
    const existing = parseLock(fs.readFileSync(target, "utf8"));
    if (existing.token !== token) return "workspace lock ownership changed";
    fs.unlinkSync(target);
    return "";
  } catch (error) {
    return `could not release workspace lock: ${error?.message || error}`;
  }
}
export function process_id() { return process.pid; }
export function os_name() { return process.platform === "win32" ? "windows" : process.platform; }
export function is_tty() { return Boolean(process.stdout?.isTTY && process.stdin?.isTTY); }

export function is_reparse_point(target) {
  if (process.platform !== "win32") return false;
  try { return fs.lstatSync(target).isSymbolicLink(); }
  catch (_) { return false; }
}

export function exit(code) {
  if (globalThis.Deno) Deno.exit(code);
  process.exit(code);
}

function descendants(rootPid) {
  if (process.platform === "win32") return [];
  const result = childProcess.spawnSync("ps", ["-eo", "pid=,ppid="], { encoding: "utf8" });
  const rows = String(result.stdout || "").trim().split(/\r?\n/).map((line) => line.trim().split(/\s+/).map(Number));
  const found = [];
  const visit = (pid) => {
    for (const [child, parent] of rows) {
      if (parent === pid && !found.includes(child)) { found.push(child); visit(child); }
    }
  };
  visit(rootPid);
  return found.reverse();
}

function killTree(pid) {
  if (!pid) return;
  if (process.platform === "win32") {
    childProcess.spawnSync("taskkill", ["/PID", String(pid), "/T", "/F"], { windowsHide: true });
    return;
  }
  const pids = [...descendants(pid), pid];
  for (const signal of ["SIGTERM", "SIGKILL"]) {
    for (const item of pids) { try { process.kill(item, signal); } catch (_) {} }
    if (signal === "SIGTERM") Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 250);
  }
}

const denoProcessWorkerSource = String.raw`
const delay = (milliseconds) => new Promise(resolve => setTimeout(resolve, milliseconds));
const OUTPUT_LIMIT = 64 * 1024;

async function readLimited(stream) {
  const reader = stream.getReader();
  const chunks = [];
  let size = 0;
  let omitted = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    const remaining = Math.max(0, OUTPUT_LIMIT - size);
    if (remaining > 0) {
      const kept = value.subarray(0, remaining);
      chunks.push(kept);
      size += kept.length;
      omitted += value.length - kept.length;
    } else omitted += value.length;
  }
  const result = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  const text = new TextDecoder().decode(result);
  return omitted > 0 ? text + "\n... " + omitted + " bytes omitted ...\n" : text;
}

function descendants(rootPid, rows) {
  const found = [];
  const visit = (pid) => {
    for (const [child, parent] of rows) {
      if (parent === pid && !found.includes(child)) { found.push(child); visit(child); }
    }
  };
  visit(rootPid);
  return found.reverse();
}

async function killTree(pid) {
  if (Deno.build.os === "windows") {
    try {
      await new Deno.Command("taskkill", {
        args: ["/PID", String(pid), "/T", "/F"], stdout: "null", stderr: "null",
      }).output();
    } catch (_) {}
    return;
  }
  let pids = [pid];
  try {
    const output = await new Deno.Command("ps", {
      args: ["-eo", "pid=,ppid="], stdout: "piped", stderr: "null",
    }).output();
    const rows = new TextDecoder().decode(output.stdout).trim().split(/\r?\n/)
      .map(line => line.trim().split(/\s+/).map(Number));
    pids = [...descendants(pid, rows), pid];
  } catch (_) {}
  for (const signal of ["SIGTERM", "SIGKILL"]) {
    for (const item of pids) { try { Deno.kill(item, signal); } catch (_) {} }
    if (signal === "SIGTERM") await delay(250);
  }
}

self.onmessage = async ({ data }) => {
  const control = new Int32Array(data.shared, 0, 2);
  const destination = new Uint8Array(data.shared, 8);
  const finish = (value) => {
    const encoded = new TextEncoder().encode(JSON.stringify(value));
    const length = Math.min(encoded.length, destination.length);
    destination.set(encoded.subarray(0, length));
    Atomics.store(control, 1, length);
    Atomics.store(control, 0, 1);
    Atomics.notify(control, 0);
  };
  try {
    const child = new Deno.Command(data.executable, {
      args: data.arguments,
      cwd: data.workingDirectory || undefined,
      env: Object.fromEntries(data.environment),
      clearEnv: false,
      stdout: "piped",
      stderr: "piped",
    }).spawn();
    const stdoutPromise = readLimited(child.stdout);
    const stderrPromise = readLimited(child.stderr);
    const statusPromise = child.status;
    let timer;
    const timeoutPromise = new Promise(resolve => { timer = setTimeout(() => resolve(null), data.timeoutMs); });
    let status = await Promise.race([statusPromise, timeoutPromise]);
    let timedOut = false;
    if (status === null) {
      timedOut = true;
      await killTree(child.pid);
      status = await Promise.race([statusPromise, delay(1000).then(() => null)]);
    }
    clearTimeout(timer);
    const [stdout, stderr] = await Promise.all([stdoutPromise, stderrPromise]);
    finish([
      status?.code ?? (timedOut ? -1 : -2),
      stdout,
      stderr || (status ? "" : "process timed out"),
      timedOut,
    ]);
  } catch (error) {
    finish([-2, "", String(error?.message || error), false]);
  }
};
`;

function startDenoProcess(executable, arguments_, workingDirectory, environment, timeoutMs) {
  const shared = new SharedArrayBuffer(8 + 256 * 1024);
  const control = new Int32Array(shared, 0, 2);
  const workerUrl = URL.createObjectURL(new Blob([denoProcessWorkerSource], { type: "text/javascript" }));
  const worker = new Worker(workerUrl, { type: "module" });
  worker.postMessage({
    executable,
    arguments: arguments_,
    workingDirectory,
    environment,
    timeoutMs,
    shared,
  });
  return { shared, control, workerUrl, worker, timeoutMs };
}

function finishDenoProcess(handle) {
  try {
    const { shared, control, timeoutMs } = handle;
    const wait = Atomics.wait(control, 0, 0, timeoutMs + 5000);
    if (wait === "timed-out") return [-1, "", "process worker timed out", true];
    const length = Atomics.load(control, 1);
    const bytes = new Uint8Array(shared, 8, length);
    return JSON.parse(new TextDecoder().decode(bytes));
  } finally {
    handle.worker.terminate();
    URL.revokeObjectURL(handle.workerUrl);
  }
}

function runDenoProcess(executable, arguments_, workingDirectory, environment, timeoutMs) {
  return finishDenoProcess(startDenoProcess(executable, arguments_, workingDirectory, environment, timeoutMs));
}

const nodeBatchSource = String.raw`
const childProcess = require("node:child_process");
const requests = JSON.parse(process.env.GLEAM_MUTANTS_BATCH_REQUESTS);
const jobs = Math.max(1, Number(process.env.GLEAM_MUTANTS_BATCH_JOBS) || 1);
const activeChildren = new Set();
const OUTPUT_LIMIT = 64 * 1024;

class LimitedOutput {
  constructor() { this.chunks = []; this.size = 0; this.omitted = 0; }
  push(chunk) {
    const remaining = Math.max(0, OUTPUT_LIMIT - this.size);
    if (remaining > 0) {
      const kept = chunk.subarray(0, remaining);
      this.chunks.push(kept);
      this.size += kept.length;
      this.omitted += chunk.length - kept.length;
    } else this.omitted += chunk.length;
  }
  text() {
    const value = Buffer.concat(this.chunks, this.size).toString("utf8");
    return this.omitted > 0 ? value + "\n... " + this.omitted + " bytes omitted ...\n" : value;
  }
}

function descendants(rootPid) {
  if (process.platform === "win32") return [];
  const result = childProcess.spawnSync("ps", ["-eo", "pid=,ppid="], { encoding: "utf8" });
  const rows = String(result.stdout || "").trim().split(/\r?\n/)
    .map(line => line.trim().split(/\s+/).map(Number));
  const found = [];
  const visit = pid => {
    for (const [child, parent] of rows) {
      if (parent === pid && !found.includes(child)) { found.push(child); visit(child); }
    }
  };
  visit(rootPid);
  return found.reverse();
}

function killTree(pid) {
  if (!pid) return;
  if (process.platform === "win32") {
    childProcess.spawnSync("taskkill", ["/PID", String(pid), "/T", "/F"], { windowsHide: true });
    return;
  }
  const pids = [...descendants(pid), pid];
  for (const signal of ["SIGTERM", "SIGKILL"]) {
    for (const item of pids) { try { process.kill(item, signal); } catch (_) {} }
    if (signal === "SIGTERM") Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 250);
  }
}

function interrupt(signal) {
  for (const pid of activeChildren) killTree(pid);
  process.exit(signal === "SIGINT" ? 130 : 143);
}

process.once("SIGINT", () => interrupt("SIGINT"));
process.once("SIGTERM", () => interrupt("SIGTERM"));

function run(request) {
  return new Promise(resolve => {
    const [executable, args, cwd, environment, timeoutMs] = request;
    const started = Date.now();
    const child = childProcess.spawn(executable, args, {
      cwd: cwd || undefined,
      env: { ...process.env, ...Object.fromEntries(environment) },
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (child.pid) activeChildren.add(child.pid);
    const stdout = new LimitedOutput();
    const stderr = new LimitedOutput();
    let timedOut = false;
    let finished = false;
    child.stdout.on("data", chunk => stdout.push(chunk));
    child.stderr.on("data", chunk => stderr.push(chunk));
    const timer = setTimeout(() => {
      timedOut = true;
      killTree(child.pid);
    }, timeoutMs);
    const finish = (status, error = "") => {
      if (finished) return;
      finished = true;
      if (child.pid) activeChildren.delete(child.pid);
      clearTimeout(timer);
      resolve([
        status ?? (timedOut ? -1 : -2),
        stdout.text(),
        stderr.text() + error,
        timedOut,
        Date.now() - started,
      ]);
    };
    child.on("error", error => finish(-2, String(error.message || error)));
    child.on("close", code => finish(code));
  });
}

(async () => {
  const results = new Array(requests.length);
  let cursor = 0;
  async function worker() {
    while (true) {
      const index = cursor++;
      if (index >= requests.length) return;
      results[index] = await run(requests[index]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(jobs, requests.length) }, worker));
  if (results.some(result => result[0] === 130)) process.exit(130);
  process.stdout.write(JSON.stringify(results));
})().catch(error => { process.stderr.write(String(error.stack || error)); process.exit(1); });
`;

export function run_process_batch(requestList, jobs) {
  const requests = listToArray(requestList).map(([executable, args, cwd, environment, timeoutMs]) => [
    executable,
    listToArray(args),
    cwd,
    listToArray(environment),
    timeoutMs,
  ]);
  if (requests.length === 0) return toList([]);
  if (globalThis.Deno) {
    const results = [];
    for (let cursor = 0; cursor < requests.length; cursor += Math.max(1, jobs)) {
      const wave = requests.slice(cursor, cursor + Math.max(1, jobs));
      const handles = wave.map(([executable, args, cwd, environment, timeoutMs]) =>
        startDenoProcess(executable, args, cwd, environment, timeoutMs));
      for (const handle of handles) {
        const started = performance.now();
        const result = finishDenoProcess(handle);
        results.push([...result, Math.max(0, Math.trunc(performance.now() - started))]);
      }
    }
    if (results.some(result => result[0] === 130)) Deno.exit(130);
    return toList(results);
  }
  const arguments_ = ["-e", nodeBatchSource];
  let status;
  let stdout;
  let stderr;
  const output = childProcess.spawnSync(process.execPath, arguments_, {
    encoding: "utf8",
    windowsHide: true,
    maxBuffer: 8 * 1024 * 1024,
    env: {
      ...process.env,
      GLEAM_MUTANTS_BATCH_REQUESTS: JSON.stringify(requests),
      GLEAM_MUTANTS_BATCH_JOBS: String(jobs),
    },
  });
  status = output.status ?? -2;
  stdout = String(output.stdout || "");
  stderr = String(output.stderr || output.error?.message || "");
  if (status !== 0) {
    if (status === 130) {
      if (globalThis.Deno) Deno.exit(130);
      process.exit(130);
    }
    return toList(requests.map(() => [-2, "", `batch runner failed: ${stderr}`, false, 0]));
  }
  return toList(JSON.parse(stdout));
}
export function run_process(executable, argumentList, workingDirectory, environment, timeoutMs) {
  const arguments_ = listToArray(argumentList);
  const overrides = listToArray(environment);
  if (globalThis.Deno) {
    const result = runDenoProcess(executable, arguments_, workingDirectory, overrides, timeoutMs);
    if (result[0] === 130) Deno.exit(130);
    return result;
  }
  const result = Array.from(run_process_batch(toList([
    [executable, toList(arguments_), workingDirectory, toList(overrides), timeoutMs],
  ]), 1))[0];
  return result.slice(0, 4);
}
