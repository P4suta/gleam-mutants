// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Loads the captured CLI output under `fixtures/`. See `fixtures/README.md`
// for the commands that produced each file.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export function fixture(name: string): string {
  return readFileSync(
    fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url)),
    "utf8",
  );
}

// The mutant ids the fixtures pin, written out once so a test reads as the
// claim it makes rather than as sixty-four characters of hex.
export const ids = {
  // `value > 0` -> `value >= 0` in `is_positive`: survived, and `suggest`
  // proposes `is_positive(0)` for it.
  boundary:
    "CF9769AE183954EDDE01DCDA44223126335AA5763AA153644C719EEA99C8D971",
  // `0` -> `1` in the same expression: survived.
  boundaryLiteral:
    "6D5A01547E105D6D2F4AA61233F346C176DD46B7ED0BD40F2B4F6BA22E378BE1",
  // `0 - value` -> `0 + value` in `abs`: killed by the workspace's own
  // tests, and the mutant the `abs` suggestion is named after.
  absArithmetic:
    "CF4568E052E6E90C046F189C89F5E26B796CEAA4ABCDBB48A3B34D36DA8EA5BE",
  // Killed, and named only in the kill set of the `abs` suggestion: no
  // suggestion carries it as its own `mutant_id`.
  absNeutral:
    "E75BC68CAB79241561EC9D9395BE74DA05E32323C189C2466E33778838B4C461",
  // `value < 0` -> `value <= 0` in `abs`: survived, and no input told it
  // apart in 200 cases.
  absEquivalent:
    "4B7AF1DF41C06FE7B26188B05660E2CD5F17E580C24BF2681D749926D84CFBD0",
  // The pipeline-stage deletion in `join` that does not type check.
  uncompilable:
    "27FEFEAD77E05733C8E1B0F4A70097075BADEB21D2A9F95F29BA02686BB9F645",
  // A mutant of the private `helper`, which no test module could call.
  privateFunction:
    "DBC32CC1C608A4660B09A793F7D4DCBCAF9322E111A50C6484BE1D0B5E8F7C00",
} as const;
