#!/usr/bin/env node
// Keys dashboard against the *real* backend.
//
// Unlike test_keys_dashboard_ui.cjs, which drives the real Web assets against an
// in-memory Node fixture server, this suite drives them against the real Swift
// APIHandler, KeysService and HTTP response serialization over a real loopback
// socket. It does not start that server: Tests/KeysreallysafeTests/
// BackendContractUITests.swift binds an ephemeral port on a synthetic temporary
// vault and launches this script with the address. Run it that way:
//
//   KEYS_BACKEND_CONTRACT_UI=1 swift test --filter BackendContractUITests
//
// Real here: the page, the routing, the response shapes, the status codes, the
// headers, the catalog rows, the key events and the X-KSF-Token, Origin/Host and
// Sec-Fetch-Site gates. Mocked there: keychain storage, Touch ID, the clipboard,
// the optimizer encryption key, any provider call and analytics upload. Every
// secret below is invented for the harness; the suite never reaches a real
// vault, credential or network endpoint, and it neither relaxes nor bypasses the
// product's authentication: the cases that are refused are refused by the real
// gates, unmodified.
//
// Two clients appear below. Most cases run inside Chromium, where the real
// Origin, Host and Sec-Fetch-Site headers are the browser's to set. The
// authorization cases use a plain Node HTTP client over the same loopback
// socket, because a page is not allowed to forge those headers — that is what
// makes them forbidden header names, and it is exactly what has to be tested.
//
// The backend keeps state between cases, so the cases below are one ordered
// scenario over one live vault and the suite stops at the first failure rather
// than reporting cascaded noise.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require("playwright");

const base = process.env.KEYS_CONTRACT_BASE_URL;
const token = process.env.KEYS_CONTRACT_TOKEN;
const projectRoot = process.env.KEYS_CONTRACT_PROJECT_ROOT;
const ALPHA_SECRET = process.env.KEYS_CONTRACT_ALPHA_SECRET;
const DELTA_SECRET = process.env.KEYS_CONTRACT_DELTA_SECRET;
const guardFile = process.env.KEYS_CONTRACT_GUARD_FILE;
const screenshotDir = process.env.KEYS_CONTRACT_SCREENSHOT_DIR
  || path.join(__dirname, "../../.build/keys-backend-contract-screenshots");

for (const [name, value] of Object.entries({ base, token, projectRoot, ALPHA_SECRET, DELTA_SECRET })) {
  if (!value) {
    console.error(`test_backend_contract_ui.cjs: missing ${name}; run it through swift test --filter BackendContractUITests`);
    process.exit(2);
  }
}

const SEEDED = ["contract-alpha", "contract-bravo", "contract-typesafe", "contract-vercel"];
const NEW_KEY = "contract-delta";
// Written and removed by the non-browser control requests; never by a forged one.
const RAW_KEY = "contract-echo";
const RAW_SECRET = "sk-contract-echo-NEVER-REAL-000005";
// The name every forged request tries to create. It must never exist.
const INTRUDER = "contract-intruder";

// ---------- helpers ----------

const rowNames = (page) => page.locator("#keys-body tr[data-name]:not(.key-events-row)")
  .evaluateAll((rows) => rows.map((row) => row.dataset.name));
const rowCell = (page, name, cell) => page.locator(`#keys-body tr[data-name="${name}"] .td-${cell}`).first();
const rowButton = (page, name, act) => page.locator(`#keys-body tr[data-name="${name}"] [data-act="${act}"]`).first();
const status = (page) => page.locator("#status").textContent();
const waitDialog = (page, id, open) =>
  page.waitForFunction(([name, want]) => document.getElementById(name).open === want, [id, open]);

// Same-origin requests issued from the page itself, so the real Origin, Host and
// Sec-Fetch-Site gates apply exactly as they do to the dashboard's own calls.
function request(page, method, url, body, headers) {
  return page.evaluate(async ([method, url, body, headers]) => {
    const options = { method, headers: Object.assign({}, headers) };
    if (body !== null) {
      options.headers["Content-Type"] = "application/json";
      options.body = JSON.stringify(body);
    }
    const response = await fetch(url, options);
    const text = await response.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = { raw: text }; }
    return {
      status: response.status,
      data,
      contentType: response.headers.get("content-type"),
      cacheControl: response.headers.get("cache-control"),
      noSniff: response.headers.get("x-content-type-options"),
    };
  }, [method, url, body === undefined ? null : body, headers || {}]);
}

const post = (page, url, body, headers) =>
  request(page, "POST", url, body, Object.assign({ "X-KSF-Token": token }, headers || {}));
const get = (page, url) => request(page, "GET", url, undefined, {});

// A client outside the browser, because a page may not forge Origin or Host:
// both are forbidden header names for fetch, so the authorization cases below
// cannot be expressed from inside Chromium. Everything here still crosses the
// same real loopback socket into the same real APIHandler; only the headers are
// ours to choose. Nothing is sent without an explicit Host.
const backend = new URL(base);
const ALLOWED_HOST = `${backend.hostname}:${backend.port}`;
const ALLOWED_ORIGIN = `http://${ALLOWED_HOST}`;
const OTHER_PORT = Number(backend.port) === 65535 ? 1024 : Number(backend.port) + 1;

