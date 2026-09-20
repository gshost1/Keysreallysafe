#!/usr/bin/env node
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require("playwright");

const root = path.resolve(__dirname, "../..");
const assets = new Map([
  ["/", ["text/html; charset=utf-8", fs.readFileSync(path.join(root, "Web/index.html"), "utf8").replace("<head>", '<head><meta name="ksf-token" content="test-token">')]],
  ["/app.js", ["application/javascript", fs.readFileSync(path.join(root, "Web/app.js"))]],
  ["/optimizer.js", ["application/javascript", fs.readFileSync(path.join(root, "Web/optimizer.js"))]],
  ["/analytics.js", ["application/javascript", ""]],
  ["/style.css", ["text/css", ""]],
  ["/optimizer.css", ["text/css", fs.readFileSync(path.join(root, "Web/optimizer.css"))]],
  ["/providers.json", ["application/json", fs.readFileSync(path.join(root, "Web/providers.json"))]],
]);

let keyMetadataUnavailable = false;
let providerAvailable = true;
let unlockRequests = [];
let reviewRequests = [];
let conflictCandidate2 = true;
let delayProjectA = false;
let pending = [
  { id: "candidate-1", kind: "plan", title: "Checked parser plan", review_state: "pending", version: 3 },
  { id: "candidate-2", kind: "memory", title: "Race candidate", review_state: "pending", version: 7 },
];

function json(response, status, value) {
  response.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(JSON.stringify(value)) });
  response.end(JSON.stringify(value));
}

function read(request, callback) {
  let body = "";
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => callback(body ? JSON.parse(body) : {}));
}

const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  if (assets.has(url.pathname)) {
    const [type, body] = assets.get(url.pathname);
    response.writeHead(200, { "Content-Type": type });
    return response.end(body);
  }
  if (url.pathname === "/api/optimizer/keys") {
    if (keyMetadataUnavailable) return json(response, 503, { error: "unavailable" });
    return json(response, 200, {
      keys: [
        { name: "jev-prod", provider: "typesafe", label: "TypeSafe", model_id: "typesafe-ai/jev", features: ["evaluation"] },
        { name: "jev-stage", provider: "typesafe", label: "TypeSafe", model_id: "typesafe-ai/jev", features: ["evaluation"] },
        { name: "plain-key", provider: "openai", label: "Plain key", features: ["chat"] },
        { name: { malformed: true }, provider: "typesafe", label: "Malformed", features: ["evaluation"] },
      ],
      providers: [{ id: "typesafe", available: providerAvailable }],
    });
  }
  if (url.pathname === "/api/keys") {
    return json(response, 200, { keys: [
      { name: "jev-prod", provider: "typesafe", kind: "runtime", created_at: "2026-09-19T00:00:00Z" },
      { name: "jev-stage", provider: "typesafe", kind: "runtime", created_at: "2026-09-19T00:00:00Z" },
      { name: "plain-key", provider: "openai", kind: "runtime", created_at: "2026-09-19T00:00:00Z" },
    ] });
  }
  if (url.pathname === "/api/optimizer/status") return json(response, 200, { unlocked: false, capabilities: { candidate_capture: true } });
  if (url.pathname === "/api/optimizer/unlock") return read(request, (body) => {
    unlockRequests.push(body);
    json(response, 200, { token: "kso_fixture", expires_at: "2099-01-01T00:00:00Z" });
  });
  if (url.pathname === "/api/optimizer/lock") return read(request, () => json(response, 200, { locked: true }));
  if (url.pathname === "/api/optimizer/rpc") return read(request, ({ operation, payload }) => {
    if (operation === "summary") return json(response, 200, { projects: [
      { id: "project-1", name: "Fixture A", root: "/fixture-a", mode: "suggest", feature_flags: { candidate_capture: true } },
      { id: "project-2", name: "Fixture B", root: "/fixture-b", mode: "suggest", feature_flags: { candidate_capture: true } },
    ], tasks: [], aggregate: {} });
    if (operation === "entry_list") return json(response, 200, { entries: [] });
    if (operation === "candidate_list") {
      const candidates = payload.review_state !== "pending" ? [] : payload.project_id === "project-2"
        ? [{ id: "candidate-b", kind: "plan", title: "Project B candidate", review_state: "pending", version: 1 }]
        : pending;
      if (payload.project_id === "project-1" && delayProjectA) {
        delayProjectA = false;
        return setTimeout(() => json(response, 200, { candidates }), 200);
      }
      return json(response, 200, { candidates });
    }
    if (operation === "entry_get") {
      const item = pending.find((candidate) => candidate.id === payload.id) || { id: payload.id, title: "Reviewed" };
      return json(response, 200, { entry: { ...item, content: "Inspect source, make the narrow repair, and run tests.", source: "task capture", captured_from_task_id: "task-9", verification: ["tests passed"] } });
    }
    if (operation === "candidate_review") {
      reviewRequests.push(payload);
      if (payload.id === "candidate-2" && conflictCandidate2) {
        conflictCandidate2 = false;
        return json(response, 409, { error: "candidate changed" });
      }
      const finish = () => {
        pending = pending.filter((candidate) => candidate.id !== payload.id);
        json(response, 200, { id: payload.id, review_state: payload.decision === "approve" ? "approved" : "rejected", version: payload.expected_version + 1 });
      };
      return payload.id === "candidate-2" ? setTimeout(finish, 200) : finish();
    }
    return json(response, 200, {});
  });
  if (url.pathname === "/api/grants") return json(response, 200, { grants: [], clients: [] });
  if (url.pathname === "/api/status") return json(response, 200, { plans: [] });
  if (url.pathname.startsWith("/api/analytics")) return json(response, 200, { enabled: false, configured: false, consent_version: 1, pending_events: 0 });
  if (url.pathname.startsWith("/api/")) return json(response, 200, { models: [], daily: [], totals: {}, keys: [] });
  json(response, 404, { error: "not found" });
});

