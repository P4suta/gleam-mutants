// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

function ownerName(owner) {
  if (!owner || typeof owner !== "object") return "unknown owner";
  return owner.username || owner.name || owner.email || "unknown owner";
}

export function classifyHexResponse(status, body) {
  if (status === 404) return { kind: "available" };
  if (status !== 200) return { kind: "unavailable", status };

  try {
    const payload = JSON.parse(body);
    const owners = Array.isArray(payload.owners)
      ? payload.owners.map(ownerName)
      : ["unknown owner"];
    return { kind: "occupied", owners };
  } catch (_) {
    return { kind: "unavailable", status };
  }
}

export function evaluateNameGate(registry, approval) {
  if (registry.kind === "occupied") {
    return {
      ok: false,
      reason: `Hex package smartest is already registered to ${registry.owners.join(", ")}`,
    };
  }
  if (registry.kind !== "available") {
    return {
      ok: false,
      reason: `Hex registry status could not be established (HTTP ${registry.status})`,
    };
  }
  if (approval !== "true") {
    return {
      ok: false,
      reason: "product-owner name and trademark review is not approved",
    };
  }
  return { ok: true };
}
