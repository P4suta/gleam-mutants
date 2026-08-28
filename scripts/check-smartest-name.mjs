// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import process from "node:process";

import {
  classifyHexResponse,
  evaluateNameGate,
} from "./name-gate-core.mjs";

const endpoint = "https://hex.pm/api/packages/smartest";
const response = await fetch(endpoint, {
  headers: { accept: "application/json" },
  redirect: "error",
});
const registry = classifyHexResponse(response.status, await response.text());
const verdict = evaluateNameGate(
  registry,
  process.env.SMARTEST_NAME_REVIEW_APPROVED,
);

if (!verdict.ok) {
  throw new Error(`Smartest name release gate is closed: ${verdict.reason}`);
}

console.log(
  "Smartest name release gate passed: Hex is currently unregistered and " +
    "the product owner approved the name/trademark review",
);
