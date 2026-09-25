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
  ["/analytics.js", ["application/javascript", ""]],
  ["/styles.css", ["text/css", asset("styles.css")]],
  ["/providers.json", ["application/json", asset("providers.json")]],
]);

// ---------- fixture state ----------

const SECRET = "sk-fixture-NEVER-REAL-0000000000";
const baseKeys = () => [
  { name: "alpha", provider: "openai", kind: "runtime", created_at: "2026-09-01T10:00:00Z", last_used_at: "2026-09-18T09:00:00Z", checkable: true, notes: "first fixture key",
    usd_month: 0.0105, usd_month_kind: "estimate", gateway_month_calls: 3, gateway_month_unpriced_calls: 0 },
  { name: "bravo", provider: "anthropic", kind: "billing", created_at: "2026-09-05T10:00:00Z", last_used_at: null, checkable: false,
    usd_month: null, usd_month_kind: "none", gateway_month_calls: 0, gateway_month_unpriced_calls: 0 },
  // A TypeSafe key: its System One calls report no tokens and no cost receipt.
  { name: "charlie", provider: "typesafe", kind: "runtime", created_at: "2026-09-09T10:00:00Z", last_used_at: null, checkable: false,
    usd_month: null, usd_month_kind: "unknown", gateway_month_calls: 2, gateway_month_unpriced_calls: 2 },
];

// The gateway's own ledger, as the engine reports it for source=keys. `alpha` routes to the Vercel
// AI Gateway and its calls carry tokens and a list-price estimate; `charlie` routes to TypeSafe,
// whose calls carry neither, so their cost is unknown rather than zero. `system-one` runs on both
// providers — a workload is a model under a provider, not a billing source of its own — which also
// makes it the review's mixed bucket: a priced part and an unpriced part under one model.
// Invented rows: no call was ever made.
const baseLedger = () => [
  { key: "alpha", provider: "vercel-ai-gateway", model: "claude-sonnet-5", model_calls: 3, input_tokens: 900, output_tokens: 300,
    cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 0, usd: null, usd_estimate: 0.0105 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "system-one", model_calls: 1, input_tokens: 400, output_tokens: 100,
    cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 0, usd: null, usd_estimate: 0.0095 },
  { key: "charlie", provider: "typesafe", model: "system-one", model_calls: 2, input_tokens: 0, output_tokens: 0,
    cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 0, usd: null, usd_estimate: null },
];

// The subscription ledger: what the tools wrote to their own logs. It is empty unless a test
// fills it, so every case written against the empty local shape keeps that shape.
let keys, ledger, localRows, plans, failures, delays, requests, unexpected;

function reset() {
  keys = baseKeys();
  ledger = baseLedger();
  localRows = [];
  // The plan cards. Empty unless a test fills it, as most of this suite expects.
  plans = [];
  failures = new Map();   // "METHOD /path" -> {status, body} | "drop"
  delays = new Map();     // "METHOD /path" -> milliseconds
  requests = [];
  unexpected = [];
}

const pad2 = (n) => String(n).padStart(2, "0");
const localDay = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;

// The spend endpoint, answering only what the query asked for. Local sources keep the empty
// shape the rest of this suite relies on; the API keys source serves the ledger above.
function spend(params) {
  const source = params.get("source") || "all";
  const by = params.get("by") || "model";
  const key = params.get("key");
  const provider = params.get("provider");
  if (by === "project" && source !== "claude") return [400, { error: "by=project requires source=claude" }];
  // The engine refuses a provider outside the gateway ledger; the fixture must too, or the page
  // could pass a stale filter and never be told.
  if (provider && source !== "keys") return [400, { error: "provider requires source=keys" }];
  const day = localDay(new Date());
  if (source !== "keys") {
    if (!localRows.length) return [200, { source, by, start_day: day, end_day: day, totals: {}, rows: [], daily: [], points: [], models: [] }];
    // A local row is a model the tool priced in its own log, or left unpriced; there is no call
    // count, which is why requests are not a unit outside the gateway ledger.
    const fam = (m) => (/^grok/i.test(m) ? "grok" : /^claude/i.test(m) ? "claude" : "openai");
    const rows = localRows.filter((r) => source === "all" || fam(r.model) === source);
    const sum = (f, pick) => rows.filter((r) => fam(r.model) === f).reduce((a, r) => a + (pick(r) || 0), 0);
    // The engine's own token rule (`TokenTotals.normalized`): Claude counts cache reads and
    // writes, the others count reasoning tokens. A bucket carries that total, not a raw sum.
    const normalized = (r) => (r.input_tokens || 0) + (r.output_tokens || 0)
      + (fam(r.model) === "claude"
        ? (r.cached_read_tokens || 0) + (r.cache_creation_tokens || 0)
        : (r.reasoning_tokens || 0));
    return [200, {
      range: params.get("range") || "today", by, source,
      start_day: day, end_day: day, last_ingest_at: day + "T00:00:00Z",
      totals: {
        grok_usd: sum("grok", (r) => r.usd),
        claude_usd_estimate: sum("claude", (r) => r.usd_estimate),
        openai_usd_estimate: sum("openai", (r) => r.usd_estimate),
      },
      rows,
      daily: by === "hour" ? [] : rows.map((r) => ({ ...r, day, tokens: normalized(r), usd: r.usd ?? null, usd_estimate: r.usd_estimate ?? null })),
      points: by === "hour"
        ? rows.map((r) => ({ ...r, hour: `${day}T${pad2(new Date().getHours())}:00`, tokens: normalized(r), usd: r.usd ?? null, usd_estimate: r.usd_estimate ?? null }))
        : [],
      models: [...new Set(rows.map((r) => r.model))],
    }];
  }
  const rows = ledger.filter((r) => (!key || r.key === key) && (!provider || r.provider === provider));
  // A gateway call's dollars arrive in `usd_estimate`, receipt or list price alike, and a
  // provider-reported zero arrives as an explicit 0 there — `SpendQueries.gatewayUsd` returns the
  // known zero and nil only when there is no receipt at all. So null, and only null, is unpriced.
  const priced = rows.filter((r) => r.usd_estimate != null);
  // The engine aggregates a day (or hour) of one model into one bucket and sums only the dollars
  // it has, so a bucket can be priced at zero and still cover a call that was never priced. A row
  // may say so with `unpriced_calls`; the bucket it serves carries no such field, exactly as the
  // real payload carries none, which is why the range totals are the only place to learn of it.
  const unpricedCalls = (r) => (r.unpriced_calls != null ? r.unpriced_calls
    : r.usd_estimate == null ? r.model_calls : 0);
  const point = (extra) => rows.map((r) => ({
    model: r.model, tokens: r.input_tokens + r.output_tokens, usd: null, usd_estimate: r.usd_estimate,
    input_tokens: r.input_tokens, output_tokens: r.output_tokens, cached_read_tokens: 0,
    cache_creation_tokens: 0, model_calls: r.model_calls, ...extra,
  }));
  return [200, {
    range: params.get("range") || "today", by, source,
    start_day: day, end_day: day, last_ingest_at: day + "T00:00:00Z",
    totals: {
      gateway_calls: rows.reduce((a, r) => a + r.model_calls, 0),
      gateway_tokens: rows.reduce((a, r) => a + r.input_tokens + r.output_tokens, 0),
      gateway_usd_estimate: priced.length ? priced.reduce((a, r) => a + r.usd_estimate, 0) : null,
      gateway_unpriced_calls: rows.reduce((a, r) => a + unpricedCalls(r), 0),
      gateway_unpriced_models: rows.filter((r) => unpricedCalls(r) > 0).map((r) => r.model),
      gateway_correlated_calls: 0,
      usd_estimate: null,
    },
    rows,
    daily: by === "hour" ? [] : point({ day }),
    points: by === "hour" ? point({ hour: `${day}T${pad2(new Date().getHours())}:00` }) : [],
  }];
}

