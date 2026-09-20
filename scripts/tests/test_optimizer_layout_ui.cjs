#!/usr/bin/env node
// Geometry regression for the Optimizer overview. Loads the real index.html,
// styles.css and optimizer.css in Chromium against a synthetic local fixture and
// measures rendered boxes; it never talks to the running Keys app.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require("playwright");

const root = path.resolve(__dirname, "../..");
const screenshotDir = process.env.KEYS_UI_SCREENSHOT_DIR || path.join(root, ".build/optimizer-ui-screenshots");
const asset = (name) => fs.readFileSync(path.join(root, "Web", name));
const assets = new Map([
  ["/", ["text/html; charset=utf-8", asset("index.html").toString("utf8").replace("<head>", '<head><meta name="ksf-token" content="test-token">')]],
  ["/app.js", ["application/javascript", asset("app.js")]],
  ["/optimizer.js", ["application/javascript", asset("optimizer.js")]],
  ["/analytics.js", ["application/javascript", ""]],
  ["/styles.css", ["text/css", asset("styles.css")]],
  ["/optimizer.css", ["text/css", asset("optimizer.css")]],
  ["/providers.json", ["application/json", asset("providers.json")]],
]);

const totals = (events, input, output, cost, unknown) => ({
  events, input_tokens_known: input, input_tokens_unknown_events: unknown, output_tokens_known: output,
  output_tokens_unknown_events: unknown, reported_cost_usd_known: cost, reported_cost_usd_unknown_events: unknown,
});
const populated = {
  projects: [{ id: "project-1", name: "Synthetic layout fixture", root: "/synthetic/layout", mode: "suggest", storage_enabled: true }],
  tasks_count: 1284,
  aggregate: {
    client: totals(48210, 182345678, 9876543, 1234.5678, 17),
    optimizer: totals(3127, 1985000, 187640, null, 3127),
    exact_cache_hits: 412,
    decisions_by_status: { suggested: 1840, abstained: 1175, observed: 112, engine_unavailable: 3 },
  },
  tasks: [
    { task_id: "task-1", title: "Synthetic task with a deliberately long title that must truncate instead of pushing the row wider than its panel", status: "success", started_at: "2026-09-19T10:00:00Z",
      aggregate: { events: 42, client: totals(40, 120000, 8000, 0.42, 1), optimizer: totals(2, 1252, 120, null, 2) } },
    { task_id: "task-2", title: "Short task", status: "unknown", started_at: "2026-09-19T11:00:00Z", aggregate: { events: 1, client: {}, optimizer: {} } },
  ],
};
const empty = { projects: populated.projects, tasks: [], aggregate: {} };
let summary = populated;

function json(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
  response.end(body);
}

const unexpected = [];
const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  if (assets.has(url.pathname)) {
    const [type, body] = assets.get(url.pathname);
    response.writeHead(200, { "Content-Type": type });
    return response.end(body);
  }
  let raw = "";
  request.on("data", (chunk) => { raw += chunk; });
  request.on("end", () => {
    const body = raw ? JSON.parse(raw) : {};
    if (url.pathname === "/api/optimizer/keys") return json(response, 200, { keys: [{ name: "jev-fixture", provider: "typesafe", label: "TypeSafe", model_id: "typesafe-ai/jev", features: ["evaluation"] }], providers: [{ id: "typesafe", available: true }] });
    if (url.pathname === "/api/optimizer/status") return json(response, 200, { unlocked: false, capabilities: {} });
    if (url.pathname === "/api/optimizer/unlock") return json(response, 200, { token: "kso_layout_fixture", expires_at: "2099-01-01T00:00:00Z" });
    if (url.pathname === "/api/optimizer/lock" || url.pathname === "/api/optimizer/close") return json(response, 200, { locked: true, closed: true });
    if (url.pathname === "/api/optimizer/rpc") {
      if (body.operation === "summary") return json(response, 200, summary);
      if (body.operation === "entry_list") return json(response, 200, { entries: [] });
      if (body.operation === "candidate_list") return json(response, 200, { candidates: [] });
      unexpected.push(body.operation);
      return json(response, 400, { error: "unexpected_fixture_operation" });
    }
    if (url.pathname === "/api/keys") return json(response, 200, { keys: [] });
    if (url.pathname === "/api/grants") return json(response, 200, { grants: [], clients: [] });
    if (url.pathname === "/api/status") return json(response, 200, { plans: [] });
    if (url.pathname.startsWith("/api/analytics")) return json(response, 200, { enabled: false, configured: false, consent_version: 1, pending_events: 0 });
    if (url.pathname.startsWith("/api/")) return json(response, 200, { models: [], daily: [], totals: {}, keys: [] });
    json(response, 404, { error: "not found" });
  });
});

