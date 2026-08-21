// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import { chromium } from "playwright";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const browser = await chromium.launch({ headless: true });
try {
  for (const argument of process.argv.slice(2)) {
    const url = pathToFileURL(path.resolve(argument)).href;
    const context = await browser.newContext({ offline: true });
    const page = await context.newPage();
    const external = [];
    const errors = [];
    page.on("request", request => {
      if (request.url() !== url) external.push(request.url());
    });
    page.on("pageerror", error => errors.push(String(error)));
    await page.addInitScript(() => {
      globalThis.__cspViolations = [];
      addEventListener("securitypolicyviolation", event => {
        globalThis.__cspViolations.push(`${event.violatedDirective}:${event.blockedURI}`);
      });
    });
    await page.goto(url, { waitUntil: "load" });
    await page.waitForFunction(() => document.querySelector("mutation-test-report-app")?.report?.files);
    const violations = await page.evaluate(() => globalThis.__cspViolations);
    if (external.length || errors.length || violations.length) {
      throw new Error(`Offline browser smoke failed for ${argument}: requests=${external}, errors=${errors}, CSP=${violations}`);
    }
    await context.close();
  }
} finally {
  await browser.close();
}

console.log(`Offline browser-smoked ${process.argv.length - 2} packaged HTML reports`);
