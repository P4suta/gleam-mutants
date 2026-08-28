// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyHexResponse,
  evaluateNameGate,
} from "./name-gate-core.mjs";

test("an exact Hex 404 is evidence that the package is currently unregistered", () => {
  assert.deepEqual(
    classifyHexResponse(404, '{"message":"Page not found","status":404}'),
    { kind: "available" },
  );
});

test("an existing Hex package remains occupied even after human approval", () => {
  const registry = classifyHexResponse(
    200,
    JSON.stringify({ name: "smartest", owners: [{ username: "somebody" }] }),
  );

  assert.deepEqual(registry, { kind: "occupied", owners: ["somebody"] });
  assert.deepEqual(evaluateNameGate(registry, "true"), {
    ok: false,
    reason: "Hex package smartest is already registered to somebody",
  });
});

test("an unexpected registry response fails closed", () => {
  const registry = classifyHexResponse(503, "maintenance");

  assert.deepEqual(registry, { kind: "unavailable", status: 503 });
  assert.deepEqual(evaluateNameGate(registry, "true"), {
    ok: false,
    reason: "Hex registry status could not be established (HTTP 503)",
  });
});

test("only an explicit product-owner attestation opens an available name gate", () => {
  const registry = { kind: "available" };

  assert.deepEqual(evaluateNameGate(registry, "false"), {
    ok: false,
    reason: "product-owner name and trademark review is not approved",
  });
  assert.deepEqual(evaluateNameGate(registry, "true"), { ok: true });
});