// Runs in the page. Returns a list of human-readable geometry violations.
function measure(expectedColumns) {
  const problems = [];
  const box = (node) => { const r = node.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height }; };
  const stacked = (container, selectors, name) => {
    const parent = box(container);
    const parts = selectors.map((selector) => container.querySelector(selector));
    if (parts.some((part) => !part)) return problems.push(`${name}: missing child`);
    const boxes = parts.map(box);
    boxes.forEach((child, index) => {
      if (child.height < 8 || child.width < 8) problems.push(`${name}: child ${selectors[index]} collapsed`);
      if (child.left < parent.left - 0.5 || child.right > parent.right + 0.5) problems.push(`${name}: child ${selectors[index]} escapes horizontally`);
      if (Math.abs(child.left - boxes[0].left) > 0.5) problems.push(`${name}: child ${selectors[index]} not left aligned`);
      if (index > 0 && child.top < boxes[index - 1].bottom - 0.5) problems.push(`${name}: ${selectors[index]} shares a line with ${selectors[index - 1]}`);
    });
    // Each text child must wrap inside its own box rather than spill over a neighbour.
    parts.forEach((part, index) => { if (part.scrollWidth > part.clientWidth + 1) problems.push(`${name}: ${selectors[index]} text overflows`); });
  };
  const grid = (selector, itemSelector, columns, name) => {
    const items = [...document.querySelectorAll(`${selector} > ${itemSelector}`)];
    if (!items.length) return problems.push(`${name}: no items`);
    const boxes = items.map(box);
    const firstRow = boxes.filter((item) => Math.abs(item.top - boxes[0].top) < 1).length;
    if (firstRow !== columns) problems.push(`${name}: expected ${columns} columns, found ${firstRow}`);
    boxes.forEach((a, i) => boxes.forEach((b, j) => {
      if (i < j && a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5) problems.push(`${name}: items ${i} and ${j} overlap`);
    }));
    boxes.forEach((item, i) => { if (item.left < -0.5 || item.right > document.documentElement.clientWidth + 0.5) problems.push(`${name}: item ${i} outside viewport`); });
    return items;
  };
  const cards = grid("#optimizer-summary-cards", ".optimizer-card", expectedColumns.cards, "summary cards") || [];
  if (cards.length !== 4) problems.push(`summary cards: expected 4, found ${cards.length}`);
  cards.forEach((card, index) => {
    stacked(card, [".optimizer-card-label", ".optimizer-card-value", ".optimizer-card-note"], `card ${index}`);
    const gap = card.querySelector(".optimizer-card-value").getBoundingClientRect().top - card.querySelector(".optimizer-card-label").getBoundingClientRect().bottom;
    if (gap < 2 || gap > 12) problems.push(`card ${index}: label/value gap ${gap.toFixed(1)}px outside 2-12px`);
  });
  const rows = grid("#optimizer-accounting", ".optimizer-accounting-row", expectedColumns.accounting, "accounting") || [];
  rows.forEach((row, index) => stacked(row, [".optimizer-accounting-label", ".optimizer-accounting-value"], `accounting ${index}`));
  for (const row of document.querySelectorAll("#optimizer-activity .optimizer-row")) {
    const limit = document.getElementById("optimizer-activity").getBoundingClientRect().right + 0.5;
    if (row.getBoundingClientRect().right > limit) problems.push("activity row wider than its list");
  }
  const pane = document.documentElement;
  if (pane.scrollWidth > pane.clientWidth + 1) problems.push(`page scrolls horizontally: ${pane.scrollWidth} > ${pane.clientWidth}`);
  return problems;
}