function raw(method, urlPath, options) {
  const { body, headers } = options || {};
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const sent = Object.assign({}, headers);
    if (payload) {
      sent["Content-Type"] = "application/json";
      sent["Content-Length"] = String(payload.length);
    }
    const req = http.request(
      { host: backend.hostname, port: backend.port, path: urlPath, method, headers: sent, setHost: false },
      (res) => {
        let text = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => { text += chunk; });
        res.on("end", () => {
          let data = null;
          try { data = text ? JSON.parse(text) : null; } catch { data = { raw: text }; }
          resolve({
            status: res.statusCode,
            data,
            contentType: res.headers["content-type"],
            cacheControl: res.headers["cache-control"],
            noSniff: res.headers["x-content-type-options"],
          });
        });
      }
    );
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function openKeys(page) {
  await page.goto(base, { waitUntil: "domcontentloaded" });
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body tr[data-name="contract-alpha"]').waitFor();
}

const checks = [];
const only = process.env.KEYS_CONTRACT_ONLY || "";
const test = (name, fn) => { if (!only || name.includes(only)) checks.push({ name, fn }); };

// The page leads with what was measured — tokens, and requests where the ledger counts them — and
// prices it only when asked. Every cost assertion below therefore chooses USD first. Both helpers
// are idempotent: asking for a unit the page is already in changes nothing.
const inUsd = () => document.querySelector('[data-unit="usd"]').getAttribute("aria-checked") === "true";
const chooseUsd = async (page) => {
  if (await page.evaluate(inUsd)) return;
  await page.getByRole("radio", { name: "USD", exact: true }).click();
  await page.waitForFunction(inUsd);
};
// The Keys pane's own switch, on the column it changes.
const chooseKeysUsd = async (page) => {
  if (await page.evaluate(inUsd)) return;
  await page.locator("#keys-unit").click();
  await page.waitForFunction(inUsd);
};

// ---------- the real key list ----------

test("the rendered list matches the real /api/keys payload field by field", async (page) => {
  await openKeys(page);
  const listed = await get(page, "/api/keys");
  assert.equal(listed.status, 200);
  assert.equal(listed.contentType, "application/json; charset=utf-8", "real JSON content type");
  assert.equal(listed.cacheControl, "no-store", "key listings must not be cached");
  assert.equal(listed.noSniff, "nosniff");

  const payload = listed.data.keys;
  assert.deepEqual(payload.map((k) => k.name).sort(), SEEDED, "the real vault rows");
  assert.deepEqual((await rowNames(page)).sort(), SEEDED, "every real row is rendered");
  assert.equal(await page.locator("#keys-count").textContent(), `${SEEDED.length} keys`);
  assert.equal(await page.locator("#keys-empty").isHidden(), true);

  // No secret may appear in a listing, whatever the real serializer emits.
  const raw = JSON.stringify(listed.data);
  assert.equal(raw.includes(ALPHA_SECRET), false, "a listing leaked a stored secret");
  assert.equal(/"secret"/.test(raw), false, "a listing carried a secret field");

  // Provider ids resolve through the real providers.json the server serves.
  const providers = await get(page, "/providers.json");
  assert.equal(providers.status, 200);
  const byId = new Map(providers.data.providers.map((p) => [p.id, p.name]));

  // The default unit is what this Mac measured, so the gateway column counts the real routed
  // requests for every key and puts no price on screen until USD is chosen.
  for (const key of payload) {
    const cell = (await rowCell(page, key.name, "usd").textContent()).trim();
    if (key.gateway_month_calls === 0) assert.match(cell, /^(—|no calls yet)$/, `${key.name}: an unrouted key counts nothing`);
    else assert.equal(cell, `${key.gateway_month_calls} ${key.gateway_month_calls === 1 ? "request" : "requests"}`,
      `${key.name}: the gateway column counts the real requests`);
  }
  assert.equal((await page.locator("#keys-table").textContent()).includes("$"), false, "no dollars until USD is chosen");
  // The switch sits on the column it changes, so the cost view is one click away from here.
  await chooseKeysUsd(page);

  for (const key of payload) {
    const expected = byId.get(key.provider) || key.provider;
    const cell = (await rowCell(page, key.name, "provider").textContent()).trim();
    assert.ok(cell.startsWith(expected),
      `${key.name}: provider cell ${JSON.stringify(cell)} does not start with the catalog name for ${key.provider}`);
    // Dates: the real ISO strings must parse, not fall through as raw text.
    const created = (await rowCell(page, key.name, "created").textContent()).trim();
    assert.notEqual(created, "—", `${key.name}: no created date rendered`);
    assert.notEqual(created, key.created_at, `${key.name}: created_at was not parsed as a date`);
    // Only the key the harness routed synthetic gateway calls through has been used.
    const used = (await rowCell(page, key.name, "used").textContent()).trim();
    if (key.last_used_at == null) assert.equal(used, "Never", `${key.name}: an untouched key reads as never used`);
    else assert.notEqual(used, "Never", `${key.name}: a routed key must show its real last-used time`);
    // The Check affordance is decided by the real provider catalog, not a fixture.
    assert.equal(await rowButton(page, key.name, "check").isDisabled(), !key.checkable,
      `${key.name}: Check enablement must follow checkable=${key.checkable}`);
    // Zero, unknown, priced and none are different things, and the real serializer says which.
    // A key the gateway never routed reads as no dollars, not $0.00; a key whose routed calls
    // carried no cost receipt reads as unpriced, not as zero either; a key whose calls could be
    // priced reads as a figure. The harness seeds one of each.
    const usdCell = (await rowCell(page, key.name, "usd").textContent()).trim();
    if (key.gateway_month_calls === 0) {
      assert.equal(key.usd_month, null, `${key.name}: an unrouted key has no dollars at all`);
      assert.equal(key.usd_month_kind, "none");
      assert.equal(usdCell, "—", `${key.name}: an unrouted key must not show a dollar figure`);
    } else if (key.usd_month_kind === "unknown") {
      assert.equal(key.usd_month, null, `${key.name}: an unpriced call is unknown, not zero`);
      assert.equal(usdCell, `${key.gateway_month_calls} calls, unpriced`);
    } else {
      assert.equal(key.usd_month_kind, "estimate", `${key.name}: a fully priced key reads as an estimate`);
      assert.ok(key.usd_month > 0, `${key.name}: a priced call must carry a figure`);
      assert.match(usdCell, /^\$/, `${key.name}: a priced key shows its dollars`);
    }
  }
});

