// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import { expect, test } from "@playwright/test";
import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

function fixture(target) {
  const args = ["run", "-m", "stryker_html_fixture", "--target", target];
  if (target === "javascript") args.push("--runtime", "node");
  const result = childProcess.spawnSync("gleam", args, {
    cwd: process.cwd(),
    encoding: "utf8",
    shell: false,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`HTML fixture failed on ${target}: ${result.stdout}${result.stderr}`);
  }
  return result.stdout;
}

test("offline report renders score, source, and survivor drawer safely", async ({
  browser,
  browserName,
}) => {
  const erlang = fixture("erlang");
  const node = fixture("javascript");
  expect(node).toBe(erlang);

  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "gleam-mutants-html-"));
  const reportPath = path.join(temporary, "mutation.html");
  fs.writeFileSync(reportPath, erlang, "utf8");
  const reportUrl = pathToFileURL(reportPath).href;
  // WebKit cannot combine file: navigation with an offline context on Windows.
  // Block every network transport explicitly; the request assertion below also
  // fails if the report attempts any external access.
  const context = await browser.newContext({ offline: browserName !== "webkit" });
  if (browserName === "webkit") {
    await context.route(/^https?:/u, route => route.abort("internetdisconnected"));
  }
  const page = await context.newPage();
  const externalRequests = [];
  const pageErrors = [];
  page.on("request", request => {
    if (request.url() !== reportUrl) externalRequests.push(request.url());
  });
  page.on("pageerror", error => pageErrors.push(String(error)));
  await page.addInitScript(() => {
    globalThis.__gleamMutantsSentinel = false;
    globalThis.__gleamMutantsCspViolations = [];
    addEventListener("securitypolicyviolation", event => {
      globalThis.__gleamMutantsCspViolations.push(`${event.violatedDirective}:${event.blockedURI}`);
    });
  });

  try {
    await page.goto(reportUrl, { waitUntil: "load" });
    const app = page.locator("mutation-test-report-app");
    await expect(app).toBeVisible();
    await expect.poll(() => app.evaluate(element => element.report?.files?.["src/adversarial.gleam"]?.mutants?.length)).toBe(2);
    const totalRow = page.getByRole("row", { name: /directory All files/ });
    await expect(totalRow).toHaveAccessibleName(/All files 0\.00/);

    const fileLink = page.getByRole("link", { name: "adversarial.gleam" });
    await expect(fileLink).toBeVisible();
    await fileLink.click();
    await expect(page.locator("body")).toContainText("pub const alive = True");

    const survived = page.getByRole("img", { name: "boolean-literal Survived" });
    await expect(survived).toBeVisible();
    await survived.click();
    await expect(page.locator("body")).toContainText("False");

    expect(await page.evaluate(() => globalThis.__gleamMutantsSentinel)).toBe(false);
    expect(await page.evaluate(() => globalThis.__gleamMutantsCspViolations)).toEqual([]);
    expect(externalRequests).toEqual([]);
    expect(pageErrors).toEqual([]);
  } finally {
    await context.close();
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});
