#!/usr/bin/env node
// Keys dashboard reliability suite. Loads the real index.html, styles.css and
// app.js in Chromium against a synthetic in-memory fixture server and exercises
// reveal expiry, copy feedback, key CRUD, filtering, failed requests and the
// timing races between them. It never talks to the running Keys app, never
// reaches a vault, and every secret below is invented for the fixture.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require("playwright");

const root = path.resolve(__dirname, "../..");
const screenshotDir = process.env.KEYS_UI_SCREENSHOT_DIR || path.join(root, ".build/keys-ui-screenshots");
const asset = (name) => fs.readFileSync(path.join(root, "Web", name));
const html = asset("index.html").toString("utf8").replace("<head>", '<head><meta name="ksf-token" content="test-token">');
const assets = new Map([
  ["/", ["text/html; charset=utf-8", html]],
  ["/app.js", ["application/javascript", asset("app.js")]],
  ["/optimizer.js", ["application/javascript", asset("optimizer.js")]],
  ["/analytics.js", ["application/javascript", ""]],
  ["/styles.css", ["text/css", asset("styles.css")]],
  ["/optimizer.css", ["text/css", asset("optimizer.css")]],
  ["/providers.json", ["application/json", asset("providers.json")]],
]);

// ---------- fixture state ----------

const SECRET = "sk-fixture-NEVER-REAL-0000000000";
const baseKeys = () => [
  { name: "alpha", provider: "openai", kind: "runtime", created_at: "2026-09-01T10:00:00Z", last_used_at: "2026-09-18T09:00:00Z", checkable: true, notes: "first fixture key" },
  { name: "bravo", provider: "anthropic", kind: "billing", created_at: "2026-09-05T10:00:00Z", last_used_at: null, checkable: false },
  { name: "charlie", provider: "typesafe", kind: "runtime", created_at: "2026-09-09T10:00:00Z", last_used_at: null, checkable: false },
];

let keys, failures, delays, requests, unexpected;

function reset() {
  keys = baseKeys();
  failures = new Map();   // "METHOD /path" -> {status, body} | "drop"
  delays = new Map();     // "METHOD /path" -> milliseconds
  requests = [];
  unexpected = [];
}

