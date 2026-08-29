// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import fs from "node:fs";
import { inspect } from "node:util";

export function runtime_name() {
  if (globalThis.Deno) return "deno";
  if (globalThis.Bun) return "bun";
  return "node";
}

const testContext = Symbol.for("gleam-mutants.test-context");

export function with_test_context(id, callback) {
  const hadPrevious = Object.prototype.hasOwnProperty.call(globalThis, testContext);
  const previous = globalThis[testContext];
  const restore = () => {
    if (hadPrevious) globalThis[testContext] = previous;
    else delete globalThis[testContext];
  };
  globalThis[testContext] = id;
  try {
    const value = callback();
    if (value && typeof value.then === "function") {
      return Promise.resolve(value).finally(restore);
    }
    restore();
    return value;
  } catch (error) {
    restore();
    throw error;
  }
}

function describe(error) {
  const message = String(error?.message ?? error ?? "test failed");
  const expression = assertionExpression(error);
  const values = assertionValues(error);
  const stack = error?.stack ? `\n${String(error.stack)}` : "";
  if (error?.gleam_error === "assert" || error?.gleam_error === "let_assert") {
    return `${error.file ?? "unknown"}:${error.line ?? 0}: ${message}`
      + `\nexpression: ${expression}`
      + `\nvalues: ${values}`
      + stack;
  }
  return message + stack;
}

function assertionExpression(error) {
  const start = Number(error?.expression_start ?? error?.start);
  const end = Number(error?.end);
  if (!error?.file || !Number.isInteger(start) || !Number.isInteger(end)) {
    return "<source unavailable>";
  }
  try {
    const bytes = fs.readFileSync(error.file);
    return new TextDecoder().decode(bytes.subarray(start, end));
  } catch (_) {
    return "<source unavailable>";
  }
}

function assertionValues(error) {
  if (error?.left || error?.right) {
    return `left=${inspect(error.left?.value)} right=${inspect(error.right?.value)}`;
  }
  if (Array.isArray(error?.arguments)) {
    return error.arguments.map((argument) => inspect(argument?.value)).join(", ");
  }
  if ("value" in (error ?? {})) return inspect(error.value);
  return "<values unavailable>";
}

export function capture(callback, timeoutMs) {
  const [status, _value, message, duration] = attempt(callback, timeoutMs);
  return [status, message, duration];
}

export function attempt(callback, timeoutMs) {
  const started = Date.now();
  try {
    const value = callback();
    const duration = Date.now() - started;
    if (duration > Math.max(0, Number(timeoutMs))) {
      return ["timed-out", undefined, "test exceeded its timeout", duration];
    }
    return ["passed", value, "", duration];
  } catch (error) {
    return ["failed", undefined, describe(error), Date.now() - started];
  }
}
