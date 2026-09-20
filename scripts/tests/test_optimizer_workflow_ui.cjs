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
  ["/styles.css", ["text/css", fs.readFileSync(path.join(root, "Web/styles.css"))]],
  ["/optimizer.css", ["text/css", fs.readFileSync(path.join(root, "Web/optimizer.css"))]],
  ["/providers.json", ["application/json", fs.readFileSync(path.join(root, "Web/providers.json"))]],
]);

let keyMetadataUnavailable = false;
let providerAvailable = true;
let unlockRequests = [];
let reviewRequests = [];
let conflictCandidate2 = true;
let delayProjectA = false;
let lockDelay = 0;
let lockFailure = false;
let closeDelay = 0;
let nextFailure = null;
const sessions = new Set();
const closeRequests = [];
const lockRequests = [];
const rpcRequests = [];
const fixtureErrors = [];
const projects = [
  { id: "project-1", name: "Fixture A", root: "/fixture-a", mode: "suggest", storage_enabled: true, feature_flags: { candidate_capture: true } },
  { id: "project-2", name: "Fixture B", root: "/fixture-b", mode: "suggest", storage_enabled: true, feature_flags: { candidate_capture: true } },
];
const entries = new Map();
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
  if (url.pathname === "/api/optimizer/status") return json(response, 200, { unlocked: sessions.size > 0, capabilities: { candidate_capture: true } });
  if (url.pathname === "/api/optimizer/unlock") return read(request, (body) => {
    unlockRequests.push(body);
    const token = `kso_fixture_${unlockRequests.length}`;
    sessions.add(token);
    json(response, 200, { token, expires_at: "2099-01-01T00:00:00Z" });
  });
  if (url.pathname === "/api/optimizer/lock") return read(request, () => {
    lockRequests.push(request.headers["x-ksf-optimizer"]);
    const finish = () => {
      if (lockFailure) { lockFailure = false; return json(response, 503, { error: "unavailable" }); }
      sessions.clear();
      json(response, 200, { locked: true });
    };
    return lockDelay ? setTimeout(finish, lockDelay) : finish();
  });
  if (url.pathname === "/api/optimizer/close") return read(request, () => {
    const token = request.headers["x-ksf-optimizer"];
    closeRequests.push(token);
    const finish = () => { sessions.delete(token); json(response, 200, { closed: true }); };
    return closeDelay ? setTimeout(finish, closeDelay) : finish();
  });
  if (url.pathname === "/api/optimizer/rpc") return read(request, ({ operation, payload }) => {
    const token = request.headers["x-ksf-optimizer"];
    rpcRequests.push({ operation, payload, token });
    if (!sessions.has(token)) return json(response, 403, { error: "optimizer_locked" });
    if (nextFailure && nextFailure.operation === operation) {
      const failure = nextFailure;
      nextFailure = null;
      const finish = () => json(response, failure.status || 403, { error: failure.error, message: failure.message });
      return failure.delay ? setTimeout(finish, failure.delay) : finish();
    }
    const invalid = (message) => json(response, 400, { error: "invalid_optimizer_request", message });
    for (const field of ["id", "query", "source", "expires_at"]) {
      if (Object.hasOwn(payload, field) && (typeof payload[field] !== "string" || !payload[field].trim())) return invalid(`invalid ${field}`);
    }
    if (operation === "summary") return json(response, 200, { projects, tasks: [], aggregate: {} });
    if (operation === "project_save") {
      if (!payload.name || !payload.root || !Number.isInteger(payload.retention_days)) return invalid("missing project fields");
      if (payload.id && !projects.some((item) => item.id === payload.id)) return json(response, 404, { error: "not_found" });
      const project = { ...payload, id: payload.id || `project-${projects.length + 1}` };
      if (payload.id) projects[projects.findIndex((item) => item.id === payload.id)] = project;
      else projects.push(project);
      return json(response, 200, { project });
    }
    if (operation === "entry_list") return json(response, 200, { entries: [...entries.values()].filter((item) => item.project_id === payload.project_id && (!payload.query || item.title.toLowerCase().includes(payload.query.toLowerCase()))) });
    if (operation === "entry_save") {
      if (!projects.find((item) => item.id === payload.project_id)?.storage_enabled) return json(response, 403, { error: "optimizer_access_denied", message: "Storage is disabled for this project." });
      if (!payload.title || !payload.content || !["plan", "memory"].includes(payload.kind)) return invalid("missing entry fields");
      if (payload.kind === "plan" && (!payload.source || !payload.verification?.length)) return invalid("plans require source and verification");
      const entry = { ...payload, id: payload.id || `entry-${entries.size + 1}` };
      entries.set(entry.id, entry);
      return json(response, 200, { entry });
    }
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
      if (entries.has(payload.id)) return json(response, 200, { entry: entries.get(payload.id) });
      const item = pending.find((candidate) => candidate.id === payload.id) || { id: payload.id, title: "Reviewed" };
      return json(response, 200, { entry: { ...item, content: "Inspect source, make the narrow repair, and run tests.", source: "task capture", captured_from_task_id: "task-9", verification: ["tests passed"], constraints: ["Only after parser verification", "<script>must stay text</script>"], required_tools: ["read", "run-tests"], dependencies: { "src/parser.ts": "sha256:fixture" }, tags: ["parser", "verified"], expires_at: "2099-10-12T00:00:00Z" } });
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
    fixtureErrors.push(`Unexpected optimizer operation: ${operation}`);
    return json(response, 400, { error: "unexpected_fixture_operation" });
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
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  const lastPayload = (operation) => rpcRequests.filter((item) => item.operation === operation).at(-1).payload;
  const withRPC = (operation, action) => Promise.all([
    page.waitForResponse((response) => response.url().endsWith("/rpc") && response.request().postDataJSON().operation === operation),
    action(),
  ]);
  const assertUnlocked = async () => {
    await page.waitForLoadState("networkidle");
    assert.equal(await page.locator("#optimizer-locked").isHidden(), true);
    assert.equal(await page.locator("#optimizer-content").isVisible(), true);
  };
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
    assert.equal(await page.locator("#optimizer-locked").isVisible(), true);
    assert.equal(await page.locator("#optimizer-content").isHidden(), true);
    await page.locator("#optimizer-jev-key").selectOption("jev-prod");
    await page.getByRole("button", { name: "Unlock with Touch ID" }).click();
    await page.locator("#optimizer-content").waitFor();
    await page.waitForFunction(() => !document.getElementById("optimizer-entries").textContent.includes("Loading"));
    await assertUnlocked();
    assert.deepEqual(lastPayload("entry_list"), { project_id: "project-1", include_archived: false });
    await page.getByRole("tab", { name: "Projects" }).click();
    await page.locator('#optimizer-view-projects [data-action="new-project"]').click();
    assert.equal(await page.locator('#optimizer-project-dialog input[name="feature_candidate_capture"]').isChecked(), false);
    assert.match(await page.locator("#optimizer-project-dialog").textContent(), /permanently deletes entries.*including pinned entries/i);
    await page.locator('#optimizer-project-dialog [name="name"]').fill("Created in browser");
    await page.locator('#optimizer-project-dialog [name="root"]').fill("/browser-fixture");
    await page.getByRole("button", { name: "Create project", exact: true }).click();
    await page.locator("#optimizer-project-dialog").waitFor({ state: "hidden" });
    assert.deepEqual(lastPayload("project_save"), {
      name: "Created in browser", root: "/browser-fixture", mode: "off", storage_enabled: false, provider_enabled: false,
      feature_flags: { memory_retrieval: true, plan_reuse: true, tool_selection: true, model_routing: true, memory_assessment: true, candidate_capture: false },
      retention_days: 30, max_requests: 1000, max_input_tokens: 1000000,
    });
    const createdProject = page.locator('#optimizer-projects [data-project-id="project-3"]');
    await createdProject.getByRole("button", { name: "Entries", exact: true }).click();
    await page.locator('#optimizer-view-library [data-action="new-entry"]').click();
    const entryForm = page.locator("#optimizer-entry-detail form");
    await entryForm.locator('[name="title"]').fill("Browser memory");
    await entryForm.locator('[name="content"]').fill("Saved from the real form.");
    await entryForm.locator('[name="source"]').fill("   ");
    await entryForm.getByRole("button", { name: "Save", exact: true }).click();
    await page.waitForFunction(() => document.getElementById("optimizer-alert").textContent.includes("Storage is disabled"));
    await assertUnlocked();
    assert.equal(await entryForm.locator('[name="content"]').inputValue(), "Saved from the real form.");
    assert.equal(closeRequests.length, 0, "policy refusals must preserve the live session");
    assert.equal(unlockRequests.length, 1);
    await page.getByRole("tab", { name: "Projects" }).click();
    await createdProject.getByRole("button", { name: "Edit", exact: true }).click();
    await page.locator('#optimizer-project-dialog [name="storage_enabled"]').check();
    await page.getByRole("button", { name: "Save changes", exact: true }).click();
    await page.locator("#optimizer-project-dialog").waitFor({ state: "hidden" });
    assert.equal(lastPayload("project_save").id, "project-3");
    assert.equal(lastPayload("project_save").storage_enabled, true);
    await createdProject.getByRole("button", { name: "Entries", exact: true }).click();
    await page.locator('#optimizer-view-library [data-action="new-entry"]').click();
    await entryForm.locator('[name="title"]').fill("Browser memory");
    await entryForm.locator('[name="content"]').fill("Saved from the real form.");
    await entryForm.getByRole("button", { name: "Save", exact: true }).click();
    await page.locator("#optimizer-entries").getByText("Browser memory", { exact: true }).waitFor();
    const emptyOptionalEntry = { project_id: "project-3", kind: "memory", title: "Browser memory", content: "Saved from the real form.", tags: [], constraints: [], required_tools: [], dependencies: {}, verification: [], pinned: false };
    assert.deepEqual(lastPayload("entry_save"), emptyOptionalEntry);
    await page.locator("#optimizer-entries").getByText("Browser memory", { exact: true }).click();
    await entryForm.locator('[name="kind"]').selectOption("plan");
    await entryForm.getByRole("button", { name: "Save", exact: true }).click();
    await page.waitForFunction(() => document.getElementById("optimizer-alert").textContent.includes("plans require source and verification"));
    await assertUnlocked();
    assert.equal(await entryForm.locator('[name="kind"]').inputValue(), "plan");
    await entryForm.locator('[name="source"]').fill("  user notes  ");
    await entryForm.locator('[name="expires_at"]').fill("2099-10-12");
    await entryForm.locator('[name="tags"]').fill("parser, verified");
    await entryForm.locator('[name="constraints"]').fill("Narrow repair\nRun offline");
    await entryForm.locator('[name="required_tools"]').fill("read, run-tests");
    await entryForm.locator('[name="dependencies"]').fill('{"src/parser.ts":"sha256:fixture"}');
    await entryForm.locator('[name="verification"]').fill("tests passed");
    await entryForm.locator('[name="pinned"]').check();
    await entryForm.getByRole("button", { name: "Save", exact: true }).click();
    await page.waitForFunction(() => document.querySelector('#optimizer-entry-detail [name="source"]')?.value === "user notes");
    assert.deepEqual(lastPayload("entry_save"), { ...emptyOptionalEntry, id: "entry-1", kind: "plan", source: "user notes", expires_at: "2099-10-12T00:00:00Z", tags: ["parser", "verified"], constraints: ["Narrow repair", "Run offline"], required_tools: ["read", "run-tests"], dependencies: { "src/parser.ts": "sha256:fixture" }, verification: ["tests passed"], pinned: true });
    await entryForm.locator('[name="kind"]').selectOption("memory");
    await entryForm.locator('[name="source"]').fill("");
    await entryForm.locator('[name="expires_at"]').fill("");
    await withRPC("entry_get", () => entryForm.getByRole("button", { name: "Save", exact: true }).click());
    assert.equal(Object.hasOwn(lastPayload("entry_save"), "source"), false, "clearing Source omits the optional field on replacement");
    assert.equal(Object.hasOwn(lastPayload("entry_save"), "expires_at"), false, "clearing expiry omits the optional field on replacement");
    assert.equal(await entryForm.locator('[name="source"]').inputValue(), "");
    assert.equal(await entryForm.locator('[name="expires_at"]').inputValue(), "");
    assert.equal(entries.get("entry-1").source, undefined);
    assert.equal(entries.get("entry-1").expires_at, undefined);
    await withRPC("entry_list", () => page.locator("#optimizer-entry-query").fill("  memory  "));
    assert.equal(lastPayload("entry_list").query, "memory");
    await withRPC("entry_list", () => page.locator("#optimizer-entry-query").fill("   "));
    assert.equal(Object.hasOwn(lastPayload("entry_list"), "query"), false);
    await page.getByRole("tab", { name: "Memory & plans" }).click();
    await page.locator("#optimizer-entry-project").selectOption("project-1");
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
    await page.locator(".optimizer-candidate-metadata").waitFor();
    const metadata = await page.locator(".optimizer-candidate-metadata").innerText();
    for (const value of ["Constraints", "Only after parser verification", "<script>must stay text</script>", "Required tools", "run-tests", "Dependencies", "src/parser.ts: sha256:fixture", "Tags", "verified", "Expires", "2099"]) assert(metadata.includes(value), `candidate applicability missing ${value}`);
    assert.equal(await page.locator(".optimizer-candidate-metadata script").count(), 0);
    nextFailure = { operation: "candidate_review", error: "optimizer_access_denied", message: "Candidate review is not permitted for this session." };
    await page.getByRole("button", { name: "Approve for reuse" }).click();
    await page.waitForFunction(() => document.getElementById("optimizer-alert").textContent.includes("not permitted"));
    await assertUnlocked();
    assert.equal(await page.getByRole("button", { name: "Approve for reuse" }).isVisible(), true);
    assert.equal(closeRequests.length, 0, "capability refusals must preserve the live session");
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
    lockDelay = 150;
    await page.locator("#optimizer-lock").click();
    assert.equal(await page.locator("#optimizer-content").isHidden(), true, "lock hides content before waiting for the server");
    assert.equal(await page.locator("#optimizer-unlock").isDisabled(), true, "a global lock must finish before a new unlock");
    await page.waitForTimeout(300);
    assert.equal(await page.locator("#optimizer-locked").isVisible(), true);
    assert.equal(await page.locator("#optimizer-content").isHidden(), true);
    assert.doesNotMatch(await page.locator("#optimizer-alert").textContent(), /approved for reuse/i);
    assert.deepEqual(reviewRequests[2], { project_id: "project-1", id: "candidate-2", decision: "approve", expected_version: 7 });
    assert.deepEqual(lockRequests, ["kso_fixture_1"]);
    assert.equal(closeRequests.length, 0, "successful global lock already revokes the old session");
    lockDelay = 0;
    await page.getByRole("button", { name: "Unlock with Touch ID" }).click();
    await page.locator("#optimizer-content").waitFor();
    await assertUnlocked();
    closeDelay = 250;
    nextFailure = { operation: "entry_list", error: "optimizer_locked" };
    await page.locator("#optimizer-entry-query").fill("expired");
    await page.locator("#optimizer-content").waitFor({ state: "hidden" });
    assert.equal(await page.locator("#optimizer-locked").isVisible(), true);
    await page.getByRole("button", { name: "Unlock with Touch ID" }).click();
    await page.locator("#optimizer-content").waitFor();
    await page.waitForTimeout(300);
    await assertUnlocked();
    assert.deepEqual(closeRequests, ["kso_fixture_2"], "late cleanup must close only the discarded session");
    assert.equal(sessions.has("kso_fixture_3"), true);
    closeDelay = 0;
    nextFailure = { operation: "entry_list", error: "optimizer_locked", delay: 300 };
    await Promise.all([
      page.waitForRequest((request) => request.url().endsWith("/rpc") && request.postDataJSON().operation === "entry_list"),
      page.locator("#optimizer-entry-query").fill("stale"),
    ]);
    await page.locator("#optimizer-lock").click();
    await page.getByRole("button", { name: "Unlock with Touch ID" }).click();
    await page.locator("#optimizer-content").waitFor();
    await page.waitForTimeout(350);
    await assertUnlocked();
    assert.deepEqual(closeRequests, ["kso_fixture_2"], "an old RPC refusal must not close a new session");
    assert.equal(sessions.has("kso_fixture_4"), true);
    lockFailure = true;
    await page.locator("#optimizer-lock").click();
    await page.waitForFunction(() => !document.getElementById("optimizer-unlock").disabled);
    assert.deepEqual(closeRequests, ["kso_fixture_2", "kso_fixture_4"], "failed global lock closes the captured old capability");
    assert.equal(sessions.size, 0);
    assert.deepEqual(fixtureErrors, []);
    assert.deepEqual(pageErrors, []);
    console.log("Optimizer workflow UI passed: real form payloads, policy denials, candidate metadata, hidden state, and session cleanup races.");
  } finally {
    await browser.close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
