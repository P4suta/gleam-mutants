// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./playwright",
  fullyParallel: false,
  workers: 1,
  reporter: "line",
  outputDir: "build/playwright-results",
  use: {
    browserName: "chromium",
    headless: true,
  },
});
