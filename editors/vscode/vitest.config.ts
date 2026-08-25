// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import { defineConfig } from "vitest/config";

// The core is pure and unit-tested on real CLI output under `fixtures/`.
// Nothing here launches VS Code: `@vscode/test-electron` is deliberately not
// a dependency of this package.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});