const rule = (method, pathname) => `${method} ${pathname}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function json(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
  response.end(body);
}

function handle(method, pathname, body) {
  const keyMatch = /^\/api\/keys\/([^/]+)(\/[a-z]+)?$/.exec(pathname);
  const name = keyMatch ? decodeURIComponent(keyMatch[1]) : null;
  const leaf = keyMatch ? (keyMatch[2] || "") : null;
  const found = () => keys.find((k) => k.name === name);

  if (pathname === "/api/keys" && method === "GET") return [200, { keys }];
  if (pathname === "/api/keys" && method === "POST") {
    if (keys.some((k) => k.name === body.name)) return [409, { error: "already_exists" }];
    keys.push({ name: body.name, provider: body.provider, kind: body.kind, notes: body.notes,
                created_at: "2026-09-20T12:00:00Z", last_used_at: null, checkable: false });
    return [200, { ok: true }];
  }
  if (keyMatch && leaf === "" && method === "DELETE") {
    if (!found()) return [404, { error: "not_found" }];
    keys = keys.filter((k) => k.name !== name);
    return [200, { ok: true }];
  }
  if (keyMatch && leaf === "" && method === "PATCH") {
    const key = found();
    if (!key) return [404, { error: "not_found" }];
    Object.assign(key, body);
    return [200, { ok: true }];
  }
  if (keyMatch && leaf === "/copy") {
    if (!found()) return [404, { error: "not_found" }];
    found().last_used_at = "2026-09-20T12:30:00Z";
    return [200, { wipes_in_s: 20 }];
  }
  if (keyMatch && leaf === "/reveal") {
    if (!found()) return [404, { error: "not_found" }];
    found().last_used_at = "2026-09-20T12:30:00Z";
    return [200, { secret: SECRET }];
  }
  if (keyMatch && leaf === "/rotate") {
    if (!found()) return [404, { error: "not_found" }];
    return [200, { version: 2 }];
  }
  if (keyMatch && leaf === "/events") return [200, { events: [] }];
  if (keyMatch && leaf === "/clients") return [200, { clients: [] }];
  if (pathname === "/api/grants") return [200, { grants: [] }];
  // The Optimizer pane shares this page and boots itself; its own behaviour is
  // covered by test_optimizer_workflow_ui.cjs, so here it only stays quiet.
  if (pathname === "/api/optimizer/keys") return [200, { keys: [], providers: [] }];
  if (pathname === "/api/optimizer/status") return [200, { locked: true }];
  if (pathname === "/api/models") return [200, []];
  if (pathname === "/api/status") return [200, { plans: [] }];
  if (pathname.startsWith("/api/spend")) return [200, { totals: {}, points: [], models: [] }];

  unexpected.push(rule(method, pathname));
  return [404, { error: "not_found" }];
}

const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  if (assets.has(url.pathname)) {
    const [type, body] = assets.get(url.pathname);
    response.writeHead(200, { "Content-Type": type });
    return response.end(body);
  }
  let raw = "";
  request.on("data", (chunk) => { raw += chunk; });
  request.on("end", async () => {
    const method = request.method.toUpperCase();
    const key = rule(method, url.pathname);
    requests.push({ method, pathname: url.pathname, search: url.search, token: request.headers["x-ksf-token"] || null });

    const failure = failures.get(key);
    if (failure === "drop") return request.socket.destroy();
    if (failure && failure.raw !== undefined) {
      response.writeHead(failure.status, { "Content-Type": "text/plain" });
      return response.end(failure.raw);
    }
    if (failure) return json(response, failure.status, failure.body);

    let body = {};
    if (raw) { try { body = JSON.parse(raw); } catch { body = {}; } }
    // The answer is computed now and delivered late, which is how a slow reply
    // carries a view of the vault that has since moved on.
    const [status, value] = handle(method, url.pathname, body);
    const wait = delays.get(key);
    if (wait) await sleep(wait);
    json(response, status, value);
  });
});

// ---------- helpers ----------

const rowNames = (page) => page.locator("#keys-body tr[data-name]:not(.key-events-row)")
  .evaluateAll((rows) => rows.map((row) => row.dataset.name));
const rowCell = (page, name, cell) => page.locator(`#keys-body tr[data-name="${name}"] .td-${cell}`).first();
const rowButton = (page, name, act) => page.locator(`#keys-body tr[data-name="${name}"] [data-act="${act}"]`).first();
const status = (page) => page.locator("#status").textContent();
// A closed <dialog> is not "hidden" in a way a visibility wait can observe, so
// the open flag is read directly.
const dialogOpen = (page, id) => page.locator(`#${id}`).evaluate((node) => node.open);
const waitDialog = (page, id, open) =>
  page.waitForFunction(([name, want]) => document.getElementById(name).open === want, [id, open]);

async function openKeys(page, origin, options = {}) {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Keys" }).click();
  if (!options.expectEmpty) await page.locator('#keys-body tr[data-name="alpha"]').waitFor();
  return page;
}

const checks = [];
const only = process.env.KEYS_UI_ONLY || "";
const test = (name, fn) => { if (!only || name.includes(only)) checks.push({ name, fn }); };

// ---------- key list ----------

test("key list renders every key with its count and no empty state", async (page, origin) => {
  await openKeys(page, origin);
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie"]);
  assert.equal(await page.locator("#keys-count").textContent(), "3 keys");
  assert.equal(await page.locator("#keys-empty").isHidden(), true);
  assert.equal(await page.locator("#keys-table").isVisible(), true);
  assert.equal((await rowCell(page, "bravo", "used").textContent()).trim(), "Never");
});

test("an empty vault shows the empty state and hides the table", async (page, origin) => {
  keys = [];
  await openKeys(page, origin, { expectEmpty: true });
  await page.locator("#keys-empty:visible").waitFor();
  assert.equal(await page.locator("#keys-table").isHidden(), true);
  assert.equal(await page.locator("#keys-count").textContent(), "0 keys");
});

// ---------- reveal and its expiry ----------