(async () => {
  const catalog = JSON.parse(fs.readFileSync(path.join(root, "Web/providers.json"), "utf8"));
  assert.deepEqual(catalog.providers.find((provider) => provider.id === "typesafe"), {
    id: "typesafe", name: "TypeSafe", group: "labs", host: "api.typesafe.ai", api: "typesafe-systemone",
    auth_header: "Authorization", auth_prefix: "Bearer ", path_prefix: "", key_prefix: null,
    usage_endpoint: null, docs: null, gateway: true, note: "SystemOne evaluation API",
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.waitForLoadState("networkidle");
    await page.getByRole("tab", { name: "Keys" }).click();
    const optimizerButton = page.locator('tr[data-name="jev-prod"] [data-act="optimizer"]');
    await optimizerButton.waitFor();
    assert.equal(await page.locator('tr[data-name="plain-key"] [data-act="optimizer"]').count(), 0);
    await optimizerButton.click();
    await page.waitForFunction(() => document.getElementById("optimizer-jev-key").value === "jev-prod");
    assert.equal(unlockRequests.length, 0, "preselection must not unlock");
    assert.match(await page.locator("#optimizer-key-state").textContent(), /never unlocks automatically/i);
    const optionText = await page.locator("#optimizer-jev-key option").allTextContents();
    assert(optionText.some((value) => value.startsWith("jev-prod · TypeSafe")));
    assert(optionText.some((value) => value.startsWith("jev-stage · TypeSafe")));
    assert.notEqual(optionText.find((value) => value.startsWith("jev-prod")), optionText.find((value) => value.startsWith("jev-stage")));
    await page.evaluate(() => window.optimizerPreselectKey({ malformed: true }));
    await page.waitForTimeout(50);
    assert.equal(await page.locator("#optimizer-jev-key").inputValue(), "");

    providerAvailable = false;
    await page.reload();
    await page.waitForLoadState("networkidle");
    await page.getByRole("tab", { name: "Optimizer" }).click();
    await page.waitForFunction(() => document.getElementById("optimizer-key-state").textContent.includes("provider is currently unavailable"));
    assert.equal(await page.locator("#optimizer-jev-key option").count(), 1);

    providerAvailable = true;
    keyMetadataUnavailable = true;
    await page.reload();
    await page.waitForLoadState("networkidle");
    await page.getByRole("tab", { name: "Optimizer" }).click();
    await page.waitForFunction(() => document.getElementById("optimizer-key-state").textContent.includes("unavailable"));
    assert.equal(await page.locator("#optimizer-jev-key").inputValue(), "");
    assert.equal(await page.locator("#optimizer-jev-key option").count(), 1);

    keyMetadataUnavailable = false;
    await page.reload();
    await page.waitForLoadState("networkidle");
    await page.getByRole("tab", { name: "Optimizer" }).click();
    await page.locator("#optimizer-jev-key").selectOption("jev-prod");
    await page.getByRole("button", { name: "Unlock with Touch ID" }).click();
    await page.getByRole("tab", { name: "Projects" }).click();
    await page.locator('#optimizer-view-projects [data-action="new-project"]').click();
    assert.equal(await page.locator('#optimizer-project-dialog input[name="feature_candidate_capture"]').isChecked(), false);
    await page.locator('#optimizer-project-dialog button', { hasText: "Cancel" }).click();
    await page.getByRole("tab", { name: "Memory & plans" }).click();
    delayProjectA = true;
    await page.locator("#optimizer-candidate-refresh").click();
    await page.locator("#optimizer-entry-project").selectOption("project-2");
    await page.locator('[data-candidate-id="candidate-b"]').waitFor();
    await page.waitForTimeout(250);
    assert.equal(await page.locator('[data-candidate-id="candidate-b"]').count(), 1);
    assert.equal(await page.locator('[data-candidate-id="candidate-1"]').count(), 0, "late project A response must not overwrite project B");
    await page.locator("#optimizer-entry-project").selectOption("project-1");
    await page.locator('[data-candidate-id="candidate-1"]').waitFor();
    await page.locator('[data-candidate-id="candidate-1"]').click();
    await page.getByRole("button", { name: "Approve for reuse" }).click();
    await page.waitForFunction(() => !document.querySelector('[data-candidate-id="candidate-1"]'));
    assert.deepEqual(reviewRequests[0], { project_id: "project-1", id: "candidate-1", decision: "approve", expected_version: 3 });
    assert.equal(unlockRequests.at(-1).jev_key, "jev-prod");

    await page.locator('[data-candidate-id="candidate-2"]').click();
    await page.locator("#optimizer-alert").evaluate((node) => { node.textContent = ""; node.hidden = true; });
    await page.getByRole("button", { name: "Approve for reuse" }).click();
    await page.waitForFunction(() => document.getElementById("optimizer-alert").textContent.includes("changed while it was open"));
    assert.equal(await page.locator('[data-candidate-id="candidate-2"]').count(), 1);
    assert.deepEqual(reviewRequests[1], { project_id: "project-1", id: "candidate-2", decision: "approve", expected_version: 7 });
    await page.locator('[data-candidate-id="candidate-2"]').click();
    await page.locator("#optimizer-alert").evaluate((node) => { node.textContent = ""; node.hidden = true; });
    await page.getByRole("button", { name: "Approve for reuse" }).click();
    await page.locator("#optimizer-lock").click();
    await page.waitForTimeout(300);
    assert.equal(await page.locator("#optimizer-locked").isVisible(), true);
    assert.equal(await page.locator("#optimizer-content").isHidden(), true);
    assert.doesNotMatch(await page.locator("#optimizer-alert").textContent(), /approved for reuse/i);
    assert.deepEqual(reviewRequests[2], { project_id: "project-1", id: "candidate-2", decision: "approve", expected_version: 7 });
  } finally {
    await browser.close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