const rule = (method, pathname) => `${method} ${pathname}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function json(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
  response.end(body);
}

function handle(method, pathname, body, params) {
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
  if (pathname === "/api/models") return [200, []];
  if (pathname === "/api/status") return [200, { plans }];
  if (pathname.startsWith("/api/spend")) return spend(params);

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
    const [status, value] = handle(method, url.pathname, body, url.searchParams);
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
  // Only the deferred reload's re-render puts the resting label back.
  await page.waitForFunction(() => document.querySelector('#keys-body tr[data-name="bravo"] [data-act="copy"]')?.textContent === "Copy");
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

// ---------- keyboard and dialog focus ----------

const focused = (page) => page.evaluate(() => {
  const a = document.activeElement;
  const tr = a && a.closest("#keys-body tr");
  return tr ? `${tr.dataset.name}${a.dataset.act ? ":" + a.dataset.act : ""}` : (a && a.id) || "";
});
const focusRow = (page, name) => page.locator(`#keys-body tr[data-name="${name}"]`).first().focus();
// A dialog's close event, and the focus hand-back it queues, land after `open` turns false.
const waitFocused = (page, want) => page.waitForFunction((want) => {
  const a = document.activeElement;
  const tr = a && a.closest("#keys-body tr");
  return (tr ? `${tr.dataset.name}${a.dataset.act ? ":" + a.dataset.act : ""}` : (a && a.id) || "") === want;
}, want, { timeout: 5000 });
// The startup key load and the Keys tab's own load each redraw the rows (as does the provider
// catalog arriving), and a redraw drops focus. networkidle has already fired by then, so wait for
// both loads to reach their grant lookups and for the catalog names before focusing a row.
async function settleKeys(page) {
  for (let i = 0; i < 100 && requests.filter((r) => r.pathname.endsWith("/clients")).length < 2 * keys.length; i++) {
    await page.waitForTimeout(50);
  }
  await page.waitForFunction(() => document.querySelector('#keys-body tr[data-name="alpha"] .td-provider').textContent.startsWith("OpenAI"));
}
const waitEmpty = (page, selector) =>
  page.waitForFunction((sel) => document.querySelector(sel).value === "", selector, { timeout: 5000 });

test("row keys move the selection and open each dialog on the focused row", async (page, origin) => {
  await openKeys(page, origin);
  await settleKeys(page);
  await focusRow(page, "alpha");
  await page.keyboard.press("ArrowDown");
  assert.equal(await focused(page), "bravo");
  await page.keyboard.press("End");
  assert.equal(await focused(page), "charlie");
  await page.keyboard.press("j");
  assert.equal(await focused(page), "charlie", "the list clamps at the end");
  await page.keyboard.press("Home");
  await page.keyboard.press("k");
  assert.equal(await focused(page), "alpha", "and at the start");
  await page.keyboard.press("ArrowDown");

  // Each dialog opens on the row's key; closing it returns focus to the row that opened it.
  await page.keyboard.press("e");
  await waitDialog(page, "dlg-edit", true);
  assert.equal(await page.locator("#edit-name").textContent(), "bravo");
  assert.equal(await page.locator("#edit-form [name=provider]").inputValue(), "anthropic");
  assert.equal(await page.locator("#edit-form [name=kind]").inputValue(), "billing");
  // Escape in the provider field closes its suggestion list first, so Cancel closes this one.
  await page.locator("#dlg-edit [data-close]").click();
  await waitDialog(page, "dlg-edit", false);
  await waitFocused(page, "bravo");

  await page.keyboard.press("r");
  await waitDialog(page, "dlg-rotate", true);
  assert.equal(await page.locator("#rotate-name").textContent(), "bravo");
  await page.keyboard.type("sk-typed-then-abandoned");
  await page.keyboard.press("Escape");
  await waitDialog(page, "dlg-rotate", false);
  await waitEmpty(page, "#rotate-form [name=secret]");
  await waitFocused(page, "bravo");

  await page.keyboard.press("Backspace");
  await waitDialog(page, "dlg-delete", true);
  assert.equal(await page.locator("#delete-name").textContent(), "bravo");
  assert.equal(await focused(page), "delete-confirm");
  await page.locator("#dlg-delete [data-close]").click();
  await waitDialog(page, "dlg-delete", false);

  // Delete on a button other than Delete is left to the button.
  await rowButton(page, "bravo", "edit").focus();
  await page.keyboard.press("Delete");
  assert.equal(await dialogOpen(page, "dlg-delete"), false);

  await focusRow(page, "bravo");
  await page.keyboard.press("c");
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Copied"));
  assert.equal(await status(page), "Copied bravo. Clipboard wipes in 20 s.");
});

test("pane keys act on the selected key from outside the list, but copy stays list-only", async (page, origin) => {
  await openKeys(page, origin);
  await settleKeys(page);
  await page.locator('#keys-body tr[data-name="alpha"] td').first().click();
  await page.evaluate(() => document.activeElement.blur());
  await page.keyboard.press("c");
  assert.equal(requests.some((r) => r.pathname === "/api/keys/alpha/copy"), false, "c outside the list copies nothing");
  await page.keyboard.press("e");
  await waitDialog(page, "dlg-edit", true);
  assert.equal(await page.locator("#edit-name").textContent(), "alpha");
  await page.locator("#dlg-edit [data-close]").click();
  await waitDialog(page, "dlg-edit", false);
  // Opened from outside the pane, the dialog has no row to return to, so the row's button takes focus.
  await waitFocused(page, "alpha:edit");

  await page.keyboard.press("n");
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=secret]").fill("sk-typed-then-abandoned");
  await page.keyboard.press("Escape");
  await waitDialog(page, "dlg-add", false);
  await waitEmpty(page, "#add-form [name=secret]");
});

test("the grant dialog issues a grant, and a client needs a method", async (page, origin) => {
  keys.find((k) => k.name === "alpha").host = "api.openai.com";
  await openKeys(page, origin);
  await settleKeys(page);
  await focusRow(page, "alpha");
  await page.keyboard.press("a");
  await waitDialog(page, "dlg-grant", true);
  await page.locator("#grant-form [name=task]").fill("fixture task");
  failures.set(rule("POST", "/api/keys/alpha/grants"), { status: 200, body: {
    id: "g1", key: "alpha", provider: "openai", host: "api.openai.com", methods: ["GET", "POST"], paths: [],
    expires_at: "2026-09-20T13:00:00Z", base_url: "http://127.0.0.1:12767/g/g1", token: "ksf-grant-fixture", auth_header: "Authorization",
  } });
  await page.locator("#grant-submit").click();
  await page.locator("#grant-result").waitFor({ state: "visible" });
  assert.equal(await page.locator("#gr-id").textContent(), "g1");
  assert.equal(await page.locator("#gr-scope").textContent(), "GET, POST · any path");
  assert.equal(await status(page), "Grant g1 issued for alpha.");
  assert.equal(await page.locator("#grant-submit").isDisabled(), false);
  await page.keyboard.press("Escape");
  await waitDialog(page, "dlg-grant", false);

  await rowButton(page, "alpha", "grant").click();
  await waitDialog(page, "dlg-grant", true);
  await page.locator('.kind-switch [data-kind="client"]').click();
  for (const box of await page.locator("#grant-form [name=cm]").all()) await box.uncheck();
  await page.locator("#grant-submit").click();
  await page.waitForFunction(() => document.getElementById("grant-err").textContent !== "");
  assert.equal(await page.locator("#grant-err").textContent(), "Pick at least one method.");
  assert.equal(await page.locator("#grant-submit").textContent(), "Issue client");
  assert.equal(await page.locator("#grant-submit").isDisabled(), false);
  assert.equal(requests.some((r) => r.method === "POST" && r.pathname === "/api/keys/alpha/clients"), false);
});

