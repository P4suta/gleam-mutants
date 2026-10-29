// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import childProcess from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = process.cwd();
function commands(module) {
	const main = path.join(
		root,
		"build",
		"dev",
		"javascript",
		"gleam_mutants",
		`${module}.mjs`,
	);
	const importMain = `import { main } from ${JSON.stringify(pathToFileURL(main).href)}; main();`;
	return [
		["erlang", "gleam", ["run", "-m", module, "--target", "erlang"]],
		[
			"node",
			"gleam",
			["run", "-m", module, "--target", "javascript", "--runtime", "node"],
		],
		["deno", "deno", ["eval", importMain]],
		["bun", "bun", ["-e", importMain]],
	];
}

for (const code of [130, 143]) {
	for (const [module, expected] of [
		["interrupt_exit_smoke", code],
		["library_interrupt_smoke", 0],
	]) {
		for (const [runtime, executable, args] of commands(module)) {
			for (const mode of module === "interrupt_exit_smoke"
				? ["sequential", "batch"]
				: ["library"]) {
				const result = childProcess.spawnSync(executable, args, {
					cwd: root,
					encoding: "utf8",
					env: {
						...process.env,
						GLEAM_MUTANTS_TEST_MODE: mode,
						GLEAM_MUTANTS_INTERRUPT_CODE: String(code),
						GITHUB_ACTIONS: "true",
					},
					windowsHide: true,
					timeout: 120_000,
				});
				if (result.error) throw result.error;
				if (result.stdout.includes("child-interrupt-output")) {
					throw new Error(`${runtime} leaked captured child output`);
				}
				if (result.status !== expected) {
					throw new Error(
						`${runtime} ${module} ${mode} expected ${expected}, got ${result.status}\n${result.stdout}\n${result.stderr}`,
					);
				}
				if (
					expected === 0 &&
					!result.stdout.includes(`API host continued after ${code}`)
				) {
					throw new Error(`${runtime} API host did not continue after ${code}`);
				}
			}
		}
	}
}

console.log(
	"CLI interrupt codes and API host preservation passed for 130 and 143 on all four runtimes",
);