test("reveal shows the secret, counts down and auto-hides at expiry", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await rowButton(page, "alpha", "reveal").click();
  await waitDialog(page, "dlg-reveal", true);
  assert.equal(await page.locator("#reveal-secret").textContent(), SECRET);
  assert.equal(await page.locator("#reveal-name").textContent(), "alpha");
  assert.match(await page.locator("#reveal-timer").textContent(), /Hides in 15 s/);

  await page.clock.runFor(5000);
  assert.match(await page.locator("#reveal-timer").textContent(), /Hides in 10 s/);

  // The row's own "Last used" is optimistic, before any reload.
  assert.equal((await rowCell(page, "alpha", "used").textContent()).trim(), "Just now");

  await page.clock.runFor(10000);
  await waitDialog(page, "dlg-reveal", false);
  await page.waitForFunction(() => document.getElementById("reveal-secret").textContent === "", null, { timeout: 5000 });
  assert.equal(await page.locator("#reveal-secret").textContent(), "", "secret must be cleared on close");
  assert.equal(await page.locator("#reveal-timer").textContent(), "");
});

test("hiding the reveal dialog early stops the timer and clears the secret", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await rowButton(page, "alpha", "reveal").click();
  await waitDialog(page, "dlg-reveal", true);
  await page.locator("#dlg-reveal [data-close]").click();
  await waitDialog(page, "dlg-reveal", false);
  // The close event runs in its own task, so wait for the clearing it does.
  await page.waitForFunction(() => document.getElementById("reveal-secret").textContent === "");
  // No timer may survive to reopen or rewrite the dialog.
  await page.clock.runFor(20000);
  assert.equal(await page.locator("#dlg-reveal").evaluate((d) => d.open), false);
  assert.equal(await page.locator("#reveal-timer").textContent(), "");
});

test("a cancelled Touch ID leaves the reveal button usable and says why", async (page, origin) => {
  await openKeys(page, origin);
  failures.set(rule("POST", "/api/keys/alpha/reveal"), { status: 401, body: { error: "auth_cancelled" } });
  await rowButton(page, "alpha", "reveal").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.includes("cancelled"));
  assert.equal(await status(page), "Mac authentication cancelled.");
  assert.equal(await page.locator("#dlg-reveal").evaluate((d) => d.open), false);
  const button = rowButton(page, "alpha", "reveal");
  assert.equal(await button.textContent(), "Reveal");
  assert.equal(await button.isDisabled(), false);
});

// ---------- copy and its feedback ----------

test("copy reports the wipe deadline and refreshes the row afterwards", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await rowButton(page, "bravo", "copy").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Copied"));
  assert.equal(await status(page), "Copied bravo. Clipboard wipes in 20 s.");
  assert.equal(await rowButton(page, "bravo", "copy").textContent(), "Copied");
  assert.equal((await rowCell(page, "bravo", "used").textContent()).trim(), "Just now");

  const before = requests.filter((r) => r.pathname === "/api/keys" && r.method === "GET").length;
  await page.clock.runFor(2600);
  await page.waitForFunction((n) => window.__keyReloads > n, before, { timeout: 5000 }).catch(() => {});
  await page.waitForTimeout(200);
  const after = requests.filter((r) => r.pathname === "/api/keys" && r.method === "GET").length;
  assert.ok(after > before, "the deferred reload must refresh the list");
  assert.equal(await rowButton(page, "bravo", "copy").textContent(), "Copy", "button returns to its resting label");
});

test("a failed copy restores the button and reports the reason", async (page, origin) => {
  await openKeys(page, origin);
  failures.set(rule("POST", "/api/keys/alpha/copy"), { status: 401, body: { error: "auth_failed" } });
  await rowButton(page, "alpha", "copy").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.includes("authentication failed"));
  assert.equal(await rowButton(page, "alpha", "copy").textContent(), "Copy");
  assert.equal(await rowButton(page, "alpha", "copy").isDisabled(), false);
});

test("a copy whose row disappears before the deferred reload does not throw", async (page, origin) => {
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.clock.install();
  await openKeys(page, origin);
  await rowButton(page, "charlie", "copy").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Copied"));
  // The key is removed elsewhere while the 2.5 s reload is still pending.
  keys = keys.filter((k) => k.name !== "charlie");
  await page.clock.runFor(3000);
  await page.waitForTimeout(300);
  assert.deepEqual(await rowNames(page), ["alpha", "bravo"]);
  assert.deepEqual(pageErrors, [], "a stale reload must not raise");
});

// ---------- CRUD ----------