test("chips and pickers wrap on the arrow keys", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator('[data-range="today"]').focus();
  await page.keyboard.press("ArrowLeft");
  assert.equal(await page.locator('[data-range="month"]').getAttribute("aria-checked"), "true", "Left from the first chip wraps to the last");
  assert.equal(await page.evaluate(() => document.activeElement.dataset.range), "month");
  await page.keyboard.press("ArrowRight");
  assert.equal(await page.locator('[data-range="today"]').getAttribute("aria-checked"), "true");
  await page.getByRole("tab", { name: "Chart" }).focus();
  await page.keyboard.press("ArrowRight");
  await page.waitForFunction(() => !document.getElementById("pane-keys").hidden);
  await page.keyboard.press("ArrowRight");
  await page.waitForFunction(() => !document.getElementById("pane-usage").hidden);
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

test("a link that names a key boots into the API keys scope with that key chosen", async (page, origin) => {
  await page.goto(`${origin}/?key=alpha&range=week`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#keys-filter:visible").waitFor();
  assert.equal(await page.evaluate(inKeysScope), true, "a key only means anything in that scope");
  assert.equal(await page.locator('#keys-filter [data-key-filter="alpha"]').getAttribute("aria-checked"), "true");
  const filtered = requests.filter((r) => r.pathname === "/api/spend" && r.search.includes("key=alpha"));
  assert.ok(filtered.length > 0, "the key filter must reach the engine");

  await page.getByRole("radio", { name: "Show every key" }).click();
  await page.waitForFunction(() => !new URL(location.href).searchParams.get("key"));
  assert.equal(await page.locator('#keys-filter [data-key-filter=""]').getAttribute("aria-checked"), "true");
});

// ---------- API keys usage ----------

const inKeysScope = () => document.querySelector('[data-scope="keys"]').getAttribute("aria-checked") === "true";
const openKeysSource = async (page, origin, query = "range=week") => {
  await page.goto(`${origin}/?${query}`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  if (!(await page.evaluate(inKeysScope))) await page.getByRole("radio", { name: "API keys" }).click();
  await page.waitForFunction(inKeysScope);
  await page.locator("#mix .mix-row").first().waitFor();
};
const spendSearches = () => requests.filter((r) => r.pathname === "/api/spend").map((r) => r.search);
const totalsText = (page) => page.locator("#totals").textContent();
// Dollars are a price put on the measurement afterwards, so they are on screen only once the
// unit chips are asked for them. Every cost assertion below goes through here first.
const chooseUsd = async (page) => {
  await page.getByRole("radio", { name: "USD", exact: true }).click();
  await page.waitForFunction(() => document.querySelector('[data-unit="usd"]').getAttribute("aria-checked") === "true");
};

test("the API keys scope charts the gateway ledger with requests, tokens and a partial cost", async (page, origin) => {
  await openKeysSource(page, origin);
  assert.ok(spendSearches().some((s) => s.includes("source=keys")), "the API keys scope must reach the engine");

  // Every key's models are charted, including the one whose provider reported no tokens.
  const models = await page.locator("#mix .mix-name").allTextContents();
  assert.deepEqual(models.sort(), ["claude-sonnet-5", "system-one"]);

  // Default unit: the measured counts, and not one dollar figure anywhere on the line.
  const measured = await totalsText(page);
  assert.match(measured, /1\.7K tokens/, "tokens lead by default");
  assert.match(measured, /6 requests/, "requests lead: every routed call is countable");
  assert.doesNotMatch(measured, /\$/, "no dollar figure until USD is chosen");
  assert.doesNotMatch(await page.locator("#mix").textContent(), /\$/, "nor on a model row");

  await chooseUsd(page);
  const totals = await totalsText(page);
  assert.match(totals, /6 requests/, "requests lead: every routed call is countable");
  assert.match(totals, /1\.7K tokens/);
  assert.match(totals, /≥ ≈ \$0\.02/, "a partly priced range is a floor, not a total");
  assert.match(totals, /partial cost · 2 requests unpriced/);
  assert.match(totals, /routed through Keys only/);

  // Selecting one model does not make the view complete: a bucket may mix priced and
  // unpriced calls, so the partial label has to survive the filter.
  await page.locator('#mix .mix-row[data-model="claude-sonnet-5"]').click();
  await page.waitForFunction(() => document.querySelector('#mix .mix-row[data-model="claude-sonnet-5"]').getAttribute("aria-selected") === "true");
  assert.match(await totalsText(page), /partial cost · 2 requests unpriced/, "a filtered view must not read as complete");

  // system-one is the review's mixed bucket: one priced Vercel call and two unpriced TypeSafe
  // ones under a single model. Its dollars keep a number, so the row itself must say the number
  // is a floor rather than let it be read as this model's complete cost.
  const mixedRow = page.locator('#mix .mix-row[data-model="system-one"]');
  assert.match((await mixedRow.locator(".mix-usd").textContent()).trim(), /^≥ ≈ \$/, "a mixed row reads as a floor");
  assert.match(await mixedRow.getAttribute("title"), /Partial: some calls in this range have no cost receipt/);
  assert.match(await mixedRow.getAttribute("title"), /TypeSafe/, "the row names the providers behind it");
  assert.match(await mixedRow.getAttribute("title"), /Vercel/);
});

test("a provider filter separates TypeSafe from Vercel without inventing a third source", async (page, origin) => {
  await openKeysSource(page, origin);
  await chooseUsd(page);
  const chips = page.locator("#provider-filter [data-provider-filter]");
  assert.deepEqual(await chips.evaluateAll((els) => els.map((e) => e.textContent)),
    ["All providers", "TypeSafe", "Vercel AI Gateway"]);
  assert.equal(await chips.first().getAttribute("aria-checked"), "true", "all providers is the default");

  // TypeSafe alone: the same workload model, now with nothing priced at all.
  await page.getByRole("radio", { name: "Show only calls routed to TypeSafe" }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("provider") === "typesafe");
  await page.waitForFunction(() => document.querySelectorAll("#mix .mix-row").length === 1);
  assert.ok(spendSearches().some((s) => s.includes("provider=typesafe") && s.includes("source=keys")));
  assert.equal(await page.locator("#mix .mix-name").textContent(), "system-one");
  assert.match(await totalsText(page), /cost unknown/, "TypeSafe reports no cost: unknown, not $0");
  assert.match(await totalsText(page), /2 requests/);
  assert.equal((await page.locator("#mix .mix-usd").textContent()).trim(), "—");
  // The key picker narrows with it: a key belongs to exactly one provider.
  assert.deepEqual(await page.locator("#keys-filter [data-key-filter]").evaluateAll((els) => els.map((e) => e.textContent)),
    ["All keys", "charlie"]);

  // Vercel alone: the same model again, this time priced, and nothing left unpriced to warn about.
  await page.getByRole("radio", { name: "Show only calls routed to Vercel AI Gateway" }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("provider") === "vercel-ai-gateway");
  // Both views have two rows, so the request count is what says the new answer has landed.
  await page.waitForFunction(() => /4 requests/.test(document.getElementById("totals").textContent));
  const vercel = await totalsText(page);
  assert.doesNotMatch(vercel, /partial cost/, "nothing in this narrower view is unpriced");
  assert.doesNotMatch(vercel, /≥/, "and so its figure is not a floor");

  // Back to every provider from the picker itself.
  await page.getByRole("radio", { name: "Show every provider these keys reached" }).click();
  await page.waitForFunction(() => !new URL(location.href).searchParams.get("provider"));
  await page.waitForFunction(() => /6 requests/.test(document.getElementById("totals").textContent));
  assert.match(await totalsText(page), /partial cost · 2 requests unpriced/, "and the warning comes back with it");
});

test("choosing a provider drops a key that belongs to another one", async (page, origin) => {
  await openKeysSource(page, origin, "range=week&source=keys&key=alpha");
  await page.waitForFunction(() => document.querySelectorAll("#keys-filter [data-key-filter]").length === 3);

  await page.getByRole("radio", { name: "Show only calls routed to TypeSafe" }).click();
  await page.waitForFunction(() => !new URL(location.href).searchParams.get("key"));
  // The unfiltered picker index goes out alongside the filtered report, so the one that carries
  // the provider is the one to read — and no request may still carry the dropped key.
  const provided = spendSearches().filter((s) => s.includes("provider=typesafe"));
  assert.ok(provided.length > 0, "the provider filter must reach the engine");
  assert.ok(provided.every((s) => !s.includes("key=")),
    `alpha is a Vercel key and cannot survive a TypeSafe filter: ${provided.join(" | ")}`);
  assert.equal(await page.locator('#keys-filter [data-key-filter=""]').getAttribute("aria-checked"), "true");
});

test("the per-key picker names every key and filters to one, all keys included", async (page, origin) => {
  await openKeysSource(page, origin);
  await chooseUsd(page);
  const chips = page.locator("#keys-filter [data-key-filter]");
  assert.deepEqual(await chips.evaluateAll((els) => els.map((e) => e.textContent)), ["All keys", "alpha", "charlie"]);
  assert.equal(await chips.first().getAttribute("aria-checked"), "true", "all keys is the default");
  // A key is named, never its value.
  assert.equal((await page.locator("#keys-filter").textContent()).includes(SECRET), false);

  await page.getByRole("radio", { name: "Show only key charlie" }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("key") === "charlie");
  assert.ok(spendSearches().some((s) => s.includes("key=charlie") && s.includes("source=keys")));
  await page.waitForFunction(() => document.querySelectorAll("#mix .mix-row").length === 1);
  assert.equal(await page.locator("#mix .mix-name").textContent(), "system-one");
  assert.match(await totalsText(page), /cost unknown/, "an unpriced key reads as unknown, not $0");
  assert.match(await totalsText(page), /2 requests/);

  // Back to every key, from the picker itself.
  await page.getByRole("radio", { name: "Show every key" }).click();
  await page.waitForFunction(() => !new URL(location.href).searchParams.get("key"));
  await page.waitForFunction(() => document.querySelectorAll("#mix .mix-row").length === 2);
  assert.equal(await page.evaluate(inKeysScope), true, "clearing a key stays in the API keys scope");
});

test("requests are a chartable unit in the API keys scope and nowhere else", async (page, origin) => {
  await page.goto(`${origin}/?range=week`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  assert.equal(await page.locator('[data-unit="requests"]').isHidden(), true, "local logs do not count every call");

  await page.getByRole("radio", { name: "API keys" }).click();
  await page.locator('[data-unit="requests"]:visible').waitFor();
  await page.getByRole("radio", { name: "Requests" }).click();
  await page.waitForFunction(() => document.getElementById("daily-unit").textContent.startsWith("requests per"));
  // The bars come from the request counts, so the unpriced, token-less key is still drawn.
  const labels = await page.locator("#daily-svg g.col").evaluateAll((g) => g.map((n) => n.getAttribute("aria-label")));
  assert.ok(labels.some((l) => /system-one 3/.test(l)), "a call with no tokens still has a bar");
  assert.ok(labels.some((l) => /claude-sonnet-5 3/.test(l)));

  // Leaving the scope drops a unit that only means something there.
  await page.getByRole("radio", { name: "Subscriptions" }).click();
  await page.waitForFunction(() => document.querySelector('[data-unit="requests"]').hidden);
  assert.equal(await page.locator('[data-unit="tokens"]').getAttribute("aria-checked"), "true");
  assert.equal(await page.locator("#keys-filter").isHidden(), true);
  assert.equal(await page.locator("#provider-filter").isHidden(), true);
  assert.equal(await page.locator("#source-chips").isHidden(), false, "the tool filter comes back with it");
});

test("a key whose provider reports no tokens says so instead of drawing nothing", async (page, origin) => {
  await openKeysSource(page, origin, "range=week&key=charlie&source=keys");
  await page.locator("#chart-nothing:visible").waitFor();
  assert.match(await page.locator("#chart-nothing").textContent(),
    /No tokens were reported for these requests\. Switch to Requests to chart them\./);
  assert.match(await totalsText(page), /2 requests/, "the requests are counted even so");

  await page.getByRole("radio", { name: "Requests" }).click();
  await page.waitForFunction(() => document.getElementById("chart-nothing").hidden);
  const labels = await page.locator("#daily-svg g.col").evaluateAll((g) => g.map((n) => n.getAttribute("aria-label")));
  assert.ok(labels.some((l) => /system-one 2/.test(l)), "requests chart what tokens cannot");
});

test("a key opened from the Keys pane cannot inherit another provider's filter", async (page, origin) => {
  await openKeysSource(page, origin);
  await page.getByRole("radio", { name: "Show only calls routed to TypeSafe" }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("provider") === "typesafe");

  // alpha routes to the Vercel gateway. Charting it under the TypeSafe filter still standing in
  // the chart would ask for an intersection that cannot exist, and report nothing for a key whose
  // calls are right there in the Keys table.
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body tr[data-name="alpha"]').waitFor();
  await rowCell(page, "alpha", "usd").click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("key") === "alpha");
  await page.waitForFunction(() => document.querySelectorAll("#mix .mix-row").length === 2);

  assert.notEqual(new URL(await page.url()).searchParams.get("provider"), "typesafe");
  const keyed = spendSearches().filter((s) => s.includes("key=alpha"));
  assert.ok(keyed.length > 0, "the drilldown must reach the engine");
  assert.ok(keyed.every((s) => !s.includes("provider=typesafe")),
    `a TypeSafe filter survived a Vercel key: ${keyed.join(" | ")}`);
  assert.match(await totalsText(page), /4 requests/, "alpha's own calls, not an empty intersection");
  assert.deepEqual((await page.locator("#mix .mix-name").allTextContents()).sort(), ["claude-sonnet-5", "system-one"]);
  assert.equal(await page.locator('#provider-filter [data-provider-filter="typesafe"]').getAttribute("aria-checked"), "false");

  // The picker inside the chart is the other case: its key list is already narrowed to the chosen
  // provider, so choosing a key there must not throw that provider away.
  await page.getByRole("radio", { name: "Show only calls routed to TypeSafe" }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("provider") === "typesafe");
  await page.getByRole("radio", { name: "Show only key charlie" }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("key") === "charlie");
  assert.equal(new URL(await page.url()).searchParams.get("provider"), "typesafe", "an ordinary key pick keeps its provider");
});

test("an explicit subscription source drops a gateway key and provider, URL included", async (page, origin) => {
  await page.goto(`${origin}/?range=week&source=claude&key=alpha&provider=typesafe`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  // The link asked for Claude Code's local log. A gateway key cannot narrow local rows to
  // anything but nothing, so the explicit source wins and both filters go.
  assert.equal(await page.locator('[data-scope="subs"]').getAttribute("aria-checked"), "true");
  assert.equal(await page.locator('[data-source="claude"]').getAttribute("aria-checked"), "true");
  const url = new URL(await page.url());
  assert.equal(url.searchParams.get("key"), null, "the URL must stop advertising a dropped filter");
  assert.equal(url.searchParams.get("provider"), null);
  // The Usage pane's own month total is a sourceless request and not part of this question.
  const searches = spendSearches().filter((s) => s.includes("source="));
  assert.ok(searches.length > 0, "the chart must still load");
  assert.ok(searches.every((s) => s.includes("source=claude") && !s.includes("key=") && !s.includes("provider=")),
    `a local source carried a gateway filter: ${searches.join(" | ")}`);

  // A later tool choice cannot bring them back either.
  await page.getByRole("radio", { name: "Grok", exact: true }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("source") === "grok");
  const grok = spendSearches().filter((s) => s.includes("source=grok"));
  assert.ok(grok.length > 0 && grok.every((s) => !s.includes("key=") && !s.includes("provider=")),
    `stale filter survived a source change: ${grok.join(" | ")}`);

  // And a key with no source at all still means the gateway ledger.
  await page.goto(`${origin}/?range=week&key=alpha`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#keys-filter:visible").waitFor();
  assert.equal(await page.evaluate(inKeysScope), true, "a source-less key still enters the API keys scope");
  assert.equal(new URL(await page.url()).searchParams.get("key"), "alpha");
});

test("a reported cost of zero is a known $0, not a missing receipt", async (page, origin) => {
  // One call the provider priced at exactly zero, and one it did not price at all. The engine
  // serializes the first as `usd_estimate: 0` and the second as null, which is the whole
  // difference between a cost that is known and one that was never reported.
  const bare = { key: "charlie", provider: "typesafe", model_calls: 1, input_tokens: 0, output_tokens: 0,
    cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 0, usd: null, usd_estimate: null };
  ledger = [{ ...bare, model: "system-one", usd_estimate: 0 }, { ...bare, model: "free-tier" }];
  await openKeysSource(page, origin);
  await page.getByRole("radio", { name: "USD", exact: true }).click();
  await page.waitForFunction(() => /cost/.test(document.getElementById("chart-nothing").textContent));

  // Mixed: a known zero beside an unknown. The note has to say both, and neither as the other.
  assert.equal(await page.locator("#chart-nothing").textContent(),
    "Part of these requests cost $0.00; no cost was reported for the rest. Switch to Requests to chart them.");
  assert.match(await totalsText(page), /\$0/, "the totals already read as a known zero");
  assert.match(await totalsText(page), /1 request unpriced/);

  // Selecting a model narrows what the note is about: this one's cost is known, and zero. The
  // range still holds a call nobody priced, and the view-wide legend cannot be read from this
  // sentence, so the zero is reported as what was reported rather than as the whole story.
  await page.locator('#mix .mix-row[data-model="system-one"]').click();
  await page.waitForFunction(() => document.getElementById("chart-nothing").textContent.startsWith("The cost reported"));
  assert.equal(await page.locator("#chart-nothing").textContent(),
    "The cost reported for these requests is $0.00; some calls in this range are unpriced."
    + " Switch to Requests to chart them.");

  // And this one's cost really is missing, which is a different sentence.
  await page.locator('#mix .mix-row[data-model="system-one"]').click();
  await page.locator('#mix .mix-row[data-model="free-tier"]').click();
  await page.waitForFunction(() => document.getElementById("chart-nothing").textContent.startsWith("No cost"));
  assert.equal(await page.locator("#chart-nothing").textContent(),
    "No cost was reported for these requests. Switch to Requests to chart them.");
});

test("a bucket priced at zero that still hides an unpriced call never claims a flat $0", async (page, origin) => {
  // One model, one key, one day: a call the provider priced at exactly zero and a call it never
  // priced at all. The engine adds what it has, so the bucket arrives as usd_estimate 0 over
  // model_calls 2 with nothing to say which half was priced — only the range totals count the
  // unpriced one. A note that read completeness out of that sum would promise a total of $0.00
  // for a request whose cost nobody knows.
  ledger = [{ key: "charlie", provider: "typesafe", model: "system-one", model_calls: 2, unpriced_calls: 1,
    input_tokens: 0, output_tokens: 0, cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 0,
    usd: null, usd_estimate: 0 }];
  const note = () => page.locator("#chart-nothing").textContent();
  const flat = "These requests cost $0.00. Switch to Requests to chart them.";
  const qualified = "The cost reported for these requests is $0.00; some calls in this range are unpriced."
    + " Switch to Requests to chart them.";

  await openKeysSource(page, origin);
  await page.getByRole("radio", { name: "USD", exact: true }).click();
  await page.waitForFunction(() => /cost/.test(document.getElementById("chart-nothing").textContent));
  assert.match(await totalsText(page), /1 request unpriced/, "the range knows what the bucket cannot say");
  assert.notEqual(await note(), flat, "a summed zero is not a receipt for every call in it");
  assert.equal(await note(), qualified);

  // Selecting the model asks the same question of the same bucket, and gets the same answer.
  await page.locator('#mix .mix-row[data-model="system-one"]').click();
  await page.waitForFunction(() => document.querySelector('#mix .mix-row[data-model="system-one"]').getAttribute("aria-selected") === "true");
  assert.notEqual(await note(), flat, "narrowing to the model cannot reveal what the payload omits");
  assert.equal(await note(), qualified);

  // Today charts the hourly buckets, which are summed the same way and must read the same.
  await page.getByRole("radio", { name: "Today", exact: true }).click();
  await page.waitForFunction(() => document.getElementById("daily-title").textContent === "Today by hour");
  await page.waitForFunction(() => /cost/.test(document.getElementById("chart-nothing").textContent));
  assert.notEqual(await note(), flat, "an hour's sum hides an unpriced call just as a day's does");
  assert.equal(await note(), qualified);

  // A range with nothing unpriced keeps the plain sentence: the zero there really is the whole cost.
  ledger = [{ key: "charlie", provider: "typesafe", model: "system-one", model_calls: 2,
    input_tokens: 0, output_tokens: 0, cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 0,
    usd: null, usd_estimate: 0 }];
  await openKeysSource(page, origin);
  await page.getByRole("radio", { name: "USD", exact: true }).click();
  await page.waitForFunction(() => /cost/.test(document.getElementById("chart-nothing").textContent));
  assert.doesNotMatch(await totalsText(page), /unpriced/);
  assert.equal(await note(), flat);
});

test("a request whose provider named no model keeps its bar under unknown", async (page, origin) => {
  // The gateway records model="" when the caller named none and the response reported none.
  ledger = [
    { key: "charlie", provider: "typesafe", model: "", model_calls: 1, input_tokens: 0, output_tokens: 0,
      cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 0, usd: null, usd_estimate: null },
    { key: "alpha", provider: "vercel-ai-gateway", model: "claude-sonnet-5", model_calls: 2, input_tokens: 600,
      output_tokens: 200, cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 0, usd: null, usd_estimate: 0.01 },
  ];
  await openKeysSource(page, origin);
  await page.getByRole("radio", { name: "Requests" }).click();
  await page.waitForFunction(() => document.getElementById("daily-unit").textContent.startsWith("requests per"));
  const barLabels = () => page.locator("#daily-svg g.col").evaluateAll((g) => g.map((n) => n.getAttribute("aria-label")));

  assert.ok((await page.locator("#mix .mix-name").allTextContents()).includes("unknown"), "the mix names it unknown");
  assert.match(await totalsText(page), /3 requests/);
  assert.ok((await barLabels()).some((l) => /unknown 1/.test(l)), "the day bar keeps the call the totals counted");

  // Today draws from the hourly buckets instead, which must ask the identity question the same way.
  await page.getByRole("radio", { name: "Today", exact: true }).click();
  await page.waitForFunction(() => document.getElementById("daily-title").textContent === "Today by hour");
  await page.waitForFunction(() => document.querySelectorAll("#daily-svg g.col").length > 0);
  assert.ok((await barLabels()).some((l) => /unknown 1/.test(l)), "and so does the hour bar");

  // Selecting that series must leave it drawn rather than empty the plot.
  await page.locator('#mix .mix-row[data-model="unknown"]').click();
  await page.waitForFunction(() => document.querySelector('#mix .mix-row[data-model="unknown"]').getAttribute("aria-selected") === "true");
  const only = await barLabels();
  assert.ok(only.some((l) => /unknown 1/.test(l)), "the selected series is the one still drawn");
  assert.ok(only.every((l) => !/claude-sonnet-5/.test(l)), "and it is the only one");
});

test("switching scope clears the filters that belong to the other one", async (page, origin) => {
  await openKeysSource(page, origin, "range=week&key=alpha&provider=vercel-ai-gateway&source=keys");
  assert.equal(await page.locator("#source-chips").isHidden(), true, "a tool filter means nothing in the gateway ledger");
  assert.equal(await page.locator("#group-chips").isHidden(), true, "projects are a Claude-only grouping");

  // Out to Subscriptions: the provider and key go with it, and the local filters come back.
  await page.getByRole("radio", { name: "Subscriptions" }).click();
  await page.waitForFunction(() => !new URL(location.href).searchParams.get("key"));
  await page.locator("#source-chips:visible").waitFor();
  assert.equal(new URL(await page.url()).searchParams.get("provider"), null);
  let last = spendSearches().pop();
  assert.ok(last.includes("source=all") && !last.includes("key=") && !last.includes("provider="),
    `stale filter survived: ${last}`);

  // Into Claude, then back to API keys: the project grouping cannot follow.
  await page.getByRole("radio", { name: "Claude", exact: true }).click();
  await page.locator("#group-chips:visible").waitFor();
  await page.getByRole("radio", { name: "Projects" }).click();
  await page.waitForFunction(() => document.querySelector('[data-group="project"]').getAttribute("aria-checked") === "true");

  await page.getByRole("radio", { name: "API keys" }).click();
  await page.waitForFunction(() => document.getElementById("group-chips").hidden);
  assert.equal(await page.locator('[data-group="model"]').getAttribute("aria-checked"), "true");
  last = spendSearches().pop();
  assert.ok(last.includes("source=keys") && last.includes("by=model"), `stale grouping survived: ${last}`);

  // And leaving again comes back to the subscription source that was last chosen, not to All.
  await page.getByRole("radio", { name: "Subscriptions" }).click();
  await page.waitForFunction(() => document.querySelector('[data-source="claude"]').getAttribute("aria-checked") === "true");
});

test("a key's gateway cell opens that key in the API keys scope", async (page, origin) => {
  await openKeys(page, origin);
  // Default unit: the column counts requests, the only figure a key's own row can always answer
  // for, and puts no price on screen.
  assert.equal((await rowCell(page, "charlie", "usd").textContent()).trim(), "2 requests");
  assert.doesNotMatch(await page.locator("#keys-table").textContent(), /\$/, "no dollars until USD is chosen");

  await rowCell(page, "charlie", "usd").click();
  await page.waitForFunction(inKeysScope);
  await page.waitForFunction(() => new URL(location.href).searchParams.get("key") === "charlie");
  assert.equal(await page.locator("#pane-chart").isVisible(), true);
  assert.ok(spendSearches().some((s) => s.includes("source=keys") && s.includes("key=charlie")),
    `landed with ${spendSearches().join(" | ")}`);
  await page.waitForFunction(() => /no reported tokens/.test(document.getElementById("totals").textContent));
  // Absent token counts are not a measured zero, and the requests are still counted.
  assert.match(await totalsText(page), /2 requests/);
  await chooseUsd(page);
  await page.waitForFunction(() => /cost unknown/.test(document.getElementById("totals").textContent));

  // The same cell again must land on the same view, not toggle the filter off.
  await page.getByRole("tab", { name: "Keys" }).click();
  await rowCell(page, "charlie", "usd").click();
  await page.waitForFunction(() => document.getElementById("pane-chart").hidden === false);
  assert.equal(await page.evaluate(inKeysScope), true);
  assert.equal(await page.locator('#keys-filter [data-key-filter="charlie"]').getAttribute("aria-checked"), "true");
  assert.equal(new URL(await page.url()).searchParams.get("key"), "charlie");
});

test("an empty API keys view explains that only routed requests are recorded", async (page, origin) => {
  ledger = [];
  await page.goto(`${origin}/?range=week&source=keys`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#spend-empty:visible").waitFor();
  const text = await page.locator("#spend-empty").textContent();
  assert.match(text, /No API key calls in this range/);
  assert.match(text, /Only requests routed through Keys are recorded here; a provider called directly is not observable/);
  assert.equal(await page.locator("#totals").isHidden(), true, "no ledger means no totals line, not a zero one");

  await page.getByRole("button", { name: "Show subscriptions" }).click();
  await page.waitForFunction(() => document.querySelector('[data-scope="subs"]').getAttribute("aria-checked") === "true");
  assert.equal(await page.locator('[data-source="all"]').getAttribute("aria-checked"), "true");
});

test("the subscriptions scope says its figures come from local logs, not plan invoices", async (page, origin) => {
  await page.goto(`${origin}/?range=week`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  assert.equal(await page.locator('[data-scope="subs"]').getAttribute("aria-checked"), "true", "subscriptions lead");
  await page.waitForFunction(() => /estimated from the tools' own local logs on this Mac, not from plan invoices/
    .test(document.getElementById("chart-caption").textContent));

  await page.getByRole("radio", { name: "API keys" }).click();
  await page.waitForFunction(inKeysScope);
  await page.waitForFunction(() => /calls this Mac routed through the local gateway with a key from the vault/
    .test(document.getElementById("chart-caption").textContent));
});

// ---------- tokens first ----------

// What this Mac measured is tokens and requests; a dollar figure is this repo's price table put
// on them afterwards. The page leads with the measurement and prices it only when asked.
const subscriptionRows = () => [
  { model: "claude-sonnet-5", input_tokens: 900, output_tokens: 300, cached_read_tokens: 400, cache_creation_tokens: 100, usd: null, usd_estimate: 0.02 },
  { model: "grok-4", input_tokens: 500, output_tokens: 200, cached_read_tokens: 0, cache_creation_tokens: 0, usd: 0.01, usd_estimate: null },
];

test("the subscriptions chart leads with tokens and prices nothing until USD is chosen", async (page, origin) => {
  localRows = subscriptionRows();
  await page.goto(`${origin}/?range=week`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#mix .mix-row").first().waitFor();

  assert.equal(await page.locator('[data-unit="tokens"]').getAttribute("aria-checked"), "true", "tokens is the default unit");
  const totals = await totalsText(page);
  assert.match(totals, /2\.4K tokens/, "Claude's cache reads and writes are billed tokens and count");
  assert.doesNotMatch(totals, /\$/, "no dollar figure until USD is chosen");
  assert.doesNotMatch(await page.locator("#mix").textContent(), /\$/);
  assert.match(totals, /cached input/, "cached input is named, not hidden inside the total");
  assert.match(await page.locator("#totals .totals-main").getAttribute("title"),
    /Cached input is counted on each request that reads it again/);
  assert.match(await page.locator("#daily-unit").textContent(), /^tokens per/);

  // USD is one click away, and everything the honest-cost work put on this line survives it.
  await chooseUsd(page);
  const priced = await totalsText(page);
  assert.match(priced, /≈ \$0\.03/);
  assert.match(priced, /estimate from list prices, not an invoice/);

  // And the choice is remembered for the next visit, tokens or dollars alike.
  await page.reload();
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.waitForFunction(() => document.querySelector('[data-unit="usd"]').getAttribute("aria-checked") === "true");
  await page.getByRole("radio", { name: "Tokens" }).click();
  await page.reload();
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.waitForFunction(() => document.querySelector('[data-unit="tokens"]').getAttribute("aria-checked") === "true");
});

test("the Usage summary and the Keys column follow the same unit, with the switch beside them", async (page, origin) => {
  localRows = subscriptionRows();
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.waitForFunction(() => /tokens/.test(document.getElementById("usage-totals").textContent));
  assert.doesNotMatch(await page.locator("#usage-totals").textContent(), /\$/, "the month summary leads with tokens");

  // The switch is on the line itself: nobody has to find another pane to change the unit.
  await page.getByRole("button", { name: "Show this month in USD instead of tokens" }).click();
  await page.waitForFunction(() => /\$/.test(document.getElementById("usage-totals").textContent));
  assert.match(await page.locator("#usage-totals").textContent(), /≈ \$0\.03/);

  // One unit for the page: the Keys column answers in it too, from its own switch.
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body tr[data-name="alpha"]').waitFor();
  assert.match((await rowCell(page, "alpha", "usd").textContent()).trim(), /\$0\.01/);
  await page.getByRole("button", { name: "Showing USD; switch the gateway column to requests" }).click();
  await page.waitForFunction(() => !/\$/.test(document.getElementById("keys-table").textContent));
  assert.equal((await rowCell(page, "alpha", "usd").textContent()).trim(), "3 requests");
  await page.getByRole("tab", { name: "Usage" }).click();
  assert.doesNotMatch(await page.locator("#usage-totals").textContent(), /\$/, "the summary follows the same switch");
});

test("the Keys unit switch survives the narrow layout that drops the table head", async (page, origin) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await openKeys(page, origin);
  assert.equal(await page.locator("#keys-table thead").isVisible(), false, "the narrow layout drops the head");
  const control = page.getByRole("button", { name: "Showing requests; switch the gateway column to USD" });
  await control.waitFor({ state: "visible" });
  // Reachable by keyboard, not only by pointer, and it really changes the column.
  await control.focus();
  assert.equal(await page.evaluate(() => document.activeElement.id), "keys-unit");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => /\$/.test(document.getElementById("keys-table").textContent));
  await page.getByRole("button", { name: "Showing USD; switch the gateway column to requests" }).click();
  await page.waitForFunction(() => !/\$/.test(document.getElementById("keys-table").textContent));
});

// The plan cards carry provider-reported money too, and they follow the same rule: what was
// measured by default, a sum only when USD is chosen.
test("the plan cards hide local dollars and OpenRouter credit until USD is chosen", async (page, origin) => {
  plans = [
    { source: "grok", title: "Grok", kind: "local", weekly_usd: 1.25, weekly_tokens: 120000, period: { label: "This week" } },
    { source: "openrouter", title: "OpenRouter", kind: "api", limit: 20, limit_remaining: 5, usage_weekly: 3.5 },
  ];
  localRows = subscriptionRows();
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.locator("#live-status .live-row").first().waitFor();
  const cards = () => page.locator("#live-status").textContent();
  const measured = await cards();
  assert.doesNotMatch(measured, /\$/, "no provider or local dollars on a card until USD is chosen");
  assert.match(measured, /120K tokens/, "the local week still says what it measured");
  assert.match(measured, /25% of the credit limit left/, "a share is the same fact without a sum");
  assert.match(measured, /choose USD below for the amount/, "and it says where the amount is");

  await page.getByRole("button", { name: "Show this month in USD instead of tokens" }).click();
  await page.waitForFunction(() => /\$/.test(document.getElementById("live-status").textContent));
  const priced = await cards();
  assert.match(priced, /\$1\.25/, "the local week's dollars come back with the unit");
  assert.match(priced, /\$5\.00 left of \$20\.00/);
  assert.match(priced, /\$3\.50 billed by OpenRouter/);
});

// The engine's token rule counts reasoning tokens for Codex, OpenAI and Grok. A headline that
// dropped them would disagree with the bars the same payload drew.
test("token headlines count reasoning tokens exactly as the engine's buckets do", async (page, origin) => {
  localRows = [
    { model: "gpt-5", source: "codex-local", input_tokens: 100, output_tokens: 20, reasoning_tokens: 80, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.01 },
  ];
  await page.goto(`${origin}/?range=week`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#mix .mix-row").first().waitFor();
  assert.match(await totalsText(page), /200 tokens/, "reasoning tokens are part of the count");
  assert.equal((await page.locator("#mix .mix-val").first().textContent()).trim(), "200");
  assert.match(await page.locator("#totals .totals-main").getAttribute("title"), /80 reasoning/);
  // The bars come from the engine's own normalized bucket, so the two must agree.
  const labels = await page.locator("#daily-svg g.col").evaluateAll((g) => g.map((n) => n.getAttribute("aria-label")));
  assert.ok(labels.some((l) => /gpt-5 200/.test(l)), `the bar and the headline must agree: ${labels.join(" | ")}`);

  await page.getByRole("tab", { name: "Usage" }).click();
  await page.waitForFunction(() => /tokens/.test(document.getElementById("usage-totals").textContent));
  assert.match(await page.locator("#usage-totals").textContent(), /200 tokens/,
    "the monthly summary counts them the same way");
});

// ---------- model identity ----------

// A palette has four shades per family. A family with more models than that keeps every model:
// colour capacity is not a reason to drop a name into "Other models".
const manyModelLedger = () => [
  { key: "alpha", provider: "vercel-ai-gateway", model: "claude-sonnet-5", model_calls: 1, input_tokens: 700, output_tokens: 100, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.007 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "claude-opus-5", model_calls: 1, input_tokens: 600, output_tokens: 100, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.006 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "claude-haiku-4-5", model_calls: 1, input_tokens: 500, output_tokens: 100, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.005 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "claude-sonnet-4-5", model_calls: 1, input_tokens: 400, output_tokens: 100, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.004 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "claude-fable-5-1", model_calls: 2, input_tokens: 300, output_tokens: 100, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.003 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "claude-opus-4-8", model_calls: 1, input_tokens: 200, output_tokens: 100, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.002 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "gpt-5", model_calls: 1, input_tokens: 190, output_tokens: 10, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.001 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "gpt-5-mini", model_calls: 1, input_tokens: 180, output_tokens: 10, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.001 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "gpt-5-nano", model_calls: 1, input_tokens: 170, output_tokens: 10, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.001 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "o4-mini", model_calls: 1, input_tokens: 160, output_tokens: 10, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.001 },
  { key: "alpha", provider: "vercel-ai-gateway", model: "codex-mini", model_calls: 1, input_tokens: 150, output_tokens: 10, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: 0.001 },
];

test("more models than palette shades keeps every model named, coloured and filterable", async (page, origin) => {
  ledger = manyModelLedger();
  await openKeysSource(page, origin);
  await page.waitForFunction((n) => document.querySelectorAll("#mix .mix-row").length === n, ledger.length);

  const named = await page.locator("#mix .mix-name").allTextContents();
  assert.equal(named.length, ledger.length, "every model has its own legend row");
  assert.equal(new Set(named).size, named.length, "and no two rows are the same model");
  assert.ok(named.includes("claude-fable-5-1"), "a recognised model is named, never folded away");
  assert.ok(!named.includes("Other models"), "nothing is merged into Other to save colours");
  // Six Claude models and five OpenAI ones: both families overflow the four hand-picked shades.
  assert.equal(named.filter((m) => m.startsWith("claude-")).length, 6);
  assert.equal(named.filter((m) => /^(gpt-|o[1-9]|codex)/.test(m)).length, 5);

  // Each series keeps its own colour value, so a stack of eleven is still readable as eleven.
  const colours = await page.locator("#mix .mix-row").evaluateAll((rows) => rows.map((r) => r.style.getPropertyValue("--c")));
  assert.equal(new Set(colours).size, colours.length, `colours must stay distinct: ${colours.join(" | ")}`);

  // The totals count every model, and the bars in the day column do too.
  const totals = await totalsText(page);
  assert.match(totals, /12 requests/);
  assert.match(totals, /4\.2K tokens/);
  const labels = await page.locator("#daily-svg g.col").evaluateAll((g) => g.map((n) => n.getAttribute("aria-label")));
  assert.ok(labels.some((l) => /claude-fable-5-1 400/.test(l)), `fable must have its own bar: ${labels.join(" | ")}`);

  // And it filters like any other model: one row selected, one model charted.
  await page.locator('#mix .mix-row[data-model="claude-fable-5-1"]').click();
  await page.waitForFunction(() => document.querySelector('#mix .mix-row[data-model="claude-fable-5-1"]').getAttribute("aria-selected") === "true");
  const filtered = await page.locator("#daily-svg g.col").evaluateAll((g) => g.map((n) => n.getAttribute("aria-label")));
  assert.ok(filtered.every((l) => !/claude-opus-5/.test(l)), "a filtered chart draws the chosen model alone");
  assert.ok(filtered.some((l) => /claude-fable-5-1 400/.test(l)));

  // Today's hourly view is the same eleven models, so an hour cannot lose one the day kept.
  await page.getByRole("radio", { name: "Today" }).click();
  await page.waitForFunction(() => /by hour/.test(document.getElementById("daily-title").textContent));
  await page.waitForFunction((n) => document.querySelectorAll("#mix .mix-row").length === n, ledger.length);
  assert.ok((await page.locator("#mix .mix-name").allTextContents()).includes("claude-fable-5-1"));
});

test("a model no provider named stays unknown rather than borrowing a name", async (page, origin) => {
  ledger = manyModelLedger().concat([
    { key: "alpha", provider: "vercel-ai-gateway", model: "", model_calls: 1, input_tokens: 10, output_tokens: 0, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: null },
  ]);
  await openKeysSource(page, origin);
  await page.waitForFunction((n) => document.querySelectorAll("#mix .mix-row").length === n, ledger.length);
  const named = await page.locator("#mix .mix-name").allTextContents();
  assert.ok(named.includes("unknown"), `an unnamed model stays unknown: ${named.join(", ")}`);
});

// ---------- first use and experimental labelling ----------

test("an empty vault gets the first-use guide, dismisses it and keeps it in help", async (page, origin) => {
  keys = [];
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.locator("#onboard:visible").waitFor();
  const guide = await page.locator("#onboard").textContent();
  assert.match(guide, /Add a key/);
  assert.match(guide, /Keychain/);
  assert.match(guide, /Touch ID/);
  assert.match(guide, /login password/, "the password fallback is named, not implied");
  assert.match(guide, /You do not need a/, "an .env file is not required");
  assert.match(guide, /expiry/, "a grant is scoped and expires");
  assert.match(guide, /only those/, "only routed calls are observable");
  assert.doesNotMatch(guide, /\$/, "no invented usage or cost in the guide");
  // Cloning the help guide must not leave two elements answering to the same id.
  assert.equal(await page.locator("#guide").count(), 1);
  assert.equal(await page.locator("#guide-title").count(), 1);

  // Always reachable from help, whether or not the card is on screen.
  await page.locator("#onboard-help").click();
  await waitDialog(page, "dlg-help", true);
  assert.match(await page.locator("#dlg-help #guide").textContent(), /Add a key/);
  await page.locator("#dlg-help [data-close]").click();
  await waitDialog(page, "dlg-help", false);

  await page.locator("#onboard-dismiss").click();
  await page.waitForFunction(() => document.getElementById("onboard").hidden);
  await page.reload();
  await page.waitForLoadState("networkidle");
  assert.equal(await page.locator("#onboard").isHidden(), true, "a dismissed guide stays dismissed");
  await page.getByRole("button", { name: "Keyboard shortcuts" }).click();
  await waitDialog(page, "dlg-help", true);
  assert.match(await page.locator("#dlg-help").textContent(), /Getting started/);
});

test("a vault that already has keys is not interrupted by the first-use guide", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body tr[data-name="alpha"]').waitFor();
  await page.getByRole("tab", { name: "Usage" }).click();
  assert.equal(await page.locator("#onboard").isHidden(), true, "an existing user is not onboarded");
});

test("three panes: the shortcuts and arrow keys reach Usage, Chart and Keys and nothing else", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const tabNames = await page.locator(".seg [role=tab]").allTextContents();
  assert.deepEqual(tabNames.map((t) => t.trim()), ["Usage", "Chart", "Keys"]);
  const shown = () => page.evaluate(() =>
    [...document.querySelectorAll("main [role=tabpanel]")].filter((p) => !p.hidden).map((p) => p.id));
  await page.locator("body").click({ position: { x: 1, y: 1 } });
  for (const [key, pane] of [["2", "pane-chart"], ["3", "pane-keys"], ["1", "pane-usage"]]) {
    await page.keyboard.press(`ControlOrMeta+${key}`);
    await page.waitForFunction((id) => !document.getElementById(id).hidden, pane);
    assert.deepEqual(await shown(), [pane], `shortcut ${key}`);
  }
  await page.keyboard.press("ControlOrMeta+4");
  assert.deepEqual(await shown(), ["pane-usage"], "a fourth shortcut no longer switches panes");
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.keyboard.press("ArrowRight");
  await page.waitForFunction(() => !document.getElementById("pane-usage").hidden);
  assert.deepEqual(await shown(), ["pane-usage"], "the arrow keys wrap from Keys back to Usage");
  await page.getByRole("button", { name: "Keyboard shortcuts" }).click();
  await waitDialog(page, "dlg-help", true);
  assert.doesNotMatch(await page.locator("#dlg-help .shortcuts").textContent(), /Optimizer/);
});

// ---------- per-pane load failures ----------

// Each loader reports its own last result in its own pane. The two overlap
// routinely (the startup key load is still in flight when the Chart pane asks
// for spend), so neither pane's recovery may touch the other's failure.
const keysDown = { status: 500, raw: "vault is locked" };
const chartDown = { status: 503, body: { error: "engine_busy" } };
const slot = (page, id) => page.locator("#" + id).textContent();
const waitSlot = (page, id, want) =>
  page.waitForFunction(([id, want]) => document.getElementById(id).textContent === want, [id, want],
    { polling: 100, timeout: 5000 });

test("a chart request that fails leaves a sticky reason and no stale drawing", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  failures.set(rule("GET", "/api/spend"), chartDown);
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.getByRole("radio", { name: "This month" }).click();
  await waitSlot(page, "chart-error", "engine_busy");
  await page.waitForTimeout(4500);
  assert.equal(await slot(page, "chart-error"), "engine_busy", "a failed load must stay reported");
  assert.equal(await page.locator("#chart-error").isVisible(), true);

  failures.delete(rule("GET", "/api/spend"));
  await page.getByRole("radio", { name: "This week" }).click();
  await waitSlot(page, "chart-error", "");
  assert.equal(await page.locator("#chart-error").isVisible(), false, "an empty slot takes no space");
});

test("a key list that fails reports in the Keys pane and clears on reload", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  failures.set(rule("GET", "/api/keys"), keysDown);
  await page.getByRole("tab", { name: "Keys" }).click();
  await waitSlot(page, "keys-error", "vault is locked");

  failures.delete(rule("GET", "/api/keys"));
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.getByRole("tab", { name: "Keys" }).click();
  await waitSlot(page, "keys-error", "");
});

test("one pane recovering leaves the other pane's failure alone", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  failures.set(rule("GET", "/api/spend"), chartDown);
  await page.getByRole("tab", { name: "Chart" }).click();
  await waitSlot(page, "chart-error", "engine_busy");

  failures.set(rule("GET", "/api/keys"), keysDown);
  await page.getByRole("tab", { name: "Keys" }).click();
  await waitSlot(page, "keys-error", "vault is locked");

  failures.delete(rule("GET", "/api/spend"));
  await page.getByRole("tab", { name: "Chart" }).click();
  await waitSlot(page, "chart-error", "");
  assert.equal(await slot(page, "keys-error"), "vault is locked", "a chart recovery must not report the vault readable");

  failures.set(rule("GET", "/api/spend"), chartDown);
  await page.getByRole("radio", { name: "This month" }).click();
  await waitSlot(page, "chart-error", "engine_busy");
  failures.delete(rule("GET", "/api/keys"));
  await page.getByRole("tab", { name: "Keys" }).click();
  await waitSlot(page, "keys-error", "");
  assert.equal(await slot(page, "chart-error"), "engine_busy", "a key list must not report the chart recovered");
});

// ---------- failed requests ----------

// The engine dies between a copy and the refresh that copy defers by 2.5 s.
async function loseEngine(page) {
  await rowButton(page, "alpha", "copy").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Copied"));
  failures.set(rule("GET", "/api/keys"), "drop");
  await page.clock.runFor(2600);
  await page.locator("#engine-down").waitFor({ state: "visible" });
}

test("an unreachable engine shows a sticky banner", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await loseEngine(page);
  assert.equal(await slot(page, "engine-down"), "Engine is not answering. Run keys dashboard or keys menubar, then reload.");
  // The banner owns reachability, so the pane does not repeat it.
  assert.equal(await slot(page, "keys-error"), "");
  // Sticky: it must outlive the ordinary 4 s status timeout.
  await page.clock.runFor(5000);
  assert.equal(await page.locator("#engine-down").isVisible(), true);
});

test("the unreachable-engine banner clears when the engine answers again", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await loseEngine(page);

  // Recovery through the background status poll, with no user action to
  // take the banner down. A stale outage notice must not outlive the outage.
  failures.delete(rule("GET", "/api/keys"));
  await page.clock.runFor(16000);
  await page.locator("#engine-down").waitFor({ state: "hidden", timeout: 5000 });
  assert.doesNotMatch(await slot(page, "keys-error"), /Can't reach/);
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

    // The subscriptions scope is what the chart opens on; shoot it before leaving.
    await page.getByRole("tab", { name: "Chart" }).click();
    await page.locator("#scope-chips:visible").waitFor();
    await capture(page, `chart-subscriptions-${viewport.name}`, { fullPage: true });

    // The API keys scope: every provider and key, then one provider, then one key.
    await openKeysSource(page, origin);
    await capture(page, `chart-api-keys-all-${viewport.name}`, { fullPage: true });
    await page.getByRole("radio", { name: "Show only calls routed to TypeSafe" }).click();
    // The filtered answer has to land first, or the shot shows the previous view.
    await page.waitForFunction(() => new URL(location.href).searchParams.get("provider") === "typesafe"
      && document.querySelectorAll("#mix .mix-row").length === 1);
    await capture(page, `chart-api-keys-provider-${viewport.name}`, { fullPage: true });

    await page.getByRole("radio", { name: "Show every provider these keys reached" }).click();
    await page.waitForFunction(() => !new URL(location.href).searchParams.get("provider")
      && document.querySelectorAll("#mix .mix-row").length === 2);
    await page.getByRole("radio", { name: "Show only key charlie" }).click();
    await page.waitForFunction(() => new URL(location.href).searchParams.get("key") === "charlie"
      && document.querySelectorAll("#mix .mix-row").length === 1);
    await capture(page, `chart-api-keys-one-${viewport.name}`, { fullPage: true });

    // A family with more models than palette shades: every model keeps its name and its colour.
    reset();
    ledger = manyModelLedger();
    await openKeysSource(page, origin);
    await page.waitForFunction((n) => document.querySelectorAll("#mix .mix-row").length === n, ledger.length);
    await capture(page, `chart-many-models-${viewport.name}`, { fullPage: true });

    reset();
    keys = [];
    await page.reload();
    await page.waitForLoadState("networkidle");
    // First use: the guide on the Usage pane, before it is dismissed.
    await page.locator("#onboard:visible").waitFor();
    await capture(page, `first-use-guide-${viewport.name}`, { fullPage: true });
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

test("long key metadata keeps every action inside the viewport", async (page, origin) => {
  keys[0].name = "acceptance-" + "long-key-name-".repeat(8);
  keys[0].host = "api.openai.com";
  keys[0].gateway_enabled = true;
  keys[0].gateway_url = "http://127.0.0.1:12767/" + keys[0].name;
  keys[0].last_check = { ok: false, checked_at: "2026-09-22T05:00:00Z", summary: "Provider rejected the synthetic key. " + "LongDiagnosticWithoutSpaces".repeat(12) };
  await openKeys(page, origin, { expectEmpty: true });
  await page.locator("#keys-body tr[data-name]").first().waitFor();
  // The key list is drawn again once grants arrive. Resolving the row
  // inside the same evaluate measures the table as it is now, not a row that redraw detached
  // (which reads as a zero-width button; seen only when the warm suite ran fast enough).
  await page.waitForLoadState("networkidle");
  for (const width of [390, 520, 521, 600, 720, 768, 1024, 1280, 1440, 1920]) {
    await page.setViewportSize({ width, height: 900 });
    const geometry = await page.evaluate(() => {
      const row = document.querySelector('#keys-body tr[data-name]');
      return {
        viewport: innerWidth,
        tableRight: document.querySelector('#keys-table').getBoundingClientRect().right,
        actions: [...row.querySelectorAll('.row-actions button')].map(b => ({name:b.dataset.act,left:b.getBoundingClientRect().left,right:b.getBoundingClientRect().right,width:b.getBoundingClientRect().width}))
      };
    });
    assert.ok(geometry.tableRight <= width + 1, `table overflows at ${width}: ${geometry.tableRight}`);
    for (const action of geometry.actions) assert.ok(action.left >= 0 && action.right <= width + 1 && action.width > 0, `${action.name} outside viewport at ${width}: ${JSON.stringify(action)}`);
    await page.screenshot({path:path.join(screenshotDir, `keys-long-metadata-${width}.png`),fullPage:true});
  }
});

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