test("the Optimizer affordance follows the real /api/optimizer/keys answer", async (page) => {
  await openKeys(page);
  const compatible = await get(page, "/api/optimizer/keys");
  assert.equal(compatible.status, 200);
  const names = compatible.data.keys.map((k) => k.name).sort();
  // Both Jev-capable providers in the vault qualify and nothing else does; the list is the real
  // adapter answer, not a fixture.
  assert.deepEqual(names, ["contract-typesafe", "contract-vercel"],
    "only the real optimizer-compatible providers qualify");
  assert.ok(compatible.data.providers.some((p) => p.id === "typesafe"), "the real adapter list");
  await rowButton(page, "contract-typesafe", "optimizer").waitFor();
  await rowButton(page, "contract-vercel", "optimizer").waitFor();
  assert.equal(await rowButton(page, "contract-alpha", "optimizer").count(), 0,
    "an incompatible key must not offer Optimizer");
});

// ---------- the real gateway ledger in the API keys view ----------

test("the API keys scope charts the real gateway ledger and keeps an unpriced cost unknown", async (page) => {
  await page.goto(base, { waitUntil: "domcontentloaded" });
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.getByRole("radio", { name: "API keys" }).click();
  await page.waitForFunction(() => document.querySelectorAll("#mix .mix-row").length > 0);

  // What the engine really answers for this scope, and what the page made of it.
  const served = await get(page, "/api/spend?range=month&by=model&source=keys");
  assert.equal(served.status, 200);
  assert.deepEqual(served.data.rows.map((r) => r.key).sort(), ["contract-typesafe", "contract-vercel"],
    "the real ledger names both keys");
  const ts = served.data.rows.find((r) => r.provider === "typesafe");
  assert.equal(ts.usd_estimate, null, "no receipt and no list price: unknown, not zero");
  assert.equal(ts.model_calls, 2);
  assert.equal(served.data.totals.gateway_calls, 3);
  assert.equal(served.data.totals.gateway_unpriced_calls, 2);
  assert.equal(JSON.stringify(served.data).includes(ALPHA_SECRET), false, "a report leaked a stored secret");

  // Default unit first: the real measured counts, and no price anywhere on the line.
  const measured = await page.locator("#totals").textContent();
  assert.match(measured, /3 requests/);
  assert.doesNotMatch(measured, /\$/, "no dollar figure until USD is chosen");

  await chooseUsd(page);
  const totals = await page.locator("#totals").textContent();
  assert.match(totals, /≥ ≈ \$/, "a partly priced real ledger is a floor, not a total");
  assert.match(totals, /3 requests/);
  assert.match(totals, /partial cost · 2 requests unpriced/);

  // The provider picker offers both real providers by name, and choosing one asks the real engine.
  assert.deepEqual(await page.locator("#provider-filter [data-provider-filter]").evaluateAll((els) => els.map((e) => e.textContent)),
    ["All providers", "TypeSafe", "Vercel AI Gateway"]);
  await page.getByRole("radio", { name: "Show only calls routed to TypeSafe" }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("provider") === "typesafe");
  await page.waitForFunction(() => /cost unknown/.test(document.getElementById("totals").textContent));
  const tsServed = await get(page, "/api/spend?range=month&by=model&source=keys&provider=typesafe");
  assert.equal(tsServed.data.totals.gateway_calls, 2);
  assert.equal(tsServed.data.totals.gateway_usd_estimate, null, "TypeSafe gains no price by being filtered to");
  assert.equal(await page.locator("#mix .mix-name").first().textContent(), "system-one");
  // The key picker narrows with the provider: this one has exactly one key.
  assert.deepEqual(await page.locator("#keys-filter [data-key-filter]").evaluateAll((els) => els.map((e) => e.textContent)),
    ["All keys", "contract-typesafe"]);
  // A provider outside the gateway ledger is refused rather than answered with a local view.
  assert.equal((await get(page, "/api/spend?range=month&by=model&source=all&provider=typesafe")).status, 400);

  // The per-key picker offers the real key by name, and filtering asks the real engine for it.
  await page.getByRole("radio", { name: "Show only key contract-typesafe" }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("key") === "contract-typesafe");
  await page.waitForFunction(() => document.querySelectorAll("#mix .mix-row").length === 1);
  const keyed = await get(page, "/api/spend?range=month&by=model&source=keys&key=contract-typesafe");
  assert.equal(keyed.data.totals.gateway_calls, 2);
  const other = await get(page, "/api/spend?range=month&by=model&source=keys&key=contract-alpha");
  assert.deepEqual(other.data.rows, [], "a key with no routed calls has no ledger");

  // Requests are countable even here, where no token count exists.
  await page.getByRole("radio", { name: "Requests" }).click();
  await page.waitForFunction(() => document.getElementById("daily-unit").textContent.startsWith("requests per"));
  const labels = await page.locator("#daily-svg g.col").evaluateAll((g) => g.map((n) => n.getAttribute("aria-label")));
  assert.ok(labels.some((l) => /system-one 2/.test(l)), `no request bar was drawn: ${labels.join(" | ")}`);

  // The local scope is untouched by all of this.
  const local = await get(page, "/api/spend?range=month&by=model&source=all");
  assert.equal(local.data.totals.gateway_calls, 3, "the local view still reports the gateway separately");
  assert.equal(local.data.rows.some((r) => r.key === "contract-typesafe"), false,
    "gateway rows must not enter the local ledger");
});

