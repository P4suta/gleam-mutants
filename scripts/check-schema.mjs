// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import Ajv from "ajv";
import Ajv2020 from "ajv/dist/2020.js";

const nativeSchemaFile = "schema/run-report-v1.schema.json";
const listSchemaFile = "schema/list-v1.schema.json";
const doctorSchemaFile = "schema/doctor-v1.schema.json";
const suggestSchemaFile = "schema/suggest-v1.schema.json";
const explainSchemaFile = "schema/explain-v1.schema.json";
const applySchemaFile = "schema/apply-v1.schema.json";
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
const suggestSchema = JSON.parse(fs.readFileSync(suggestSchemaFile, "utf8"));
const explainSchema = JSON.parse(fs.readFileSync(explainSchemaFile, "utf8"));
const applySchema = JSON.parse(fs.readFileSync(applySchemaFile, "utf8"));
for (const [file, schema] of [[listSchemaFile, listSchema], [doctorSchemaFile, doctorSchema], [suggestSchemaFile, suggestSchema], [explainSchemaFile, explainSchema], [applySchemaFile, applySchema]]) {
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

function cliFixture(command, target, root = "fixtures/basic_project", environment = {}) {
  const args = ["run", "-m", "gleam_mutants", "--target", target];
  if (target === "javascript") args.push("--runtime", "node");
  args.push("--", "--root", root, ...command);
  const result = childProcess.spawnSync("gleam", args, {
    cwd: process.cwd(),
    encoding: "utf8",
    shell: false,
    maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, ...environment },
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    process.stderr.write((result.stdout || "") + (result.stderr || ""));
    throw new Error(`CLI ${command.join(" ")} fixture failed on ${target}`);
  }
  return result.stdout;
}

// Where a run stores what it knows about one workspace: the same directory
// `cache.workspace_id` and the platform FFI compute, spelled out here because
// this script has to delete one without asking the tool to.
function workspaceCacheEntry(root) {
  const home = process.env.HOME || ".";
  const base = process.platform === "win32"
    ? (process.env.LOCALAPPDATA || os.tmpdir())
    : process.platform === "darwin"
      ? path.join(home, "Library", "Caches")
      : (process.env.XDG_CACHE_HOME || path.join(home, ".cache"));
  const id = crypto.createHash("sha256").update(path.resolve(root)).digest("hex").toUpperCase();
  return path.join(base, "gleam-mutants", "v1", "workspaces", id);
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

const failingTestCommand = [
  "list",
  "--json",
  "--test-command",
  "node",
  "-e",
  "process.exit(91)",
];
const listErlang = cliFixture(failingTestCommand, "erlang");
const listNode = cliFixture(failingTestCommand, "javascript");
if (listErlang !== listNode) throw new Error("Erlang and Node list JSON differ byte-for-byte");
const validateList = nativeAjv.compile(listSchema);
const listReport = JSON.parse(listErlang);
if (!validateList(listReport)) {
  throw new Error(`List JSON schema validation failed:\n${nativeAjv.errorsText(validateList.errors, { separator: "\n" })}`);
}
if (listReport.validated !== false || listReport.mutants.length === 0 || listReport.rejected.length !== 0) {
  throw new Error("Unvalidated list did not return discovered candidates without running the failing test command");
}

const invalidRoot = "fixtures/compile_invalid_project";
const validatedErlang = cliFixture(["list", "--validate", "--json"], "erlang", invalidRoot);
const validatedNode = cliFixture(["list", "--validate", "--json"], "javascript", invalidRoot);
if (validatedErlang !== validatedNode) {
  throw new Error(
    "Erlang and Node validated-list JSON differ byte-for-byte"
    + `\nErlang:\n${validatedErlang}`
    + `\nNode:\n${validatedNode}`,
  );
}
const validatedReport = JSON.parse(validatedErlang);
if (!validateList(validatedReport)) {
  throw new Error(`Validated-list JSON schema validation failed:\n${nativeAjv.errorsText(validateList.errors, { separator: "\n" })}`);
}
if (
  validatedReport.validated !== true
  || validatedReport.mutants.length !== 0
  || validatedReport.rejected.length === 0
  || validatedReport.rejected.some(mutant => mutant.reason !== "compile-invalid")
) {
  throw new Error("Validated list did not report an all-compile-invalid catalogue as 0 valid plus rejected");
}

const doctor = JSON.parse(cliFixture(["doctor", "--json"], "erlang"));
const validateDoctor = nativeAjv.compile(doctorSchema);
if (!validateDoctor(doctor)) {
  throw new Error(`Doctor JSON schema validation failed:\n${nativeAjv.errorsText(validateDoctor.errors, { separator: "\n" })}`);
}

// `suggest` probes each function inside a snapshot by spawning an Erlang
// process per call, which has no JavaScript counterpart: the command refuses a
// JavaScript workspace outright (GMU8001), so there is deliberately no Node
// output to compare byte-for-byte against. The fixture is still deterministic
// — the default seed drives the same property search every time — so the one
// suggestion that only `0` can produce is asserted alongside the schema.
const suggestReport = JSON.parse(cliFixture(["suggest", "--json"], "erlang", "fixtures/boundary_project"));
const validateSuggest = nativeAjv.compile(suggestSchema);
if (!validateSuggest(suggestReport)) {
  throw new Error(`Suggest JSON schema validation failed:\n${nativeAjv.errorsText(validateSuggest.errors, { separator: "\n" })}`);
}
const boundarySuggestion = suggestReport.suggestions.find(
  suggestion => suggestion.function === "is_positive" && suggestion.operator === "comparison-boundary",
);
if (
  !boundarySuggestion
  || JSON.stringify(boundarySuggestion.inputs) !== JSON.stringify(["0"])
  || boundarySuggestion.expected !== "False"
  || !boundarySuggestion.test_source.includes("assert boundary.is_positive(0) == False")
) {
  throw new Error("The default seed did not produce the deterministic is_positive boundary suggestion");
}
if (!suggestReport.indistinguishable.some(entry => entry.function === "abs")) {
  throw new Error("The equivalent `abs` mutants were not reported as indistinguishable");
}
if (!suggestReport.unsupported.some(entry => entry.function === "applies" && entry.reason.includes("function"))) {
  throw new Error("The function-typed parameter of `applies` was not reported as unsupported");
}
// One mutant the compiler rejects must not take its file down: `join`'s
// pipeline-stage-deletion leaves a `List(String)` where a `String` belongs, and
// the string-neutral mutant on the very same line is still a test worth
// pasting.
if (!suggestReport.unsupported.some(entry => entry.function === "join" && entry.reason.includes("does not compile"))) {
  throw new Error("The type-invalid pipeline mutant of `join` was not reported as unsupported");
}
if (!suggestReport.suggestions.some(suggestion => suggestion.function === "join" && suggestion.operator === "string-neutral")) {
  throw new Error("The string-neutral mutant beside the type-invalid one was never suggested");
}
// `nondeterministic` is a bucket of its own, present even when empty: a
// consumer must not have to string-match a reason to recover a documented
// status.
if (!Array.isArray(suggestReport.nondeterministic) || suggestReport.nondeterministic.length !== 0) {
  throw new Error("Suggest JSON v1 is missing the `nondeterministic` array, or the fixture reported an entry in it");
}
// `--operator` narrows a probe the way it narrows `run` and `list`.
const narrowedSuggest = JSON.parse(cliFixture(
  ["suggest", "--operator", "string-neutral", "--json"],
  "erlang",
  "fixtures/boundary_project",
));
if (!validateSuggest(narrowedSuggest)) {
  throw new Error(`Operator-narrowed suggest JSON schema validation failed:\n${nativeAjv.errorsText(validateSuggest.errors, { separator: "\n" })}`);
}
if (
  narrowedSuggest.suggestions.length === 0
  || narrowedSuggest.suggestions.some(suggestion => suggestion.operator !== "string-neutral")
) {
  throw new Error("`suggest --operator string-neutral` did not narrow the run to string-neutral mutants");
}

// `explain` is the same probe narrowed to one mutant, so it is Erlang-only for
// the same reason `suggest` is. The run is narrowed to `is_positive` as well,
// which is the function the boundary mutant lives in: the answer is identical
// and the probe has one function to search instead of six.
const explanation = JSON.parse(cliFixture(
  ["explain", boundarySuggestion.display_id, "--function", "is_positive", "--json"],
  "erlang",
  "fixtures/boundary_project",
));
const validateExplain = nativeAjv.compile(explainSchema);
if (!validateExplain(explanation)) {
  throw new Error(`Explain JSON schema validation failed:\n${nativeAjv.errorsText(validateExplain.errors, { separator: "\n" })}`);
}
if (
  explanation.mutant_id !== boundarySuggestion.mutant_id
  || explanation.status !== "distinguished"
  || explanation.function !== "is_positive"
  || JSON.stringify(explanation.inputs) !== JSON.stringify(["0"])
  || explanation.original !== "value > 0"
  || explanation.replacement !== "value >= 0"
  || !explanation.test_source.includes("assert boundary.is_positive(0) == False")
) {
  throw new Error("`explain` did not describe the mutant `suggest` had just proposed a test for");
}

// `apply` without `--yes` is a dry run: it resolves the same suggestions
// against the workspace's own test modules and writes nothing at all, which is
// what makes it safe to validate against the fixture in the repository. The
// fixture already holds `test/boundary_test.gleam`, so the plan is an update
// rather than a creation, and no verification was asked for.
const applyPlan = JSON.parse(cliFixture(["apply", "--json"], "erlang", "fixtures/boundary_project"));
const validateApply = nativeAjv.compile(applySchema);
if (!validateApply(applyPlan)) {
  throw new Error(`Apply JSON schema validation failed:\n${nativeAjv.errorsText(validateApply.errors, { separator: "\n" })}`);
}
const boundaryPlan = applyPlan.plans.find(plan => plan.file === "test/boundary_test.gleam");
if (
  applyPlan.verification !== null
  || !boundaryPlan
  || boundaryPlan.create !== false
  || !boundaryPlan.tests_added.some(name => name.startsWith("is_positive_kills_"))
) {
  throw new Error("A dry-run `apply` did not plan the is_positive test into the fixture's own test module");
}

// A dry run's `verification` is `null`, so the shape `--verify` fills it with
// — `attribution` on every entry included — is only exercised by writing for
// real. That happens in a throwaway copy of the fixture: `apply --yes` writes
// into the workspace's own `test/` directory, and the fixture in the
// repository is not the place for it.
//
// It is run as GitHub Actions runs it, whether or not this script is itself
// running there. `--verify` runs the mutation engine twice on the reader's
// behalf, and on Actions the engine annotates surviving mutants: `::warning`
// lines on stdout, and a run summary appended to the file `GITHUB_STEP_SUMMARY`
// names. Those runs are internal, so neither may happen — the `JSON.parse`
// below is what a `::warning` line on stdout breaks, and the step summary is
// checked to have been left as empty as it was found.
const verifyRoot = fs.mkdtempSync(path.join(os.tmpdir(), "gleam-mutants-apply-"));
const stepSummary = path.join(os.tmpdir(), `gleam-mutants-step-summary-${crypto.randomUUID()}.md`);
fs.writeFileSync(stepSummary, "");
let applied;
let summaryAfterApply = "";
try {
  fs.cpSync("fixtures/boundary_project", verifyRoot, { recursive: true });
  applied = JSON.parse(cliFixture(["apply", "--yes", "--verify", "--json"], "erlang", verifyRoot, {
    GITHUB_ACTIONS: "true",
    GITHUB_STEP_SUMMARY: stepSummary,
  }));
  summaryAfterApply = fs.readFileSync(stepSummary, "utf8");
} finally {
  fs.rmSync(verifyRoot, { recursive: true, force: true });
  fs.rmSync(stepSummary, { force: true });
  // A run also stores its report history under the user's cache, keyed by the
  // workspace it ran in. That workspace is gone, so its entry is an orphan
  // nothing will ever read again: deleting the copy without it would leave one
  // behind per invocation of this script.
  fs.rmSync(workspaceCacheEntry(verifyRoot), { recursive: true, force: true });
}
if (summaryAfterApply !== "") {
  throw new Error(`\`apply --yes --verify --json\` appended a mutation run to $GITHUB_STEP_SUMMARY:\n${summaryAfterApply}`);
}
if (!validateApply(applied)) {
  throw new Error(`Verified apply JSON schema validation failed:\n${nativeAjv.errorsText(validateApply.errors, { separator: "\n" })}`);
}
const attributions = new Set((applied.verification ?? []).map(entry => entry.attribution));
if (
  !Array.isArray(applied.verification)
  || applied.verification.length === 0
  || !applied.verification.every(entry => typeof entry.attribution === "string")
) {
  throw new Error("`apply --yes --verify --json` reported no verification entry carrying an attribution");
}
if (!attributions.has("new") || !attributions.has("already_killed") || attributions.has("surviving")) {
  throw new Error(`The verified fixture did not attribute its kills to both the generated tests and its own suite: ${[...attributions].join(", ")}`);
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
console.log("Native, unvalidated-list, validated-list, and doctor v1 fixtures validated against JSON Schema 2020-12 with Erlang/Node byte parity; Erlang-only suggest v1, explain v1, planned apply v1 and verified apply v1 fixtures validated against JSON Schema 2020-12; deterministic Stryker fixture validated against official Draft-07 schema with Ajv 8.20.0");