const viewports = [
  { name: "desktop", width: 1280, height: 900, columns: { cards: 4, accounting: 4 } },
  { name: "tablet", width: 820, height: 1000, columns: { cards: 2, accounting: 2 } },
  { name: "mobile", width: 390, height: 844, columns: { cards: 2, accounting: 2 } },
  { name: "narrow", width: 320, height: 640, columns: { cards: 2, accounting: 2 } },
];

(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  fs.mkdirSync(screenshotDir, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const pageErrors = [];
  try {
    for (const viewport of viewports) {
      const page = await browser.newPage({ viewport: { width: viewport.width, height: viewport.height } });
      page.on("pageerror", (error) => pageErrors.push(error.message));
      summary = populated;
      await page.goto(`http://127.0.0.1:${server.address().port}/`);
      await page.waitForLoadState("networkidle");
      await page.getByRole("tab", { name: "Optimizer" }).click();
      await page.locator("#optimizer-jev-key").selectOption("jev-fixture");
      await page.getByRole("button", { name: "Unlock with Touch ID" }).click();
      await page.locator("#optimizer-summary-cards .optimizer-card").first().waitFor();
      await page.waitForLoadState("networkidle");

      assert.deepEqual(await page.evaluate(measure, viewport.columns), [], `${viewport.name} populated geometry`);
      const texts = await page.locator("#optimizer-summary-cards .optimizer-card").evaluateAll((cards) => cards.map((card) => [...card.children].map((child) => child.textContent)));
      assert.deepEqual(texts[0], ["Tasks", "1,284", "Recorded task identities"]);
      assert.deepEqual(texts[3], ["Measured savings", "Unknown", "Comparison evidence required"]);
      await page.screenshot({ path: path.join(screenshotDir, `optimizer-overview-${viewport.name}-populated.png`), fullPage: true });

      // The state in the defect report: zero tasks and unknown savings.
      summary = empty;
      await page.reload();
      await page.waitForLoadState("networkidle");
      await page.getByRole("tab", { name: "Optimizer" }).click();
      await page.locator("#optimizer-jev-key").selectOption("jev-fixture");
      await page.getByRole("button", { name: "Unlock with Touch ID" }).click();
      await page.locator("#optimizer-summary-cards .optimizer-card").first().waitFor();
      await page.waitForLoadState("networkidle");
      assert.deepEqual(await page.evaluate(measure, viewport.columns), [], `${viewport.name} empty geometry`);
      await page.locator("#optimizer-summary-cards").screenshot({ path: path.join(screenshotDir, `optimizer-cards-${viewport.name}-empty.png`) });

      // Negative control: with the pre-fix inline children the same measurement must fail,
      // otherwise this test could not have caught "Tasks0Recorded task identities".
      await page.addStyleTag({ content: ".optimizer-card-label, .optimizer-card-value, .optimizer-card-note { display: inline !important; }" });
      const broken = await page.evaluate(measure, viewport.columns);
      assert(broken.some((problem) => /shares a line/.test(problem)), `${viewport.name}: inline children must be detected`);
      await page.close();
    }
    assert.deepEqual(unexpected, [], "fixture saw unexpected optimizer operations");
    assert.deepEqual(pageErrors, [], "page errors");
    console.log(`Optimizer layout UI passed at ${viewports.map((item) => `${item.width}px`).join(", ")}; screenshots in ${screenshotDir}`);
  } finally {
    await browser.close();
    server.close();
  }
})().catch((error) => { console.error(error); process.exit(1); });