test("a real key opened from the Keys table cannot inherit another provider's filter", async (page) => {
  const spend = [];
  page.on("request", (r) => {
    const u = new URL(r.url());
    if (u.pathname === "/api/spend") spend.push(u.search);
  });
  await page.goto(base, { waitUntil: "domcontentloaded" });
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.getByRole("radio", { name: "API keys" }).click();
  await page.waitForFunction(() => document.querySelectorAll("#mix .mix-row").length > 0);
  await page.getByRole("radio", { name: "Show only calls routed to TypeSafe" }).click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("provider") === "typesafe");

  // contract-vercel belongs to the other provider, and its real ledger holds one priced call.
  // The drilldown has to show that call, not the empty intersection of two filters that cannot
  // both hold of the same key.
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body tr[data-name="contract-vercel"]').waitFor();
  await page.locator('#keys-body tr[data-name="contract-vercel"] .td-usd').first().click();
  await page.waitForFunction(() => new URL(location.href).searchParams.get("key") === "contract-vercel");
  await page.waitForFunction(() => /1 request/.test(document.getElementById("totals").textContent));
  assert.notEqual(new URL(page.url()).searchParams.get("provider"), "typesafe");
  const keyed = spend.filter((s) => s.includes("key=contract-vercel"));
  assert.ok(keyed.length > 0 && keyed.every((s) => !s.includes("provider=typesafe")),
    `a TypeSafe filter survived a Vercel key: ${keyed.join(" | ")}`);
  assert.equal(await page.locator("#mix .mix-name").first().textContent(), "claude-sonnet-5");

  // And the engine confirms what the page refused to ask for really would have been empty.
  const crossed = await get(page, "/api/spend?range=month&by=model&source=keys&key=contract-vercel&provider=typesafe");
  assert.equal(crossed.status, 200, "a key of another provider is an empty intersection, not an error");
  assert.deepEqual(crossed.data.rows, []);
});

// ---------- create, edit, reveal, copy, delete against the real vault ----------

test("the add dialog creates a real key through POST /api/keys", async (page) => {
  await openKeys(page);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=name]").fill(NEW_KEY);
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=notes]").fill("created by the contract harness");
  await page.locator("#add-form [name=secret]").fill(DELTA_SECRET);
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  await page.locator(`#keys-body tr[data-name="${NEW_KEY}"]`).waitFor();
  assert.equal(await status(page), `Added ${NEW_KEY}.`);
  assert.equal(await page.locator("#keys-count").textContent(), `${SEEDED.length + 1} keys`);

  const listed = await get(page, "/api/keys");
  const row = listed.data.keys.find((k) => k.name === NEW_KEY);
  assert.ok(row, "the real backend must now list the created key");
  assert.equal(row.provider, "openai");
  assert.equal(row.kind, "runtime");
  assert.equal(row.notes, "created by the contract harness");
  assert.equal(row.version, 1);
  assert.equal(JSON.stringify(listed.data).includes(DELTA_SECRET), false, "the typed secret must not come back");
});

test("a duplicate name surfaces the real 409 already_exists", async (page) => {
  await openKeys(page);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=name]").fill("contract-alpha");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill("sk-contract-duplicate-NEVER-REAL");
  await page.locator("#add-form [type=submit]").click();
  await page.waitForFunction(() => document.getElementById("add-err").textContent !== "");
  assert.equal(await page.locator("#add-err").textContent(), "A key with that name already exists.");
  assert.equal(await page.locator("#dlg-add").evaluate((d) => d.open), true);
  await page.locator("#dlg-add [data-close]").click();
  await waitDialog(page, "dlg-add", false);
  // The refusal changed nothing in the real vault.
  const listed = await get(page, "/api/keys");
  assert.equal(listed.data.keys.filter((k) => k.name === "contract-alpha").length, 1);
});