test("add validates locally before it sends anything", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  const sent = requests.filter((r) => r.method === "POST" && r.pathname === "/api/keys").length;

  await page.locator("#add-form [type=submit]").click();
  assert.match(await page.locator("#add-err").textContent(), /^Name:/);

  await page.locator("#add-form [name=name]").fill("delta");
  await page.locator("#add-form [type=submit]").click();
  assert.equal(await page.locator("#add-err").textContent(), "Provider is required.");

  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [type=submit]").click();
  assert.equal(await page.locator("#add-err").textContent(), "Secret is required.");

  assert.equal(requests.filter((r) => r.method === "POST" && r.pathname === "/api/keys").length, sent,
    "no request may leave until the form is valid");
});

test("add creates the key, carries the launch token and selects the new row", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await page.locator("#add-form [name=name]").fill("delta");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SECRET);
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  await page.locator('#keys-body tr[data-name="delta"]').waitFor();
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie", "delta"]);
  assert.equal(await status(page), "Added delta.");
  assert.equal(await page.locator('#keys-body tr[data-name="delta"]').getAttribute("aria-selected"), "true");
  const post = requests.find((r) => r.method === "POST" && r.pathname === "/api/keys");
  assert.equal(post.token, "test-token", "mutations must carry the launch token");
});

test("a duplicate name keeps the add dialog open and explains the conflict", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await page.locator("#add-form [name=name]").fill("alpha");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SECRET);
  await page.locator("#add-form [type=submit]").click();
  await page.waitForFunction(() => document.getElementById("add-err").textContent !== "");
  assert.equal(await page.locator("#add-err").textContent(), "A key with that name already exists.");
  assert.equal(await page.locator("#dlg-add").evaluate((d) => d.open), true);
  assert.equal(await page.locator("#add-form [type=submit]").textContent(), "Add key");
  assert.equal(await page.locator("#add-form [type=submit]").isDisabled(), false);
});

test("the add dialog never leaves a typed secret in the DOM after it closes", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await page.locator("#add-form [name=secret]").fill(SECRET);
  await page.locator("#dlg-add [data-close]").click();
  await waitDialog(page, "dlg-add", false);
  await page.waitForFunction(() => document.getElementById("add-form").elements.secret.value === "");
  assert.equal(await page.locator("#add-form [name=secret]").inputValue(), "");
});

test("edit sends only changed fields and reports a server refusal in the dialog", async (page, origin) => {
  await openKeys(page, origin);
  await rowButton(page, "alpha", "edit").click();
  await waitDialog(page, "dlg-edit", true);

  // Unchanged: the dialog closes without a request.
  const before = requests.filter((r) => r.method === "PATCH").length;
  await page.locator("#edit-form [type=submit]").click();
  await waitDialog(page, "dlg-edit", false);
  assert.equal(requests.filter((r) => r.method === "PATCH").length, before, "an unchanged edit sends nothing");

  failures.set(rule("PATCH", "/api/keys/alpha"), { status: 403, body: { error: "forbidden" } });
  await rowButton(page, "alpha", "edit").click();
  await page.locator("#edit-form [name=notes]").fill("changed");
  await page.locator("#edit-form [type=submit]").click();
  await page.waitForFunction(() => document.getElementById("edit-err").textContent !== "");
  assert.equal(await page.locator("#edit-err").textContent(), "Blocked: request was not same-origin.");
  assert.equal(await page.locator("#dlg-edit").evaluate((d) => d.open), true);
  assert.equal(await page.locator("#edit-form [type=submit]").isDisabled(), false, "the retry must be possible");

  failures.delete(rule("PATCH", "/api/keys/alpha"));
  await page.locator("#edit-form [type=submit]").click();
  await waitDialog(page, "dlg-edit", false);
  assert.equal(await status(page), "Saved alpha.");
  assert.equal((await rowCell(page, "alpha", "name").textContent()).includes("changed"), true);
});

