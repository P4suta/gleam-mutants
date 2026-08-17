// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import fs from "node:fs";
import process from "node:process";
import Ajv from "ajv";
import Ajv2020 from "ajv/dist/2020.js";

const nativeSchemaFile = "schema/run-report-v1.schema.json";
const listSchemaFile = "schema/list-v1.schema.json";
const doctorSchemaFile = "schema/doctor-v1.schema.json";
const strykerSchemaFile = "schema/mutation-testing-report-schema-3.9.0.json";
const nativeSchema = JSON.parse(fs.readFileSync(nativeSchemaFile, "utf8"));
if (nativeSchema.$schema !== "https://json-schema.org/draft/2020-12/schema") {
  throw new Error(`${nativeSchemaFile} does not declare JSON Schema 2020-12`);
}
const strykerSchema = JSON.parse(fs.readFileSync(strykerSchemaFile, "utf8"));
if (strykerSchema.$schema !== "http://json-schema.org/draft-07/schema#") {
  throw new Error(`${strykerSchemaFile} does not declare JSON Schema Draft-07`);
}

const listSchema = JSON.parse(fs.readFileSync(listSchemaFile, "utf8"));
const doctorSchema = JSON.parse(fs.readFileSync(doctorSchemaFile, "utf8"));
for (const [file, schema] of [[listSchemaFile, listSchema], [doctorSchemaFile, doctorSchema]]) {
  if (schema.$schema !== "https://json-schema.org/draft/2020-12/schema") {
    throw new Error(`${file} does not declare JSON Schema 2020-12`);
  }
}

function fixture(module, target) {
  const args = ["run", "-m", module, "--target", target];
  if (target === "javascript") args.push("--runtime", "node");
  const result = childProcess.spawnSync("gleam", args, {
    cwd: process.cwd(),
    encoding: "utf8",
    shell: false,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    process.stderr.write((result.stdout || "") + (result.stderr || ""));
    throw new Error(`${module} fixture failed on ${target}`);
  }
  return result.stdout;
}

function cliFixture(command, target) {
  const args = ["run", "-m", "gleam_mutants", "--target", target];
  if (target === "javascript") args.push("--runtime", "node");
  args.push("--", "--root", "fixtures/basic_project", ...command);
  const result = childProcess.spawnSync("gleam", args, {
    cwd: process.cwd(),
    encoding: "utf8",
    shell: false,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    process.stderr.write((result.stdout || "") + (result.stderr || ""));
    throw new Error(`CLI ${command.join(" ")} fixture failed on ${target}`);
  }
  return result.stdout;
}

const nativeErlang = fixture("native_schema_fixture", "erlang");
const nativeNode = fixture("native_schema_fixture", "javascript");
if (nativeErlang !== nativeNode) throw new Error("Erlang and Node native JSON differ byte-for-byte");
const nativeReport = JSON.parse(nativeErlang);
const nativeAjv = new Ajv2020({ allErrors: true, strict: false });
const validateNative = nativeAjv.compile(nativeSchema);
if (!validateNative(nativeReport)) {
  throw new Error(`Native report schema validation failed:\n${nativeAjv.errorsText(validateNative.errors, { separator: "\n" })}`);
}

const listErlang = cliFixture(["list", "--json"], "erlang");
const listNode = cliFixture(["list", "--json"], "javascript");
if (listErlang !== listNode) throw new Error("Erlang and Node list JSON differ byte-for-byte");
const validateList = nativeAjv.compile(listSchema);
if (!validateList(JSON.parse(listErlang))) {
  throw new Error(`List JSON schema validation failed:\n${nativeAjv.errorsText(validateList.errors, { separator: "\n" })}`);
}

const doctor = JSON.parse(cliFixture(["doctor", "--json"], "erlang"));
const validateDoctor = nativeAjv.compile(doctorSchema);
if (!validateDoctor(doctor)) {
  throw new Error(`Doctor JSON schema validation failed:\n${nativeAjv.errorsText(validateDoctor.errors, { separator: "\n" })}`);
}

const erlang = fixture("stryker_schema_fixture", "erlang");
const node = fixture("stryker_schema_fixture", "javascript");
if (erlang !== node) throw new Error("Erlang and Node Stryker JSON differ byte-for-byte");
const report = JSON.parse(erlang);
const ajv = new Ajv({ allErrors: true, strict: false, validateFormats: false });
const validate = ajv.compile(strykerSchema);
if (!validate(report)) {
  throw new Error(`Stryker report schema validation failed:\n${ajv.errorsText(validate.errors, { separator: "\n" })}`);
}
if (report.schemaVersion !== "1.0") throw new Error("Expected schemaVersion 1.0");
if ("projectRoot" in report || "config" in report) throw new Error("Privacy-sensitive fields were projected");
const file = report.files["src/adversarial.gleam"];
if (!file?.source.includes("</script><!--") || !file.source.includes("😀")) {
  throw new Error("Original adversarial source was not preserved");
}
const statuses = file.mutants.map(mutant => mutant.status).sort();
if (JSON.stringify(statuses) !== JSON.stringify(["CompileError", "Survived"])) {
  throw new Error(`Unexpected projected statuses: ${statuses.join(", ")}`);
}
for (const mutant of file.mutants) {
  for (const forbidden of ["coveredBy", "killedBy", "testsCompleted"]) {
    if (forbidden in mutant) throw new Error(`Unexpected ${forbidden} field`);
  }
}
console.log("Native, list, and doctor v1 fixtures validated against JSON Schema 2020-12; deterministic Stryker fixture validated against official Draft-07 schema with Ajv 8.20.0");