test("the edit dialog patches the real row and the list reflects the stored values", async (page) => {
  await openKeys(page);
  await rowButton(page, NEW_KEY, "edit").click();
  await waitDialog(page, "dlg-edit", true);
  await page.locator("#edit-form [name=kind]").selectOption("billing");
  await page.locator("#edit-form [name=notes]").fill("edited by the contract harness");
  await page.locator("#edit-form [type=submit]").click();
  await waitDialog(page, "dlg-edit", false);
  assert.equal(await status(page), `Saved ${NEW_KEY}.`);
  await page.waitForFunction((name) => {
    const row = document.querySelector(`#keys-body tr[data-name="${name}"] .td-kind`);
    return row && row.textContent.trim() === "billing";
  }, NEW_KEY);
  assert.equal((await rowCell(page, NEW_KEY, "name").textContent()).includes("edited by the contract harness"), true);
  const row = (await get(page, "/api/keys")).data.keys.find((k) => k.name === NEW_KEY);
  assert.equal(row.kind, "billing");
  assert.equal(row.notes, "edited by the contract harness");
});

test("reveal returns exactly the secret the dialog stored", async (page) => {
  await openKeys(page);
  await rowButton(page, NEW_KEY, "reveal").click();
  await waitDialog(page, "dlg-reveal", true);
  assert.equal(await page.locator("#reveal-name").textContent(), NEW_KEY);
  assert.equal(await page.locator("#reveal-secret").textContent(), DELTA_SECRET,
    "the create/store/reveal round trip must return the typed secret unchanged");
  assert.match(await page.locator("#reveal-timer").textContent(), /Hides in 15 s/);
  await page.locator("#dlg-reveal [data-close]").click();
  await waitDialog(page, "dlg-reveal", false);
  await page.waitForFunction(() => document.getElementById("reveal-secret").textContent === "");
});

test("copy reports the real wipe deadline and marks the row used", async (page) => {
  await openKeys(page);
  await rowButton(page, "contract-alpha", "copy").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Copied"));
  assert.equal(await status(page), "Copied contract-alpha. Clipboard wipes in 20 s.",
    "the wipe deadline comes from the real ClipboardWipe setting");
  assert.equal((await rowCell(page, "contract-alpha", "used").textContent()).trim(), "Just now");
  // The real backend recorded the use before it answered, so a fresh listing
  // must agree with the optimistic cell the click wrote.
  const row = (await get(page, "/api/keys")).data.keys.find((k) => k.name === "contract-alpha");
  assert.ok(row.last_used_at, "the real copy route must stamp last_used_at");
  assert.ok(!Number.isNaN(Date.parse(row.last_used_at)), `unparseable last_used_at ${row.last_used_at}`);
});

test("the history pane shows the real key events the backend recorded", async (page) => {
  await openKeys(page);
  const events = await get(page, "/api/keys/contract-alpha/events?limit=50");
  assert.equal(events.status, 200);
  const actions = events.data.events.map((e) => e.action);
  assert.ok(actions.includes("copy"), `expected a recorded copy, got ${JSON.stringify(actions)}`);
  assert.ok(actions.includes("add"), `expected a recorded add, got ${JSON.stringify(actions)}`);
  assert.equal(JSON.stringify(events.data).includes(ALPHA_SECRET), false, "an event log leaked a secret");
  await rowButton(page, "contract-alpha", "history").click();
  await page.locator("#keys-body .key-events-row .key-events").waitFor();
  const rendered = await page.locator("#keys-body .key-events-row .ev-action").allTextContents();
  assert.equal(rendered.length, actions.length, "every real event must be rendered");
  assert.ok(rendered.includes("copied"), `the rendered history omits the real copy: ${JSON.stringify(rendered)}`);
  assert.ok(rendered.includes("added"), `the rendered history omits the real add: ${JSON.stringify(rendered)}`);
  await rowButton(page, "contract-alpha", "history").click();
});

test("delete removes the real row and its stored secret", async (page) => {
  await openKeys(page);
  await rowButton(page, NEW_KEY, "delete").click();
  await waitDialog(page, "dlg-delete", true);
  assert.equal(await page.locator("#delete-name").textContent(), NEW_KEY);
  await page.locator("#delete-confirm").click();
  await waitDialog(page, "dlg-delete", false);
  await page.waitForFunction((name) => !document.querySelector(`#keys-body tr[data-name="${name}"]`), NEW_KEY);
  assert.equal(await status(page), `Deleted ${NEW_KEY}.`);
  assert.deepEqual((await rowNames(page)).sort(), SEEDED);

  // Deleting again is a real 404 the dashboard translates, not a silent success.
  const again = await request(page, "DELETE", `/api/keys/${NEW_KEY}`, undefined, { "X-KSF-Token": token });
  assert.equal(again.status, 404);
  assert.equal(again.data.error, "not_found");
});

// ---------- the real authorization gates ----------

