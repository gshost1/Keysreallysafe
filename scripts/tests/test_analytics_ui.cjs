#!/usr/bin/env node
/* Browser regression coverage for the local product-analytics privacy dialog. */
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require("playwright");

const root = path.resolve(__dirname, "../..");
const html = fs.readFileSync(path.join(root, "Web/index.html"), "utf8")
  .replace("<head>", '<head><meta name="ksf-token" content="test-csrf-token">');
const analytics = fs.readFileSync(path.join(root, "Web/analytics.js"));

let status = {
  enabled: false, configured: true, endpoint: null,
  consent_version: 2, pending_events: 2, last_result: "never",
  preview: { reports: [{ date: "2026-09-19", report_id: "fixture" }] },
};
const requests = [];
let malformedNextPost = false;
let failedNextPost = false;
let delayedGet = false;
let collectorRequests = 0;

function respond(response, code, body = "") {
  response.writeHead(code, { "Content-Type": "application/json" });
  response.end(body);
}

const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  if (url.pathname === "/") {
    response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return response.end(html);
  }
  if (url.pathname === "/analytics.js") {
    response.writeHead(200, { "Content-Type": "application/javascript" });
    return response.end(analytics);
  }
  if (url.pathname === "/app.js") {
    response.writeHead(200, { "Content-Type": "application/javascript" });
    return response.end("");
  }
  if (url.pathname.endsWith(".css")) {
    response.writeHead(200, { "Content-Type": "text/css" });
    return response.end("");
  }
  if (url.pathname === "/api/analytics" && request.method === "GET") {
    const snapshot = JSON.stringify(status);
    if (delayedGet) {
      delayedGet = false;
      return setTimeout(() => respond(response, 200, snapshot), 150);
    }
    return respond(response, 200, snapshot);
  }
  if (url.pathname.startsWith("/api/analytics/") || url.pathname === "/api/analytics") {
    let body = "";
    request.on("data", (part) => { body += part; });
    return request.on("end", () => {
      const parsed = body ? JSON.parse(body) : {};
      requests.push({ path: url.pathname, headers: request.headers, body: parsed });
      if (url.pathname === "/api/analytics" && request.method === "POST") {
        status = { ...status, enabled: parsed.enabled, pending_events: parsed.enabled ? status.pending_events : 0,
          last_result: parsed.enabled ? status.last_result : "disabled", preview: parsed.enabled ? status.preview : null };
        if (malformedNextPost) {
          malformedNextPost = false;
          return respond(response, 200, JSON.stringify({ enabled: status.enabled }));
        }
        if (failedNextPost) {
          failedNextPost = false;
          return respond(response, 503, JSON.stringify({ error: "fixture failure" }));
        }
        return respond(response, 200, JSON.stringify(status));
      }
      return respond(response, 204);
    });
  }
  respond(response, 404);
});
const collector = http.createServer((_request, response) => {
  collectorRequests += 1;
  response.writeHead(204);
  response.end();
});

async function open(page) {
  await page.getByRole("button", { name: "Privacy" }).click();
  await page.locator("#dlg-privacy").waitFor({ state: "visible" });
  await page.waitForFunction(() => document.getElementById("analytics-state").textContent !== "");
}