test("delete confirms first, survives a refusal and then removes the row", async (page, origin) => {
  await openKeys(page, origin);
  failures.set(rule("DELETE", "/api/keys/charlie"), { status: 404, body: { error: "not_found" } });
  await rowButton(page, "charlie", "delete").click();
  await waitDialog(page, "dlg-delete", true);
  assert.equal(await page.locator("#delete-name").textContent(), "charlie");

  await page.locator("#delete-confirm").click();
  await page.waitForFunction(() => document.getElementById("delete-err").textContent !== "");
  assert.equal(await page.locator("#delete-err").textContent(), "That key no longer exists.");
  assert.equal(await page.locator("#dlg-delete").evaluate((d) => d.open), true);
  assert.equal(await page.locator("#delete-confirm").isDisabled(), false);
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie"], "nothing is removed optimistically");

  failures.delete(rule("DELETE", "/api/keys/charlie"));
  await page.locator("#delete-confirm").click();
  await waitDialog(page, "dlg-delete", false);
  await page.waitForFunction(() => !document.querySelector('#keys-body tr[data-name="charlie"]'));
  assert.deepEqual(await rowNames(page), ["alpha", "bravo"]);
  assert.equal(await status(page), "Deleted charlie.");
});

test("rotate replaces the secret, reports failure in its own dialog and clears the field", async (page, origin) => {
  await openKeys(page, origin);
  failures.set(rule("POST", "/api/keys/alpha/rotate"), { status: 401, body: { error: "auth_failed" } });
  await rowButton(page, "alpha", "rotate").click();
  await waitDialog(page, "dlg-rotate", true);
  assert.equal(await page.locator("#rotate-name").textContent(), "alpha");

  await page.locator("#rotate-form [name=secret]").fill(SECRET);
  await page.locator("#rotate-form [type=submit]").click();
  await page.waitForFunction(() => document.getElementById("rotate-err").textContent !== "");
  assert.equal(await page.locator("#rotate-err").textContent(), "Mac authentication failed (Touch ID or password not accepted).");
  assert.equal(await dialogOpen(page, "dlg-rotate"), true);

  failures.delete(rule("POST", "/api/keys/alpha/rotate"));
  await page.locator("#rotate-form [type=submit]").click();
  await waitDialog(page, "dlg-rotate", false);
  await page.waitForFunction(() => document.getElementById("rotate-form").elements.secret.value === "");
  assert.equal(await page.locator("#rotate-form [name=secret]").inputValue(), "",
    "a rotated secret must not stay in the form");
  assert.equal(await status(page), "Rotated alpha (version 2).");

  // Cancelling after typing must not leave the new secret behind either.
  await rowButton(page, "alpha", "rotate").click();
  await waitDialog(page, "dlg-rotate", true);
  await page.locator("#rotate-form [name=secret]").fill(SECRET);
  await page.locator("#dlg-rotate [data-close]").click();
  await waitDialog(page, "dlg-rotate", false);
  await page.waitForFunction(() => document.getElementById("rotate-form").elements.secret.value === "");
});

// ---------- filtering ----------

test("range and source chips drive the query, the URL and the group chips", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  assert.equal(await page.locator("#group-chips").isHidden(), true, "grouping is Claude-only");

  await page.getByRole("radio", { name: "This week" }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("range") === "week");
  const weekly = requests.filter((r) => r.pathname === "/api/spend" && r.search.includes("range=week"));
  assert.ok(weekly.length > 0, "the week range must reach the engine");

  await page.getByRole("radio", { name: "Claude", exact: true }).click();
  await page.locator("#group-chips:visible").waitFor();
  await page.getByRole("radio", { name: "Projects" }).click();
  await page.waitForFunction(() => document.querySelector('[data-group="project"]').getAttribute("aria-checked") === "true");
  const grouped = requests.filter((r) => r.pathname === "/api/spend" && r.search.includes("by=project"));
  assert.ok(grouped.length > 0, "grouping by project must reach the engine");

  // Leaving Claude must drop a grouping that no longer applies.
  await page.getByRole("radio", { name: "All", exact: true }).click();
  await page.waitForFunction(() => document.getElementById("group-chips").hidden);
  assert.equal(await page.locator('[data-group="model"]').getAttribute("aria-checked"), "true");
});