// The suite above only ever sends requests the backend should accept, so it
// would still pass with the token gate or the same-origin gate deleted. These
// cases send the requests the gates exist to refuse, and then check the vault.
test("the real token gate refuses a missing, empty, wrong or truncated X-KSF-Token", async (page) => {
  await openKeys(page);
  const before = (await get(page, "/api/keys")).data.keys;
  assert.deepEqual(before.map((k) => k.name).sort(), SEEDED);

  // Control first. The same non-browser client, carrying the real token and a
  // real same-origin Host and Origin, is accepted — so a refusal below is the
  // gate answering, not an artefact of sending the request this way.
  const accepted = await raw("POST", "/api/keys", {
    body: { name: RAW_KEY, provider: "openai", kind: "runtime", notes: "loopback control", secret: RAW_SECRET },
    headers: { Host: ALLOWED_HOST, Origin: ALLOWED_ORIGIN, "X-KSF-Token": token },
  });
  assert.equal(accepted.status, 201, `the same-origin control was refused: ${JSON.stringify(accepted.data)}`);

  const forged = [
    ["no X-KSF-Token at all", {}],
    ["an empty X-KSF-Token", { "X-KSF-Token": "" }],
    ["a wrong X-KSF-Token of the right length", { "X-KSF-Token": "z".repeat(token.length) }],
    ["a truncated X-KSF-Token", { "X-KSF-Token": token.slice(0, -1) }],
    ["an X-KSF-Token with a trailing byte", { "X-KSF-Token": `${token}z` }],
  ];
  for (const [why, extra] of forged) {
    const headers = Object.assign({ Host: ALLOWED_HOST, Origin: ALLOWED_ORIGIN }, extra);
    const created = await raw("POST", "/api/keys", {
      body: { name: INTRUDER, provider: "openai", kind: "runtime", notes: "", secret: "sk-never-stored" },
      headers,
    });
    assert.equal(created.status, 403, `POST /api/keys with ${why} was not refused: ${JSON.stringify(created.data)}`);
    assert.equal(created.data.error, "missing or bad token", `POST with ${why}: wrong refusal`);

    const removed = await raw("DELETE", `/api/keys/${RAW_KEY}`, { headers });
    assert.equal(removed.status, 403, `DELETE with ${why} was not refused: ${JSON.stringify(removed.data)}`);
    assert.equal(removed.data.error, "missing or bad token");

    const patched = await raw("PATCH", `/api/keys/${RAW_KEY}`, {
      body: { kind: "billing", notes: "forged" },
      headers,
    });
    assert.equal(patched.status, 403, `PATCH with ${why} was not refused: ${JSON.stringify(patched.data)}`);
    assert.equal(patched.data.error, "missing or bad token");
  }

  // Nothing any of that attempted reached the vault.
  const after = (await get(page, "/api/keys")).data.keys;
  assert.equal(after.some((k) => k.name === INTRUDER), false, "a refused POST created a key");
  const echo = after.find((k) => k.name === RAW_KEY);
  assert.ok(echo, "a refused DELETE removed the key it was refused for");
  assert.equal(echo.kind, "runtime", "a refused PATCH changed the stored kind");
  assert.equal(echo.notes, "loopback control", "a refused PATCH changed the stored notes");
  assert.equal(echo.version, 1, "a refused PATCH bumped the stored version");
  assert.deepEqual(
    after.filter((k) => k.name !== RAW_KEY).map((k) => k.name).sort(), SEEDED,
    "the refused requests changed the vault"
  );
});

