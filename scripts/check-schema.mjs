// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import fs from "node:fs";

for (const file of ["schema/run-report-v1.schema.json"]) {
  const schema = JSON.parse(fs.readFileSync(file, "utf8"));
  if (schema.$schema !== "https://json-schema.org/draft/2020-12/schema") {
    throw new Error(`${file} does not declare JSON Schema 2020-12`);
  }
}
console.log("JSON schemas are syntactically valid");