(async () => {
  await new Promise((resolve) => collector.listen(0, "127.0.0.1", resolve));
  status.endpoint = `http://127.0.0.1:${collector.address().port}/collector`;
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.waitForLoadState("networkidle");
    await open(page);
    assert.equal(await page.locator("#analytics-enabled").isChecked(), false);
    assert.match(await page.locator("#analytics-destination").textContent(), /127\.0\.0\.1/);
    assert.equal(await page.getByText("Pending events", { exact: true }).count(), 1);
    await page.locator("#analytics-enabled").check();
    await page.getByRole("button", { name: "Save preference" }).click();
    await page.waitForFunction(() => document.getElementById("analytics-state").textContent.includes("Enabled"));
    const enable = requests.find((item) => item.path === "/api/analytics" && item.body.enabled === true);
    assert.deepEqual(enable.body, { enabled: true, consent_version: 2 });
    assert.equal(enable.headers["x-ksf-token"], "test-csrf-token");
    assert.equal(collectorRequests, 0, "the browser must not contact the analytics collector");

    await page.locator("#dlg-privacy").evaluate((element) => element.close());
    status = { ...status, enabled: false, configured: false, endpoint: null, pending_events: 0, preview: null, last_result: "disabled" };
    await page.reload();
    await page.waitForLoadState("networkidle");
    await open(page);
    assert.equal(await page.locator("#analytics-enabled").isDisabled(), true);
    assert.equal(await page.getByRole("button", { name: "Save preference" }).isDisabled(), true);

    await page.locator("#dlg-privacy").evaluate((element) => element.close());
    status = { ...status, enabled: true, configured: false, endpoint: null, pending_events: 3,
      preview: { reports: [{ date: "2026-09-19", report_id: "pending" }] }, last_result: "failed" };
    await page.reload();
    await page.waitForLoadState("networkidle");
    await open(page);
    await page.getByRole("button", { name: "Turn off and discard unsent reports" }).click();
    await page.waitForFunction(() => document.getElementById("analytics-state").textContent.startsWith("Off."));
    assert.equal(status.enabled, false);
    assert.equal(status.pending_events, 0);
    assert.equal(requests.some((item) => item.path === "/api/analytics/clear"), false);

    await page.locator("#dlg-privacy").evaluate((element) => element.close());
    status = { ...status, enabled: false, configured: true, pending_events: 1,
      preview: { reports: [{ date: "2026-09-19", report_id: "uncertain" }] }, last_result: "never" };
    malformedNextPost = true;
    await page.reload();
    await page.waitForLoadState("networkidle");
    await open(page);
    await page.locator("#analytics-enabled").check();
    await page.getByRole("button", { name: "Save preference" }).click();
    await page.waitForFunction(() => document.getElementById("analytics-state").textContent.startsWith("Current preference unknown"));
    assert.equal(await page.locator("#analytics-enabled").isDisabled(), true);

    status = { ...status, enabled: false, configured: true, pending_events: 1,
      preview: { reports: [{ date: "2026-09-19", report_id: "failed" }] }, last_result: "never" };
    failedNextPost = true;
    await page.reload();
    await page.waitForLoadState("networkidle");
    await open(page);
    await page.locator("#analytics-enabled").check();
    await page.getByRole("button", { name: "Save preference" }).click();
    await page.waitForFunction(() => document.getElementById("analytics-state").textContent.startsWith("Current preference unknown"));
    assert.equal(await page.locator("#analytics-save").isDisabled(), true);

    await page.reload();
    await page.waitForLoadState("networkidle");
    status = { ...status, enabled: true, configured: true, pending_events: 2,
      preview: { reports: [{ date: "2026-09-19", report_id: "race" }] }, last_result: "never" };
    await open(page);
    delayedGet = true;
    await page.evaluate(() => { window.KeysAnalytics.refresh(); });
    await page.getByRole("button", { name: "Turn off and discard unsent reports" }).click();
    await page.waitForTimeout(250);
    assert.match(await page.locator("#analytics-state").textContent(), /^Off\./);
    assert.equal(await page.locator("#analytics-pending").textContent(), "0");

    // Compare line: absent without sharing or without a benchmark; plain text when present.
    assert.equal(await page.locator("#usage-compare").isHidden(), true);
    status = { ...status, enabled: true, configured: true, compare: {
      window_days: 28,
      sources: [{ source: "claude_code", typical_day_tokens: 42_000_000, higher_than_percent: 80,
        cap_hits: [{ window: "5h", hit_rate: 0.18 }, { window: "<img src=x onerror=alert(1)>", hit_rate: 0.5 }] },
        { source: "<b>injected</b>", typical_day_tokens: 1, higher_than_percent: 5 }],
    } };
    await page.reload();
    await page.waitForFunction(() => !document.getElementById("usage-compare").hidden);
    const line = await page.locator("#usage-compare").textContent();
    assert.match(line, /Claude Code: your typical day 42M tokens, more than 80% of shared days; sharers hit the 5-hour limit on 18% of days/);
    assert.doesNotMatch(line, /injected|img|onerror/);
    assert.equal(await page.locator("#usage-compare img, #usage-compare b").count(), 0);
    status = { ...status, enabled: false };
    await page.reload();
    await page.waitForLoadState("networkidle");
    assert.equal(await page.locator("#usage-compare").isHidden(), true, "no line for people who do not share");
    assert.equal(collectorRequests, 0, "the browser must not contact the analytics collector");
  } finally {
    await browser.close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    collector.closeAllConnections();
    await new Promise((resolve) => collector.close(resolve));
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