test("the real same-origin gate refuses a disallowed Origin or Host even with the right token", async (page) => {
  await openKeys(page);
  const before = (await get(page, "/api/keys")).data.keys;
  const echoBefore = before.find((k) => k.name === RAW_KEY);
  assert.ok(echoBefore, "the loopback control key must still be here");

  // Every case below carries the real token, so only the Origin/Host gate can
  // be the one refusing.
  const forged = [
    ["a cross-site Origin", { Host: ALLOWED_HOST, Origin: "http://attacker.example" }],
    ["an Origin on another port", { Host: ALLOWED_HOST, Origin: `http://127.0.0.1:${OTHER_PORT}` }],
    ["an https Origin", { Host: ALLOWED_HOST, Origin: `https://${ALLOWED_HOST}` }],
    ["an Origin naming a non-loopback host", { Host: ALLOWED_HOST, Origin: `http://10.0.0.1:${backend.port}` }],
    ["a foreign Host", { Host: "attacker.example", Origin: ALLOWED_ORIGIN }],
    ["a Host on another port", { Host: `127.0.0.1:${OTHER_PORT}`, Origin: ALLOWED_ORIGIN }],
    ["a bare Host with no port", { Host: backend.hostname, Origin: ALLOWED_ORIGIN }],
    ["no Host header at all", { Origin: ALLOWED_ORIGIN }],
  ];
  for (const [why, headers] of forged) {
    const sent = Object.assign({ "X-KSF-Token": token }, headers);
    const created = await raw("POST", "/api/keys", {
      body: { name: INTRUDER, provider: "openai", kind: "runtime", notes: "", secret: "sk-never-stored" },
      headers: sent,
    });
    assert.equal(created.status, 403, `POST /api/keys with ${why} was not refused: ${JSON.stringify(created.data)}`);
    assert.equal(created.data.error, "forbidden", `POST with ${why}: wrong refusal`);

    const removed = await raw("DELETE", `/api/keys/${RAW_KEY}`, { headers: sent });
    assert.equal(removed.status, 403, `DELETE with ${why} was not refused: ${JSON.stringify(removed.data)}`);
    assert.equal(removed.data.error, "forbidden");

    // The gate is not a read/write distinction: a listing is refused too, and
    // so no forged request may see a name, a provider or a note.
    const listed = await raw("GET", "/api/keys", { headers: sent });
    assert.equal(listed.status, 403, `GET /api/keys with ${why} was not refused`);
    assert.equal(listed.data.error, "forbidden");
    assert.equal(listed.data.keys, undefined, `GET with ${why} leaked the vault listing`);
  }

  // A cross-site Sec-Fetch-Site is refused on the routes that carry a secret,
  // and the refusal is not recorded as a use.
  const eventsBefore = (await get(page, `/api/keys/contract-alpha/events?limit=50`)).data.events.length;
  const revealed = await raw("POST", "/api/keys/contract-alpha/reveal", {
    body: {},
    headers: { Host: ALLOWED_HOST, Origin: ALLOWED_ORIGIN, "X-KSF-Token": token, "Sec-Fetch-Site": "cross-site" },
  });
  assert.equal(revealed.status, 403, `a cross-site reveal was not refused: ${JSON.stringify(revealed.data)}`);
  assert.equal(revealed.data.error, "forbidden");
  assert.equal(JSON.stringify(revealed.data).includes(ALPHA_SECRET), false, "a refused reveal returned the secret");
  const eventsAfter = (await get(page, `/api/keys/contract-alpha/events?limit=50`)).data.events.length;
  assert.equal(eventsAfter, eventsBefore, "a refused reveal was recorded as a use");

  // An unlock refused by the token gate hands out no session and opens none.
  const unlocked = await raw("POST", "/api/optimizer/unlock", {
    body: { minutes: 30, writable: true },
    headers: { Host: ALLOWED_HOST, Origin: ALLOWED_ORIGIN },
  });
  assert.equal(unlocked.status, 403, `an untokened unlock was not refused: ${JSON.stringify(unlocked.data)}`);
  assert.equal(unlocked.data.error, "missing or bad token");
  assert.equal(unlocked.data.token, undefined, "a refused unlock handed out a session token");
  assert.equal((await get(page, "/api/optimizer/status")).data.unlocked, false,
    "a refused unlock opened an optimizer session");

  // The vault is byte-for-byte what it was, and the documented loopback alias
  // still works: the control key goes out the way it came in.
  const after = (await get(page, "/api/keys")).data.keys;
  assert.deepEqual(after, before, "a refused request changed the vault");
  const removed = await raw("DELETE", `/api/keys/${RAW_KEY}`, {
    headers: {
      Host: `localhost:${backend.port}`,
      Origin: `http://localhost:${backend.port}`,
      "X-KSF-Token": token,
    },
  });
  assert.equal(removed.status, 200, `the documented localhost alias was refused: ${JSON.stringify(removed.data)}`);
  await openKeys(page);
  assert.deepEqual((await rowNames(page)).sort(), SEEDED, "the page must agree the vault is back to its seed");
});

// ---------- the optimizer usage ledger over the real HTTP stack ----------

test("a reused event id across tasks is refused with 409 while a same-task retry stays idempotent", async (page) => {
  await openKeys(page);
  const unlocked = await post(page, "/api/optimizer/unlock", { minutes: 30, writable: true });
  assert.equal(unlocked.status, 200, JSON.stringify(unlocked.data));
  const session = unlocked.data.token;
  const rpc = (operation, payload) =>
    post(page, "/api/optimizer/rpc", { operation, payload }, { "X-KSF-Optimizer": session });

  const project = await rpc("project_save", {
    name: "Contract harness", root: projectRoot, mode: "suggest", storage_enabled: true,
    provider_enabled: false, retention_days: 30, max_requests: 10, max_input_tokens: 60000,
  });
  assert.equal(project.status, 200, JSON.stringify(project.data));
  const projectID = project.data.id;

  const baseline = await rpc("task_start", { project_id: projectID, client: "contract-harness" });
  const treatment = await rpc("task_start", { project_id: projectID, client: "contract-harness" });
  assert.equal(baseline.status, 200, JSON.stringify(baseline.data));
  assert.equal(treatment.status, 200, JSON.stringify(treatment.data));
  assert.notEqual(baseline.data.id, treatment.data.id);

  const event = {
    project_id: projectID, event_id: "turn-1", source: "client", kind: "model_call",
    model: "synthetic", input_tokens: 100, output_tokens: 10, reported_cost_usd: 0,
    latency_ms: 1, status: "success",
  };
  const first = await rpc("event_record", Object.assign({}, event, { task_id: baseline.data.id }));
  assert.equal(first.status, 200, JSON.stringify(first.data));
  assert.equal(first.data.deduplicated, false);

  const retry = await rpc("event_record", Object.assign({}, event, { task_id: baseline.data.id }));
  assert.equal(retry.status, 200, "an ordinary same-task retry must still succeed");
  assert.equal(retry.data.deduplicated, true);
  assert.equal(retry.data.deduplication, "event_id");

  const crossed = await rpc("event_record", Object.assign({}, event, { task_id: treatment.data.id, input_tokens: 40 }));
  assert.equal(crossed.status, 409, `expected a conflict, got ${crossed.status} ${JSON.stringify(crossed.data)}`);
  assert.equal(crossed.data.error, "optimizer_changed");
  assert.equal(crossed.contentType, "application/json; charset=utf-8");
  assert.equal(crossed.cacheControl, "no-store");
  assert.equal(crossed.noSniff, "nosniff");

  // The refusal wrote nothing: one event, still under the baseline task.
  const listed = await rpc("event_list", { project_id: projectID });
  assert.equal(listed.status, 200, JSON.stringify(listed.data));
  assert.equal(listed.data.events.length, 1);
  assert.equal(listed.data.events[0].task_id, baseline.data.id);
  assert.equal(listed.data.events[0].input_tokens, 100);

  const closed = await post(page, "/api/optimizer/close", {}, { "X-KSF-Optimizer": session });
  assert.equal(closed.status, 200);
  const afterClose = await rpc("event_list", { project_id: projectID });
  assert.equal(afterClose.status, 403, "a closed session must lose content access");
});