test("a key filter shows a clearable chip and leaves the URL clean when removed", async (page, origin) => {
  await page.goto(`${origin}/?key=alpha&range=week`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#key-chip:visible").waitFor();
  assert.match(await page.locator("#key-chip").textContent(), /key · alpha/);
  const filtered = requests.filter((r) => r.pathname === "/api/spend" && r.search.includes("key=alpha"));
  assert.ok(filtered.length > 0, "the key filter must reach the engine");

  await page.locator("#key-chip .chip-clear").click();
  await page.waitForFunction(() => !new URL(location.href).searchParams.get("key"));
  assert.equal(await page.locator("#key-chip").isHidden(), true);
});

test("a chart request that fails leaves a sticky reason and no stale drawing", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  failures.set(rule("GET", "/api/spend"), { status: 503, body: { error: "engine_busy" } });
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.getByRole("radio", { name: "This month" }).click();
  await page.waitForFunction(() => document.getElementById("status").textContent === "engine_busy", null, { polling: 100 });
  await page.waitForTimeout(4500);
  assert.equal(await status(page), "engine_busy", "a failed load must stay reported");

  failures.delete(rule("GET", "/api/spend"));
  await page.getByRole("radio", { name: "This week" }).click();
  await page.waitForFunction(() => document.getElementById("status").textContent !== "engine_busy");
});

// ---------- overlapping loaders ----------

// The key list and the spend series share one status line, and they overlap
// routinely: the startup key load is still in flight when the user opens the
// Chart pane. Either can finish first, so each direction is exercised, and a
// success may only take down the failure it is actually the answer to.
const keysDown = { status: 500, raw: "vault is locked" };
const chartDown = { status: 503, body: { error: "engine_busy" } };
const waitStatus = (page, text) =>
  page.waitForFunction((want) => document.getElementById("status").textContent === want, text,
    { polling: 100, timeout: 5000 });

test("a key list arriving late does not clear a chart that is still failing", async (page, origin) => {
  // The real startup order: a slow quiet key load is outstanding from page
  // load, and the chart fails underneath it.
  delays.set(rule("GET", "/api/keys"), 1200);
  failures.set(rule("GET", "/api/spend"), chartDown);
  await page.goto(origin);
  await page.getByRole("tab", { name: "Chart" }).click();
  await waitStatus(page, "engine_busy");

  // Rendered rows are how the key load announces it succeeded; the pane is
  // hidden, so the rows are only attached.
  await page.locator('#keys-body tr[data-name="alpha"]').waitFor({ state: "attached", timeout: 5000 });
  await page.waitForTimeout(300);
  assert.equal(await status(page), "engine_busy", "a key list must not report the chart recovered");

  failures.delete(rule("GET", "/api/spend"));
  await page.getByRole("radio", { name: "This week" }).click();
  await waitStatus(page, "");
});

test("a chart recovering does not clear a key list that is still failing", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  failures.set(rule("GET", "/api/spend"), chartDown);
  await page.getByRole("tab", { name: "Chart" }).click();
  await waitStatus(page, "engine_busy");

  failures.set(rule("GET", "/api/keys"), keysDown);
  await page.getByRole("tab", { name: "Keys" }).click();
  await waitStatus(page, "vault is locked");

  // The chart is the one that comes back. Its own message is no longer on the
  // line, so its recovery has nothing to take down.
  failures.delete(rule("GET", "/api/spend"));
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.waitForTimeout(400);
  assert.equal(await status(page), "vault is locked", "a chart recovery must not report the vault readable");

  failures.delete(rule("GET", "/api/keys"));
  await page.getByRole("tab", { name: "Keys" }).click();
  await waitStatus(page, "");
});

test("recovering one loader uncovers the other's unresolved failure", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  failures.set(rule("GET", "/api/spend"), chartDown);
  await page.getByRole("tab", { name: "Chart" }).click();
  await waitStatus(page, "engine_busy");

  failures.set(rule("GET", "/api/keys"), keysDown);
  await page.getByRole("tab", { name: "Keys" }).click();
  await waitStatus(page, "vault is locked");

  // The key list comes back while the chart is still broken, so the line falls
  // back to the chart's failure rather than reading healthy.
  failures.delete(rule("GET", "/api/keys"));
  await page.getByRole("tab", { name: "Keys" }).click();
  await waitStatus(page, "engine_busy");
  await page.waitForTimeout(4500);
  assert.equal(await status(page), "engine_busy", "the uncovered failure is sticky like any other");

  // And the line is not stuck: the last failure to recover empties it.
  failures.delete(rule("GET", "/api/spend"));
  await page.getByRole("tab", { name: "Chart" }).click();
  await waitStatus(page, "");
});

