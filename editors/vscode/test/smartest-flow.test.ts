// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import { beforeEach, describe, expect, it } from "vitest";

import {
  smartestFindings,
  smartestReplay,
  smartestReview,
} from "../src/flows/smartest";
import { FakeHost } from "./fake-host";

const FINDINGS =
  "finding-1 provisional demo/number_test/property_test\n" +
  "finding-2 unjudged demo/api_test/differential_test\n";

const EXPLANATION =
  "finding-1\n" +
  "Test: demo/number_test/property_test\n" +
  "State: provisional\n" +
  "Witness: [0, 1]\n";

let host: FakeHost;

beforeEach(() => {
  host = new FakeHost();
  host.reply("findings", { stdout: FINDINGS });
  host.reply("explain", { stdout: EXPLANATION });
});

describe("smartestFindings", () => {
  it("offers the evidence ledger and explains the chosen finding", async () => {
    host.chooseIndex = 1;

    await smartestFindings(host);

    expect(host.picks[0]?.items).toHaveLength(2);
    expect(host.picks[0]?.items[0]).toMatchObject({
      label: "demo/number_test/property_test",
      description: "provisional",
    });
    expect(host.runs).toEqual([
      ["findings", "--root", "/w"],
      ["explain", "finding-2", "--root", "/w"],
    ]);
    expect(host.runCommands.map((run) => run.command)).toEqual([
      ["smartest"],
      ["smartest"],
    ]);
    expect(host.output()).toContain("Witness:");
    expect(host.outputShown).toBe(1);
  });

  it("reports an empty inbox without opening a picker", async () => {
    host.reply("findings", { stdout: "No findings.\n" });

    await smartestFindings(host);

    expect(host.picks).toEqual([]);
    expect(host.onlyMessage("info").message).toMatch(/no Smartest findings/i);
  });

  it("reports malformed CLI output instead of reviewing the wrong item", async () => {
    host.reply("findings", { stdout: "finding-1 equivalent demo/a/b\n" });

    await smartestFindings(host);

    expect(host.picks).toEqual([]);
    expect(host.onlyMessage("error").message).toMatch(/evidence state/i);
  });
});

describe("smartestReview", () => {
  it("accepts a provisional finding only after a non-empty review note", async () => {
    host.chooseIndex = 0;
    host.button = "Accept";
    host.inputAnswers.push("checked against the public contract");
    host.reply("accept", { stdout: "Accepted finding-1 as trusted.\n" });

    await smartestReview(host);

    expect(host.runs[2]).toEqual([
      "accept",
      "finding-1",
      "--root",
      "/w",
      "--review",
      "checked against the public contract",
    ]);
    expect(host.messagesOf("info").at(-1)?.message).toMatch(/accepted finding-1/i);
  });

  it("can attach an independent oracle when accepting unjudged evidence", async () => {
    host.chooseIndex = 1;
    host.button = "Accept";
    host.inputAnswers.push("compared the protocol", "RFC 9999 section 4");
    host.reply("accept", { stdout: "Accepted finding-2 as trusted.\n" });

    await smartestReview(host);

    expect(host.runs[2]).toEqual([
      "accept",
      "finding-2",
      "--root",
      "/w",
      "--review",
      "compared the protocol",
      "--oracle",
      "RFC 9999 section 4",
    ]);
  });

  it("rejects with an explicit audit reason", async () => {
    host.chooseIndex = 0;
    host.button = "Reject";
    host.inputAnswers.push("the fixture is invalid");
    host.reply("reject", { stdout: "Rejected finding-1.\n" });

    await smartestReview(host);

    expect(host.runs[2]).toEqual([
      "reject",
      "finding-1",
      "--root",
      "/w",
      "--reason",
      "the fixture is invalid",
    ]);
  });

  it("does not mutate evidence when the decision is dismissed", async () => {
    host.chooseIndex = 0;

    await smartestReview(host);

    expect(host.runs.map((args) => args[0])).toEqual(["findings", "explain"]);
  });
});

describe("smartestReplay", () => {
  it("replays the chosen witness in a visible Smartest terminal", async () => {
    host.chooseIndex = 1;

    await smartestReplay(host);

    expect(host.terminals).toEqual([{
      name: "Smartest: replay finding-2",
      command: ["smartest"],
      args: ["replay", "finding-2", "--root", "/w"],
    }]);
  });
});