// ---------- screenshots ----------

const viewports = [
  { name: "desktop", width: 1440, height: 900 },
  { name: "mobile", width: 390, height: 844 },
];

async function shoot(browser) {
  const taken = [];
  for (const viewport of viewports) {
    const page = await browser.newPage({ viewport: { width: viewport.width, height: viewport.height } });
    try {
      await openKeys(page);
      const list = path.join(screenshotDir, `backend-contract-keys-${viewport.name}.png`);
      await page.screenshot({ path: list, animations: "disabled", fullPage: true });
      taken.push(list);

      await rowButton(page, "contract-alpha", "reveal").click();
      await waitDialog(page, "dlg-reveal", true);
      const reveal = path.join(screenshotDir, `backend-contract-reveal-${viewport.name}.png`);
      await page.screenshot({ path: reveal, animations: "disabled" });
      taken.push(reveal);
      await page.locator("#dlg-reveal [data-close]").click();
      await waitDialog(page, "dlg-reveal", false);
    } finally {
      await page.close();
    }
  }
  const smallest = taken.filter((file) => /keys-/.test(file)).map((file) => fs.statSync(file).size);
  assert.ok(Math.min(...smallest) > 20000, "a key-list screenshot is suspiciously blank");
  return taken;
}

// ---------- runner ----------

// How long a signalled run may spend closing the browser politely before the
// browser's process group is killed outright. Kept below the host's own grace
// window so this process, not the host, is normally the one that cleans up.
const HARD_CLOSE_MS = Number(process.env.KEYS_CONTRACT_HARD_CLOSE_MS || 5000);

(async () => {
  fs.mkdirSync(screenshotDir, { recursive: true });
  // launchServer rather than launch, because the host needs the browser's pid.
  // Playwright launches Chromium detached, so it leads a process group of its
  // own: killing this process alone would leave that group running, and a host
  // that guessed at it would be reaching for processes it did not start.
  const server = await chromium.launchServer();
  const browserPID = server.process().pid;
  if (guardFile) {
    // Process *group* ids, not pids, and the host signals them as such. Both
    // are group leaders: the host spawned this process into a group of its own,
    // and Playwright launches Chromium detached, which makes it the leader of
    // one. Naming the groups rather than the leaders is what lets the host
    // still reap a browser whose own leader has exited with children behind it.
    // Written before any test runs, so the host can do that even if this
    // process is killed in the next instant.
    const owned = { node_group: process.pid, browser_group: browserPID };
    fs.writeFileSync(guardFile, `${JSON.stringify(owned)}\n`);
  }
  const browser = await chromium.connect(server.wsEndpoint());

  const closeAll = async () => {
    await browser.close().catch(() => {});
    await server.close().catch(() => {});
  };
  // The Swift host terminates this process if it overruns its watchdog; the
  // browser must not outlive it, and the polite close must not be unbounded
  // either. If it wedges, the browser's own group is killed by pid — never by
  // name and never by pattern.
  for (const signal of ["SIGTERM", "SIGINT"]) {
    process.once(signal, () => {
      const hard = setTimeout(() => {
        try { process.kill(-browserPID, "SIGKILL"); } catch { /* already gone */ }
        process.exit(1);
      }, HARD_CLOSE_MS);
      hard.unref();
      closeAll().finally(() => process.exit(1));
    });
  }
  let failed = null;
  let passed = 0;
  try {
    for (const check of checks) {
      const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
      const pageErrors = [];
      page.on("pageerror", (error) => pageErrors.push(error.message));
      try {
        await check.fn(page);
        assert.deepEqual(pageErrors, [], `${check.name}: page errors`);
        console.log(`  ok  ${check.name}`);
        passed += 1;
      } catch (error) {
        failed = check.name;
        console.error(`  FAIL  ${check.name}\n        ${String(error.message).split("\n").join("\n        ")}`);
      } finally {
        await page.close();
      }
      // The backend carries state forward, so a later case would only report
      // damage the failed one did.
      if (failed) break;
    }
    if (!failed) {
      const shots = await shoot(browser);
      console.log(`  ok  screenshots (${shots.length}) in ${screenshotDir}`);
    }
  } finally {
    await closeAll();
  }
  if (failed) {
    console.error(`\nBackend contract UI: stopped at "${failed}" after ${passed} of ${checks.length} cases`);
    process.exit(1);
  }
  console.log(`\nBackend contract UI passed: ${checks.length} cases against ${base}, screenshots in ${screenshotDir}`);
})().catch((error) => { console.error(error); process.exit(1); });