test("the engine coming back leaves a chart failure that outlived the outage", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  failures.set(rule("GET", "/api/spend"), chartDown);
  await page.getByRole("tab", { name: "Chart" }).click();
  await waitStatus(page, "engine_busy");

  // The engine dies: its banner, and the key load's unreachable message, both
  // land on top of the chart's 503.
  failures.set(rule("GET", "/api/keys"), "drop");
  await page.getByRole("tab", { name: "Keys" }).click();
  await waitStatus(page, "Can't reach the local site. Is keys dashboard still running?");

  // Answering again retires the outage, whoever reported it, but the chart's
  // own refusal has not been retried and is still current.
  failures.delete(rule("GET", "/api/keys"));
  await page.getByRole("tab", { name: "Keys" }).click();
  await waitStatus(page, "engine_busy");

  failures.delete(rule("GET", "/api/spend"));
  await page.getByRole("tab", { name: "Chart" }).click();
  await waitStatus(page, "");
});

test("a user message outlives the loader recovery that lands under it", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  failures.set(rule("GET", "/api/spend"), chartDown);
  await page.getByRole("tab", { name: "Chart" }).click();
  await waitStatus(page, "engine_busy");
  await page.getByRole("tab", { name: "Keys" }).click();

  // Copy writes its own message, then refreshes the list 2.5 s later: that
  // refresh succeeding may not wipe what the user is reading.
  await rowButton(page, "bravo", "copy").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Copied"));
  await page.clock.runFor(2600);
  await page.waitForTimeout(200);
  assert.equal(await status(page), "Copied bravo. Clipboard wipes in 20 s.");
});

// ---------- failed requests ----------

// The engine dies between a copy and the refresh that copy defers by 2.5 s.
async function loseEngine(page) {
  await rowButton(page, "alpha", "copy").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Copied"));
  failures.set(rule("GET", "/api/keys"), "drop");
  await page.clock.runFor(2600);
  await page.waitForFunction(() => document.getElementById("status").textContent.includes("Can't reach"));
}

test("an unreachable engine shows a sticky banner", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await loseEngine(page);
  assert.equal(await status(page), "Can't reach the local site. Is keys dashboard still running?");
  // Sticky: it must outlive the ordinary 4 s status timeout.
  await page.clock.runFor(5000);
  assert.match(await status(page), /Can't reach the local site/);
});

test("the unreachable-engine banner clears when the engine answers again", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await loseEngine(page);

  // Recovery through the background status poll, with no user action to
  // overwrite the banner. A stale outage notice must not outlive the outage.
  failures.delete(rule("GET", "/api/keys"));
  await page.clock.runFor(16000);
  await page.waitForFunction(() => document.getElementById("status").textContent === "", null, { timeout: 5000 });
  assert.equal(await status(page), "");
});

test("a stale launch token is reported as a page that must be reloaded", async (page, origin) => {
  await openKeys(page, origin);
  failures.set(rule("DELETE", "/api/keys/alpha"), { status: 403, body: { error: "missing or bad token" } });
  await rowButton(page, "alpha", "delete").click();
  await page.locator("#delete-confirm").click();
  await page.waitForFunction(() => document.getElementById("delete-err").textContent !== "");
  assert.equal(await page.locator("#delete-err").textContent(), "This page is from an older launch. Reload it.");
});

test("an error body that is not JSON still produces a readable message", async (page, origin) => {
  await openKeys(page, origin);
  failures.set(rule("POST", "/api/keys/alpha/reveal"), { status: 500, raw: "upstream exploded" });
  await rowButton(page, "alpha", "reveal").click();
  await page.waitForFunction(() => document.getElementById("status").textContent !== "");
  assert.equal(await status(page), "upstream exploded");
  assert.equal(await dialogOpen(page, "dlg-reveal"), false, "no dialog may open without a secret");
});

// ---------- timing and races ----------

test("a slow key list cannot overwrite a newer one", async (page, origin) => {
  await openKeys(page, origin);
  // A refresh is answered from the vault as it is now, then held back while the
  // vault changes and a second, faster refresh overtakes it.
  delays.set(rule("GET", "/api/keys"), 1500);
  await rowButton(page, "alpha", "reveal").click();
  await waitDialog(page, "dlg-reveal", true);
  await page.locator("#dlg-reveal [data-close]").click();   // the close handler refreshes
  await page.waitForTimeout(150);

  delays.delete(rule("GET", "/api/keys"));
  keys = keys.filter((k) => k.name !== "charlie");
  await page.locator("#btn-add").click();
  await page.locator("#add-form [name=name]").fill("foxtrot");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SECRET);
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  await page.locator('#keys-body tr[data-name="foxtrot"]').waitFor();
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "foxtrot"]);

  // The slow reply, carrying the older vault, lands last.
  await page.waitForTimeout(1800);
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "foxtrot"],
    "a stale list must not restore a deleted key or drop a new one");
});

