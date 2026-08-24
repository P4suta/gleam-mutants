// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import Ajv2020 from "ajv/dist/2020.js";

const root = process.cwd();
const deadline = Date.now() + 13 * 60 * 1_000;
const summaryPath = path.join(root, "test-results", "ecosystem-summary.json");
const nativeSchema = JSON.parse(
  fs.readFileSync(path.join(root, "schema", "run-report-v1.schema.json"), "utf8"),
);
const ajv = new Ajv2020({ allErrors: true, strict: false });
const validateNative = ajv.compile(nativeSchema);
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "gleam-mutants-ecosystem-"));

const corpora = [
  {
    name: "stdlib",
    repository: "https://github.com/gleam-lang/stdlib.git",
    commit: "55f9454419add4382a3c913af25da6d893d878a8",
    scope: "src/gleam/bool.gleam",
    target: "erlang",
    runtime: "erlang",
    timeout: "60s",
    timeoutMs: 60_000,
    expected: { candidates: 11, executed: 11, rejected: 0, killed: 11, survived: 0 },
  },
  {
    name: "json",
    repository: "https://github.com/gleam-lang/json.git",
    commit: "9792d8a5ec14e03760f8ccbc8992dff4d45105fe",
    scope: "src/gleam/json.gleam",
    target: "erlang",
    runtime: "erlang",
    timeout: "30s",
    timeoutMs: 30_000,
    expected: { candidates: 6, executed: 3, rejected: 3, killed: 1, survived: 2 },
  },
  {
    name: "http",
    repository: "https://github.com/gleam-lang/http.git",
    commit: "da44e896606b498dd9e004e3d8480e4c08f47d23",
    scope: "src/gleam/http/cookie.gleam",
    target: "erlang",
    runtime: "erlang",
    timeout: "30s",
    timeoutMs: 30_000,
    expected: { candidates: 34, executed: 29, rejected: 5, killed: 26, survived: 3 },
  },
  {
    name: "erlang",
    repository: "https://github.com/gleam-lang/erlang.git",
    commit: "dfa7cd705d8e97fe3af48754307130ecc14b5a45",
    scope: "src/gleam/erlang/atom.gleam",
    target: "erlang",
    runtime: "erlang",
    timeout: "30s",
    timeoutMs: 30_000,
    expected: { candidates: 2, executed: 2, rejected: 0, killed: 1, survived: 1 },
  },
  {
    name: "javascript",
    repository: "https://github.com/gleam-lang/javascript.git",
    commit: "b51b4365c2b5fa3f9767a349a7e7a68a874264cb",
    scope: "src/**/*.gleam",
    target: "javascript",
    runtime: "node",
    timeout: "30s",
    timeoutMs: 30_000,
    expected: { candidates: 6, executed: 2, rejected: 4, killed: 1, survived: 1 },
  },
];

function remainingMilliseconds(label) {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new Error(`ecosystem smoke exceeded its 13-minute deadline during ${label}`);
  return remaining;
}

function run(executable, arguments_, cwd, label) {
  const result = childProcess.spawnSync(executable, arguments_, {
    cwd,
    encoding: "utf8",
    shell: false,
    timeout: remainingMilliseconds(label),
    maxBuffer: 128 * 1024 * 1024,
    env: process.env,
  });
  if (result.error) {
    if (result.error.code === "ETIMEDOUT") {
      throw new Error(`ecosystem smoke exceeded its 13-minute deadline during ${label}`);
    }
    throw result.error;
  }
  if (result.status !== 0) {
    process.stderr.write((result.stdout || "") + (result.stderr || ""));
    throw new Error(`${label} failed with exit ${result.status}`);
  }
  return result.stdout;
}

function checkout(corpus, destination) {
  fs.mkdirSync(destination, { recursive: true });
  run("git", ["init", "--quiet"], destination, `${corpus.name} git init`);
  run("git", ["remote", "add", "origin", corpus.repository], destination, `${corpus.name} remote setup`);
  run(
    "git",
    ["-c", "protocol.version=2", "fetch", "--quiet", "--depth=1", "--no-tags", "origin", corpus.commit],
    destination,
    `${corpus.name} fixed-commit fetch`,
  );
  run("git", ["checkout", "--quiet", "--detach", "FETCH_HEAD"], destination, `${corpus.name} checkout`);
  const actual = run("git", ["rev-parse", "HEAD"], destination, `${corpus.name} commit verification`).trim();
  if (actual !== corpus.commit) {
    throw new Error(`${corpus.name} resolved ${actual}, expected ${corpus.commit}`);
  }
}

function sourceFiles(project, scope) {
  if (scope !== "src/**/*.gleam") return [scope];
  const files = [];
  const visit = directory => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(absolute);
      else if (entry.isFile() && entry.name.endsWith(".gleam")) {
        files.push(path.relative(project, absolute).replaceAll(path.sep, "/"));
      }
    }
  };
  visit(path.join(project, "src"));
  return files.sort((left, right) => left.localeCompare(right));
}

