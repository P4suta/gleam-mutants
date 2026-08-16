// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
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
    const outputPromise = child.output();
    let timer;
    const timeoutPromise = new Promise(resolve => { timer = setTimeout(() => resolve(null), data.timeoutMs); });
    let output = await Promise.race([outputPromise, timeoutPromise]);
    let timedOut = false;
    if (output === null) {
      timedOut = true;
      await killTree(child.pid);
      output = await Promise.race([outputPromise, delay(1000).then(() => null)]);
    }
    clearTimeout(timer);
    finish([
      output?.code ?? (timedOut ? -1 : -2),
      output ? new TextDecoder().decode(output.stdout) : "",
      output ? new TextDecoder().decode(output.stderr) : "process timed out",
      timedOut,
    ]);
  } catch (error) {
    finish([-2, "", String(error?.message || error), false]);
  }
};
`;

function runDenoProcess(executable, arguments_, workingDirectory, environment, timeoutMs) {
  const shared = new SharedArrayBuffer(8 + 64 * 1024 * 1024);
  const control = new Int32Array(shared, 0, 2);
  const workerUrl = URL.createObjectURL(new Blob([denoProcessWorkerSource], { type: "text/javascript" }));
  const worker = new Worker(workerUrl, { type: "module" });
  try {
    worker.postMessage({
      executable,
      arguments: arguments_,
      workingDirectory,
      environment,
      timeoutMs,
      shared,
    });
    const wait = Atomics.wait(control, 0, 0, timeoutMs + 5000);
    if (wait === "timed-out") return [-1, "", "process worker timed out", true];
    const length = Atomics.load(control, 1);
    const bytes = new Uint8Array(shared, 8, length);
    return JSON.parse(new TextDecoder().decode(bytes));
  } finally {
    worker.terminate();
    URL.revokeObjectURL(workerUrl);
  }
}

const nodeBatchSource = String.raw`
const childProcess = require("node:child_process");
const requests = JSON.parse(process.argv[1]);
const jobs = Math.max(1, Number(process.argv[2]) || 1);
const activeChildren = new Set();

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
    const stdout = [];
    const stderr = [];
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
        Buffer.concat(stdout).toString("utf8"),
        Buffer.concat(stderr).toString("utf8") + error,
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
  const arguments_ = ["-e", nodeBatchSource, JSON.stringify(requests), String(jobs)];
  let status;
  let stdout;
  let stderr;
  if (globalThis.Deno) {
    const output = new Deno.Command("node", {
      args: arguments_, stdout: "piped", stderr: "piped",
    }).outputSync();
    status = output.code;
    stdout = new TextDecoder().decode(output.stdout);
    stderr = new TextDecoder().decode(output.stderr);
  } else {
    const output = childProcess.spawnSync("node", arguments_, {
      encoding: "utf8", windowsHide: true, maxBuffer: 128 * 1024 * 1024,
    });
    status = output.status ?? -2;
    stdout = String(output.stdout || "");
    stderr = String(output.stderr || output.error?.message || "");
  }
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
  const mergedEnvironment = { ...process.env };
  for (const [key, value] of overrides) mergedEnvironment[key] = value;
  const result = childProcess.spawnSync(executable, arguments_, {
    cwd: workingDirectory || undefined,
    env: mergedEnvironment,
    encoding: "utf8",
    windowsHide: true,
    timeout: timeoutMs,
    killSignal: "SIGTERM",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status === 130 || result.signal === "SIGINT") process.exit(130);
  const timedOut = result.error?.code === "ETIMEDOUT";
  if (timedOut) killTree(result.pid);
  const status = result.status ?? (timedOut ? -1 : -2);
  return [status, String(result.stdout || ""), String(result.stderr || result.error?.message || ""), timedOut];
}