test("repeated reveals of different keys never show the wrong secret", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await rowButton(page, "alpha", "reveal").click();
  await waitDialog(page, "dlg-reveal", true);
  assert.equal(await page.locator("#reveal-name").textContent(), "alpha");
  await page.locator("#dlg-reveal [data-close]").click();
  await waitDialog(page, "dlg-reveal", false);
  await page.waitForTimeout(100);

  await rowButton(page, "bravo", "reveal").click();
  await waitDialog(page, "dlg-reveal", true);
  assert.equal(await page.locator("#reveal-name").textContent(), "bravo");
  // The first key's countdown must not close the second key's dialog early.
  await page.clock.runFor(14000);
  assert.equal(await page.locator("#dlg-reveal").evaluate((d) => d.open), true);
  await page.clock.runFor(2000);
  await waitDialog(page, "dlg-reveal", false);
});

// ---------- screenshots ----------

const viewports = [
  { name: "desktop", width: 1440, height: 900 },
  { name: "mobile", width: 390, height: 844 },
];

// Switching panes runs a 160 ms opacity animation, so a screenshot taken the
// instant a row appears catches a pane that is still transparent.
async function shoot(browser, origin) {
  const taken = [];
  const capture = async (page, name, options = {}) => {
    const file = path.join(screenshotDir, `${name}.png`);
    await page.screenshot({ path: file, animations: "disabled", ...options });
    taken.push(file);
  };
  for (const viewport of viewports) {
    reset();
    const page = await browser.newPage({ viewport: { width: viewport.width, height: viewport.height } });
    await openKeys(page, origin);
    await capture(page, `keys-list-${viewport.name}`, { fullPage: true });

    await rowButton(page, "alpha", "reveal").click();
    await waitDialog(page, "dlg-reveal", true);
    await capture(page, `keys-reveal-${viewport.name}`);
    await page.locator("#dlg-reveal [data-close]").click();

    keys = [];
    await page.reload();
    await page.waitForLoadState("networkidle");
    await page.getByRole("tab", { name: "Keys" }).click();
    await page.locator("#keys-empty:visible").waitFor();
    await capture(page, `keys-empty-${viewport.name}`, { fullPage: true });
    await page.close();
  }
  // A blank pane would mean the fade was captured mid-flight, or the list did
  // not render: either way the evidence would be worthless, so it is checked.
  const smallest = taken.filter((file) => /keys-list/.test(file)).map((file) => fs.statSync(file).size);
  assert.ok(Math.min(...smallest) > 20000, "a key-list screenshot is suspiciously blank");
  return taken;
}

// ---------- runner ----------

(async () => {
  fs.mkdirSync(screenshotDir, { recursive: true });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();
  const failed = [];
  try {
    for (const check of checks) {
      reset();
      const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
      const pageErrors = [];
      page.on("pageerror", (error) => pageErrors.push(error.message));
      try {
        await check.fn(page, origin);
        assert.deepEqual(unexpected, [], `${check.name}: fixture saw unexpected operations`);
        assert.deepEqual(pageErrors, [], `${check.name}: page errors`);
        console.log(`  ok  ${check.name}`);
      } catch (error) {
        failed.push(check.name);
        console.error(`  FAIL  ${check.name}\n        ${error.message.split("\n").join("\n        ")}`);
      } finally {
        await page.close();
      }
    }
    const shots = await shoot(browser, origin);
    console.log(`  ok  screenshots (${shots.length}) in ${screenshotDir}`);
  } finally {
    await browser.close();
    server.close();
  }
  if (failed.length) {
    console.error(`\nKeys dashboard UI: ${failed.length} of ${checks.length} failed: ${failed.join(", ")}`);
    process.exit(1);
  }
  console.log(`\nKeys dashboard UI passed: ${checks.length} cases, screenshots in ${screenshotDir}`);
})().catch((error) => { console.error(error); process.exit(1); });
