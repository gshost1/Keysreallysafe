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
// Sec-Fetch-Site gates the page's own requests pass. Mocked there: keychain
// storage, Touch ID, the clipboard, any provider call and analytics upload.
// Every secret below is invented for the harness; the suite never reaches a real
// vault, credential or network endpoint, and it neither relaxes nor bypasses the
// product's authentication. The forged-request matrix (bad tokens, foreign
// Origin and Host) is ServerTests.testDashboardGatesRefuseForgedTokenOriginAndHost,
// because a page may not set those headers.
//
// The backend keeps state between cases, so the cases below are one ordered
// scenario over one live vault and the suite stops at the first failure rather
// than reporting cascaded noise.
const assert = require("node:assert/strict");
const { chromium } = require("playwright");

const base = process.env.KEYS_CONTRACT_BASE_URL;
const token = process.env.KEYS_CONTRACT_TOKEN;
const ALPHA_SECRET = process.env.KEYS_CONTRACT_ALPHA_SECRET;
const DELTA_SECRET = process.env.KEYS_CONTRACT_DELTA_SECRET;

for (const [name, value] of Object.entries({ base, token, ALPHA_SECRET, DELTA_SECRET })) {
  if (!value) {
    console.error(`test_backend_contract_ui.cjs: missing ${name}; run it through swift test --filter BackendContractUITests`);
    process.exit(2);
  }
}

const SEEDED = ["contract-alpha", "contract-bravo", "contract-typesafe", "contract-vercel"];
const NEW_KEY = "contract-delta";

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

const get = (page, url) => request(page, "GET", url, undefined, {});

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

// ---------- runner ----------

(async () => {
  const browser = await chromium.launch();
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
  } finally {
    await browser.close().catch(() => {});
  }
  if (failed) {
    console.error(`\nBackend contract UI: stopped at "${failed}" after ${passed} of ${checks.length} cases`);
    process.exit(1);
  }
  console.log(`\nBackend contract UI passed: ${checks.length} cases against ${base}`);
})().catch((error) => { console.error(error); process.exit(1); });
