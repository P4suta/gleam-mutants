// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Every `GMU` code the tool can print is documented, and every code the
// catalogue lists is one the tool can print. A code with no entry leaves a
// reader with nothing to look up; an entry with no code is a promise about a
// diagnostic that no longer exists. Both rot silently, so both are checked.

import fs from "node:fs";
import path from "node:path";

const CODE = /GMU\d{4}/g;

function gleamSources(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const target = path.join(directory, entry.name);
    if (entry.isDirectory()) return gleamSources(target);
    return entry.isFile() && entry.name.endsWith(".gleam") ? [target] : [];
  });
}

const emitted = new Map();
for (const source of gleamSources("src")) {
  const text = fs.readFileSync(source, "utf8");
  for (const [code] of text.matchAll(CODE)) {
    if (!emitted.has(code)) emitted.set(code, source);
  }
}

// Only table rows count as catalogue entries, so a retired code can still be
// explained in prose without claiming the tool still prints it.
const catalogue = fs.readFileSync(path.join("docs", "errors.md"), "utf8");
const documented = new Map();
for (const line of catalogue.split("\n")) {
  const row = line.match(/^\|\s*`(GMU\d{4})`\s*\|/);
  if (row) documented.set(row[1], line);
}

// Other pages name codes in passing -- `docs/suggest.md` keeps its own table
// of the range it owns -- and a code that is renamed or retired must not be
// left behind in one of them. They are held to the catalogue, not to each
// other's wording. `docs/errors.md` is exempt from its own rule, because it is
// the one page allowed to name a retired code and say so.
const elsewhere = [
  ...fs.readdirSync("docs")
    .filter(name => name.endsWith(".md") && name !== "errors.md")
    .map(name => path.join("docs", name)),
  "README.md",
];

const problems = [];
for (const page of elsewhere) {
  const text = fs.readFileSync(page, "utf8");
  for (const code of new Set([...text.matchAll(CODE)].map(([code]) => code))) {
    if (!documented.has(code)) problems.push(`${page} names ${code}, which docs/errors.md does not list`);
  }
}
for (const [code, source] of [...emitted].sort()) {
  if (!documented.has(code)) problems.push(`${code} is printed by ${source} but docs/errors.md does not list it`);
}
for (const code of [...documented.keys()].sort()) {
  if (!emitted.has(code)) problems.push(`${code} is listed in docs/errors.md but nothing in src/ prints it`);
}
// A family heading with no rows under it would pass the two checks above while
// leaving the table empty, so the count is asserted as well.
if (documented.size !== emitted.size) {
  problems.push(`docs/errors.md lists ${documented.size} codes, src/ prints ${emitted.size}`);
}
if (problems.length > 0) throw new Error(problems.join("\n"));

console.log(`docs/errors.md documents all ${emitted.size} GMU codes printed by src/, and every code named across ${elsewhere.length} other pages`);