function sourceHash(project, scope) {
  const hash = crypto.createHash("sha256");
  const files = sourceFiles(project, scope);
  if (files.length === 0) throw new Error(`${scope} selected no source files`);
  for (const relative of files) {
    const content = fs.readFileSync(path.join(project, ...relative.split("/")));
    hash.update(`${Buffer.byteLength(relative)}:${relative}${content.length}:`);
    hash.update(content);
  }
  return hash.digest("hex");
}

function configure(project, corpus) {
  const gleamToml = path.join(project, "gleam.toml");
  const source = fs.readFileSync(gleamToml, "utf8");
  if (/\[tools\.gleam_mutants(?:\.|\])/.test(source)) {
    throw new Error(`${corpus.name} now contains its own gleam_mutants configuration; update the pinned corpus adapter`);
  }
  const configuration = `

[tools.gleam_mutants]
version = 1

[tools.gleam_mutants.test]
target = "${corpus.target}"
runtime = "${corpus.runtime}"

[tools.gleam_mutants.execution]
jobs = 4

[tools.gleam_mutants.cache]
mode = "off"

[tools.gleam_mutants.policy]
strict = false

[tools.gleam_mutants.report]
formats = []
history = false
`;
  fs.appendFileSync(gleamToml, configuration, "utf8");
}

function assertCount(corpus, field, actual) {
  const expected = corpus.expected[field];
  if (actual !== expected) {
    throw new Error(`${corpus.name} ${field} was ${actual}, expected ${expected}`);
  }
}

function verifyReport(corpus, report) {
  if (!validateNative(report)) {
    throw new Error(
      `${corpus.name} native report failed schema validation:\n${ajv.errorsText(validateNative.errors, { separator: "\n" })}`,
    );
  }
  assertCount(corpus, "candidates", report.selection.candidates);
  assertCount(corpus, "executed", report.selection.executed);
  assertCount(corpus, "rejected", report.selection.compile_errors);
  assertCount(corpus, "killed", report.score.killed);
  assertCount(corpus, "survived", report.score.survived);
  if (report.rejected.length !== corpus.expected.rejected) {
    throw new Error(`${corpus.name} rejected array length did not match compile_errors`);
  }
  if (report.mutants.length !== corpus.expected.executed || report.score.total !== corpus.expected.executed) {
    throw new Error(`${corpus.name} executed/result/score totals disagree`);
  }
  if (report.score.errors !== 0 || report.score.timed_out !== 0) {
    throw new Error(`${corpus.name} produced ${report.score.errors} errors and ${report.score.timed_out} timeouts`);
  }
  if (report.policy.strict !== false || report.policy.failure !== null) {
    throw new Error(`${corpus.name} did not run with strict policy disabled`);
  }
  const unexpected = report.mutants.filter(
    mutant => !["killed", "survived"].includes(mutant.aggregate)
      || mutant.outcomes.some(
        outcome => outcome.runtime !== corpus.runtime
          || !["killed", "survived"].includes(outcome.outcome),
      ),
  );
  if (unexpected.length !== 0) throw new Error(`${corpus.name} produced non-golden outcomes`);
}

function normalizedResult(corpus) {
  const project = path.join(temporaryRoot, corpus.name);
  console.log(`ecosystem: ${corpus.name}@${corpus.commit.slice(0, 7)} (${corpus.runtime})`);
  checkout(corpus, project);
  const before = sourceHash(project, corpus.scope);
  configure(project, corpus);
  run("gleam", ["deps", "download"], project, `${corpus.name} dependency download`);
  const output = run(
    "gleam",
    [
      "run",
      "-m",
      "gleam_mutants",
      "--target",
      "erlang",
      "--",
      "--root",
      project,
      "run",
      "--include",
      corpus.scope,
      "--jobs",
      "4",
      "--timeout",
      corpus.timeout,
      "--no-strict",
      "--report",
      "none",
      "--json",
    ],
    root,
    `${corpus.name} mutation run`,
  );
  const report = JSON.parse(output);
  verifyReport(corpus, report);
  if (fs.existsSync(path.join(project, "reports", "mutation"))) {
    throw new Error(`${corpus.name} created a project report despite report output being disabled`);
  }
  const after = sourceHash(project, corpus.scope);
  if (after !== before) throw new Error(`${corpus.name} source hash changed during mutation testing`);
  return {
    name: corpus.name,
    repository: corpus.repository.replace(/\.git$/, ""),
    commit: corpus.commit,
    scope: corpus.scope,
    target: corpus.target,
    runtime: corpus.runtime,
    workers: 4,
    timeout_ms: corpus.timeoutMs,
    candidates: report.selection.candidates,
    executed: report.selection.executed,
    rejected: report.selection.compile_errors,
    killed: report.score.killed,
    survived: report.score.survived,
    timed_out: report.score.timed_out,
    errors: report.score.errors,
    source_sha256: after,
  };
}

try {
  fs.rmSync(summaryPath, { force: true });
  const results = corpora.map(normalizedResult);
  remainingMilliseconds("summary write");
  fs.mkdirSync(path.dirname(summaryPath), { recursive: true });
  fs.writeFileSync(
    summaryPath,
    JSON.stringify({ schema_version: 1, corpora: results }, null, 2) + "\n",
    "utf8",
  );
  console.log(`ecosystem smoke passed for ${results.length} fixed corpora; summary: ${summaryPath}`);
} finally {
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
