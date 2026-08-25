// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Two builds out of one source tree.
//
// `dist/extension.js` is the extension itself: one CommonJS file VS Code can
// require, with `vscode` left external because the host provides it and
// everything else inlined so the packaged extension carries no
// `node_modules`.
//
// `dist/core/*.mjs` is the pure core on its own, as ES modules, for
// `scripts/smoke.mjs` to import: the smoke test drives the real CLI through
// the same parsers the editor uses, which is only evidence if it is the same
// build of them.

import { build, context } from "esbuild";

const watch = process.argv.includes("--watch");

const shared = {
  bundle: true,
  platform: "node",
  target: "node20",
  logLevel: "info",
};

const extension = {
  ...shared,
  entryPoints: ["src/extension.ts"],
  outfile: "dist/extension.js",
  format: "cjs",
  external: ["vscode"],
  sourcemap: true,
  minify: false,
};

const core = {
  ...shared,
  entryPoints: [
    "src/core/cli.ts",
    "src/core/stryker.ts",
    "src/core/suggest.ts",
    "src/core/apply.ts",
    "src/core/diagnostics.ts",
  ],
  outdir: "dist/core",
  outExtension: { ".js": ".mjs" },
  format: "esm",
  sourcemap: false,
};

if (watch) {
  const watcher = await context(extension);
  await watcher.watch();
} else {
  await build(extension);
  await build(core);
}
