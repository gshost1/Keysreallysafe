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
const asset = (name) => fs.readFileSync(path.join(root, "Web", name));
const html = asset("index.html").toString("utf8").replace("<head>", '<head><meta name="ksf-token" content="test-token">');
const assets = new Map([
  ["/", ["text/html; charset=utf-8", html]],
  ["/app.js", ["application/javascript", asset("app.js")]],
  ["/analytics.js", ["application/javascript", ""]],
  ["/styles.css", ["text/css", asset("styles.css")]],
  ["/providers.json", ["application/json", asset("providers.json")]],
  ["/icon.png", ["image/png", asset("icon.png")]],
  ["/icon.svg", ["image/svg+xml", asset("icon.svg")]],
]);

// The merged catalog the engine serves at /api/providers, mirrored from the shipped file: the
// dashboard skips `hidden` records in the Add dialog while the key table still names them.
const shippedCatalog = JSON.parse(asset("providers.json").toString("utf8"));
const providersCatalog = () => ({
  groups: [{ id: "yours", name: "Yours" }, ...shippedCatalog.groups],
  providers: [
    // A custom id overrides a shipped one, so the override replaces it in the listing.
    ...customProviders.map((p) => ({ ...p, custom: true, hidden: null })),
    ...shippedCatalog.providers
      .filter((p) => !customProviders.some((c) => c.id === p.id))
      .map((p) => ({
        ...p,
        custom: false,
        hidden: p.hidden ? "app" : (hiddenUsers.has(p.id) ? "user" : null),
      })),
  ],
});

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
let keys, ledger, localRows, plans, failures, delays, requests, unexpected, fixtureSecrets, rotations, customProviders, hiddenUsers, limits, subscriptions, nextSubId, grants, profiles, preferences;

function reset() {
  keys = baseKeys();
  fixtureSecrets = new Map(keys.map(k => [k.name, SECRET]));
  rotations = [];
  customProviders = [];
  hiddenUsers = new Set();
  // "source/window" -> token limit, mirroring the engine's usage_limits rows.
  limits = new Map();
  ledger = baseLedger();
  localRows = [];
  // The plan cards. Empty unless a test fills it, as most of this suite expects.
  plans = [];
  // The subscriptions the user pinned on the Usage pane, mirroring the engine's rows.
  subscriptions = [];
  nextSubId = 1;
  failures = new Map();   // "METHOD /path" -> {status, body} | "drop"
  delays = new Map();     // "METHOD /path" -> milliseconds
  requests = [];
  unexpected = [];
  // The active grants GET /api/grants answers. Empty unless a test fills it.
  grants = [];
  // The saved grant bounds (the engine's grant_profiles rows): names and scope numbers only,
  // exactly the fields the real /api/profiles answers with. Empty unless a test fills it.
  profiles = [];
  // The engine's catalog version on /api/status; a gateway call bumps it with no one on the page.
  catalogVersion = 1;
  // The audit rows a key's History drawer shows; invented, like everything else here.
  keyEvents = [];
  // The app's relay as GET /api/relay reports it: set up, off, no relay in a Terminal.
  relay = {
    configured: true, url: "https://keysrs-relay.example.workers.dev", on: false, state: "off",
    connected_since: null, retry_at: null, last_error: null, inflight: 0,
    elsewhere: false, elsewhere_pid: null, stay_awake: false, awake: false,
  };
  // The persisted app choices (GET /api/preferences). The app-mode default has the
  // meter off, but this suite is about the meter's own presentation, so its fixture
  // starts with the meter on; the fresh-store default and its migration are pinned
  // in the XCTest PreferencesTests. The meter-visibility case flips it off and back.
  preferences = { show_usage_meter: true, menubar_item: false, update_checks: true };
}
let catalogVersion = 1;
let keyEvents = [];
let relay;

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
    if (!localRows.length) return [200, { source, by, start_day: day, end_day: day, ...(emptyIngested ? { last_ingest_at: day + "T00:00:00Z" } : {}), totals: {}, rows: [], daily: [], points: [], models: [] }];
    // The vendor families, mirrored from the page's family(): the family decides a row's
    // fallback token rule and where a sourceless row's tool filter looks.
    const fam = (m) => (/^grok/i.test(m) ? "grok" : /^claude/i.test(m) ? "claude"
      : /^(gpt-|o[1-9]|codex|chatgpt)/i.test(m) ? "openai"
      : /^gemini/i.test(m) ? "gemini" : /^glm/i.test(m) ? "glm" : /^kimi/i.test(m) ? "kimi"
      : /^deepseek/i.test(m) ? "deepseek" : "other");
    // A row that names a source belongs to that tool's filter whatever vendor its model is
    // (Droid runs Claude and GLM models); a row of the old shape, with no source, keeps being
    // matched by its model's family the way this suite always matched it.
    const wireSource = { grok: "grok-local", claude: "claude-local", openai: "codex-local", droid: "droid-local" };
    // Cloud is the two imported sources, mirroring SourceFilter.cloud.
    const inSource = (r) => source === "all"
      || (source === "cloud" ? ["droid-remote", "claude-remote"].includes(r.source)
        : r.source ? r.source === wireSource[source] : fam(r.model) === source);
    const rows = localRows.filter(inSource);
    if (!rows.length) return [200, { source, by, start_day: day, end_day: day, ...(emptyIngested ? { last_ingest_at: day + "T00:00:00Z" } : {}), totals: {}, rows: [], daily: [], points: [], models: [] }];
    // The engine's own token rule (`TokenTotals.normalized`), applied per source: Claude's
    // cache buckets are billed tokens, Codex's and Grok's reasoning tokens are, and Droid's
    // log bills every bucket it reports. A row with no source follows its model's family.
    const counted = (r) => {
      const input = r.input_tokens || 0, output = r.output_tokens || 0;
      const cache = (r.cached_read_tokens || 0) + (r.cache_creation_tokens || 0);
      const reasoning = r.reasoning_tokens || 0;
      if (r.source === "claude-local" || r.source === "claude-remote") return input + output + cache;
      if (r.source === "codex-local" || r.source === "grok-local") return input + output + reasoning;
      if (r.source === "droid-local" || r.source === "droid-remote") return input + output + cache + reasoning;
      return input + output + (fam(r.model) === "claude" ? cache : reasoning);
    };
    // by=model groups by the model id, so the same model from two tools is one row: the raw
    // buckets are summed and `counted_tokens` is each part counted under its own source's rule —
    // the field the engine sends so the chart never has to guess a merged row's token rule.
    const merged = new Map();
    for (const r of rows) {
      const m = merged.get(r.model) || {
        model: r.model, input_tokens: 0, output_tokens: 0, cached_read_tokens: 0,
        cache_creation_tokens: 0, reasoning_tokens: 0, model_calls: 0, counted_tokens: 0, remote_counted_tokens: 0,
        usd: null, usd_estimate: null,
      };
      m.input_tokens += r.input_tokens || 0;
      m.output_tokens += r.output_tokens || 0;
      m.cached_read_tokens += r.cached_read_tokens || 0;
      m.cache_creation_tokens += r.cache_creation_tokens || 0;
      m.reasoning_tokens += r.reasoning_tokens || 0;
      m.model_calls += r.model_calls || 0;
      m.counted_tokens += counted(r);
      if (/-remote$/.test(r.source || "")) m.remote_counted_tokens += counted(r);
      if (r.usd != null) m.usd = (m.usd || 0) + r.usd;
      if (r.usd_estimate != null) m.usd_estimate = (m.usd_estimate || 0) + r.usd_estimate;
      merged.set(r.model, m);
    }
    const modelRows = [...merged.values()];
    // Dollars stay per tool: Grok's own receipt, Claude's and Codex's list-price estimates.
    const grokUsd = rows.filter((r) => r.source === "grok-local" || (!r.source && fam(r.model) === "grok"))
      .reduce((a, r) => a + (r.usd || 0), 0);
    const claudeEst = rows.filter((r) => r.source === "claude-local" || (!r.source && fam(r.model) === "claude"))
      .reduce((a, r) => a + (r.usd_estimate || 0), 0);
    const openaiEst = rows.filter((r) => r.source === "codex-local" || (!r.source && fam(r.model) === "openai"))
      .reduce((a, r) => a + (r.usd_estimate || 0), 0);
    return [200, {
      range: params.get("range") || "today", by, source,
      start_day: day, end_day: day, last_ingest_at: day + "T00:00:00Z",
      totals: { grok_usd: grokUsd, claude_usd_estimate: claudeEst, openai_usd_estimate: openaiEst,
        remote_tokens: rows.filter((r) => /-remote$/.test(r.source || "")).reduce((a, r) => a + counted(r), 0) },
      rows: modelRows,
      daily: by === "hour" ? [] : modelRows.map((r) => ({ ...r, day, tokens: r.counted_tokens, usd: r.usd ?? null, usd_estimate: r.usd_estimate ?? null })),
      points: by === "hour"
        ? modelRows.map((r) => ({ ...r, hour: `${day}T${pad2(new Date().getHours())}:00`, tokens: r.counted_tokens, usd: r.usd ?? null, usd_estimate: r.usd_estimate ?? null }))
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

const SUB_TOOLS = ["cursor", "gemini", "copilot", "perplexity", "chatgpt", "factory", "custom"];
const SUB_UNITS = ["tokens", "requests", "credits", "usd"];
const SUB_PERIODS = ["five_hour", "weekly", "monthly"];

// The engine's subscription validation, mirrored so a page that sends a half-sent payload
// fails here instead of passing. `existing` carries PATCH's "absent means keep".
function subLimitOf(body, existingLimit) {
  const present = (k) => Object.prototype.hasOwnProperty.call(body, k);
  const keys = ["limit_amount", "limit_unit", "limit_period"];
  const presentCount = keys.filter(present).length;
  if (!presentCount) return [null, existingLimit];
  const amount = present("limit_amount") && body.limit_amount !== null ? body.limit_amount : null;
  const unit = present("limit_unit") && body.limit_unit !== null ? body.limit_unit : null;
  const period = present("limit_period") && body.limit_period !== null ? body.limit_period : null;
  const allOrNothing = "limit fields are all-or-nothing: set amount, unit and period together, or clear all three";
  if (amount == null && unit == null && period == null) {
    if (presentCount !== 3) return [allOrNothing];
    return [null, null];
  }
  if (presentCount !== 3 || amount == null || unit == null || period == null) return [allOrNothing];
  const value = Number(amount);
  if (typeof amount !== "number" || !Number.isFinite(value) || value <= 0 || value > 1e9) {
    return ["limit amount must be greater than 0 and at most a billion"];
  }
  if (!SUB_UNITS.includes(unit)) return [`limit unit must be one of ${SUB_UNITS.join(", ")}`];
  if (!SUB_PERIODS.includes(period)) return [`limit period must be one of ${SUB_PERIODS.join(", ")}`];
  if ((unit === "tokens" || unit === "requests") && !Number.isInteger(value)) {
    return [`a ${unit} limit is a whole number`];
  }
  return [null, { amount: value, unit, period }];
}

function subValidate(body, existing) {
  if (!existing && (typeof body.tool !== "string" || !SUB_TOOLS.includes(body.tool))) {
    return [`tool must be one of ${SUB_TOOLS.join(", ")}`];
  }
  const tool = existing ? existing.tool : body.tool;
  const rawName = body.name !== undefined ? body.name : (existing ? existing.name : undefined);
  const name = typeof rawName === "string" ? rawName.trim() : "";
  if (tool === "custom") {
    if (!name || name.length > 64 || /\n/.test(name)) {
      return ["a custom subscription needs a name (one line, at most 64 characters)"];
    }
  } else if (name) return ["name is only for a custom tool"];
  const rawPlan = body.plan !== undefined ? body.plan : (existing ? existing.plan : undefined);
  const plan = typeof rawPlan === "string" ? rawPlan.trim() : "";
  if (!plan || plan.length > 80 || /\n/.test(plan)) {
    return ["plan is required (one line, at most 80 characters)"];
  }
  const [limitErr, limit] = subLimitOf(body, existing ? existing.limit : null);
  if (limitErr) return [limitErr];
  return [null, { tool, name, plan, limit }];
}

function subRecord(sub) {
  return {
    id: sub.id, tool: sub.tool, name: sub.name, plan: sub.plan,
    limit_amount: sub.limit ? sub.limit.amount : null,
    limit_unit: sub.limit ? sub.limit.unit : null,
    limit_period: sub.limit ? sub.limit.period : null,
    created_at: sub.created_at,
  };
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
    // Mirror the real server's KeyName.validate, which checks the 128-char cap before the
    // pattern, so each refusal answers the exact wire string the real backend does. The
    // client pattern has no length cap, so a long lowercase name passes the browser and
    // only the server can refuse it.
    if (body.name.length > 128) return [400, { error: "name too long" }];
    if (!/^[a-z0-9][a-z0-9._-]*$/.test(body.name)) {
      return [400, { error: "invalid name (expected [a-z0-9][a-z0-9._-]*)" }];
    }
    if (keys.some((k) => k.name === body.name)) return [409, { error: "already_exists" }];
    fixtureSecrets.set(body.name, body.secret);
    keys.push({ name: body.name, provider: body.provider, kind: body.kind, notes: body.notes,
                created_at: "2026-09-20T12:00:00Z", last_used_at: null, checkable: false });
    return [200, { ok: true }];
  }
  if (keyMatch && leaf === "" && method === "DELETE") {
    if (!found()) return [404, { error: "not_found" }];
    keys = keys.filter((k) => k.name !== name);
    fixtureSecrets.delete(name);
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
    return [200, { secret: fixtureSecrets.get(name) }];
  }
  if (keyMatch && leaf === "/rotate") {
    if (!found()) return [404, { error: "not_found" }];
    if (typeof body.secret !== "string" || !body.secret) return [400, { error: "secret_required" }];
    rotations.push({ name, body });
    fixtureSecrets.set(name, body.secret);
    return [200, { version: 2 }];
  }
  if (keyMatch && leaf === "/gateway" && method === "POST") {
    const key = found();
    if (!key) return [404, { error: "not_found" }];
    key.gateway_enabled = !!body.enabled;
    key.gateway_url = key.gateway_enabled ? `http://127.0.0.1:12767/${name}` : null;
    return [200, { gateway_url: key.gateway_url }];
  }
  if (keyMatch && leaf === "/check" && method === "POST") {
    const key = found();
    if (!key) return [404, { error: "not_found" }];
    const result = {
      ok: true, provider: key.provider, host: key.host || "api.example.test", endpoint: "/v1/models",
      checked_at: "2026-10-27T12:00:00Z", model_count: 2, models: ["fixture-small", "fixture-large"],
    };
    key.last_check = { ok: true, checked_at: result.checked_at, summary: "2 models" };
    return [200, result];
  }
  if (keyMatch && leaf === "/events") return [200, { events: keyEvents }];
  if (keyMatch && leaf === "/clients") return [200, { clients: [] }];
  // Mirrors the engine: a plain GET lists active grants only; ?all=1 keeps the expired
  // (still renewable) and revoked rows the dashboard's renewal surface shows.
  if (pathname === "/api/grants") {
    const all = params.get("all") === "1" || params.get("all") === "true";
    return [200, { grants: all ? grants : grants.filter((g) => g.status === "active") }];
  }
  // POST /api/grants/<id>/renew, mirroring the engine: an active or expired grant re-opens
  // for another window of its original span — same id, and the answer never carries the
  // token. A revoked grant is the named refusal (a revoke that raced the click lands here).
  const renewMatch = /^\/api\/grants\/([0-9a-f]{8})\/renew$/.exec(pathname);
  if (renewMatch && method === "POST") {
    const g = grants.find((x) => x.id === renewMatch[1]);
    if (!g) return [404, { error: "renew_not_found" }];
    if (g.status === "revoked") return [409, { error: "renew_revoked" }];
    g.renewals += 1;
    g.renewed_at = new Date().toISOString();
    g.expires_at = new Date(Date.now() + g.window_minutes * 60000).toISOString();
    g.requests = 0; g.usd = 0; g.unpriced_calls = 0; g.last_used_at = null;
    g.status = "active";
    const answer = { ...g };
    delete answer.token;
    return [200, answer];
  }
  // DELETE /api/grants/<id>, mirroring the engine: a revoke is a kill, not a removal — the
  // row stays on the list under ?all=1 as revoked (its fate visible, offering nothing), so
  // the page's own reload reads the same state the mutation left behind. The answer carries
  // no token.
  const revokeMatch = /^\/api\/grants\/([0-9a-f]{8})$/.exec(pathname);
  if (revokeMatch && method === "DELETE") {
    const g = grants.find((x) => x.id === revokeMatch[1]);
    if (!g) return [404, { error: "grant_not_found" }];
    g.status = "revoked";
    g.revoked_at = new Date().toISOString();
    g.revoke_reason = "revoked";
    return [200, { ok: true }];
  }
  // Saved grant bounds, mirroring the engine's grant_profiles rows. The page only lists and
  // removes them — `keys profile add` is the CLI's surface — so the fixture fakes GET and
  // DELETE only; a POST from the page would land in `unexpected` and fail the case.
  if (pathname === "/api/profiles" && method === "GET") return [200, { profiles }];
  const profileMatch = /^\/api\/profiles\/([0-9a-z]+)$/.exec(pathname);
  if (profileMatch && method === "DELETE") {
    const gone = profiles.find((p) => p.id === profileMatch[1]);
    if (!gone) return [404, { error: "profile_not_found" }];
    profiles = profiles.filter((p) => p.id !== gone.id);
    return [200, gone];
  }
  if (pathname === "/api/providers" && method === "GET") return [200, providersCatalog()];
  if (pathname === "/api/providers" && method === "POST") {
    if (typeof body.id !== "string" || !/^[a-z0-9][a-z0-9-]*$/.test(body.id)) return [400, { error: "invalid provider id" }];
    if (typeof body.name !== "string" || !body.name) return [400, { error: "provider name is required" }];
    customProviders = customProviders.filter((p) => p.id !== body.id);
    const record = { ...body, group: "yours", custom: true, hidden: null };
    customProviders.push(record);
    return [201, record];
  }
  const providerMatch = /^\/api\/providers\/([a-z0-9-]+)$/.exec(pathname);
  if (providerMatch && method === "PATCH") {
    const id = providerMatch[1];
    const mine = customProviders.find((p) => p.id === id);
    const shipped = shippedCatalog.providers.find((p) => p.id === id);
    if (mine && body.hidden === true) return [400, { error: "a provider you added is removed instead" }];
    if (!mine && !shipped) return [404, { error: "not_found" }];
    if (body.hidden) hiddenUsers.add(id); else hiddenUsers.delete(id);
    const source = mine ?? shipped;
    return [200, { ...source, custom: Boolean(mine), hidden: body.hidden ? "user" : null }];
  }
  if (providerMatch && method === "DELETE") {
    const id = providerMatch[1];
    const before = customProviders.length;
    customProviders = customProviders.filter((p) => p.id !== id);
    if (customProviders.length === before && shippedCatalog.providers.some((p) => p.id === id)) {
      return [400, { error: "openai is a built-in provider; hide it instead".replace("openai", id) }];
    }
    if (customProviders.length === before) return [404, { error: "not_found" }];
    return [200, { removed: id }];
  }
  if (pathname === "/api/models") return [200, []];
  if (pathname === "/api/status") return [200, { plans, catalog_version: catalogVersion }];
  // The per-window token limits, mirroring the engine's usage_limits: only the Droid row is
  // tracked, the windows are fixed, and a limit is a positive whole number and nothing else.
  if (pathname === "/api/limits" && method === "GET") {
    return [200, { limits: [...limits].map(([key, tokens]) => {
      const [source, window] = key.split("/");
      return { source, window, tokens };
    }) }];
  }
  const limitMatch = /^\/api\/limits\/([a-z0-9-]+)\/([a-z_]+)$/.exec(pathname);
  if (limitMatch) {
    const source = limitMatch[1], window = limitMatch[2];
    if (source !== "droid") return [400, { error: "limits exist for droid only" }];
    if (!["five_hour", "weekly", "monthly"].includes(window)) return [400, { error: "window must be five_hour, weekly or monthly" }];
    if (method === "PUT") {
      if (typeof body.tokens !== "number" || !Number.isInteger(body.tokens) || body.tokens <= 0) {
        return [400, { error: "tokens must be a positive whole number" }];
      }
      limits.set(`${source}/${window}`, body.tokens);
      return [200, { source, window, tokens: body.tokens }];
    }
    if (method === "DELETE") {
      limits.delete(`${source}/${window}`);
      return [200, { removed: `${source}/${window}` }];
    }
  }
  // The subscriptions the user pins to the Usage pane, mirroring the engine's rows and its
  // strict validation: one of the listed tools, a custom tool named by its own name, a plan
  // always, and the limit one fact in three fields.
  if (pathname === "/api/subscriptions" && method === "GET") {
    return [200, { subscriptions: subscriptions.map(subRecord) }];
  }
  if (pathname === "/api/subscriptions" && method === "POST") {
    const [err, fields] = subValidate(body, null);
    if (err) return [400, { error: err }];
    if (fields.tool === "factory" && subscriptions.some((s) => s.tool === "factory")) {
      return [400, { error: "a Factory subscription already exists; edit it instead" }];
    }
    const sub = { id: "sub-" + (nextSubId++), created_at: "2026-10-11T00:00:00Z", ...fields };
    subscriptions.push(sub);
    return [201, subRecord(sub)];
  }
  const subMatch = /^\/api\/subscriptions\/([^/]+)$/.exec(pathname);
  if (subMatch) {
    const sub = subscriptions.find((s) => s.id === subMatch[1]);
    if (method === "PATCH") {
      if (!sub) return [404, { error: "not_found" }];
      if (body.tool !== undefined && body.tool !== sub.tool) {
        return [400, { error: "tool cannot change; remove the subscription and add it again" }];
      }
      const [err, fields] = subValidate(body, sub);
      if (err) return [400, { error: err }];
      Object.assign(sub, fields);
      return [200, subRecord(sub)];
    }
    if (method === "DELETE") {
      if (!sub) return [404, { error: "not_found" }];
      subscriptions = subscriptions.filter((s) => s.id !== subMatch[1]);
      return [200, { removed: subMatch[1] }];
    }
    return [405, { error: "method_not_allowed" }];
  }
  // The app's relay, mirroring the engine: the body is enabled and/or stay_awake, booleans and
  // nothing else; on needs a relay that is set up and no relay running in a Terminal.
  // The menu bar's copy of the hidden usage cards, mirroring the engine's validation.
  if (pathname === "/api/preferences/hidden-usage" && method === "POST") {
    if (!Array.isArray(body.hidden) || body.hidden.some((x) => typeof x !== "string")) {
      return [400, { error: "hidden must be a list" }];
    }
    return [200, { hidden: [...new Set(body.hidden)].sort() }];
  }
  // The persisted app choices, mirroring the engine: GET reads them, each write takes exactly
  // {on: bool} and answers the whole persisted state.
  if (pathname === "/api/preferences" && method === "GET") return [200, preferences];
  const preferenceKeys = {
    "/api/preferences/show-usage-meter": "show_usage_meter",
    "/api/preferences/menubar-item": "menubar_item",
    "/api/preferences/update-checks": "update_checks",
  };
  if (preferenceKeys[pathname] && method === "POST") {
    if (Object.keys(body).length !== 1 || typeof body.on !== "boolean") return [400, { error: "send on" }];
    preferences[preferenceKeys[pathname]] = body.on;
    return [200, preferences];
  }
  // Quit: the engine answers before it terminates; the fixture only records that it was asked.
  if (pathname === "/api/app/quit" && method === "POST") return [200, { ok: true }];
  if (pathname === "/api/relay" && method === "GET") return [200, relay];
  if (pathname === "/api/relay" && method === "POST") {
    const fields = Object.keys(body);
    if (!fields.length || fields.some((f) => f !== "enabled" && f !== "stay_awake")) {
      return [400, { error: "send enabled, stay_awake or both" }];
    }
    for (const f of fields) if (typeof body[f] !== "boolean") return [400, { error: `${f} must be true or false` }];
    if ("stay_awake" in body) relay.stay_awake = body.stay_awake;
    if (body.enabled === true && !relay.on) {
      if (!relay.configured) return [400, { error: "no relay is set up; deploy the Worker (docs/relay.md), then run: keys relay setup --url https://<your worker>.workers.dev" }];
      if (relay.elsewhere) return [400, { error: "keys relay is already running on this Mac (process 4242), and the Worker keeps only one Mac connection; stop it with Ctrl-C in its Terminal, then turn the relay on here" }];
      Object.assign(relay, { on: true, state: "connected", connected_since: new Date().toISOString() });
    }
    if (body.enabled === false) {
      Object.assign(relay, { on: false, state: "off", connected_since: null, retry_at: null, last_error: null, inflight: 0, awake: false });
    }
    return [200, relay];
  }
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
    let body = {};
    if (raw) { try { body = JSON.parse(raw); } catch { body = {}; } }
    // The parsed body rides along so cases can assert what the page actually sent.
    requests.push({ method, pathname: url.pathname, search: url.search, token: request.headers["x-ksf-token"] || null, body });

    if (process.env.KEYS_FIXTURE_PORT && url.pathname === "/__fixture/reset" && method === "POST") {
      reset();
      return json(response, 200, { ok: true });
    }
    if (process.env.KEYS_FIXTURE_PORT && url.pathname === "/__fixture/rotations" && method === "GET") {
      return json(response, 200, { rotations });
    }
    const failure = failures.get(key);
    if (failure === "drop") return request.socket.destroy();
    if (failure && failure.raw !== undefined) {
      response.writeHead(failure.status, { "Content-Type": "text/plain" });
      return response.end(failure.raw);
    }
    if (failure) return json(response, failure.status, failure.body);

    // The answer is computed now and delivered late, which is how a slow reply
    // carries a view of the vault that has since moved on.
    const [status, value] = handle(method, url.pathname, body, url.searchParams);
    const wait = delays.get(key);
    if (wait) await sleep(wait);
    json(response, status, value);
  });
});

// ---------- helpers ----------

const rowNames = (page) => page.locator("#keys-body .key-row[data-name]")
  .evaluateAll((rows) => rows.map((row) => row.dataset.name));
// A row's parts: name, provider, host, used, gateway (this month's figure), notes, avatar.
const rowCell = (page, name, cell) => page.locator(`#keys-body .key-row[data-name="${name}"] .key-${cell}`).first();
const rowButton = (page, name, act) => page.locator(`#keys-body .key-row[data-name="${name}"] [data-act="${act}"]`).first();
const menuItem = (page, label) => page.getByRole("menuitem", { name: label, exact: true });
const openRowMenu = async (page, name) => {
  await rowButton(page, name, "menu").click();
  await page.locator("#key-menu:visible").waitFor();
};
// The row's letter actions remain available alongside Copy and the More menu.
const ROW_LETTER = { reveal: "v", edit: "e", gateway: "g", grant: "a", check: "t", history: "h", rotate: "r", delete: "Backspace", copy: "c" };
async function rowAct(page, name, act) {
  const row = page.locator(`#keys-body .key-row[data-name="${name}"]`).first();
  await row.locator(".key-name").click();
  await row.press(ROW_LETTER[act]);
}
// The figure is absent, not "—", when a key has no gateway calls this month.
const gatewayText = (page, name) => page.evaluate((n) => {
  const node = document.querySelector(`#keys-body .key-row[data-name="${n}"] .key-gateway`);
  return node ? node.textContent.trim() : null;
}, name);
const status = (page) => page.locator("#status").textContent();
// A closed <dialog> is not "hidden" in a way a visibility wait can observe, so
// the open flag is read directly.
const dialogOpen = (page, id) => page.locator(`#${id}`).evaluate((node) => node.open);
const waitDialog = (page, id, open) =>
  page.waitForFunction(([name, want]) => document.getElementById(name).open === want, [id, open]);

// Droid is off the Usage pane by default (Settings → Show Droid on Usage); the tests about its
// card turn it on before the page loads.
const showDroidOnUsage = (page) => page.addInitScript(() => { try { localStorage.setItem("ksf.showDroid", "1"); } catch { /* fine */ } });

async function openKeys(page, origin, options = {}) {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Keys" }).click();
  if (!options.expectEmpty) await page.locator('#keys-body .key-row[data-name="alpha"]').waitFor();
  return page;
}

const checks = [];
const only = process.env.KEYS_UI_ONLY || "";
const test = (name, fn) => { if (!only || name.includes(only)) checks.push({ name, fn }); };

// ---------- key list ----------

test("key list renders every key with its count and no empty state", async (page, origin) => {
  await openKeys(page, origin);
  // One flat list in the default name order; no provider header rows between keys.
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie"]);
  assert.equal(await page.locator("#keys-body > :not(.key-row)").count(), 0, "nothing but key rows");
  assert.equal(await page.locator("#keys-count").textContent(), "3 keys");
  assert.equal(await page.locator("#keys-empty").isHidden(), true);
  assert.equal(await page.locator("#keys-list").isVisible(), true);
  assert.equal((await rowCell(page, "bravo", "used").textContent()).trim(), "Never used");
});

test("an empty vault shows the empty state and hides the table", async (page, origin) => {
  keys = [];
  await openKeys(page, origin, { expectEmpty: true });
  await page.locator("#keys-empty:visible").waitFor();
  assert.equal(await page.locator("#keys-list").isHidden(), true);
  assert.equal(await page.locator("#keys-count").textContent(), "0 keys");
  assert.equal(await page.locator("#keys-count").isVisible(), true, "the count says so on screen");
  assert.equal(await page.locator("#keys-no-match").isHidden(), true);
});

// ---------- the vault list's design ----------

// Read in the page: an element's text colour against its own background, flattened through a
// canvas so color-mix() and alpha values resolve to the pixels actually drawn.
const avatarLook = (page) => page.evaluate(() => {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  const px = (css, under) => {
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = under; ctx.fillRect(0, 0, 1, 1);
    ctx.fillStyle = css; ctx.fillRect(0, 0, 1, 1);
    return [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3);
  };
  const lum = ([r, g, b]) => [r, g, b].map((c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; })
    .reduce((a, c, i) => a + c * [0.2126, 0.7152, 0.0722][i], 0);
  const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const card = getComputedStyle(document.getElementById("pane-keys")).backgroundColor;
  return [...document.querySelectorAll("#keys-body .key-row")].map((row) => {
    const tile = row.querySelector(".key-avatar");
    const cs = getComputedStyle(tile);
    const rowBg = px(getComputedStyle(row).backgroundColor, card);
    const bg = px(cs.backgroundColor, `rgb(${rowBg.join(",")})`);
    const fg = px(cs.color, `rgb(${bg.join(",")})`);
    return {
      name: row.dataset.name, initials: tile.textContent, tint: [...tile.classList].find((c) => c.startsWith("tint-")),
      hidden: tile.getAttribute("aria-hidden"), media: tile.querySelectorAll("img, svg").length,
      contrast: Math.round(ratio(fg, bg) * 100) / 100,
    };
  });
});

test("key rows show an initials tile, a mono name, the provider, last used and Copy in both themes", async (page, origin) => {
  const foreign = [];
  page.on("request", (r) => { if (new URL(r.url()).origin !== origin) foreign.push(r.url()); });
  await openKeys(page, origin);
  await settleKeys(page);
  const rows = await page.evaluate(() => [...document.querySelectorAll("#keys-body .key-row")].map((row) => ({
    name: row.dataset.name,
    title: row.querySelector(".key-name").textContent,
    font: getComputedStyle(row.querySelector(".key-name")).fontFamily,
    provider: row.querySelector(".key-provider").textContent,
    used: row.querySelector(".key-used").textContent,
    buttons: [...row.querySelectorAll("button")].map((b) => b.dataset.act + ":" + b.textContent.trim()),
    columns: getComputedStyle(row).gridTemplateColumns.split(" ").slice(-2).join(" "),
    height: row.getBoundingClientRect().height,
  })));
  assert.deepEqual(rows.map((r) => [r.name, r.title, r.provider]), [["alpha", "alpha", "OpenAI"], ["bravo", "bravo", "Anthropic"], ["charlie", "charlie", "TypeSafe"]]);
  assert.match(rows[0].used, /^(Sep 18|\d+ (days|weeks|months) ago)$/, "a used key shows a relative time");
  assert.deepEqual(rows.slice(1).map((r) => r.used), ["Never used", "Never used"]);
  for (const r of rows) {
    assert.match(r.font, /monospace|Menlo|SF Mono/, `${r.name}: the name is monospaced`);
    assert.equal(r.buttons.filter((b) => b.startsWith("copy:"))[0], "copy:Copy");
    // Copy, More, and only where real, the gateway figure. More exposes the existing actions.
    assert.ok(r.buttons.every((b) => /^(copy|menu|chart):/.test(b)), `${r.name}: unexpected buttons ${r.buttons}`);
    assert.ok(r.buttons.some((b) => b.startsWith("menu:")), `${r.name}: the More button is visible`);
    assert.equal(r.columns, "99px 118px", `${r.name}: the last-used and actions columns`);
    assert.ok(r.height >= 62, `${r.name}: row is ${r.height}px tall`);
  }

  const dark = await avatarLook(page);
  assert.deepEqual(dark.map((a) => a.initials), ["Op", "An", "Ty"]);
  assert.equal(new Set(dark.map((a) => a.tint)).size, 3, "each fixture provider has its own tint");
  for (const a of dark) {
    assert.equal(a.hidden, "true", "the tile is decoration; the provider name is the text");
    assert.equal(a.media, 0, "initials only, never a logo");
    assert.ok(a.contrast >= 4.5, `${a.name} initials at ${a.contrast}:1 in dark`);
  }

  // The header, search and list tools of the design.
  assert.equal(await page.locator("#pane-keys .eyebrow").textContent(), "KEYSRS");
  assert.equal(await page.locator("#pane-keys h1").textContent(), "Your keys.");
  assert.equal(await page.locator("#pane-keys h1").evaluate((n) => getComputedStyle(n).fontSize), "39px");
  await page.getByRole("button", { name: "Add key", exact: true }).waitFor();
  assert.equal(await page.locator("#btn-add kbd").textContent(), "N");
  assert.equal(await page.locator("#keys-search-box kbd").textContent(), "/");
  assert.equal(await page.locator(".list-label").evaluate((n) => n.firstChild.textContent.trim()), "All keys");
  assert.equal(await page.locator("#keys-search-box").evaluate((n) => n.getBoundingClientRect().height), 42);

  await page.getByRole("tab", { name: "Settings" }).click();
  await page.locator("#theme-switch").click();
  await page.getByRole("tab", { name: "Keys" }).click();
  const light = await avatarLook(page);
  assert.deepEqual(light.map((a) => [a.initials, a.tint]), dark.map((a) => [a.initials, a.tint]), "the same tile in both themes");
  for (const a of light) assert.ok(a.contrast >= 4.5, `${a.name} initials at ${a.contrast}:1 in light`);
  const palette = await page.evaluate(() => ({
    page: getComputedStyle(document.body).backgroundColor,
    add: getComputedStyle(document.getElementById("btn-add")).backgroundColor,
  }));
  assert.deepEqual(palette, { page: "rgb(245, 245, 247)", add: "rgb(0, 113, 227)" });
  assert.doesNotMatch(await page.evaluate(() => document.body.innerHTML), new RegExp(SECRET));
  assert.deepEqual(foreign, []);
});

test("the More menu has the designed order, semantics, theme and viewport placement", async (page, origin) => {
  await openKeys(page, origin);
  await settleKeys(page);
  const menuButton = rowButton(page, "alpha", "menu");
  assert.equal(await menuButton.isVisible(), true, "More is visible without hovering");
  assert.equal(await menuButton.getAttribute("aria-haspopup"), "menu");
  assert.equal(await menuButton.getAttribute("aria-label"), "More actions for alpha");

  const order = async () => page.locator("#key-menu").evaluate((menu) =>
    [...menu.children].map((node) => node.getAttribute("role") === "separator"
      ? "separator" : node.querySelector(".key-menu-label").textContent));
  let menuShortcuts = [];
  for (const theme of ["dark", "light"]) {
    if (theme === "light") {
      await page.getByRole("tab", { name: "Settings" }).click();
      await page.locator("#theme-switch").click();
      await page.getByRole("tab", { name: "Keys" }).click();
      await settleKeys(page);
    }
    await page.setViewportSize({ width: 390, height: 844 });
    await openRowMenu(page, "charlie");
    assert.deepEqual(await order(), [
      "Reveal key", "Edit details", "separator", "Access & grants", "Turn on gateway…",
      "Activity", "Check connection", "Rotate key…", "separator", "Delete key…",
    ]);
    const geometry = await page.evaluate(() => {
      const menu = document.getElementById("key-menu").getBoundingClientRect();
      const button = document.querySelector('#keys-body [data-name="charlie"] [data-act="menu"]').getBoundingClientRect();
      return {
      left: menu.left, right: menu.right, top: menu.top, bottom: menu.bottom,
      buttonLeft: button.left, buttonRight: button.right, buttonTop: button.top, buttonBottom: button.bottom,
        background: getComputedStyle(document.getElementById("key-menu")).backgroundColor,
        viewportWidth: innerWidth, viewportHeight: innerHeight,
      };
    });
    assert.ok(geometry.left >= 0 && geometry.right <= geometry.viewportWidth, `${theme}: menu stays inside horizontally: ${JSON.stringify(geometry)}`);
    assert.ok(geometry.top >= 0 && geometry.bottom <= geometry.viewportHeight, `${theme}: menu stays inside vertically: ${JSON.stringify(geometry)}`);
    assert.ok(Math.abs(geometry.right - geometry.buttonRight) <= 1, `${theme}: menu is right-aligned to its button`);
    assert.ok(geometry.top >= geometry.buttonBottom || geometry.bottom <= geometry.buttonTop,
      `${theme}: menu opens below or flips above: ${JSON.stringify(geometry)}`);
    assert.equal(await page.locator("#key-menu").getAttribute("role"), "menu");
    assert.equal(await page.locator("#key-menu").getAttribute("aria-label"), "More actions for charlie");
    assert.equal(await page.locator("#key-menu [role=menuitem]").count(), 8);
    menuShortcuts = await page.locator("#key-menu [role=menuitem]").evaluateAll((items) =>
      items.map((item) => [item.dataset.act, item.querySelector(".key-menu-shortcut")?.textContent || ""]));
    assert.equal(await rowButton(page, "charlie", "menu").getAttribute("aria-expanded"), "true");
    assert.equal(await page.locator("#key-menu").evaluate((n) => getComputedStyle(n).backgroundColor), geometry.background);
    assert.doesNotMatch(await page.evaluate(() => document.body.innerHTML), new RegExp(SECRET));
    await page.keyboard.press("Escape");
    await waitFocused(page, "charlie:menu");
  }
  await page.getByRole("button", { name: "Keyboard shortcuts" }).click();
  const help = await page.locator("#dlg-help .shortcuts").evaluate((box) => ({
    keys: [...box.querySelectorAll("dt")].map((dt) => [...dt.querySelectorAll("kbd")].map((k) => k.textContent.trim()).join("")),
    text: box.textContent,
  }));
  for (const [act, key] of menuShortcuts) {
    if (!key) continue;
    assert.ok(help.keys.includes(key), `${act} has ${key} in the help list`);
  }
  for (const phrase of ["Reveal key", "Edit details", "Access & grants", "Turn the gateway on or off", "Activity", "Check connection", "Rotate key"]) {
    assert.ok(help.text.includes(phrase), `help describes ${phrase}`);
  }
  await waitDialog(page, "dlg-help", true);
});

// The vault's whole surface — listing, searching, filtering, sorting, copying and the More
// menu — runs without the secret ever entering the DOM and without a single off-origin request.
test("no secret reaches the DOM and no request leaves the origin across list, search, filter, sort, copy and the menu", async (page, origin) => {
  const foreign = [];
  page.on("request", (r) => { if (new URL(r.url()).origin !== origin) foreign.push(r.url()); });
  const secretFree = async (step) =>
    assert.doesNotMatch(await page.evaluate(() => document.documentElement.innerHTML), new RegExp(SECRET), step);
  await openKeys(page, origin);
  await settleKeys(page);
  await secretFree("the rendered list");

  await page.locator("#keys-search").fill("bravo");
  assert.deepEqual(await rowNames(page), ["bravo"]);
  await secretFree("search");
  await page.locator("#keys-search").fill("");
  await page.selectOption("#keys-provider", "openai");
  assert.deepEqual(await rowNames(page), ["alpha"]);
  await secretFree("the provider filter");
  await page.selectOption("#keys-provider", "");
  await page.selectOption("#keys-sort", "recent");
  await secretFree("sorting");

  await rowButton(page, "bravo", "copy").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Copied"));
  await secretFree("copy feedback");
  await page.waitForFunction(() => document.querySelector('#keys-body .key-row[data-name="bravo"] [data-act="copy"]')?.textContent === "Copy");
  await secretFree("the post-copy refresh");

  await openRowMenu(page, "alpha");
  await secretFree("the open menu");
  await page.keyboard.press("Escape");
  await waitFocused(page, "alpha:menu");
  await secretFree("after the menu closes");

  assert.deepEqual(foreign, [], `off-origin requests: ${foreign.join(", ")}`);
});

test("the More menu dispatches every action through the selected key's existing handlers", async (page, origin) => {
  keys.find((k) => k.name === "alpha").host = "api.openai.com";
  await openKeys(page, origin);
  await settleKeys(page);

  await openRowMenu(page, "alpha");
  await menuItem(page, "Reveal key").click();
  await waitDialog(page, "dlg-reveal", true);
  assert.equal(await page.locator("#reveal-name").textContent(), "alpha");
  assert.ok(requests.some((r) => r.method === "POST" && r.pathname === "/api/keys/alpha/reveal"));
  await page.locator("#dlg-reveal [data-close]").click();
  await waitFocused(page, "alpha:menu");
  await page.waitForFunction(() => !document.body.innerHTML.includes("sk-fixture-NEVER-REAL"));

  await openRowMenu(page, "alpha");
  await menuItem(page, "Edit details").click();
  await waitDialog(page, "dlg-edit", true);
  assert.equal(await page.locator("#edit-name").textContent(), "alpha");
  await page.locator("#edit-form [name=notes]").fill("edited through More");
  await page.locator("#edit-form [type=submit]").click();
  await waitDialog(page, "dlg-edit", false);
  assert.equal(await status(page), "Saved alpha.");
  await page.waitForFunction(() => document.querySelector('#keys-body [data-name="alpha"] .key-notes')?.textContent === "edited through More");
  await waitFocused(page, "alpha:menu");

  await openRowMenu(page, "alpha");
  await menuItem(page, "Access & grants").click();
  await waitDialog(page, "dlg-grant", true);
  assert.equal(await page.locator("#grant-name").textContent(), "alpha");
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await waitDialog(page, "dlg-grant", false);
  await waitFocused(page, "alpha:menu");

  await openRowMenu(page, "alpha");
  await menuItem(page, "Turn on gateway…").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Gateway on."));
  assert.ok(requests.some((r) => r.method === "POST" && r.pathname === "/api/keys/alpha/gateway"));
  assert.match(await status(page), /^Gateway on\. Base URL http:\/\/127\.0\.0\.1:12767\/alpha\./);
  await page.waitForFunction(() => document.querySelector('#keys-body [data-name="alpha"] .badge')?.textContent === "Gateway on");
  await waitFocused(page, "alpha:menu");

  await openRowMenu(page, "alpha");
  await menuItem(page, "Turn off gateway").waitFor();
  await menuItem(page, "Turn off gateway").click();
  await page.waitForFunction(() => document.getElementById("status").textContent === "Gateway off for alpha.");
  assert.equal(requests.filter((r) => r.method === "POST" && r.pathname === "/api/keys/alpha/gateway").length, 2);
  await page.waitForFunction(() => !document.querySelector('#keys-body [data-name="alpha"] .badge'));
  await waitFocused(page, "alpha:menu");

  await openRowMenu(page, "alpha");
  await menuItem(page, "Activity").click();
  await page.locator('#keys-body .key-events-row[data-name="alpha"]').waitFor();
  assert.ok(requests.some((r) => r.pathname === "/api/keys/alpha/events"));
  await waitFocused(page, "alpha:menu");
  await openRowMenu(page, "alpha");
  await menuItem(page, "Activity").click();
  await page.locator('#keys-body .key-events-row[data-name="alpha"]').waitFor({ state: "detached" });

  await openRowMenu(page, "alpha");
  await menuItem(page, "Check connection").click();
  await waitDialog(page, "dlg-check", true);
  assert.equal(await page.locator("#check-name").textContent(), "alpha");
  assert.ok(requests.some((r) => r.method === "POST" && r.pathname === "/api/keys/alpha/check"));
  await page.locator("#dlg-check [data-close]").click();
  await waitDialog(page, "dlg-check", false);
  await waitFocused(page, "alpha:menu");

  await openRowMenu(page, "alpha");
  await menuItem(page, "Rotate key…").click();
  await waitDialog(page, "dlg-rotate", true);
  assert.equal(await page.locator("#rotate-name").textContent(), "alpha");
  await page.locator("#dlg-rotate [data-close]").click();
  await waitDialog(page, "dlg-rotate", false);
  await waitFocused(page, "alpha:menu");

  await openRowMenu(page, "alpha");
  await menuItem(page, "Delete key…").click();
  await waitDialog(page, "dlg-delete", true);
  assert.equal(await page.locator("#delete-name").textContent(), "alpha");
  await page.locator("#dlg-delete [data-close]").click();
  await waitDialog(page, "dlg-delete", false);
  await waitFocused(page, "alpha:menu");
});

test("rows show kind, created date and the active-grant count", async (page, origin) => {
  keys = baseKeys();
  keys[0].active_grants = 2;
  await openKeys(page, origin);
  assert.equal((await rowCell(page, "alpha", "kind").textContent()).trim(), "runtime");
  assert.equal((await rowCell(page, "bravo", "kind").textContent()).trim(), "billing");
  assert.equal((await rowCell(page, "alpha", "created").textContent()).trim(), "Added Sep 1, 2026");
  assert.equal(await rowCell(page, "alpha", "created").getAttribute("title"), "2026-09-01T10:00:00Z");
  assert.equal((await page.locator('#keys-body .key-row[data-name="alpha"] .badge.grants').textContent()).trim(), "2 grants");
  assert.equal(await page.locator('#keys-body .key-row[data-name="bravo"] .badge.grants').count(), 0, "no badge without grants");
  // Newest/Oldest sort by the date the row now shows.
  await page.locator("#keys-sort").selectOption("newest");
  assert.deepEqual(await rowNames(page), ["charlie", "bravo", "alpha"]);
  await page.locator("#keys-sort").selectOption("oldest");
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie"]);
  await openRowMenu(page, "alpha");
  await menuItem(page, "Access & grants (2)").waitFor();
  await page.keyboard.press("Escape");
  await openRowMenu(page, "bravo");
  await menuItem(page, "Access & grants").waitFor();
  await page.keyboard.press("Escape");
});

test("the More menu skips disabled items, supports keyboard dismissal and stays one at a time", async (page, origin) => {
  keys = [...baseKeys(), {
    name: "no-gateway", provider: "fixture-no-gateway", kind: "runtime",
    created_at: "2026-09-10T10:00:00Z", last_used_at: null, checkable: true, host: "api.example.test",
  }];
  customProviders = [{
    id: "fixture-no-gateway", name: "Gatewayless Fixture", group: "yours", gateway: false,
    host: "api.example.test", api: "openai-chat", auth_header: "Authorization", auth_prefix: "Bearer ",
    path_prefix: "", key_prefix: "", note: "Synthetic provider with gateway disabled.",
  }];
  await openKeys(page, origin);
  await settleKeys(page);
  await page.waitForFunction(() => document.querySelector('#keys-body [data-name="no-gateway"] .key-provider')?.textContent === "Gatewayless Fixture");

  await openRowMenu(page, "no-gateway");
  for (const label of ["Access & grants", "Turn on gateway…"]) {
    assert.equal(await menuItem(page, label).getAttribute("aria-disabled"), "true");
  }
  // A greyed item says why, as a tooltip and as its accessible description.
  const why = {
    "Turn on gateway…": "Gatewayless Fixture needs request signing; it cannot be proxied",
    "Access & grants": "Gatewayless Fixture cannot be proxied, so no grant",
  };
  for (const [label, reason] of Object.entries(why)) {
    assert.equal(await menuItem(page, label).getAttribute("title"), reason);
    assert.equal(await menuItem(page, label).evaluate((item) =>
      document.getElementById(item.getAttribute("aria-describedby"))?.textContent), reason);
  }
  assert.equal(await menuItem(page, "Check connection").getAttribute("aria-disabled"), "false");
  assert.equal(await menuItem(page, "Check connection").getAttribute("title"), null, "an available item carries no reason");
  const before = requests.filter((r) => /\/(gateway|grants|check)$/.test(r.pathname)).length;
  await menuItem(page, "Access & grants").evaluate((item) =>
    item.dispatchEvent(new MouseEvent("click", { bubbles: true })));
  assert.equal(await dialogOpen(page, "dlg-grant"), false);
  await menuItem(page, "Turn on gateway…").evaluate((item) =>
    item.dispatchEvent(new MouseEvent("click", { bubbles: true })));
  assert.equal(requests.filter((r) => /\/(gateway|grants|check)$/.test(r.pathname)).length, before,
    "disabled grant and gateway items issue no request");

  await page.keyboard.press("Escape");
  await openRowMenu(page, "bravo");
  assert.equal(await menuItem(page, "Check connection").getAttribute("aria-disabled"), "true");
  assert.equal(await menuItem(page, "Check connection").getAttribute("title"),
    "No read-only check endpoint for this provider; nothing is sent");
  assert.equal(await menuItem(page, "Check connection").evaluate((item) =>
    document.getElementById(item.getAttribute("aria-describedby"))?.textContent),
  "No read-only check endpoint for this provider; nothing is sent");
  const checks = requests.filter((r) => /\/api\/keys\/bravo\/check$/.test(r.pathname)).length;
  await menuItem(page, "Check connection").evaluate((item) =>
    item.dispatchEvent(new MouseEvent("click", { bubbles: true })));
  assert.equal(requests.filter((r) => /\/api\/keys\/bravo\/check$/.test(r.pathname)).length, checks);
  assert.equal(await dialogOpen(page, "dlg-check"), false);
  await page.keyboard.press("Escape");

  const noGatewayButton = rowButton(page, "no-gateway", "menu");
  await noGatewayButton.focus();
  await page.keyboard.press("Enter");
  await page.locator("#key-menu:visible").waitFor();
  assert.equal(await page.evaluate(() => document.activeElement.textContent.trim()), "Reveal keyV");
  await page.keyboard.press("ArrowDown");
  assert.equal(await page.evaluate(() => document.activeElement.querySelector(".key-menu-label").textContent), "Edit details");
  await page.keyboard.press("ArrowDown");
  assert.equal(await page.evaluate(() => document.activeElement.querySelector(".key-menu-label").textContent), "Activity",
    "ArrowDown skips the separator and both disabled items");
  await page.keyboard.press("Home");
  assert.equal(await page.evaluate(() => document.activeElement.querySelector(".key-menu-label").textContent), "Reveal key");
  await page.keyboard.press("End");
  assert.equal(await page.evaluate(() => document.activeElement.querySelector(".key-menu-label").textContent), "Delete key…");
  await page.keyboard.press("Tab");
  assert.equal(await focused(page), "no-gateway:menu", "Tab closes the menu and returns focus");

  await noGatewayButton.focus();
  await page.keyboard.press("Space");
  await page.locator("#key-menu:visible").waitFor();
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Space");
  await waitDialog(page, "dlg-edit", true);
  assert.equal(await page.locator("#edit-name").textContent(), "no-gateway");
  await page.locator("#dlg-edit [data-close]").click();
  await waitDialog(page, "dlg-edit", false);
  await waitFocused(page, "no-gateway:menu");

  await noGatewayButton.focus();
  await page.keyboard.press("Enter");
  await page.locator("#key-menu:visible").waitFor();
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  await waitDialog(page, "dlg-edit", true);
  assert.equal(await page.locator("#edit-name").textContent(), "no-gateway");
  await page.locator("#dlg-edit [data-close]").click();
  await waitDialog(page, "dlg-edit", false);
  await waitFocused(page, "no-gateway:menu");

  await noGatewayButton.focus();
  await page.keyboard.press("Enter");
  await page.locator("#key-menu:visible").waitFor();
  await page.keyboard.press("Escape");
  assert.equal(await focused(page), "no-gateway:menu", "Escape returns focus to More");

  await page.locator('#keys-body [data-name="alpha"]').focus();
  await page.keyboard.press("Shift+F10");
  await page.locator("#key-menu:visible").waitFor();
  await rowButton(page, "bravo", "menu").evaluate((button) => button.click());
  assert.equal(await page.locator("#key-menu [role=menuitem]").count(), 8);
  assert.equal(await rowButton(page, "alpha", "menu").getAttribute("aria-expanded"), "false");
  assert.equal(await rowButton(page, "bravo", "menu").getAttribute("aria-expanded"), "true");
  await page.locator("#pane-keys h1").click();
  await page.waitForFunction(() => document.getElementById("key-menu").hidden);
  assert.equal(await focused(page), "bravo:menu", "outside click returns focus to the invoking More button");
});

test("a busy key action leaves a skipped menu action focused and lets refresh close it safely", async (page, origin) => {
  delays.set(rule("POST", "/api/keys/alpha/check"), 1200);
  await openKeys(page, origin);
  await settleKeys(page);
  await openRowMenu(page, "alpha");
  await menuItem(page, "Check connection").click();
  for (let i = 0; i < 100 && !requests.some((r) => r.method === "POST" && r.pathname === "/api/keys/alpha/check"); i++) {
    await page.waitForTimeout(10);
  }
  assert.ok(requests.some((r) => r.method === "POST" && r.pathname === "/api/keys/alpha/check"), "check is pending");

  await openRowMenu(page, "bravo");
  await menuItem(page, "Reveal key").click();
  assert.equal(await page.locator("#key-menu").isVisible(), true, "the skipped action leaves its menu open");
  assert.equal(await rowButton(page, "bravo", "menu").getAttribute("aria-expanded"), "true");
  assert.equal(await page.evaluate(() => document.activeElement.querySelector(".key-menu-label")?.textContent), "Reveal key");
  assert.equal(requests.some((r) => r.method === "POST" && r.pathname === "/api/keys/bravo/reveal"), false,
    "the busy action sends no second request");

  await waitDialog(page, "dlg-check", true);
  await page.waitForFunction(() => document.getElementById("key-menu").hidden);
  await page.locator("#dlg-check [data-close]").click();
  await waitDialog(page, "dlg-check", false);
});

test("a background key refresh closes the More menu without leaving detached focus", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await settleKeys(page);
  await openRowMenu(page, "alpha");
  catalogVersion += 1;
  await page.clock.runFor(16000);
  await page.waitForFunction(() => document.getElementById("key-menu").hidden);
  assert.equal(await rowButton(page, "alpha", "menu").getAttribute("aria-expanded"), "false");
  assert.equal(await page.evaluate(() => document.activeElement === document.body || document.activeElement.isConnected), true);
});

test("a background key refresh keeps focus on the row's own button, and Enter still acts", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await settleKeys(page);
  await rowCell(page, "alpha", "gateway").focus();
  await page.locator('#keys-body .key-row[data-name="alpha"]').evaluate((row) => { row.dataset.stale = "1"; });
  catalogVersion += 1;
  await page.clock.runFor(16000);
  await page.waitForFunction(() => !document.querySelector('#keys-body .key-row[data-name="alpha"]').dataset.stale);
  assert.equal(await page.evaluate(() => document.activeElement.matches('#keys-body .key-row[data-name="alpha"] .key-gateway')
    && document.activeElement.isConnected), true, "focus is on the redrawn row's gateway figure, not <body>");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => new URL(location.href).searchParams.get("key") === "alpha");
});

test("deleting from the More menu updates rows, count and the provider filter", async (page, origin) => {
  await openKeys(page, origin);
  await settleKeys(page);
  const filter = page.locator("#keys-provider");
  await filter.selectOption("typesafe");
  assert.deepEqual(await rowNames(page), ["charlie"]);
  assert.equal(await page.locator("#keys-count").textContent(), "1 of 3 keys");
  await openRowMenu(page, "charlie");
  await menuItem(page, "Delete key…").click();
  await waitDialog(page, "dlg-delete", true);
  await page.locator("#delete-confirm").click();
  await waitDialog(page, "dlg-delete", false);
  await page.waitForFunction(() => !document.querySelector('#keys-body [data-name="charlie"]'));
  assert.deepEqual(await rowNames(page), ["alpha", "bravo"]);
  assert.equal(await page.locator("#keys-count").textContent(), "2 keys");
  assert.equal(await filter.inputValue(), "");
  assert.deepEqual(await filter.locator("option").allTextContents(), ["All providers", "Anthropic", "OpenAI"]);
  assert.equal(await status(page), "Deleted charlie.");
});

// VAL-CROSS-001: landing on Usage, the vault is reached from the rail and search, copy and a
// menu-driven edit all act on the same key without losing the selection.
test("a first vault visit searches, copies and edits through the More menu", async (page, origin) => {
  await page.clock.install();
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  assert.equal(await page.locator("#pane-usage").isVisible(), true, "Usage is the default pane");
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body .key-row[data-name="alpha"]').waitFor();
  await settleKeys(page);
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie"]);

  await page.locator("#keys-search").fill("bravo");
  assert.deepEqual(await rowNames(page), ["bravo"]);
  await rowButton(page, "bravo", "copy").click();
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Copied"));
  assert.equal(await status(page), "Copied bravo. Clipboard wipes in 20 s.");
  assert.ok(requests.some((r) => r.method === "POST" && r.pathname === "/api/keys/bravo/copy"
    && r.token === "test-token"));
  // Flush the deferred refresh after a copy so the resting label and the reload settle.
  await page.clock.runFor(2600);
  await page.waitForFunction(() => document.querySelector('#keys-body .key-row[data-name="bravo"] [data-act="copy"]')?.textContent === "Copy");

  await page.locator("#keys-search").fill("");
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie"]);

  await openRowMenu(page, "bravo");
  await menuItem(page, "Edit details").click();
  await waitDialog(page, "dlg-edit", true);
  assert.equal(await page.locator("#edit-name").textContent(), "bravo");
  await page.locator("#edit-form [name=notes]").fill("first-visit note");
  await page.locator("#edit-form [type=submit]").click();
  await waitDialog(page, "dlg-edit", false);
  assert.equal(await status(page), "Saved bravo.");
  await page.waitForFunction(() => document.querySelector('#keys-body [data-name="bravo"] .key-notes')?.textContent === "first-visit note");
  assert.equal(await page.locator('#keys-body .key-row[data-name="bravo"]').getAttribute("aria-current"), "true",
    "the edited row stays selected");
});

test("provider initials follow the documented rule for one-word, multi-word and unknown providers", async (page, origin) => {
  keys = [
    { name: "k-google", provider: "google", created_at: "2026-09-01T10:00:00Z", last_used_at: null, checkable: false },
    { name: "k-moonshot", provider: "moonshot", created_at: "2026-09-01T10:00:00Z", last_used_at: null, checkable: false },
    { name: "k-made-up", provider: "made_up-provider.x", created_at: "2026-09-01T10:00:00Z", last_used_at: null, checkable: false },
    { name: "k-none", provider: null, created_at: "2026-09-01T10:00:00Z", last_used_at: null, checkable: false },
    { name: "k-openai-1", provider: "openai", created_at: "2026-09-01T10:00:00Z", last_used_at: null, checkable: false },
    { name: "k-openai-2", provider: "openai", created_at: "2026-09-01T10:00:00Z", last_used_at: null, checkable: false },
  ];
  await openKeys(page, origin, { expectEmpty: true });
  // The catalog's display names arrive after the first draw; wait for them.
  await page.waitForFunction(() => document.querySelector('#keys-body .key-row[data-name="k-google"] .key-avatar')?.textContent === "GG");
  const tiles = Object.fromEntries((await avatarLook(page)).map((a) => [a.name, a]));
  assert.equal(tiles["k-google"].initials, "GG", "Google Gemini: first letters of two words");
  assert.equal(tiles["k-moonshot"].initials, "MK", "Moonshot (Kimi): punctuation does not count");
  assert.equal(tiles["k-made-up"].initials, "MU", "an id the catalog does not know splits on - _ and .");
  assert.equal(tiles["k-none"].initials, "?");
  assert.equal(await rowCell(page, "k-none", "provider").textContent(), "No provider");
  assert.equal(tiles["k-openai-1"].initials, "Op");
  assert.equal(tiles["k-openai-1"].tint, tiles["k-openai-2"].tint, "one provider, one tint");
});

test("the count reads N keys, N of M keys while a search hides some, and 0 keys when empty", async (page, origin) => {
  await openKeys(page, origin);
  assert.equal(await page.locator("#keys-count").textContent(), "3 keys");
  await page.locator("#keys-search").fill("bravo");
  assert.equal(await page.locator("#keys-count").textContent(), "1 of 3 keys");
  assert.deepEqual(await rowNames(page), ["bravo"]);
  await page.locator("#keys-search").fill("zzz");
  assert.equal(await page.locator("#keys-count").textContent(), "0 of 3 keys");
  assert.equal(await page.locator("#keys-no-match").textContent(), "No keys match “zzz”.");
  assert.equal(await page.locator("#keys-empty").isHidden(), true);
  await page.locator("#keys-search").fill("");
  assert.equal(await page.locator("#keys-count").textContent(), "3 keys");
});

test("the provider filter lists the vault's providers, combines with search and names it on a miss", async (page, origin) => {
  await openKeys(page, origin);
  await settleKeys(page);
  const filter = page.locator("#keys-provider");
  // Only providers that hold a key, by display name, "All providers" first.
  assert.deepEqual(await filter.locator("option").evaluateAll((os) => os.map((o) => [o.value, o.textContent])),
    [["", "All providers"], ["anthropic", "Anthropic"], ["openai", "OpenAI"], ["typesafe", "TypeSafe"]]);

  const box = await page.locator("#keys-search").boundingBox();
  await filter.selectOption("anthropic");
  assert.deepEqual(await rowNames(page), ["bravo"]);
  assert.equal(await page.locator("#keys-count").textContent(), "1 of 3 keys");
  const after = await page.locator("#keys-search").boundingBox();
  assert.deepEqual([after.x, after.y, after.width, after.height].map((n) => Math.round(n * 10) / 10),
    [box.x, box.y, box.width, box.height].map((n) => Math.round(n * 10) / 10),
    "the count changed under the filter, the search box did not move");

  // The two are AND-ed: a row must satisfy both.
  await page.locator("#keys-search").fill("bravo");
  assert.deepEqual(await rowNames(page), ["bravo"]);
  await page.locator("#keys-search").fill("alpha");
  assert.deepEqual(await rowNames(page), []);
  assert.equal(await page.locator("#keys-no-match").textContent(), "No keys for Anthropic match “alpha”.",
    "the miss names the provider whose filter hid the match");
  assert.equal(await page.locator("#keys-count").textContent(), "0 of 3 keys");

  // Search behaviour is unchanged under a filter: ArrowDown enters the filtered list, Escape clears.
  await page.locator("#keys-search").fill("");
  await page.locator("#keys-search").focus();
  await page.keyboard.press("ArrowDown");
  assert.equal(await page.evaluate(() => document.activeElement.closest(".key-row")?.dataset.name), "bravo");
  await page.locator("#keys-search").fill("nothing");
  await page.locator("#keys-search").press("Escape");
  assert.deepEqual(await rowNames(page), ["bravo"]);
  assert.equal(await page.locator("#keys-no-match").isHidden(), true);

  // All providers restores the whole list, search included.
  await filter.selectOption("");
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie"]);
  assert.equal(await page.locator("#keys-count").textContent(), "3 keys");
});

test("the provider filter is session-only and returns to All when its provider disappears", async (page, origin) => {
  await openKeys(page, origin);
  const filter = page.locator("#keys-provider");
  await filter.selectOption("anthropic");
  assert.deepEqual(await rowNames(page), ["bravo"]);

  // A reload forgets the choice: like the search, a provider filter is a look at part of the
  // vault, not a setting to come back to (the sort is the setting that survives; its own test
  // covers that).
  await openKeys(page, origin);
  assert.equal(await filter.inputValue(), "");
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie"]);
  assert.equal(await page.locator("#keys-count").textContent(), "3 keys");

  // The provider's last key is deleted behind the page (a background refresh): the filter must
  // not strand the list on a provider that no longer holds a key.
  await filter.selectOption("anthropic");
  keys = keys.filter((k) => k.name !== "bravo");
  catalogVersion += 1;
  await page.waitForFunction(() => document.getElementById("keys-provider").value === "", null, { timeout: 30000 });
  assert.deepEqual(await rowNames(page), ["alpha", "charlie"]);
  assert.equal(await page.locator("#keys-count").textContent(), "2 keys");
});

test("a provider filter that hides nothing reads as an unfiltered count", async (page, origin) => {
  for (const k of keys) k.provider = "openai";
  await openKeys(page, origin);
  const options = await page.locator("#keys-provider option").evaluateAll((os) => os.map((o) => o.value));
  assert.deepEqual(options, ["", "openai"], "one option per provider present, not one per key");
  await page.locator("#keys-provider").selectOption("openai");
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie"]);
  assert.equal(await page.locator("#keys-count").textContent(), "3 keys", "nothing is hidden, so the count admits no 'of'");
});

test("the sort and the provider filter stay reachable and working at 390 px", async (page, origin) => {
  await openKeys(page, origin);
  await page.setViewportSize({ width: 390, height: 844 });
  const onScreen = (sel) => page.locator(sel).evaluate((n) => {
    const r = n.getBoundingClientRect();
    return r.width > 0 && r.left >= 0 && r.right <= innerWidth && r.top >= 0 && r.bottom <= innerHeight;
  });
  assert.equal(await onScreen("#keys-provider"), true, "the provider filter is on screen");
  assert.equal(await onScreen("#keys-sort"), true, "the sort stays on screen instead of being hidden");
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1),
    true, "no horizontal overflow");

  // Both controls still work at this width, including the widest option label.
  await page.selectOption("#keys-sort", "most");
  assert.equal(await onScreen("#keys-sort"), true, "the widest sort label stays on screen");
  assert.deepEqual(await rowNames(page), ["alpha", "charlie", "bravo"],
    "Most used this month: alpha 3 calls, charlie 2, bravo 0; ties by name");
  await page.selectOption("#keys-provider", "anthropic");
  assert.deepEqual(await rowNames(page), ["bravo"]);
  assert.equal(await page.locator("#keys-count").textContent(), "1 of 3 keys");
});

test("the footer states the Keychain and the 20 s clipboard wipe, and drops the right half under 780 px", async (page, origin) => {
  await openKeys(page, origin);
  const read = () => page.evaluate(() => {
    const f = document.querySelector("#pane-keys .keys-footer");
    const list = document.getElementById("keys-list").getBoundingClientRect();
    return {
      left: f.querySelector(".keys-footer-left").textContent.trim(),
      lock: !!f.querySelector(".keys-footer-left svg"),
      right: f.querySelector(".keys-footer-right").textContent.trim(),
      rightShown: f.querySelector(".keys-footer-right").getBoundingClientRect().width > 0,
      below: f.getBoundingClientRect().top >= list.bottom,
    };
  });
  assert.deepEqual(await read(), { left: "Stored in macOS Keychain", lock: true, right: "Copy requires approval · Clipboard clears in 20 s", rightShown: true, below: true });
  await page.setViewportSize({ width: 780, height: 900 });
  const narrow = await read();
  assert.equal(narrow.left, "Stored in macOS Keychain");
  assert.equal(narrow.rightShown, false);
});

test("a key with the gateway on shows the badge and its URL; only keys with calls show a figure", async (page, origin) => {
  const alpha = keys.find((k) => k.name === "alpha");
  alpha.gateway_enabled = true;
  alpha.gateway_url = "http://127.0.0.1:12767/alpha";
  await openKeys(page, origin);
  const row = (n) => page.locator(`#keys-body .key-row[data-name="${n}"]`);
  assert.equal(await row("alpha").locator(".badge").textContent(), "Gateway on");
  assert.equal(await row("alpha").locator(".gw-url").textContent(), "http://127.0.0.1:12767/alpha");
  assert.equal(await row("bravo").locator(".badge, .gw-url").count(), 0, "no badge for a key that is off");
  assert.equal(await gatewayText(page, "alpha"), "3 requests");
  assert.equal(await row("alpha").locator(".key-gateway-wrap").textContent(), "3 requests this month");
  assert.equal(await gatewayText(page, "bravo"), null);
  assert.equal(await gatewayText(page, "charlie"), "2 requests");
  assert.doesNotMatch(await page.locator("#keys-list").textContent(), /\$0(?!\.0[1-9])/, "never $0");
});

test("the vault fits 780 and 540 px in both themes with last used under the provider", async (page, origin) => {
  await openKeys(page, origin);
  for (const theme of ["dark", "light"]) {
    if (theme === "light") {
      await page.getByRole("tab", { name: "Settings" }).click();
      await page.locator("#theme-switch").click();
      await page.getByRole("tab", { name: "Keys" }).click();
    }
    for (const width of [780, 540, 390]) {
      await page.setViewportSize({ width, height: 900 });
      const g = await page.evaluate(() => {
        const row = document.querySelector('#keys-body .key-row[data-name="bravo"]');
        const r = (n) => n.getBoundingClientRect();
        return {
          vw: innerWidth,
          spill: document.documentElement.scrollWidth - document.documentElement.clientWidth,
          provider: r(row.querySelector(".key-provider")), used: r(row.querySelector(".key-used")),
          usedText: row.querySelector(".key-used").textContent,
          copy: r(row.querySelector('[data-act="copy"]')),
          kbd: r(document.querySelector("#btn-add kbd")).width,
          sort: r(document.getElementById("keys-sort")),
          avatar: r(row.querySelector(".key-avatar")).width,
        };
      });
      const at = `${theme} ${width}px`;
      assert.ok(g.spill <= 1, `${at}: spills ${g.spill}px`);
      assert.equal(g.usedText, "Never used", `${at}: last used is still there`);
      assert.ok(g.used.width > 0 && g.used.top >= g.provider.bottom - 1, `${at}: last used sits under the provider`);
      assert.ok(g.copy.left >= 0 && g.copy.right <= g.vw && g.copy.width > 0, `${at}: Copy is on screen`);
      assert.ok(g.sort.width > 0 && g.sort.right <= g.vw, `${at}: sort stays reachable`);
      assert.equal(g.kbd > 0, width > 540, `${at}: the N hint shows only above 540 px`);
      assert.equal(g.avatar, width > 540 ? 40 : 32, `${at}: tile size`);
    }
    await page.setViewportSize({ width: 1440, height: 900 });
  }
});

test("the grants box sits below the list and its Revoke button revokes", async (page, origin) => {
  // Seeded persistent state, not a transient GET override: the DELETE route below mutates this
  // same array, so every re-render (boot and the Keys-tab switch each run loadKeys → loadGrants
  // → renderGrants, which rebuilds the box with replaceChildren) reproduces the same active row
  // until the click's own DELETE lands. Nothing can empty the list and tear the Revoke button
  // out mid-click, so no timing gate or retry is needed.
  grants = [fixtureGrant({
    id: "aa11bb22", key: "alpha", task: "fixture task", methods: ["POST"], paths: [],
    requests: 1, profile: null, unattended: false, expires_at: "2099-01-01T00:00:00Z",
  })];
  await openKeys(page, origin);
  await page.locator("#grants-list li").first().waitFor();
  assert.match(await page.locator("#grants-count").textContent(), /^1 active grant, 0 clients\./);
  const order = await page.evaluate(() => document.getElementById("keys-list").getBoundingClientRect().bottom <= document.getElementById("grants").getBoundingClientRect().top);
  assert.equal(order, true, "the box is below the list");

  await page.getByRole("button", { name: "Revoke grant aa11bb22" }).click();
  await page.waitForFunction(() => document.getElementById("status").textContent === "Grant aa11bb22 revoked.");
  // The reload reads the mutated state: the kill stays on the list as a revoked row that
  // offers nothing, so the count breaks out revoked instead of calling the box empty.
  // The status line is set as soon as the DELETE answers, before that reload redraws the box,
  // so the active row can still be on screen here; the wait is for the redrawn one.
  await page.waitForFunction(() => [...document.querySelectorAll("#grants-list li")]
    .some((li) => li.textContent.includes("fixture task") && li.querySelector(".badge")?.textContent === "revoked"));
  const row = page.locator("#grants-list li", { hasText: "fixture task" });
  assert.deepEqual(await row.locator(".badge").allTextContents(), ["revoked"], "the row shows its revoked fate");
  assert.equal(await row.locator('[aria-label="Revoke grant aa11bb22"]').count(), 0, "a revoked row offers no Revoke button");
  assert.equal(await page.locator("#grants-count").textContent(), "0 active, 1 revoked grant, 0 clients.");
  assert.ok(requests.some((r) => r.method === "DELETE" && r.pathname === "/api/grants/aa11bb22" && r.token === "test-token"),
    "the DELETE rides the page token");
});

// ---------- reveal and its expiry ----------

test("reveal shows the secret, counts down and auto-hides at expiry", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await rowAct(page, "alpha", "reveal");
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
  await rowAct(page, "alpha", "reveal");
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

test("a cancelled Touch ID leaves reveal usable and says why", async (page, origin) => {
  await openKeys(page, origin);
  failures.set(rule("POST", "/api/keys/alpha/reveal"), { status: 401, body: { error: "auth_cancelled" } });
  await rowAct(page, "alpha", "reveal");
  await page.waitForFunction(() => document.getElementById("status").textContent.includes("cancelled"));
  assert.equal(await status(page), "Mac authentication cancelled.");
  assert.equal(await page.locator("#dlg-reveal").evaluate((d) => d.open), false);
  // The failure released the busy guard: the same key reveals on the next try.
  failures.delete(rule("POST", "/api/keys/alpha/reveal"));
  await rowAct(page, "alpha", "reveal");
  await waitDialog(page, "dlg-reveal", true);
  assert.equal(await page.locator("#reveal-name").textContent(), "alpha");
  await page.locator("#dlg-reveal [data-close]").click();
  await waitDialog(page, "dlg-reveal", false);
});

// ---------- copy and its feedback ----------

test("copy reports the wipe deadline and refreshes the row afterwards", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  // The secret goes to the clipboard on the server; the page never touches it.
  await page.evaluate(() => { window.__clip = 0; navigator.clipboard.writeText = async () => { window.__clip += 1; }; });
  delays.set(rule("POST", "/api/keys/bravo/copy"), 300);
  await rowButton(page, "bravo", "copy").click();
  assert.equal(await rowButton(page, "bravo", "copy").textContent(), "Touch ID…");
  assert.equal(await rowButton(page, "bravo", "copy").isDisabled(), true);
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Copied"));
  assert.equal(await status(page), "Copied bravo. Clipboard wipes in 20 s.");
  assert.equal(await rowButton(page, "bravo", "copy").textContent(), "Copied");
  assert.equal(await rowButton(page, "bravo", "copy").locator("svg").count(), 1, "the label changes, the icon stays");
  const post = requests.find((r) => r.method === "POST" && r.pathname === "/api/keys/bravo/copy");
  assert.equal(post.token, "test-token", "the copy carries the launch token");
  assert.equal(await page.evaluate(() => window.__clip), 0, "navigator.clipboard is never used for a key");
  assert.equal((await rowCell(page, "bravo", "used").textContent()).trim(), "Just now");

  const before = requests.filter((r) => r.pathname === "/api/keys" && r.method === "GET").length;
  await page.clock.runFor(2600);
  // Only the deferred reload's re-render puts the resting label back.
  await page.waitForFunction(() => document.querySelector('#keys-body .key-row[data-name="bravo"] [data-act="copy"]')?.textContent === "Copy");
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

// The Add dialog's inputs carry no id, so activeElement is compared against the field node
// itself: validation must focus exactly the offending control, not merely show the message.
const addFocus = (page, field) =>
  page.evaluate((f) => document.activeElement === document.getElementById("add-form").elements[f], field);

test("add validates locally before it sends anything", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  const sent = requests.filter((r) => r.method === "POST" && r.pathname === "/api/keys").length;

  // VAL-REQ-001/002/003: each missing field is named and focused, and nothing leaves the page.
  await page.locator("#add-form [type=submit]").click();
  assert.match(await page.locator("#add-err").textContent(), /^Name:/);
  assert.equal(await addFocus(page, "name"), true, "an empty name must focus the name field");

  await page.locator("#add-form [name=name]").fill("delta");
  await page.locator("#add-form [type=submit]").click();
  assert.equal(await page.locator("#add-err").textContent(), "Provider is required.");
  assert.equal(await addFocus(page, "provider"), true, "a missing provider must focus the provider field");

  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [type=submit]").click();
  assert.equal(await page.locator("#add-err").textContent(), "Secret is required.");
  assert.equal(await addFocus(page, "secret"), true, "a missing secret must focus the secret field");

  assert.equal(requests.filter((r) => r.method === "POST" && r.pathname === "/api/keys").length, sent,
    "no request may leave until the form is valid");
});

// VAL-INVAL-001: the name pattern is enforced in the browser for every shape the server would
// refuse, so none of them can reach the wire.
test("add refuses pattern-violating names locally and sends nothing", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SECRET);
  const sent = () => requests.filter((r) => r.method === "POST" && r.pathname === "/api/keys").length;
  const before = sent();
  for (const bad of ["UPPER", "spa ce", "-lead", ".dot", "café"]) {
    await page.locator("#add-form [name=name]").fill(bad);
    await page.locator("#add-form [type=submit]").click();
    assert.match(await page.locator("#add-err").textContent(), /^Name:/, `"${bad}" must show the name error`);
    assert.equal(await addFocus(page, "name"), true, `"${bad}" must focus the name field`);
    assert.equal(sent(), before, `"${bad}" must not reach the server`);
  }
});

// VAL-INVAL-002: a provider of only spaces trims to nothing, so it is refused like an empty one.
test("add refuses a whitespace-only provider locally", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=name]").fill("delta");
  await page.locator("#add-form [name=provider]").fill("   ");
  await page.locator("#add-form [name=secret]").fill(SECRET);
  const before = requests.filter((r) => r.method === "POST" && r.pathname === "/api/keys").length;
  await page.locator("#add-form [type=submit]").click();
  assert.equal(await page.locator("#add-err").textContent(), "Provider is required.");
  assert.equal(await addFocus(page, "provider"), true, "a blank provider must focus the provider field");
  assert.equal(requests.filter((r) => r.method === "POST" && r.pathname === "/api/keys").length, before,
    "a blank provider must not reach the server");
});

// VAL-INVAL-003: a 129-character lowercase name passes the client pattern (no length cap), so
// only the server's KeyName rule refuses it. KeyName.validate checks the cap before the
// pattern, so the real backend answers "name too long" — and the fixture mirrors that exact
// string, keeping "invalid name …" for pattern violations alone.
test("add keeps the dialog open with the server's message when the name is too long", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  const longName = "a".repeat(129);
  await page.locator("#add-form [name=name]").fill(longName);
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SECRET);
  await page.locator("#add-form [type=submit]").click();
  await page.waitForFunction(() => document.getElementById("add-err").textContent !== "");
  assert.equal(await page.locator("#add-err").textContent(), "name too long",
    "the server's length-cap message must be shown verbatim");
  assert.equal(await page.locator("#dlg-add").evaluate((d) => d.open), true, "the dialog stays open");
  assert.equal(await page.locator("#add-form [name=name]").inputValue(), longName, "the name is preserved");
  assert.equal(await page.locator("#add-form [name=provider]").inputValue(), "openai", "the provider is preserved");
  assert.equal(await page.locator("#add-form [name=secret]").inputValue().then((v) => v.length > 0), true,
    "the typed secret is preserved for retry");
  assert.equal(await page.locator("#add-form [type=submit]").textContent(), "Add key");
  assert.equal(await page.locator("#add-form [type=submit]").isDisabled(), false, "the retry must be possible");
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie"], "nothing was created");
});

test("add creates the key, carries the launch token and selects the new row", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await page.locator("#add-form [name=name]").fill("delta");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SECRET);
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  await page.locator('#keys-body .key-row[data-name="delta"]').waitFor();
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "charlie", "delta"]);
  assert.equal(await status(page), "Added delta.");
  assert.equal(await page.locator('#keys-body .key-row[data-name="delta"]').getAttribute("aria-current"), "true");
  assert.equal(await page.locator('#keys-body [aria-current="true"]').count(), 1, "one selected row");
  assert.equal(await rowCell(page, "delta", "avatar").textContent(), "Op", "the new row has its initials tile");
  assert.equal(await page.locator("#keys-count").textContent(), "4 keys");
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

// The sentinel for the secret-safety tests below: invented, never a real credential, held
// in one named constant and only ever asserted against negatively — it is never printed or
// written into an assertion message.
const SAFETY_SECRET = "sk-add-safety-NEVER-REAL-0000000000";
// A full-document scan for the sentinel — the markup plus every input and textarea value,
// because a typed or pasted value lives in the value property and never reaches innerHTML.
// Negative only, and the message never embeds it.
const safetyFree = (page, step) =>
  page.evaluate(() => [
    document.documentElement.innerHTML,
    ...[...document.querySelectorAll("input, textarea")].map((n) => n.value || ""),
  ].join("\n"))
    .then((blob) => assert.doesNotMatch(blob, new RegExp(SAFETY_SECRET), step));

// VAL-SECRET-001: a saved key's secret must not linger anywhere in the document once the
// dialog has closed — not in the rendered row, not in the closed dialog's markup — and the
// secret input itself must come back blank for the next key.
test("add leaves no trace of the typed secret in the dom after it saves", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=name]").fill("delta");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SAFETY_SECRET);
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  await page.locator('#keys-body .key-row[data-name="delta"]').waitFor();
  await page.waitForFunction(() => document.getElementById("add-form").elements.secret.value === "");
  assert.equal(await page.locator("#add-form [name=secret]").inputValue(), "",
    "the secret input must come back blank");
  await safetyFree(page, "no secret in DOM after save");
});

// VAL-SECRET-002: nothing the add flow sends back may carry the typed secret. The responses
// are read off the wire (the POST's own body and the listing the page refetches), and the
// audit endpoint the History drawer reads is fetched from the page over the fixture's
// invented add row, which mirrors the shape the real engine audits for a created key.
test("no add-flow response echoes the typed secret", async (page, origin) => {
  keyEvents = [{ ts: "2026-10-27T12:00:00Z", action: "add", caller: "add", detail: null }];
  await openKeys(page, origin);
  const addResponses = [];
  const listings = [];
  page.on("response", (r) => {
    if (new URL(r.url()).pathname !== "/api/keys") return;
    if (r.request().method() === "POST") addResponses.push(r);
    if (r.request().method() === "GET") listings.push(r);
  });
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=name]").fill("delta");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SAFETY_SECRET);
  const listingsBefore = listings.length;
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  await page.locator('#keys-body .key-row[data-name="delta"]').waitFor();
  assert.equal(addResponses.length, 1, "exactly one add POST was answered");
  assert.equal((await addResponses[0].text()).includes(SAFETY_SECRET), false,
    "the add response must not echo the typed secret");
  assert.ok(listings.length > listingsBefore, "the page refetched the listing after the add");
  assert.equal((await listings[listings.length - 1].text()).includes(SAFETY_SECRET), false,
    "the listing must not echo the typed secret");
  const eventsText = await page.evaluate(async () => (await fetch("/api/keys/delta/events")).text());
  assert.equal(JSON.parse(eventsText).events.length, 1, "the fixture's audit row for the add is served");
  assert.equal(eventsText.includes(SAFETY_SECRET), false, "the audit endpoint must not echo the typed secret");
});

// VAL-SECRET-003: a refused submit is a retry, not a dead end. While the dialog stays open
// every typed value survives (the secret included, so the user does not retype it), and the
// close that abandons the retry wipes the secret like every other close path.
test("a duplicate 409 keeps every typed value for the retry and wipes the secret when the dialog closes", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=name]").fill("alpha");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SAFETY_SECRET);
  await page.locator("#add-form [type=submit]").click();
  await page.waitForFunction(() => document.getElementById("add-err").textContent !== "");
  assert.equal(await dialogOpen(page, "dlg-add"), true, "the dialog stays open for the retry");
  assert.equal(await page.locator("#add-form [name=name]").inputValue(), "alpha", "the name is preserved");
  assert.equal(await page.locator("#add-form [name=provider]").inputValue(), "openai", "the provider is preserved");
  assert.equal(await page.locator("#add-form [name=secret]").inputValue().then((v) => v.length > 0), true,
    "the typed secret is preserved while the dialog stays open");
  assert.equal(await page.locator("#add-form [type=submit]").isDisabled(), false, "the retry must be possible");
  await page.locator("#dlg-add [data-close]").click();
  await waitDialog(page, "dlg-add", false);
  await page.waitForFunction(() => document.getElementById("add-form").elements.secret.value === "");
  assert.equal(await page.locator("#add-form [name=secret]").inputValue(), "",
    "closing after the refusal wipes the secret");
  await safetyFree(page, "no trace of the abandoned secret may stay in the dom");
});

// VAL-SECRET-003: the wipe is the property of every close path, not just Cancel. Escape
// counts twice — plain, and with the provider list open where the first Escape must close
// only the list (the secret surviving until the dialog itself closes) — and so does the
// backdrop click outside the card.
test("cancel, escape and the backdrop each wipe the typed secret when they close the add dialog", async (page, origin) => {
  await openKeys(page, origin);
  const secretInput = page.locator("#add-form [name=secret]");
  const typedAndWiped = async (close, step) => {
    await page.locator("#btn-add").click();
    await waitDialog(page, "dlg-add", true);
    await secretInput.fill(SAFETY_SECRET);
    await close();
    await waitDialog(page, "dlg-add", false);
    await page.waitForFunction(() => document.getElementById("add-form").elements.secret.value === "");
    assert.equal(await secretInput.inputValue(), "", `${step} must wipe the secret input`);
    await safetyFree(page, `no trace of the typed secret may stay in the dom after ${step}`);
  };
  await typedAndWiped(() => page.locator("#dlg-add [data-close]").click(), "cancel");
  await typedAndWiped(() => page.keyboard.press("Escape"), "escape");

  // Escape with the picker list open: the first Escape closes only the list, so the typed
  // secret must still be there for the retry; the second closes the dialog and wipes it.
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await secretInput.fill(SAFETY_SECRET);
  await page.locator("#add-form [name=provider]").click();
  await page.locator("#add-form .pick-list:visible").waitFor();
  await page.keyboard.press("Escape");
  assert.equal(await dialogOpen(page, "dlg-add"), true, "the first escape closes only the picker list");
  assert.equal(await page.locator("#add-form .pick-list").isHidden(), true, "the picker list is closed");
  assert.equal(await secretInput.inputValue().then((v) => v.length > 0), true,
    "the secret survives while the dialog stays open");
  await page.keyboard.press("Escape");
  await waitDialog(page, "dlg-add", false);
  await page.waitForFunction(() => document.getElementById("add-form").elements.secret.value === "");
  assert.equal(await secretInput.inputValue(), "", "the second escape wipes the secret input");
  await safetyFree(page, "no trace of the typed secret may stay in the dom after the picker escape");

  await typedAndWiped(() => page.mouse.click(8, 8), "a backdrop click");
});

// Invented sentinels for the provider tests below, in the suite's NEVER-REAL style. The
// sk-ant- and gsk_ shapes carry the real vendors' unique key_prefixes, which is the point
// of the guess test; none of these is a real credential.
const ADD_SECRET = "sk-add-NEVER-REAL-0000000000";
const ANT_SECRET = "sk-ant-add-NEVER-REAL-0000000000";
const PLAIN_SECRET = "plain-add-NEVER-REAL-0000000000";
const GROQ_SECRET = "gsk_add-NEVER-REAL-0000000000";

// VAL-PROV-001: a provider the user added lives in the catalog overlay under "Yours"; it
// must be offered like a built-in and the row it produces must carry its display name.
test("add offers a custom provider under yours and names the row with its display name", async (page, origin) => {
  customProviders = [{
    id: "fixture-labs", name: "Fixture Labs", group: "yours", gateway: true,
    host: "api.fixture-labs.test", api: "openai", auth_header: "Authorization", auth_prefix: "Bearer ",
    path_prefix: "", key_prefix: "fxl-live-", note: "Synthetic overlay provider invented for this suite.",
  }];
  await openKeys(page, origin);
  await settleKeys(page);
  const bodies = [];
  page.on("request", (r) => {
    if (r.method() === "POST" && new URL(r.url()).pathname === "/api/keys") bodies.push(r.postData());
  });
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=provider]").click();
  // The listId prefix is always three dash-separated parts (name-pick-xxxxx), so the
  // provider id itself is everything after that.
  const offered = await page.locator("#add-form .pick-list .pick-item")
    .evaluateAll((nodes) => nodes.map((n) => n.id.split("-").slice(3).join("-")));
  assert.ok(offered.includes("fixture-labs"), "a provider from the overlay is offered for new keys");
  assert.equal(await page.locator("#add-form .pick-list .pick-group").first().textContent(), "Yours",
    "the user's own group is offered first");
  await page.locator("#add-form .pick-list .pick-item").filter({ hasText: "Fixture Labs" }).click();
  assert.equal(await page.locator("#add-form [name=provider]").inputValue(), "fixture-labs",
    "picking the item writes the id into the field");
  await page.locator("#add-form [name=name]").fill("zulu");
  await page.locator("#add-form [name=secret]").fill(ADD_SECRET);
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  await page.locator('#keys-body .key-row[data-name="zulu"]').waitFor();
  assert.equal(await rowCell(page, "zulu", "provider").textContent(), "Fixture Labs",
    "the row shows the catalog's display name, not the raw id");
  assert.equal(JSON.parse(bodies[0]).provider, "fixture-labs", "the picked id is what rides the POST");
});

// VAL-PROV-002: a vendor that is not in the catalog is free text. The picker must say the
// typed id will be kept, the add must go through, and the row must fall back to the raw id.
test("add accepts an unknown provider typed by hand and shows the raw id", async (page, origin) => {
  await openKeys(page, origin);
  await settleKeys(page);
  const bodies = [];
  page.on("request", (r) => {
    if (r.method() === "POST" && new URL(r.url()).pathname === "/api/keys") bodies.push(r.postData());
  });
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=provider]").fill("vendor-zzz");
  assert.equal(await page.locator("#add-form .pick-list .pick-none").textContent(),
    'No match. "vendor-zzz" will be saved as typed.',
    "the picker must promise the typed id is kept as-is");
  await page.locator("#add-form [name=name]").fill("yankee");
  await page.locator("#add-form [name=secret]").fill(ADD_SECRET);
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  await page.locator('#keys-body .key-row[data-name="yankee"]').waitFor();
  assert.equal(await rowCell(page, "yankee", "provider").textContent(), "vendor-zzz",
    "an unknown id has no display name, so the row shows the raw id");
  assert.equal(JSON.parse(bodies[0]).provider, "vendor-zzz", "the typed id rides the POST untouched");
});

// VAL-PROV-004: the secret-prefix guess had no coverage anywhere. A unique key_prefix
// pre-fills an empty provider field (and clears again when the prefix stops matching), a
// provider typed by hand is never overwritten, a hidden provider is never guessed, and the
// guessed id is what the POST carries.
test("the add dialog guesses the provider from the secret but never over a typed or hidden one", async (page, origin) => {
  // Groq's gsk_ prefix is unique and four characters, so it would match if the hidden rule broke.
  hiddenUsers.add("groq");
  await openKeys(page, origin);
  await settleKeys(page);
  const bodies = [];
  page.on("request", (r) => {
    if (r.method() === "POST" && new URL(r.url()).pathname === "/api/keys") bodies.push(r.postData());
  });
  const providerValue = () => page.evaluate(() => document.getElementById("add-form").elements.provider.value);
  const guessed = () => page.evaluate(() => document.getElementById("add-form").elements.provider.dataset.guessed || "");
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);

  await page.locator("#add-form [name=secret]").fill(ANT_SECRET);
  assert.equal(await providerValue(), "anthropic", "the unique prefix pre-fills an empty provider");
  assert.equal(await guessed(), "1", "the filled provider is marked guessed so later typing can replace it");

  await page.locator("#add-form [name=secret]").fill(PLAIN_SECRET);
  assert.equal(await providerValue(), "", "the guess clears when the prefix stops matching");
  assert.equal(await guessed(), "");

  await page.locator("#add-form [name=provider]").fill("openrouter");
  await page.locator("#add-form [name=secret]").fill(ANT_SECRET);
  assert.equal(await providerValue(), "openrouter", "a provider typed by hand is never overwritten");
  assert.equal(await guessed(), "");

  await page.locator("#add-form [name=provider]").fill("");
  await page.locator("#add-form [name=secret]").fill(GROQ_SECRET);
  assert.equal(await providerValue(), "", "a hidden provider's prefix never fills the field");

  await page.locator("#add-form [name=secret]").fill(ANT_SECRET);
  await page.locator("#add-form [name=name]").fill("echo");
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  await page.locator('#keys-body .key-row[data-name="echo"]').waitFor();
  assert.equal(await rowCell(page, "echo", "provider").textContent(), "Anthropic",
    "the row resolves the guessed provider's display name");
  assert.equal(JSON.parse(bodies[0]).provider, "anthropic", "the guessed id is what gets saved");
});

// The Add dialog keeps the three required fields up front; Kind and Notes live behind the
// Advanced disclosure (VAL-ADD-001/002). A collapsed <details> renders no boxes, so its
// inputs are neither visible nor focusable until the summary is activated.
test("the add dialog keeps the essential fields up front and hides kind and notes until advanced opens", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  for (const sel of ["[name=name]", "[name=provider]", "[name=secret]"]) {
    assert.equal(await page.locator(`#add-form ${sel}`).isVisible(), true, `${sel} is visible without expansion`);
  }
  assert.equal(await page.locator("#dlg-add .hint").textContent(), "Stored in the macOS Keychain. It never appears in the list.");
  assert.equal(await page.locator("#add-advanced").isVisible(), true, "the disclosure itself is up front");
  assert.equal(await page.locator("#add-advanced summary").textContent(), "Advanced");
  assert.equal(await page.locator("#add-form [name=kind]").isVisible(), false, "kind hides while collapsed");
  assert.equal(await page.locator("#add-form [name=notes]").isVisible(), false, "notes hide while collapsed");

  await page.locator("#add-advanced summary").click();
  assert.equal(await page.locator("#add-form [name=kind]").isVisible(), true, "expanding reveals kind");
  assert.equal(await page.locator("#add-form [name=notes]").isVisible(), true, "expanding reveals notes");
  assert.deepEqual(await page.locator("#add-form [name=kind] option").evaluateAll((os) => os.map((o) => o.value)),
    ["runtime", "billing"], "kind offers runtime first, then billing");
  assert.equal(await page.locator("#add-form [name=kind]").inputValue(), "runtime", "runtime stays the default");
});

// VAL-ADD-002: native <details> semantics give the keyboard and the expanded state for
// free — the test only has to prove they are actually wired to the summary.
test("the add dialog's advanced section starts collapsed and toggles by click, enter and space", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  const advanced = page.locator("#add-advanced");
  assert.equal(await advanced.evaluate((d) => d.open), false, "advanced starts collapsed");
  // A collapsed field cannot take focus, so a stray Tab or programmatic focus never
  // lands inside the hidden row.
  assert.equal(await page.evaluate(() => {
    document.getElementById("add-form").elements.notes.focus();
    return document.activeElement === document.getElementById("add-form").elements.notes;
  }), false, "a collapsed field is not focusable");

  await page.locator("#add-advanced summary").focus();
  await page.keyboard.press("Enter");
  assert.equal(await advanced.evaluate((d) => d.open), true, "enter expands");
  assert.equal(await page.locator("#add-form [name=notes]").isVisible(), true);
  await page.keyboard.press("Enter");
  assert.equal(await advanced.evaluate((d) => d.open), false, "enter collapses again");
  await page.keyboard.press("Space");
  assert.equal(await advanced.evaluate((d) => d.open), true, "space expands");
  await page.keyboard.press("Space");
  assert.equal(await advanced.evaluate((d) => d.open), false, "space collapses again");
  await page.locator("#add-advanced summary").click();
  assert.equal(await advanced.evaluate((d) => d.open), true, "a click expands");
  await page.locator("#add-advanced summary").click();
  assert.equal(await advanced.evaluate((d) => d.open), false, "a click collapses");
});

// VAL-ADD-003: every open starts fresh. form.reset() restores the fields but not the
// disclosure, so openAdd must close Advanced itself — even after an expanded cancel or a
// failed submit left it open with stale values.
test("the add dialog's advanced section and its fields reset on every open", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-advanced summary").click();
  await page.locator("#add-form [name=kind]").selectOption("billing");
  await page.locator("#add-form [name=notes]").fill("stale note");
  await page.locator("#add-form [name=name]").fill("alpha");
  await page.locator("#dlg-add [data-close]").click();
  await waitDialog(page, "dlg-add", false);

  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  assert.equal(await page.locator("#add-advanced").evaluate((d) => d.open), false, "advanced re-collapses after expand-and-cancel");
  assert.equal(await page.locator("#add-form [name=kind]").inputValue(), "runtime", "kind resets to runtime");
  assert.equal(await page.locator("#add-form [name=notes]").inputValue(), "", "notes reset to empty");
  assert.equal(await page.locator("#add-form [name=name]").inputValue(), "", "name resets too");
  assert.equal(await page.locator("#add-err").textContent(), "", "no stale error");

  // A 409 keeps the dialog open with values preserved; the next open must still be fresh.
  await page.locator("#add-form [name=name]").fill("alpha");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SECRET);
  await page.locator("#add-advanced summary").click();
  await page.locator("#add-form [name=kind]").selectOption("billing");
  await page.locator("#add-form [type=submit]").click();
  await page.waitForFunction(() => document.getElementById("add-err").textContent !== "");
  assert.equal(await page.locator("#dlg-add").evaluate((d) => d.open), true);
  assert.equal(await page.locator("#add-form [name=kind]").inputValue(), "billing", "the failed submit preserves the typed values");
  await page.locator("#dlg-add [data-close]").click();
  await waitDialog(page, "dlg-add", false);

  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  assert.equal(await page.locator("#add-advanced").evaluate((d) => d.open), false, "advanced re-collapses after an error cycle");
  assert.equal(await page.locator("#add-form [name=kind]").inputValue(), "runtime");
  assert.equal(await page.locator("#add-form [name=notes]").inputValue(), "");
  assert.equal(await page.locator("#add-err").textContent(), "", "the error dies with the close");
});

// VAL-ADD-004: a collapsed disclosure must not change the wire contract — the hidden
// fields still submit, with their untouched defaults. The fixture's request log keeps
// no bodies, so the POST is captured in the page.
test("a collapsed advanced section still submits kind runtime and empty notes", async (page, origin) => {
  await openKeys(page, origin);
  const bodies = [];
  page.on("request", (r) => {
    if (r.method() === "POST" && new URL(r.url()).pathname === "/api/keys") bodies.push(r.postData());
  });
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  assert.equal(await page.locator("#add-advanced").evaluate((d) => d.open), false);
  await page.locator("#add-form [name=name]").fill("delta");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=secret]").fill(SECRET);
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  assert.equal(bodies.length, 1, "exactly one add POST left the page");
  const body = JSON.parse(bodies[0]);
  assert.deepEqual([body.name, body.provider, body.kind, body.notes], ["delta", "openai", "runtime", ""],
    "the collapsed defaults submit exactly as the visible fields did before the restructure");
  await page.locator('#keys-body .key-row[data-name="delta"]').waitFor();
  assert.equal(await status(page), "Added delta.");
});

// VAL-CROSS-003: the Advanced fields are not decoration — kind and notes travel in the POST
// and come back on the new row (and, on reopening Edit, still hold).
test("add submits the advanced kind and notes and renders them on the new row", async (page, origin) => {
  await openKeys(page, origin);
  const bodies = [];
  page.on("request", (r) => {
    if (r.method() === "POST" && new URL(r.url()).pathname === "/api/keys") bodies.push(r.postData());
  });
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-advanced summary").click();
  await page.locator("#add-form [name=name]").fill("delta");
  await page.locator("#add-form [name=provider]").fill("openai");
  await page.locator("#add-form [name=kind]").selectOption("billing");
  await page.locator("#add-form [name=notes]").fill("monthly invoice");
  await page.locator("#add-form [name=secret]").fill(SECRET);
  await page.locator("#add-form [type=submit]").click();
  await waitDialog(page, "dlg-add", false);
  assert.equal(bodies.length, 1, "exactly one add POST left the page");
  const body = JSON.parse(bodies[0]);
  assert.deepEqual([body.name, body.provider, body.kind, body.notes], ["delta", "openai", "billing", "monthly invoice"],
    "the advanced values must ride the POST body");
  await page.locator('#keys-body .key-row[data-name="delta"]').waitFor();
  assert.equal(await rowCell(page, "delta", "notes").textContent(), "monthly invoice", "the row shows the notes");
  assert.equal(await status(page), "Added delta.");

  // Reopening Edit on the new row shows both stored values.
  await rowAct(page, "delta", "edit");
  await waitDialog(page, "dlg-edit", true);
  assert.equal(await page.locator("#edit-form [name=kind]").inputValue(), "billing");
  assert.equal(await page.locator("#edit-form [name=notes]").inputValue(), "monthly invoice");
});

// VAL-ADD-005: the dialog stays inside its card and the viewport at 390 px with the
// disclosure expanded — the row must not spill and the actions must stay reachable.
test("the add dialog keeps its expanded advanced row inside the card at 390 px", async (page, origin) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await openKeys(page, origin);
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-advanced summary").click();
  const g = await page.evaluate(() => {
    const r = (n) => n.getBoundingClientRect();
    const form = document.getElementById("add-form");
    return {
      vw: innerWidth, vh: innerHeight,
      dlg: r(document.getElementById("dlg-add")),
      kind: r(form.elements.kind),
      notes: r(form.elements.notes),
      cancel: r(document.querySelector("#dlg-add [data-close]")),
      submit: r(document.querySelector("#dlg-add [type=submit]")),
      spill: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    };
  });
  const insideCard = (a) => a.left >= g.dlg.left - 0.5 && a.right <= g.dlg.right + 0.5 && a.top >= g.dlg.top - 0.5 && a.bottom <= g.dlg.bottom + 0.5;
  assert.equal(insideCard(g.kind), true, "kind stays inside the dialog card");
  assert.equal(insideCard(g.notes), true, "notes stay inside the dialog card");
  assert.ok(g.kind.width > 0 && g.notes.width > 0 && g.notes.left - g.kind.right >= 8, "the row2 keeps its two columns");
  assert.ok(g.kind.left >= 0 && g.notes.right <= g.vw, "the row fits the viewport");
  assert.ok(g.cancel.top >= 0 && g.cancel.bottom <= g.vh, "Cancel is reachable");
  assert.ok(g.submit.top >= 0 && g.submit.bottom <= g.vh, "Add key is reachable");
  assert.equal(g.spill, 0, "the page gains no horizontal scroll");
});

// VAL-CROSS-004: the restructure touched only the Add dialog — Edit keeps its Kind and
// Notes flat, with no disclosure to open.
test("the edit dialog still shows kind and notes without an advanced section", async (page, origin) => {
  await openKeys(page, origin);
  await rowAct(page, "alpha", "edit");
  await waitDialog(page, "dlg-edit", true);
  assert.equal(await page.locator("#dlg-edit details").count(), 0, "edit has no disclosure");
  assert.equal(await page.locator("#edit-form [name=kind]").isVisible(), true, "kind shows directly");
  assert.equal(await page.locator("#edit-form [name=notes]").isVisible(), true, "notes show directly");
  assert.equal(await page.locator("#edit-form [name=kind]").inputValue(), "runtime", "alpha is a runtime key");
  assert.equal(await page.locator("#edit-form [name=notes]").inputValue(), "first fixture key");
});

test("edit sends only changed fields and reports a server refusal in the dialog", async (page, origin) => {
  await openKeys(page, origin);
  await rowAct(page, "alpha", "edit");
  await waitDialog(page, "dlg-edit", true);

  // Unchanged: the dialog closes without a request.
  const before = requests.filter((r) => r.method === "PATCH").length;
  await page.locator("#edit-form [type=submit]").click();
  await waitDialog(page, "dlg-edit", false);
  assert.equal(requests.filter((r) => r.method === "PATCH").length, before, "an unchanged edit sends nothing");

  failures.set(rule("PATCH", "/api/keys/alpha"), { status: 403, body: { error: "forbidden" } });
  await rowAct(page, "alpha", "edit");
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
  await page.waitForFunction(() => document.querySelector('#keys-body .key-row[data-name="alpha"] .key-notes')?.textContent === "changed");
});

test("delete confirms first, survives a refusal and then removes the row", async (page, origin) => {
  await openKeys(page, origin);
  failures.set(rule("DELETE", "/api/keys/charlie"), { status: 404, body: { error: "not_found" } });
  await rowAct(page, "charlie", "delete");
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
  await page.waitForFunction(() => !document.querySelector('#keys-body .key-row[data-name="charlie"]'));
  assert.deepEqual(await rowNames(page), ["alpha", "bravo"]);
  assert.equal(await status(page), "Deleted charlie.");
  assert.equal(await page.locator("#keys-count").textContent(), "2 keys");
});

test("rotate replaces the secret, reports failure in its own dialog and clears the field", async (page, origin) => {
  await openKeys(page, origin);
  failures.set(rule("POST", "/api/keys/alpha/rotate"), { status: 401, body: { error: "auth_failed" } });
  await rowAct(page, "alpha", "rotate");
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
  await rowAct(page, "alpha", "rotate");
  await waitDialog(page, "dlg-rotate", true);
  await page.locator("#rotate-form [name=secret]").fill(SECRET);
  await page.locator("#dlg-rotate [data-close]").click();
  await waitDialog(page, "dlg-rotate", false);
  await page.waitForFunction(() => document.getElementById("rotate-form").elements.secret.value === "");
});

// ---------- keyboard and dialog focus ----------

const focused = (page) => page.evaluate(() => {
  const a = document.activeElement;
  const tr = a && a.closest("#keys-body .key-row");
  return tr ? `${tr.dataset.name}${a.dataset.act ? ":" + a.dataset.act : ""}` : (a && a.id) || "";
});
const focusRow = (page, name) => page.locator(`#keys-body .key-row[data-name="${name}"]`).first().focus();
// A dialog's close event, and the focus hand-back it queues, land after `open` turns false.
const waitFocused = (page, want) => page.waitForFunction((want) => {
  const a = document.activeElement;
  const tr = a && a.closest("#keys-body .key-row");
  return (tr ? `${tr.dataset.name}${a.dataset.act ? ":" + a.dataset.act : ""}` : (a && a.id) || "") === want;
}, want, { timeout: 5000 });
// The startup key load and the Keys tab's own load each redraw the rows (as does the provider
// catalog arriving), and a redraw drops focus. networkidle has already fired by then, so wait for
// both loads to reach their grant lookups and for the catalog names before focusing a row.
async function settleKeys(page) {
  for (let i = 0; i < 100 && requests.filter((r) => r.pathname.endsWith("/clients")).length < 2 * keys.length; i++) {
    await page.waitForTimeout(50);
  }
  await page.waitForFunction(() => document.querySelector('#keys-body .key-row[data-name="alpha"] .key-provider').textContent.startsWith("OpenAI"));
}
const waitEmpty = (page, selector) =>
  page.waitForFunction((sel) => document.querySelector(sel).value === "", selector, { timeout: 5000 });

test("row keys move the selection and open each dialog on the focused row", async (page, origin) => {
  await openKeys(page, origin);
  await settleKeys(page);
  // One flat list in name order: alpha, bravo, charlie.
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
  assert.equal(await focused(page), "bravo");

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
  await rowButton(page, "bravo", "copy").focus();
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
  await page.locator('#keys-body .key-row[data-name="alpha"] .key-name').click();
  await page.evaluate(() => document.activeElement.blur());
  await page.keyboard.press("c");
  assert.equal(requests.some((r) => r.pathname === "/api/keys/alpha/copy"), false, "c outside the list copies nothing");
  await page.keyboard.press("e");
  await waitDialog(page, "dlg-edit", true);
  assert.equal(await page.locator("#edit-name").textContent(), "alpha");
  await page.locator("#dlg-edit [data-close]").click();
  await waitDialog(page, "dlg-edit", false);
  // Opened from outside the list, the dialog hands focus back to the selected row.
  await waitFocused(page, "alpha");

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

  await rowAct(page, "alpha", "grant");
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

// ---------- profiles in the grant dialog and the grants area ----------
// UI mechanics only: this fixture is a mimic, and nothing here proves server enforcement —
// the bounds and named refusals are the Swift in-process tests' business.

const fixtureGrant = (over = {}) => ({
  id: "g9", key: "alpha", provider: "openai", host: "api.openai.com", task: "fixture task",
  methods: ["GET", "POST"], paths: ["/v1/messages"], requests: 0, usd: 0, unpriced_calls: 0,
  max_requests: 500, max_usd: 2.5, profile: "evals", unattended: true,
  // The renewal fields the engine's jsonObject carries: the window a renew re-opens and
  // the state marker the row badge reads. `token`/`base_url` appear only at issuance.
  window_minutes: 480, renewals: 0, renewed_at: null, revoked_at: null, revoke_reason: null, status: "active",
  created_at: "2026-09-20T12:00:00Z", expires_at: "2026-09-20T20:00:00Z",
  base_url: "http://127.0.0.1:12767/g/g9", token: "ksf-grant-fixture", auth_header: "Authorization",
  ...over,
});

test("the grant dialog offers only this key's profiles, and picking one prefills the scope", async (page, origin) => {
  keys.find((k) => k.name === "alpha").host = "api.openai.com";
  profiles = [
    { id: "ab12cd34", name: "evals", keys: ["alpha"], methods: ["GET", "POST"], paths: ["/v1/messages"], minutes: 480, max_requests: 500, max_usd: 2.5, unattended: true },
    { id: "ef56ab78", name: "reads", keys: ["bravo"], methods: ["GET"], paths: [], minutes: 60, max_requests: null, max_usd: null, unattended: false },
  ];
  await openKeys(page, origin);
  await settleKeys(page);
  await focusRow(page, "alpha");
  await page.keyboard.press("a");
  await waitDialog(page, "dlg-grant", true);
  const sel = page.locator("#grant-form [name=profile]");
  await page.waitForFunction(() => document.querySelector('#grant-form [name="profile"]').options.length > 1);
  assert.deepEqual(
    await sel.locator("option").evaluateAll((os) => os.map((o) => o.value)),
    ["", "evals"],
    "only profiles whose keys include alpha are offered"
  );
  assert.equal(await sel.locator("option[value=evals]").textContent(), "evals (unattended)", "the unattended marker is in the picker");

  await sel.selectOption("evals");
  assert.equal(await page.locator("#grant-form [name=minutes]").inputValue(), "480");
  assert.equal(await page.locator('#grant-form [name=minutes] option[value="480"]').textContent(), "8 hours", "a span with no preset gets its own option");
  assert.equal(await page.locator("#grant-form [name=methods]").inputValue(), "GET,POST");
  assert.equal(await page.locator("#grant-form [name=paths]").inputValue(), "/v1/messages");
  assert.equal(await page.locator("#grant-form [name=max_requests]").inputValue(), "500");
  assert.equal(await page.locator("#grant-form [name=max_usd]").inputValue(), "2.5");

  await page.locator("#grant-form [name=task]").fill("profiled fixture task");
  failures.set(rule("POST", "/api/keys/alpha/grants"), { status: 200, body: fixtureGrant() });
  await page.locator("#grant-submit").click();
  await page.locator("#grant-result").waitFor({ state: "visible" });
  const profiled = requests.filter((r) => r.method === "POST" && r.pathname === "/api/keys/alpha/grants").pop();
  assert.equal(profiled.body.profile, "evals", "the picked profile rides on the request");
  assert.equal(profiled.body.minutes, 480, "the prefilled span rides too");
  assert.equal(await page.locator("#gr-scope").textContent(),
    "GET, POST · /v1/messages · max 500 requests · max $2.50, ends on an unpriced call · profile evals · unattended");
  await page.keyboard.press("Escape");
  await waitDialog(page, "dlg-grant", false);

  // A reopen starts at None, and issuing without picking sends no profile field at all.
  await rowAct(page, "alpha", "grant");
  await waitDialog(page, "dlg-grant", true);
  assert.equal(await sel.inputValue(), "");
  assert.equal(await page.locator('#grant-form [name=minutes] option[value="480"]').count(), 0,
    "a prefill's span choice does not outlive the dialog");
  assert.equal(await page.locator("#grant-form [name=minutes]").inputValue(), "30", "the shipped default span is back");
  await page.locator("#grant-form [name=task]").fill("plain fixture task");
  await page.locator("#grant-submit").click();
  await page.locator("#grant-result").waitFor({ state: "visible" });
  const plain = requests.filter((r) => r.method === "POST" && r.pathname === "/api/keys/alpha/grants").pop();
  assert.equal("profile" in plain.body, false, "no profile picked means no profile sent");
});

test("grant rows show the profile and the unattended badge, and unpriced spend never reads $0", async (page, origin) => {
  keys.find((k) => k.name === "alpha").host = "api.openai.com";
  const soon = new Date(Date.now() + 3600_000).toISOString();
  grants = [
    fixtureGrant({ id: "aa11bb22", task: "night evals", requests: 12, usd: 0.4, unpriced_calls: 2, expires_at: soon }),
    fixtureGrant({ id: "bb22cc33", task: "plain ask", methods: ["GET"], paths: [], max_requests: null, max_usd: null, profile: null, unattended: false, requests: 1, usd: 0, unpriced_calls: 0, expires_at: soon }),
  ];
  await openKeys(page, origin);
  await page.locator("#grants-list li").first().waitFor();
  const profiled = page.locator("#grants-list li", { hasText: "night evals" });
  assert.match(await profiled.textContent(), /profile evals/, "the row names the profile");
  assert.match(await profiled.textContent(), /unattended/, "the unattended badge is on the row");
  assert.match(await profiled.textContent(), /12 req\/500/, "the caps stay readable");
  assert.match(await profiled.textContent(), /unpriced \(2 calls\)/, "unpriced spend stays unpriced");
  assert.doesNotMatch(await profiled.textContent(), /· \$0 ·/, "unknown money is never rendered as $0");
  const plain = page.locator("#grants-list li", { hasText: "plain ask" });
  assert.deepEqual(await plain.locator(".badge").allTextContents(), ["active"], "a plain grant row carries only its status badge");
});

test("the grants area lists saved profiles with their bounds, and Remove deletes them", async (page, origin) => {
  profiles = [
    { id: "ab12cd34", name: "evals", keys: ["alpha"], methods: ["GET", "POST"], paths: ["/v1/messages"], minutes: 480, max_requests: 500, max_usd: 2.5, unattended: true },
    { id: "ef56ab78", name: "reads", keys: ["bravo"], methods: ["GET"], paths: [], minutes: 60, max_requests: null, max_usd: null, unattended: false },
  ];
  await openKeys(page, origin);
  await page.locator("#profiles-list li").first().waitFor();
  assert.equal(await page.locator("#grants-count").textContent(), "0 active grants, 0 clients, 2 profiles.");
  const evals = page.locator("#profiles-list li", { hasText: "evals" });
  assert.match(await evals.textContent(), /keys alpha/, "the row names the keys");
  assert.match(await evals.textContent(), /\/v1\/messages/, "the row shows the path scope");
  assert.match(await evals.textContent(), /8 h/, "the row shows the lifetime");
  assert.match(await evals.textContent(), /max 500 requests/, "the row shows the request cap");
  assert.match(await evals.textContent(), /max \$2\.50/, "the row shows the usd cap");
  assert.match(await evals.textContent(), /unattended/, "the unattended badge is on the row");

  await page.locator('#profiles-list [aria-label="Remove profile evals"]').click();
  await page.waitForFunction(() => document.getElementById("profiles-list").children.length === 1);
  assert.ok(requests.some((r) => r.method === "DELETE" && r.pathname === "/api/profiles/ab12cd34"),
    "Remove deletes the row by id");
  assert.equal(await page.locator("#grants-count").textContent(), "0 active grants, 0 clients, 1 profile.");
  assert.equal(await page.locator("#profiles-list li", { hasText: "evals" }).count(), 0, "the removed row is gone after the reload");
});

// ---------- renewal: status badges and the Renew button ----------
// UI mechanics only, like the profile cases above: the fixture is a mimic, and the named
// refusals' wording is the Swift suites' business.

test("grant rows offer Renew on active and expired rows, never on revoked ones", async (page, origin) => {
  const soon = new Date(Date.now() + 3600_000).toISOString();
  const past = new Date(Date.now() - 3600_000).toISOString();
  grants = [
    fixtureGrant({ id: "aa11bb22", task: "live task", expires_at: soon, renewals: 2, renewed_at: soon, profile: null, unattended: false }),
    fixtureGrant({ id: "bb22cc33", task: "stale task", expires_at: past, status: "expired", profile: null, unattended: false }),
    fixtureGrant({ id: "cc33dd44", task: "dead task", expires_at: past, status: "revoked", revoked_at: past, revoke_reason: "revoked", profile: null, unattended: false }),
  ];
  await openKeys(page, origin);
  await page.locator("#grants-list li").nth(2).waitFor();

  // ?all=1 lists every state, so the count line breaks the rows down per status
  // instead of calling them all active.
  assert.equal(await page.locator("#grants-count").textContent(), "1 active, 1 expired, 1 revoked grants, 0 clients.");

  const live = page.locator("#grants-list li", { hasText: "live task" });
  assert.deepEqual(await live.locator(".badge").allTextContents(), ["active"], "the active row carries its status badge");
  assert.match(await live.textContent(), /min left/, "an active row counts down");
  assert.match(await live.textContent(), /renewed 2×/, "the renewal count shows once there is one");
  assert.equal(await live.locator('[aria-label="Renew grant aa11bb22"]').count(), 1);
  assert.equal(await live.locator('[aria-label="Revoke grant aa11bb22"]').count(), 1);

  const stale = page.locator("#grants-list li", { hasText: "stale task" });
  assert.deepEqual(await stale.locator(".badge").allTextContents(), ["expired"], "the expired row carries its status badge");
  assert.match(await stale.textContent(), /expired/, "an expired row says so instead of counting down");
  assert.doesNotMatch(await stale.textContent(), /min left/, "no countdown on an expired row");
  assert.doesNotMatch(await stale.textContent(), /renewed/, "no renewal marker before the first renewal");
  assert.equal(await stale.locator('[aria-label="Renew grant bb22cc33"]').count(), 1, "an expired grant is the renewable one");
  assert.equal(await stale.locator('[aria-label="Revoke grant bb22cc33"]').count(), 0, "there is nothing left to revoke");

  const dead = page.locator("#grants-list li", { hasText: "dead task" });
  assert.deepEqual(await dead.locator(".badge").allTextContents(), ["revoked"], "the revoked row carries its status badge");
  assert.equal(await dead.locator('[aria-label="Renew grant cc33dd44"]').count(), 0, "a killed grant is never renewable");
  assert.equal(await dead.locator('[aria-label="Revoke grant cc33dd44"]').count(), 0, "a killed grant cannot be revoked twice");
});

test("renewing a grant posts to the renew route and refreshes the row, and a refusal is shown", async (page, origin) => {
  const soon = new Date(Date.now() + 3600_000).toISOString();
  grants = [
    fixtureGrant({ id: "dd44ee55", task: "renewable task", expires_at: soon, profile: null, unattended: false }),
  ];
  await openKeys(page, origin);
  await page.locator("#grants-list li").first().waitFor();

  await page.locator('[aria-label="Renew grant dd44ee55"]').click();
  await page.waitForFunction(() => document.querySelector("#grants-list li").textContent.includes("renewed 1×"));
  const call = requests.find((r) => r.method === "POST" && r.pathname === "/api/grants/dd44ee55/renew");
  assert.ok(call, "the click POSTs the renew route");
  assert.equal(call.token, "test-token", "the page's token rides on the renewal");
  const row = await page.locator("#grants-list li", { hasText: "renewable task" }).textContent();
  assert.match(row, /renewed 1×/, "the refreshed row counts the renewal");
  assert.match(row, /min left/, "the refreshed row counts down from the new expiry");
  assert.match(await status(page), /^Grant dd44ee55 renewed until /, "the confirmation names the new expiry");

  // A revoke that raced the click answers 409 renew_revoked: the refusal reads as an
  // error through the same friendly() path every API error uses, and the list survives.
  failures.set(rule("POST", "/api/grants/dd44ee55/renew"), { status: 409, body: { error: "renew_revoked" } });
  await page.locator('[aria-label="Renew grant dd44ee55"]').click();
  await page.waitForFunction(() => document.getElementById("status").textContent === "renew_revoked");
  assert.equal(await page.locator("#grants-list li").count(), 1, "the list still renders");
  assert.equal(await page.locator('[aria-label="Renew grant dd44ee55"]').count(), 1, "the row keeps its Renew button");
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
  await page.waitForFunction(() => !document.getElementById("pane-settings").hidden);
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
  assert.equal(await keyPicked(page), "alpha");
  const filtered = requests.filter((r) => r.pathname === "/api/spend" && r.search.includes("key=alpha"));
  assert.ok(filtered.length > 0, "the key filter must reach the engine");

  await page.locator("#keys-filter-select").selectOption("");
  await page.waitForFunction(() => !new URL(location.href).searchParams.get("key"));
  assert.equal(await keyPicked(page), "");
});

// The key picker is a dropdown; its value is the key chosen, "" for all keys.
const keyPicked = (page) => page.locator("#keys-filter-select").inputValue();
const keyOptions = (page) => page.locator("#keys-filter [data-key-filter]").evaluateAll((els) => els.map((e) => e.textContent));

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
let emptyIngested = false;
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
  assert.equal(await keyPicked(page), "");
});

test("the per-key picker names every key and filters to one, all keys included", async (page, origin) => {
  await openKeysSource(page, origin);
  await chooseUsd(page);
  assert.deepEqual(await keyOptions(page), ["All keys", "alpha", "charlie"]);
  assert.equal(await keyPicked(page), "", "all keys is the default");
  // A compact dropdown, one control, reachable and operable from the keyboard.
  const select = page.locator("#keys-filter-select");
  assert.equal(await select.getAttribute("aria-label"), "API key");
  assert.equal(await page.locator("#keys-filter [role='radio']").count(), 0, "no chip row");
  // A key is named, never its value.
  assert.equal((await page.locator("#keys-filter").textContent()).includes(SECRET), false);

  // Keyboard: the picker is a native select in the tab order (Chromium's arrow-key handling on
  // a closed select differs by platform, so the choice itself is made through the select API),
  // and it keeps focus when the chart redraws it with the new choice.
  await select.focus();
  assert.equal(await page.evaluate(() => document.activeElement.id), "keys-filter-select");
  assert.notEqual(await select.getAttribute("tabindex"), "-1");
  await select.selectOption("charlie");
  await page.waitForFunction(() => new URL(location.href).searchParams.get("key") === "charlie");
  assert.equal(await page.evaluate(() => document.activeElement.id), "keys-filter-select", "focus stays on the picker after it redraws");
  assert.ok(spendSearches().some((s) => s.includes("key=charlie") && s.includes("source=keys")));
  await page.waitForFunction(() => document.querySelectorAll("#mix .mix-row").length === 1);
  assert.equal(await page.locator("#mix .mix-name").textContent(), "system-one");
  assert.match(await totalsText(page), /cost unknown/, "an unpriced key reads as unknown, not $0");
  assert.match(await totalsText(page), /2 requests/);

  // Back to every key, from the picker itself.
  await select.selectOption("");
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
  // calls are right there in the Keys list.
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body .key-row[data-name="alpha"]').waitFor();
  await rowCell(page, "alpha", "gateway").click();
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
  await page.locator("#keys-filter-select").selectOption("charlie");
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
  assert.equal(await page.locator('[data-group="project"]').isHidden(), true, "projects are a Claude-only grouping");
  assert.equal(await page.locator('[data-group="key"]').isVisible(), true, "the gateway ledger groups by key");
  assert.equal(await page.locator('[data-group="provider"]').isVisible(), true, "and by provider");

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
  await page.waitForFunction(() => document.querySelector('[data-group="project"]').hidden);
  assert.equal(await page.locator('[data-group="model"]').getAttribute("aria-checked"), "true");
  last = spendSearches().pop();
  assert.ok(last.includes("source=keys") && last.includes("by=model"), `stale grouping survived: ${last}`);

  // And leaving again comes back to the subscription source that was last chosen, not to All.
  await page.getByRole("radio", { name: "Subscriptions" }).click();
  await page.waitForFunction(() => document.querySelector('[data-source="claude"]').getAttribute("aria-checked") === "true");
});

test("a key's gateway figure opens that key in the API keys scope", async (page, origin) => {
  await openKeys(page, origin);
  // Default unit: the figure counts requests, the only figure a key's own row can always answer
  // for, and puts no price on screen.
  assert.equal(await gatewayText(page, "charlie"), "2 requests");
  assert.doesNotMatch(await page.locator("#keys-list").textContent(), /\$/, "no dollars until USD is chosen");

  await rowCell(page, "charlie", "gateway").click();
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

  // The same figure again must land on the same view, not toggle the filter off.
  await page.getByRole("tab", { name: "Keys" }).click();
  await rowCell(page, "charlie", "gateway").click();
  await page.waitForFunction(() => document.getElementById("pane-chart").hidden === false);
  assert.equal(await page.evaluate(inKeysScope), true);
  assert.equal(await keyPicked(page), "charlie");
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

test("the Usage summary and the Keys figures follow the same unit, switched from Usage", async (page, origin) => {
  localRows = subscriptionRows();
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.waitForFunction(() => /tokens/.test(document.getElementById("usage-totals").textContent));
  assert.doesNotMatch(await page.locator("#usage-totals").textContent(), /\$/, "the month summary leads with tokens");

  // The switch is on the line itself: nobody has to find another pane to change the unit.
  await page.getByRole("button", { name: "Show this month in USD instead of tokens" }).click();
  await page.waitForFunction(() => /\$/.test(document.getElementById("usage-totals").textContent));
  assert.match(await page.locator("#usage-totals").textContent(), /≈ \$0\.03/);

  // One unit for the page: the Keys figures answer in it too, and the pane says which one it is.
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body .key-row[data-name="alpha"]').waitFor();
  assert.equal((await page.locator("#keys-unit").textContent()).trim(), "USD", "the Keys pane names the unit it shows");
  assert.match(await gatewayText(page, "alpha"), /\$0\.01/);
  assert.equal(await gatewayText(page, "charlie"), "2 calls, unpriced", "an unpriced figure is never $0");
  assert.equal(await gatewayText(page, "bravo"), null, "no figure for a key without gateway calls");
  // Switched from Keys itself, and the Usage summary follows the same switch.
  await page.getByRole("button", { name: "Showing USD; switch the gateway figures to requests" }).click();
  await page.waitForFunction(() => !/\$/.test(document.getElementById("keys-list").textContent));
  assert.equal(await gatewayText(page, "alpha"), "3 requests");
  assert.equal(await gatewayText(page, "bravo"), null, "still no figure for a key without gateway calls");
  assert.equal((await page.locator("#keys-unit").textContent()).trim(), "requests");
  await page.getByRole("tab", { name: "Usage" }).click();
  assert.doesNotMatch(await page.locator("#usage-totals").textContent(), /\$/, "the summary follows the Keys switch");
});

test("the Keys unit switch stays visible and keyboard-reachable at 390 px", async (page, origin) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await openKeys(page, origin);
  const control = page.getByRole("button", { name: "Showing requests; switch the gateway figures to USD" });
  await control.waitFor({ state: "visible" });
  const box = await control.boundingBox();
  assert.ok(box.x >= 0 && box.x + box.width <= 390, `the switch leaves the viewport: ${JSON.stringify(box)}`);
  await control.focus();
  assert.equal(await page.evaluate(() => document.activeElement.id), "keys-unit");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => /\$/.test(document.getElementById("keys-list").textContent));
  assert.match(await gatewayText(page, "alpha"), /\$0\.01/);
  await page.getByRole("button", { name: "Showing USD; switch the gateway figures to requests" }).click();
  await page.waitForFunction(() => !/\$/.test(document.getElementById("keys-list").textContent));
});

test("the Keys figures follow the Chart's unit at 390 px and stay inside the row", async (page, origin) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await openKeys(page, origin);
  assert.equal(await gatewayText(page, "alpha"), "3 requests");
  await page.getByRole("tab", { name: "Chart" }).click();
  await chooseUsd(page);
  // The unit switch redraws the hidden Keys rows at once, so a "$" is on screen before the pane's
  // own /api/keys answer lands and replaces every row. Measuring or focusing the figure in that
  // gap holds a node about to be detached (a null box, or Enter pressed on <body>), so the wait
  // is for a row drawn after the Keys tab was opened.
  await page.locator('#keys-body .key-row[data-name="alpha"]').evaluate((row) => { row.dataset.stale = "1"; });
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.waitForFunction(() => {
    const row = document.querySelector('#keys-body .key-row[data-name="alpha"]');
    return row && !row.dataset.stale && /\$/.test(row.querySelector(".key-gateway").textContent);
  });
  const box = await rowCell(page, "alpha", "gateway").boundingBox();
  assert.ok(box.width > 0 && box.x >= 0 && box.x + box.width <= 390, `the figure leaves the viewport: ${JSON.stringify(box)}`);
  // Reachable by keyboard: it is a button of the selected row, and Enter opens the chart.
  await rowCell(page, "alpha", "gateway").focus();
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => new URL(location.href).searchParams.get("key") === "alpha");
  assert.equal(await page.locator("#pane-chart").isVisible(), true);
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

// Grok Bot keeps no usage figures on disk, only chats. A week with prompts gets a card that says
// what was counted; an idle week falls into "not tracked" rather than showing a zero as a measure.
test("Grok Bot shows this week's prompt count, and an idle week is not tracked", async (page, origin) => {
  plans = [
    { source: "grok-bot", title: "Grok Bot", kind: "subscription", weekly_prompts: 12, period: { label: "This week" },
      usage_note: "12 prompts in 3 chats this week, counted from the chats Grok Bot keeps on this Mac. Grok Bot's plan is separate from SuperGrok; its credits and limits are not in local files." },
  ];
  localRows = subscriptionRows();
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const card = page.locator('#live-status .live-row[data-source="grok-bot"]');
  await card.waitFor();
  assert.match(await card.textContent(), /12 prompts sent · limit not tracked/);
  assert.match(await card.textContent(), /plan is separate from SuperGrok/);

  // An idle week is not a card: nothing is measured, so nothing is shown, and no "not tracked"
  // list stands in for it.
  plans = [{ source: "grok-bot", title: "Grok Bot", kind: "subscription", weekly_prompts: 0, usage_note: "No Grok Bot prompts this week." }];
  await page.reload();
  await page.waitForLoadState("networkidle");
  await page.locator("#usage-totals b").first().waitFor();
  assert.equal(await page.locator('#live-status .live-row[data-source="grok-bot"]').count(), 0);
  assert.equal(await page.locator("#live-status").isHidden(), true);
  assert.equal(await page.locator("#pane-usage details").count(), 0, "no collapsed 'not tracked locally' group");
  assert.doesNotMatch(await page.locator("#pane-usage").textContent(), /not tracked locally|cards? hidden/);
});

// The Droid row is catalog-backed: three windows (5-hour rolling, calendar week, calendar month),
// each tokens-only until the user sets a limit for it, which turns that one window into a
// percent meter. The fixture numbers mirror the droid-home fixture's windows at its fixed clock.
const droidPlan = (extra = {}) => ({
  source: "droid", title: "Droid", kind: "subscription",
  five_hour_tokens: 74352, weekly_tokens: 75308, monthly_tokens: 75308, ...extra,
  usage_note: extra.usage_note || "Tokens per window, from the per-request records in Droid's local logs. Factory's own plan limits are not in local files; use Set limits to add your own.",
});

test("Droid shows three token windows, tokens only until a window gets a limit", async (page, origin) => {
  await showDroidOnUsage(page);
  plans = [droidPlan()];
  localRows = subscriptionRows();
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const card = page.locator('#live-status .live-row[data-source="droid"]');
  await card.waitFor();
  // Laid out like the Claude/OpenAI rows: one meter line per window, in this order.
  assert.deepEqual(
    await card.locator(".live-meter-label").evaluateAll((rows) => rows.map((r) => r.firstChild.textContent.trim())),
    ["5 hour", "Weekly", "Month"],
  );
  const text = await card.textContent();
  assert.match(text, /74\.4K tokens/, "the 5-hour window shows its own tokens");
  assert.match(text, /75\.3K tokens.*75\.3K tokens/, "weekly and month each show their figure");
  assert.match(text, /per-request records in Droid's local logs/);
  // Without limits nothing is a percent: no track, no % sign, and the row stays tracked.
  assert.equal(await card.locator(".live-track").count(), 0);
  assert.doesNotMatch(text, /%/);
  assert.equal(await card.locator("#live-status .live-absent").count(), 0);
  assert.equal(await card.getByRole("button", { name: "Set limits" }).count(), 1);

  // A limit turns exactly its own window into a meter; the others stay token text.
  plans = [droidPlan({ weekly_limit: 100000, weekly_pct: 75 })];
  await page.reload();
  await page.waitForLoadState("networkidle");
  await card.locator(".live-track").waitFor();
  const weekly = card.locator(".live-meter", { hasText: "Weekly" });
  assert.match(await weekly.textContent(), /75% · 75\.3K of 100K tokens/);
  const fill = await weekly.locator(".live-fill").evaluate((n) => n.style.width);
  assert.equal(fill, "75%");
  assert.equal(await card.locator(".live-track").count(), 1, "only the limited window gets a track");
  assert.match(await card.locator(".live-meter", { hasText: "5 hour" }).textContent(), /74\.4K tokens/);
  assert.match(await card.locator(".live-meter", { hasText: "Month" }).textContent(), /75\.3K tokens/);
});

test("a blown Droid limit caps the bar but keeps the true percentage", async (page, origin) => {
  await showDroidOnUsage(page);
  plans = [droidPlan({ weekly_tokens: 120000, monthly_tokens: 120000, weekly_limit: 100000, weekly_pct: 120 })];
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const weekly = page.locator('#live-status .live-row[data-source="droid"] .live-meter', { hasText: "Weekly" });
  await weekly.waitFor();
  assert.match(await weekly.textContent(), /120% · 120K of 100K tokens/, "the number stays honest past 100");
  assert.equal(await weekly.locator(".live-fill").evaluate((n) => n.style.width), "100%", "the bar caps visually");
  assert.match(await weekly.locator(".live-fill").getAttribute("class"), /live-fill-over/);
});

test("Set limits sets, validates and clears Droid window limits through the API", async (page, origin) => {
  await showDroidOnUsage(page);
  plans = [droidPlan()];
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const card = page.locator('#live-status .live-row[data-source="droid"]');
  await card.waitFor();
  await card.getByRole("button", { name: "Set limits" }).click();
  await waitDialog(page, "dlg-limits", true);
  const form = page.locator("#limits-form");
  // Three optional fields, prefilled from the row's current limits (none yet).
  assert.deepEqual(
    await form.locator("input").evaluateAll((inputs) => inputs.map((i) => i.value)),
    ["", "", ""],
  );

  // 0 is not a limit: an inline error, the dialog stays open, nothing is sent.
  await form.locator('input[name="weekly"]').fill("0");
  await page.getByRole("button", { name: "Save" }).click();
  assert.match(await page.locator("#limits-err").textContent(), /whole token counts of 1 or more/);
  assert.equal(await dialogOpen(page, "dlg-limits"), true);
  assert.equal(requests.filter((r) => r.pathname.startsWith("/api/limits")).length, 0);
  // Non-numeric text, negatives and fractions are refused the same way, never read as an empty
  // "no limit". Chromium drops typed letters outright, but "1e" reaches the field as badInput.
  await form.locator('input[name="weekly"]').fill("");
  for (const bad of ["1e", "-5", "12.5"]) {
    await page.locator("#limits-err").evaluate((n) => { n.textContent = ""; });
    await form.locator('input[name="monthly"]').evaluate((n) => { n.value = ""; });
    await form.locator('input[name="monthly"]').pressSequentially(bad);
    await page.getByRole("button", { name: "Save" }).click();
    assert.match(await page.locator("#limits-err").textContent(), /whole token counts of 1 or more/, `"${bad}" must be refused`);
    assert.equal(await dialogOpen(page, "dlg-limits"), true);
  }
  assert.equal(requests.filter((r) => r.pathname.startsWith("/api/limits")).length, 0);
  await form.locator('input[name="monthly"]').fill("");

  // A valid limit saves (the fixture answers, and the status reload carries the meter).
  await form.locator('input[name="weekly"]').fill("100000");
  plans = [droidPlan({ weekly_limit: 100000, weekly_pct: 75 })];
  await page.getByRole("button", { name: "Save" }).click();
  await waitDialog(page, "dlg-limits", false);
  const put = requests.find((r) => r.method === "PUT" && r.pathname === "/api/limits/droid/weekly");
  assert.ok(put, "the save writes the limit through the token-protected route");
  assert.equal(put.token, "test-token");
  await card.locator(".live-track").waitFor();
  assert.match(await card.textContent(), /75% · 75\.3K of 100K tokens/);

  // Reopening prefills the saved limit; clearing the field clears the window's limit.
  await card.getByRole("button", { name: "Set limits" }).click();
  await waitDialog(page, "dlg-limits", true);
  assert.equal(await form.locator('input[name="weekly"]').inputValue(), "100000");
  plans = [droidPlan()];
  await form.locator('input[name="weekly"]').fill("");
  await page.getByRole("button", { name: "Save" }).click();
  await waitDialog(page, "dlg-limits", false);
  const del = requests.find((r) => r.method === "DELETE" && r.pathname === "/api/limits/droid/weekly");
  assert.ok(del, "an emptied field clears the limit instead of writing 0");
  await page.waitForFunction(() => document.querySelector('#live-status .live-row[data-source="droid"]') && document.querySelectorAll('#live-status .live-row[data-source="droid"] .live-track').length === 0);
  assert.match(await card.textContent(), /75\.3K tokens/);
});

test("an empty Droid catalog shows zeros and no fabricated numbers", async (page, origin) => {
  await showDroidOnUsage(page);
  plans = [droidPlan({
    five_hour_tokens: 0, weekly_tokens: 0, monthly_tokens: 0,
    usage_note: "No Droid usage recorded yet. The windows fill from the per-request records in Droid's local logs.",
  })];
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const card = page.locator('#live-status .live-row[data-source="droid"]');
  await card.waitFor();
  const text = await card.textContent();
  assert.match(text, /No Droid usage recorded yet/);
  assert.equal((text.match(/0 tokens/g) || []).length, 3, "each window says its real zero");
  assert.doesNotMatch(text, /%/, "no percent without a limit");
  assert.equal(await card.locator(".live-track").count(), 0);

  // A limit on an empty window is a real 0%, which is the one honest percent there is.
  plans = [droidPlan({
    five_hour_tokens: 0, weekly_tokens: 0, monthly_tokens: 0,
    monthly_limit: 500000, monthly_pct: 0,
    usage_note: "No Droid usage recorded yet. The windows fill from the per-request records in Droid's local logs.",
  })];
  await page.reload();
  await page.waitForLoadState("networkidle");
  const month = card.locator(".live-meter", { hasText: "Month" });
  await month.locator(".live-track").waitFor();
  assert.match(await month.textContent(), /0% · 0 of 500K tokens/);
  assert.equal(await card.locator(".live-track").count(), 1, "the unlimited windows stay plain");
});

// ---------- subscriptions (plans the user pins to the Usage pane) ----------

// The shape the engine gives a pinned subscription row on /api/status.
const subPlan = (extra = {}) => ({
  source: "cursor", title: "Cursor", kind: "subscription", subscription_id: "sub-1",
  plan: "Pro", limit_text: "500 requests per month", usage_note: "usage not tracked locally", ...extra,
});
// The dialog's own controls, scoped so the toolbar's "+ Add subscription" and a row's Edit and
// Remove (whose accessible names are just "Edit" / "Remove") never collide with them.
const subSubmit = (page) => page.locator("#dlg-sub").getByRole("button", { name: "Add subscription", exact: true });
const subCancel = (page) => page.locator("#dlg-sub-remove").getByRole("button", { name: "Cancel", exact: true });
const subConfirm = (page) => page.locator("#dlg-sub-remove").getByRole("button", { name: "Remove", exact: true });

test("+ Add subscription opens the dialog and Custom requires a name", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("button", { name: "+ Add subscription" }).click();
  await waitDialog(page, "dlg-sub", true);
  const form = page.locator("#sub-form");
  // Every tool the engine lists, and only those.
  assert.deepEqual(
    await form.locator("select[name=tool] option").evaluateAll((os) => os.map((o) => o.textContent.trim())),
    ["Cursor", "Gemini", "GitHub Copilot", "Perplexity", "ChatGPT", "Factory", "Custom…"],
  );
  // The name field belongs to Custom alone.
  assert.equal(await page.locator("#sub-name-label").evaluate((n) => n.hidden), true);
  await form.locator("select[name=tool]").selectOption("custom");
  assert.equal(await page.locator("#sub-name-label").evaluate((n) => n.hidden), false);

  // A custom tool with no name is refused here; nothing is sent.
  await form.locator("input[name=plan]").fill("Team");
  await subSubmit(page).click();
  assert.match(await page.locator("#sub-err").textContent(), /custom tool needs a name/);
  assert.equal(await dialogOpen(page, "dlg-sub"), true);
  assert.equal(requests.filter((r) => r.pathname === "/api/subscriptions").length, 0);

  // With a name the POST carries the tool and the name, and no limit was invented.
  await form.locator("input[name=name]").fill("Windsurf");
  plans = [subPlan({ source: "custom", title: "Windsurf", subscription_id: "sub-1", plan: "Team", limit_text: null, usage_note: "usage not tracked locally" })];
  await subSubmit(page).click();
  await waitDialog(page, "dlg-sub", false);
  const post = requests.find((r) => r.method === "POST" && r.pathname === "/api/subscriptions");
  assert.ok(post, "the save goes through the token-protected route");
  assert.equal(post.token, "test-token");
  assert.equal(subscriptions[0].tool, "custom");
  assert.equal(subscriptions[0].name, "Windsurf");
  assert.equal(subscriptions[0].plan, "Team");
  assert.equal(subscriptions[0].limit, null);
  const row = page.locator('#live-status .live-row[data-sub-id="sub-1"]');
  await row.waitFor();
  const text = await row.textContent();
  assert.match(text, /Windsurf/);
  assert.match(text, /Team/);
  assert.match(text, /usage not tracked locally/);
  assert.doesNotMatch(text, /%/, "a row that measures nothing shows no percent");
});

test("a built-in subscription shows its plan, limit text and honest note, and hides the placeholder", async (page, origin) => {
  plans = [
    subPlan(),
    { source: "gemini", title: "Gemini", kind: "subscription", usage_note: "Google AI Pro/Ultra remaining is not in local files." },
  ];
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const card = page.locator('#live-status .live-row[data-source="cursor"]');
  await card.waitFor();
  const text = await card.textContent();
  assert.match(text, /Cursor/);
  assert.match(text, /Pro/);
  assert.match(text, /500 requests per month/);
  assert.match(text, /usage not tracked locally/);
  // No invented usage: no percent, no token figure, no meter track on a row that measures nothing.
  assert.doesNotMatch(text, /%/);
  assert.doesNotMatch(text, /tokens/);
  assert.equal(await card.locator(".live-track").count(), 0);
  // A tool nobody pinned and nothing measures is not on the pane at all: no placeholder row and
  // no collapsed "not tracked locally" group for it to sit in.
  assert.equal(await page.locator("#live-status .live-row").count(), 1, "the pinned Cursor card is the only row");
  assert.doesNotMatch(await page.locator("#live-status").textContent(), /Gemini/);
  assert.equal(await page.locator("#pane-usage details").count(), 0);
  assert.equal(await card.locator('button[title="Edit this subscription"]').count(), 1);
  assert.equal(await card.locator('button[title="Remove this subscription"]').count(), 1);
});

test("the subscription limit is all-or-nothing before anything is sent", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("button", { name: "+ Add subscription" }).click();
  await waitDialog(page, "dlg-sub", true);
  const form = page.locator("#sub-form");
  await form.locator("input[name=plan]").fill("Pro");
  // An amount alone is not a limit.
  await form.locator("input[name=limit_amount]").fill("500");
  await subSubmit(page).click();
  assert.match(await page.locator("#sub-err").textContent(), /amount, a unit and a period together/);
  // Unit and period without an amount are not one either.
  await form.locator("select[name=limit_unit]").selectOption("requests");
  await form.locator("select[name=limit_period]").selectOption("monthly");
  await form.locator("input[name=limit_amount]").fill("");
  await subSubmit(page).click();
  assert.match(await page.locator("#sub-err").textContent(), /amount, a unit and a period together/);
  // Zero, negatives and fractions of a request are refused, never coerced.
  for (const bad of ["0", "-5", "12.5"]) {
    await page.locator("#sub-err").evaluate((n) => { n.textContent = ""; });
    await form.locator("input[name=limit_amount]").evaluate((n) => { n.value = ""; });
    await form.locator("input[name=limit_amount]").pressSequentially(bad);
    await subSubmit(page).click();
    assert.match(await page.locator("#sub-err").textContent(), bad === "12.5" ? /whole number/ : /greater than 0/, `"${bad}" must be refused`);
    assert.equal(await dialogOpen(page, "dlg-sub"), true);
  }
  assert.equal(requests.filter((r) => r.pathname === "/api/subscriptions").length, 0);

  // A valid one sends all three fields together.
  await form.locator("input[name=limit_amount]").fill("500");
  plans = [subPlan()];
  await subSubmit(page).click();
  await waitDialog(page, "dlg-sub", false);
  assert.deepEqual(subscriptions[0].limit, { amount: 500, unit: "requests", period: "monthly" });
  await page.locator('#live-status .live-row[data-source="cursor"]').waitFor();
});

test("Edit and Remove go through PATCH and a confirmed DELETE, and the placeholder returns", async (page, origin) => {
  subscriptions = [{
    id: "sub-1", tool: "cursor", name: "", plan: "Pro",
    limit: { amount: 500, unit: "requests", period: "monthly" },
    created_at: "2026-10-11T00:00:00Z",
  }];
  plans = [subPlan()];
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const card = page.locator('#live-status .live-row[data-source="cursor"]');
  await card.waitFor();
  await card.locator('button[title="Edit this subscription"]').click();
  await waitDialog(page, "dlg-sub", true);
  const form = page.locator("#sub-form");
  // The edit dialog keeps the tool fixed and fills the fields from the stored record.
  assert.equal(await form.locator("select[name=tool]").isDisabled(), true);
  assert.equal(await form.locator("select[name=tool]").inputValue(), "cursor");
  await page.waitForFunction(() => document.querySelector('#sub-form input[name="plan"]').value === "Pro");
  assert.equal(await form.locator("input[name=limit_amount]").inputValue(), "500");
  assert.equal(await form.locator("select[name=limit_unit]").inputValue(), "requests");
  assert.equal(await form.locator("select[name=limit_period]").inputValue(), "monthly");
  // The title and the button say edit.
  assert.equal(await page.locator("#sub-title").textContent(), "Edit subscription");

  await form.locator("input[name=plan]").fill("Ultra");
  await form.locator("input[name=limit_amount]").fill("1000");
  plans = [subPlan({ plan: "Ultra", limit_text: "1,000 requests per month" })];
  await page.locator("#dlg-sub").getByRole("button", { name: "Save" }).click();
  await waitDialog(page, "dlg-sub", false);
  const patch = requests.find((r) => r.method === "PATCH" && r.pathname === "/api/subscriptions/sub-1");
  assert.ok(patch, "the edit is a token-protected PATCH on the row's id");
  assert.equal(patch.token, "test-token");
  assert.equal(subscriptions[0].plan, "Ultra");
  assert.deepEqual(subscriptions[0].limit, { amount: 1000, unit: "requests", period: "monthly" });
  await page.waitForFunction(() => /Ultra/.test(document.querySelector('#live-status .live-row[data-source="cursor"]').textContent));
  assert.match(await card.textContent(), /1,000 requests per month/);

  // Remove asks first; a cancel keeps the row.
  await card.locator('button[title="Remove this subscription"]').click();
  await waitDialog(page, "dlg-sub-remove", true);
  assert.match(await page.locator("#sub-remove-title").textContent(), /Remove Cursor\?/);
  await subCancel(page).click();
  await waitDialog(page, "dlg-sub-remove", false);
  assert.equal(requests.filter((r) => r.method === "DELETE" && r.pathname === "/api/subscriptions/sub-1").length, 0);
  assert.equal(await card.count(), 1, "the row survives a cancelled remove");

  // Confirming removes it, and the built-in placeholder returns to the not-tracked group.
  await card.locator('button[title="Remove this subscription"]').click();
  await waitDialog(page, "dlg-sub-remove", true);
  plans = [{ source: "cursor", title: "Cursor", kind: "subscription", usage_note: "Plan remaining is not in local files. We do not read Cursor cookies." }];
  await subConfirm(page).click();
  await waitDialog(page, "dlg-sub-remove", false);
  const del = requests.find((r) => r.method === "DELETE" && r.pathname === "/api/subscriptions/sub-1");
  assert.ok(del, "the confirmed remove is a DELETE on the row's id");
  assert.equal(del.token, "test-token");
  assert.equal(subscriptions.length, 0);
  await page.waitForFunction(() => document.querySelectorAll("#live-status .live-row[data-sub-id]").length === 0);
  // The engine's placeholder row is back, but a tool nothing measures is not a card: the pane
  // shows no Cursor and no "not tracked" group, only the way to pin a plan again.
  assert.equal(await page.locator('#live-status .live-row[data-source="cursor"]').count(), 0);
  assert.equal(await page.locator("#pane-usage details").count(), 0);
  assert.equal(await page.getByRole("button", { name: "+ Add subscription" }).isVisible(), true);
});

test("a Factory subscription attaches to the Droid row, its token limit becoming a window meter", async (page, origin) => {
  await showDroidOnUsage(page);
  subscriptions = [{
    id: "sub-9", tool: "factory", name: "", plan: "Max",
    limit: { amount: 100000, unit: "tokens", period: "monthly" },
    created_at: "2026-10-11T00:00:00Z",
  }];
  plans = [droidPlan({ plan: "Max", subscription_id: "sub-9", monthly_limit: 100000, monthly_pct: 75 })];
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const card = page.locator('#live-status .live-row[data-source="droid"]');
  await card.waitFor();
  assert.match(await card.textContent(), /Max/, "the Factory plan names the Droid row");
  const month = card.locator(".live-meter", { hasText: "Month" });
  assert.match(await month.textContent(), /75% · 75\.3K of 100K tokens/, "the Factory token limit is the Month window's meter");
  assert.equal(await page.locator('#live-status .live-row[data-source="factory"]').count(), 0, "no duplicate Factory row appears");
  // The Droid row carries the pinned subscription's own Edit and Remove beside Set limits.
  assert.equal(await card.locator('button[title="Edit the Factory subscription pinned to this row"]').count(), 1);
  assert.equal(await card.locator('button[title="Remove the Factory subscription from the Droid row"]').count(), 1);
  assert.equal(await card.getByRole("button", { name: "Set limits" }).count(), 1);

  // Removing it from the Droid row takes the plan and the meter off with it.
  await card.locator('button[title="Remove the Factory subscription from the Droid row"]').click();
  await waitDialog(page, "dlg-sub-remove", true);
  // The question is about the subscription, not the row it is pinned to.
  assert.match(await page.locator("#sub-remove-title").textContent(), /Remove the Factory subscription\?/);
  assert.doesNotMatch(await page.locator("#sub-remove-title").textContent(), /Droid/);
  plans = [droidPlan()];
  await subConfirm(page).click();
  await waitDialog(page, "dlg-sub-remove", false);
  await page.waitForFunction(() => !/Max/.test(document.querySelector('#live-status .live-row[data-source="droid"]').textContent));
  assert.equal(await card.locator(".live-track").count(), 0, "the window the subscription drove goes back to tokens only");

  // A non-token Factory limit stays one line of text beside the plan, never a meter.
  plans = [droidPlan({ plan: "Max", subscription_id: "sub-9", limit_text: "$200 per month" })];
  await page.reload();
  await page.waitForLoadState("networkidle");
  const text = await card.textContent();
  assert.match(text, /Max/);
  assert.match(text, /\$200 per month/);
  assert.equal(await card.locator(".live-track").count(), 0);
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

// ---------- vendor families, the Droid source, and the merge ----------

// The droid-home fixture's October records, in the local shape the engine serves after
// `keys ingest droid`: two claude-sonnet-5 requests and one gpt-6-pro, every bucket Droid's
// log reports counted. The month total 75,308 is the figure the Droid row's Month window shows
// for the same data (the mock's numbers mirror Fixtures/droid-home/README.md).
const droidFixtureRows = () => [
  { model: "claude-sonnet-5", source: "droid-local", input_tokens: 1200, output_tokens: 340, cached_read_tokens: 30000, cache_creation_tokens: 500, reasoning_tokens: 0, usd: null, usd_estimate: null },
  { model: "claude-sonnet-5", source: "droid-local", input_tokens: 800, output_tokens: 512, cached_read_tokens: 41000, cache_creation_tokens: 0, reasoning_tokens: 0, usd: null, usd_estimate: null },
  { model: "gpt-6-pro", source: "droid-local", input_tokens: 640, output_tokens: 220, cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 96, usd: null, usd_estimate: null },
];

test("the Droid chip filters the chart to Droid's own records and the URL boots into it", async (page, origin) => {
  await showDroidOnUsage(page);
  localRows = droidFixtureRows();
  await page.goto(`${origin}/?range=month`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#mix .mix-row").first().waitFor();
  const names = () => page.locator("#mix .mix-name").allTextContents();
  assert.deepEqual((await names()).sort(), ["claude-sonnet-5", "gpt-6-pro"], "All shows both October models");

  // The chip sits alongside the tool chips and asks the engine for the droid-local ledger.
  await page.getByRole("radio", { name: "Droid", exact: true }).click();
  await page.waitForFunction(() => document.querySelector('#source-chips [data-source="droid"]').getAttribute("aria-checked") === "true");
  assert.ok(spendSearches().some((s) => s.includes("source=droid")), "the Droid chip must reach /api/spend?source=droid");
  assert.equal(new URL(await page.url()).searchParams.get("source"), "droid", "the URL carries the choice");
  assert.deepEqual((await names()).sort(), ["claude-sonnet-5", "gpt-6-pro"], "the same two models, and only they");

  // Droid's Claude model is not Claude Code's: the Claude chip narrows to nothing here, and
  // the empty state names the tool rather than pretending the model was counted elsewhere.
  await page.getByRole("radio", { name: "Claude", exact: true }).click();
  await page.locator("#spend-empty:visible").waitFor();
  assert.match(await page.locator("#spend-empty").textContent(), /No Claude Code sessions in this range/);

  // Back to All, Droid's rows return untouched.
  await page.getByRole("radio", { name: "All", exact: true }).click();
  await page.locator("#mix .mix-row").first().waitFor();
  assert.equal((await names()).length, 2);

  // A link that says ?source=droid boots straight into the Droid source.
  await page.goto(`${origin}/?range=month&source=droid`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#mix .mix-row").first().waitFor();
  assert.equal(await page.locator('#source-chips [data-source="droid"]').getAttribute("aria-checked"), "true", "the boot source is Droid");
  assert.ok(spendSearches().some((s) => s.includes("source=droid") && s.includes("range=month")),
    `the booted chart must load the Droid month: ${spendSearches().join(" | ")}`);
  assert.deepEqual((await names()).sort(), ["claude-sonnet-5", "gpt-6-pro"]);
});

test("every vendor family wears its own palette, Claude stays orange, and the legend orders by family", async (page, origin) => {
  localRows = [
    { model: "grok-4", source: "grok-local", input_tokens: 700, output_tokens: 130, reasoning_tokens: 64, usd: 0.01, usd_estimate: null },
    { model: "claude-sonnet-5", source: "claude-local", input_tokens: 900, output_tokens: 300, cached_read_tokens: 400, cache_creation_tokens: 100, usd: null, usd_estimate: 0.02 },
    { model: "gpt-5", source: "codex-local", input_tokens: 100, output_tokens: 20, reasoning_tokens: 80, usd: null, usd_estimate: 0.01 },
    { model: "gemini-3-pro", source: "droid-local", input_tokens: 2100, output_tokens: 430, usd: null, usd_estimate: null },
    { model: "glm-5.3", source: "droid-local", input_tokens: 900, output_tokens: 150, cached_read_tokens: 1200, cache_creation_tokens: 60, usd: null, usd_estimate: null },
    { model: "kimi-k3", source: "droid-local", input_tokens: 450, output_tokens: 90, usd: null, usd_estimate: null },
    { model: "deepseek-r2", source: "droid-local", input_tokens: 300, output_tokens: 60, usd: null, usd_estimate: null },
    { model: "typesafe-one", source: "droid-local", input_tokens: 10, output_tokens: 5, usd: null, usd_estimate: null },
  ];
  await page.emulateMedia({ colorScheme: "light" });
  await page.goto(`${origin}/?range=month`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.waitForFunction((n) => document.querySelectorAll("#mix .mix-row").length === n, 8);

  // Every model keeps its own name and its own colour: eight rows, eight distinct swatches.
  const swatches = await page.locator("#mix .mix-row").evaluateAll((rows) => rows.map((r) => ({
    model: r.dataset.model,
    color: getComputedStyle(r.querySelector(".sw")).backgroundColor,
  })));
  const colors = swatches.map((s) => s.color);
  assert.equal(new Set(colors).size, colors.length, `every family's swatch must be distinct: ${colors.join(" | ")}`);

  // Each family resolves to its own palette's first shade, read from the page itself so the
  // test follows the palette rather than a copy of it.
  const hexToRgb = (hex) => {
    const n = parseInt(hex.slice(1), 16);
    return `rgb(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255})`;
  };
  const palette = await page.evaluate(() => Object.fromEntries(
    ["grok", "claude", "openai", "gemini", "glm", "kimi", "deepseek", "other"]
      .map((f) => [f, getComputedStyle(document.documentElement).getPropertyValue(`--s-${f}-1`).trim()])
  ));
  // Dark is the default face; Claude's orange there is the lighter shade that reads on it.
  assert.equal(palette.claude, "#e08a6a", "Claude's shade is orange in the dark face");
  const expected = {
    "grok-4": palette.grok, "claude-sonnet-5": palette.claude, "gpt-5": palette.openai,
    "gemini-3-pro": palette.gemini, "glm-5.3": palette.glm, "kimi-k3": palette.kimi,
    "deepseek-r2": palette.deepseek, "typesafe-one": palette.other,
  };
  for (const [model, color] of Object.entries(expected)) {
    const swatch = swatches.find((s) => s.model === model);
    assert.ok(swatch, `${model} must be charted`);
    assert.equal(swatch.color, hexToRgb(color), `${model} must wear its family's first shade`);
  }

  // The legend orders by family first (grok, claude, openai, then the newer families), so a
  // stack never interleaves one vendor's shades with another's.
  assert.deepEqual(
    (await page.locator("#mix .mix-name").allTextContents()),
    ["grok-4", "claude-sonnet-5", "gpt-5", "gemini-3-pro", "glm-5.3", "kimi-k3", "deepseek-r2", "typesafe-one"],
  );
});

// ---------- theme ----------

// The dashboard wears the keysrs.com light look and nothing else: the dark block is gone, so a
// Mac set to Dark (which headless Chrome also inherits) still gets the light palette.
test("neutral dark is the default, Settings switches to the site's light look and it survives a reload", async (page, origin) => {
  // The OS preference never decides: a light system still opens dark.
  await page.emulateMedia({ colorScheme: "light" });
  plans = [droidPlan()];
  await showDroidOnUsage(page);
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.locator('#live-status .live-row[data-source="droid"]').waitFor();
  const read = () => page.evaluate(() => ({
    attr: document.documentElement.dataset.theme || null,
    meta: document.querySelector('meta[name="color-scheme"]').content,
    scheme: getComputedStyle(document.documentElement).colorScheme,
    bodyBg: getComputedStyle(document.body).backgroundColor,
    bodyInk: getComputedStyle(document.body).color,
    paneBg: getComputedStyle(document.getElementById("pane-usage")).backgroundColor,
    paneRadius: getComputedStyle(document.getElementById("pane-usage")).borderRadius,
    blue: getComputedStyle(document.documentElement).getPropertyValue("--blue").trim(),
    claude: getComputedStyle(document.documentElement).getPropertyValue("--s-claude-1").trim(),
    muted: getComputedStyle(document.documentElement).getPropertyValue("--ink-3").trim(),
    railBg: getComputedStyle(document.querySelector(".rail")).backgroundColor,
  }));
  const dark = await read();
  assert.equal(dark.attr, null);
  assert.equal(dark.meta, "dark light");
  assert.equal(dark.scheme, "dark");
  assert.equal(dark.bodyBg, "rgb(17, 17, 19)", "the page sits on 0.11.0's near-black #111113");
  assert.equal(dark.bodyInk, "rgb(236, 236, 238)", "#ececee ink");
  assert.equal(dark.paneBg, "rgb(26, 26, 29)", "panes are the raised #1a1a1d");
  assert.equal(dark.paneRadius, "18px", "the pane is still a rounded card");
  assert.equal(dark.blue, "#4c9aff", "the accent blue stays for links and buttons");
  // Surfaces are neutral grey, not blue-tinted: every channel within a hair of the others.
  for (const rgb of [dark.bodyBg, dark.paneBg, dark.railBg]) {
    const [r, g, b] = rgb.match(/\d+/g).map(Number);
    assert.ok(Math.max(r, g, b) - Math.min(r, g, b) <= 3, `${rgb} is a neutral surface`);
  }
  // Muted text still reads: WCAG contrast of --ink-3 against the pane is at least 4.5:1.
  const lum = (hex) => {
    const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
      .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  };
  const contrast = (lum(dark.muted) + 0.05) / (lum("#1a1a1d") + 0.05);
  assert.ok(contrast >= 4.5, `--ink-3 ${dark.muted} on the pane is ${contrast.toFixed(2)}:1`);

  await page.getByRole("tab", { name: "Settings" }).click();
  const sw = page.locator("#theme-switch");
  assert.equal(await sw.getAttribute("aria-checked"), "false");
  await sw.click();
  assert.equal(await sw.getAttribute("aria-checked"), "true");
  const light = await read();
  assert.equal(light.attr, "light");
  assert.equal(light.scheme, "light");
  assert.equal(light.bodyBg, "rgb(245, 245, 247)", "the site's #f5f5f7 surface");
  assert.equal(light.bodyInk, "rgb(29, 29, 31)", "the site's #1d1d1f ink");
  assert.equal(light.paneBg, "rgb(255, 255, 255)", "the pane is a white card");
  assert.equal(light.blue, "#0071e3", "the primary blue is the site's");
  assert.equal(light.claude, "#c45c38", "Claude keeps its orange");
  assert.equal(await page.evaluate(() => localStorage.getItem("ksf.theme")), "light");

  // Remembered, and applied before the first paint rather than after a flash of dark.
  await page.reload();
  await page.waitForLoadState("networkidle");
  assert.equal((await read()).attr, "light");
  // Even under a dark system preference, the stored choice wins.
  await page.emulateMedia({ colorScheme: "dark" });
  assert.equal((await read()).bodyBg, "rgb(245, 245, 247)");

  // The sheet never follows the OS.
  const css = await page.evaluate(() => fetch("/styles.css").then((r) => r.text()));
  assert.ok(!css.includes("prefers-color-scheme"), "no OS-driven media block");

  // The primary button is the site's blue pill in the light look.
  await page.getByRole("tab", { name: "Usage" }).click();
  await page.locator("#btn-add-sub").click();
  await waitDialog(page, "dlg-sub", true);
  const primary = await page.locator("#dlg-sub .btn-primary").evaluate((n) => {
    const cs = getComputedStyle(n);
    return { bg: cs.backgroundColor, radius: cs.borderRadius, color: cs.color };
  });
  assert.equal(primary.bg, "rgb(0, 113, 227)", "primary buttons are the site's #0071e3");
  assert.equal(primary.radius, "999px", "primary buttons are pills");
  assert.equal(primary.color, "rgb(255, 255, 255)");
});

// A theme switch is a pane round trip through Settings: the vault's session state (provider
// filter, search, the More menu) must keep working afterwards, while the persisted choices
// (theme, sort) survive a reload and the session-only filter resets.
test("a theme switch keeps the vault's filter, search and menu, and a reload keeps theme and sort", async (page, origin) => {
  await openKeys(page, origin);
  await page.selectOption("#keys-provider", "anthropic");
  assert.deepEqual(await rowNames(page), ["bravo"]);
  await page.selectOption("#keys-sort", "newest");

  await page.getByRole("tab", { name: "Settings" }).click();
  await page.locator("#theme-switch").click();
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body .key-row[data-name="bravo"]').waitFor();
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "light");
  assert.equal(await page.evaluate(() => getComputedStyle(document.body).backgroundColor), "rgb(245, 245, 247)");
  assert.equal(await page.inputValue("#keys-provider"), "anthropic", "the filter survives the theme switch");
  assert.equal(await page.inputValue("#keys-sort"), "newest", "the sort survives the theme switch");
  assert.deepEqual(await rowNames(page), ["bravo"]);

  // Search still combines with the filter and names it on a miss.
  await page.locator("#keys-search").fill("alpha");
  assert.deepEqual(await rowNames(page), []);
  assert.equal(await page.locator("#keys-no-match").textContent(), "No keys for Anthropic match “alpha”.");
  await page.locator("#keys-search").fill("bravo");
  assert.deepEqual(await rowNames(page), ["bravo"]);
  await page.locator("#keys-search").fill("");
  assert.deepEqual(await rowNames(page), ["bravo"]);

  // The More menu still opens, and Escape returns focus to its button.
  await openRowMenu(page, "bravo");
  assert.equal(await page.locator("#key-menu").isVisible(), true);
  await page.keyboard.press("Escape");
  await waitFocused(page, "bravo:menu");

  // A reload keeps the theme and the sort; the provider filter is session-only.
  await page.reload();
  await page.waitForLoadState("networkidle");
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "light", "the theme survives the reload");
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body .key-row[data-name="alpha"]').waitFor();
  assert.equal(await page.inputValue("#keys-sort"), "newest", "the sort survives the reload");
  assert.deepEqual(await rowNames(page), ["charlie", "bravo", "alpha"], "newest by created date");
  assert.equal(await page.inputValue("#keys-provider"), "", "the provider filter is session-only");
});

test("every pane fits the viewport at 390, 540, 780, 1280 and 1920 px, and nothing loads off-origin", async (page, origin) => {
  const foreign = [];
  page.on("request", (r) => { if (new URL(r.url()).origin !== origin) foreign.push(r.url()); });
  plans = [droidPlan()];
  localRows = subscriptionRows();
  await showDroidOnUsage(page);
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  for (const width of [390, 540, 780, 1280, 1920]) {
    await page.setViewportSize({ width, height: 900 });
    for (const pane of ["Usage", "Chart", "Keys", "Settings"]) {
      await page.getByRole("tab", { name: pane, exact: true }).click();
      if (pane === "Usage") await page.locator("#live-status .live-row").first().waitFor();
      else if (pane === "Chart") await page.locator("#daily-svg").waitFor();
      else if (pane === "Keys") await page.locator("#keys-body .key-row[data-name]").first().waitFor();
      else await page.locator("#theme-switch").waitFor();
      const spill = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(spill <= 1, `${pane} pane spills ${spill}px at ${width}px`);
      // html/body clip horizontal overflow, so a document-level spill check alone cannot see a
      // pane child (the rail made the Chart chips row 53px narrower) whose content is cut off.
      if (pane === "Chart") {
        const chips = await page.evaluate(() => {
          const row = document.querySelector("#source-chips");
          const cloud = row.querySelector('[data-source="cloud"]').getBoundingClientRect();
          return { scroll: row.scrollWidth, client: row.clientWidth, cloudRight: cloud.right, vw: document.documentElement.clientWidth };
        });
        assert.ok(chips.scroll <= chips.client + 1, `#source-chips clips its chips at ${width}px (scroll ${chips.scroll} > client ${chips.client})`);
        assert.ok(chips.cloudRight <= chips.vw, `the Cloud chip is cut off at ${width}px (right edge ${chips.cloudRight} > viewport ${chips.vw})`);
      }
    }
  }
  assert.deepEqual(foreign, [], "every request stays on the dashboard's own origin");
});

// The status line used to share the header with the tabs; it now has its own strip above the
// panes, so a long message must ellipsize on one line there and never reach the rail.
test("the status line stays one row beside the rail on every pane from 390 px up", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.evaluate(() => { document.getElementById("status").textContent = "Ingested 1,234 new rows from 56 files, 3 parse errors. ".repeat(3); });
  for (const width of [390, 540, 780, 1180, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    for (const pane of ["Usage", "Chart", "Keys", "Settings"]) {
      await page.getByRole("tab", { name: pane, exact: true }).click();
      const g = await page.evaluate(() => {
        const r = (sel) => document.querySelector(sel).getBoundingClientRect();
        const status = r("#status"), rail = r(".rail"), pane = r("main [role=tabpanel]:not([hidden])");
        const hit = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
        return { status, railHits: hit(status, rail), paneHits: hit(status, pane), vw: innerWidth };
      });
      assert.ok(g.status.height > 0 && g.status.height <= 22, `${pane} at ${width}px: status is ${g.status.height}px tall`);
      assert.ok(g.status.left >= 0 && g.status.right <= g.vw, `${pane} at ${width}px: status leaves the viewport`);
      assert.ok(!g.railHits, `${pane} at ${width}px: the status overlaps the rail`);
      assert.ok(!g.paneHits, `${pane} at ${width}px: the status overlaps the pane`);
    }
  }
});

// ---------- app shell: the rail ----------

test("the rail carries the original app icon and Usage, Chart, Keys, Help and Settings in both themes", async (page, origin) => {
  const icons = [];
  page.on("response", (r) => { if (new URL(r.url()).pathname === "/icon.png") icons.push({ origin: new URL(r.url()).origin, status: r.status() }); });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const read = () => page.evaluate(() => {
    const img = document.querySelector(".rail .brand-mark img");
    const mark = getComputedStyle(document.querySelector(".rail .brand-mark"));
    const box = img.getBoundingClientRect();
    return {
      src: img.getAttribute("src"), alt: img.alt, loaded: img.complete && img.naturalWidth > 0,
      w: box.width, h: box.height,
      markBorder: mark.borderTopWidth, markBg: mark.backgroundColor,
      rail: document.querySelector(".rail").getBoundingClientRect().width,
      items: [...document.querySelectorAll(".rail .rail-button")].map((b) => [b.id, b.textContent.trim(), !!b.querySelector("svg")]),
      textBrand: !!document.querySelector(".brand-name, .brand-purpose, header.toolbar"),
    };
  });
  const dark = await read();
  assert.equal(dark.src, "/icon.png", "the original app icon, same-origin");
  assert.equal(dark.alt, "Keysrs");
  assert.ok(dark.loaded, "the icon loaded");
  assert.deepEqual([dark.w, dark.h], [48, 48]);
  assert.equal(dark.markBorder, "0px", "no extra tile around the icon");
  assert.equal(dark.markBg, "rgba(0, 0, 0, 0)");
  assert.equal(dark.rail, 78);
  assert.deepEqual(dark.items, [
    ["nav-usage", "Usage", true], ["nav-chart", "Chart", true], ["nav-keys", "Keys", true],
    ["btn-help", "Help", true], ["nav-settings", "Settings", true],
  ]);
  assert.equal(dark.textBrand, false, "the old text brand and header are gone");
  // Help and Settings sit at the foot of the rail with a divider between them.
  const foot = await page.evaluate(() => [...document.querySelector(".rail-bottom").children].map((n) => n.id || n.className));
  assert.deepEqual(foot, ["btn-help", "rail-divider", "nav-settings"]);
  const gap = await page.evaluate(() => document.getElementById("btn-help").getBoundingClientRect().top - document.getElementById("nav-keys").getBoundingClientRect().bottom);
  assert.ok(gap > 100, `the bottom group is pushed down (${gap}px below Keys)`);

  await page.getByRole("tab", { name: "Settings" }).click();
  await page.locator("#theme-switch").click();
  for (const pane of ["Usage", "Chart", "Keys", "Settings"]) {
    await page.getByRole("tab", { name: pane, exact: true }).click();
    const light = await read();
    assert.equal(light.src, "/icon.png", `${pane}: the same icon in the light theme`);
    assert.deepEqual([light.w, light.h], [48, 48]);
    assert.ok(await page.locator(".rail").isVisible(), `${pane}: the rail stays`);
  }
  assert.ok(icons.length >= 1 && icons.every((r) => r.origin === origin && r.status === 200), JSON.stringify(icons));
});

test("rail tabs switch panes, mark the selection and step on every arrow key", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const selected = () => page.evaluate(() =>
    [...document.querySelectorAll("[role=tab]")].filter((t) => t.getAttribute("aria-selected") === "true").map((t) => t.id));
  for (const [name, id] of [["Keys", "nav-keys"], ["Chart", "nav-chart"], ["Settings", "nav-settings"], ["Usage", "nav-usage"]]) {
    await page.getByRole("tab", { name, exact: true }).click();
    assert.deepEqual(await selected(), [id], `${name} click`);
    assert.equal(await page.locator(`#${id}`).getAttribute("tabindex"), "0");
  }
  await page.getByRole("tab", { name: "Keys", exact: true }).click();
  const look = await page.evaluate(() => {
    const tab = document.getElementById("nav-keys");
    const cs = getComputedStyle(tab), bar = getComputedStyle(tab, "::before");
    const other = getComputedStyle(document.getElementById("nav-chart"), "::before");
    const root = getComputedStyle(document.documentElement);
    const probe = document.createElement("i");
    document.body.append(probe);
    probe.style.color = root.getPropertyValue("--blue-ink");
    const ink = getComputedStyle(probe).color;
    probe.style.color = root.getPropertyValue("--blue-tint");
    const tint = getComputedStyle(probe).color;
    probe.style.color = root.getPropertyValue("--blue");
    const blue = getComputedStyle(probe).color;
    probe.remove();
    return { color: cs.color, bg: cs.backgroundColor, bar: bar.width, barBg: bar.backgroundColor, otherBar: other.content, ink, tint, blue };
  });
  assert.equal(look.color, look.ink, "selected text is --blue-ink");
  assert.equal(look.bg, look.tint, "selected fill is --blue-tint");
  assert.equal(look.bar, "2px", "a 2px indicator on the left edge");
  assert.equal(look.barBg, look.blue);
  assert.equal(look.otherBar, "none", "only the selected tab has the indicator");

  // The rail is vertical: Down and Up step and wrap, and focus stays on the tab even when the
  // Keys pane (whose list also listens for Down) comes up.
  await page.getByRole("tab", { name: "Chart", exact: true }).click();
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => !document.getElementById("pane-keys").hidden);
  assert.equal(await page.evaluate(() => document.activeElement.id), "nav-keys");
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => !document.getElementById("pane-settings").hidden);
  assert.equal(await page.evaluate(() => document.activeElement.id), "nav-settings", "Help is skipped: it is not a tab");
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => !document.getElementById("pane-usage").hidden);
  await page.keyboard.press("ArrowUp");
  await page.waitForFunction(() => !document.getElementById("pane-settings").hidden);
  assert.deepEqual(await selected(), ["nav-settings"]);
  await page.keyboard.press("ArrowLeft");
  await page.waitForFunction(() => !document.getElementById("pane-keys").hidden);
  assert.equal(await page.evaluate(() => document.activeElement.id), "nav-keys");

  // Settings is still a member of the one tablist, though it sits below Help.
  const owned = await page.evaluate(() => {
    const list = document.querySelector("[role=tablist]");
    return { owns: list.getAttribute("aria-owns"), orientation: list.getAttribute("aria-orientation"), count: document.querySelectorAll("[role=tablist]").length };
  });
  assert.deepEqual(owned, { owns: "nav-settings", orientation: "vertical", count: 1 });

  await page.locator("#btn-help").click();
  await waitDialog(page, "dlg-help", true);
  assert.deepEqual(await selected(), ["nav-keys"], "Help opens the dialog without changing pane");
});

test("the rail narrows at 780 and 540 px and the logo shrinks to 40 px", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  for (const [width, rail, logo] of [[1280, 78, 48], [781, 78, 48], [780, 65, 48], [541, 65, 48], [540, 53, 40], [390, 53, 40]]) {
    await page.setViewportSize({ width, height: 800 });
    const g = await page.evaluate(() => {
      const r = (sel) => document.querySelector(sel).getBoundingClientRect();
      const labels = [...document.querySelectorAll(".rail .rail-button")].map((b) => {
        const box = b.getBoundingClientRect();
        return { w: box.width, scroll: b.scrollWidth, client: b.clientWidth, size: parseFloat(getComputedStyle(b).fontSize) };
      });
      return { rail: r(".rail").width, logo: r(".brand-mark img").width, labels, help: r("#btn-help").bottom, vh: innerHeight };
    });
    assert.equal(g.rail, rail, `rail at ${width}px`);
    assert.equal(g.logo, logo, `logo at ${width}px`);
    for (const l of g.labels) {
      assert.ok(l.scroll <= l.client + 1, `a rail label is clipped at ${width}px`);
      assert.ok(l.size >= 8, `rail labels stay legible at ${width}px`);
    }
    assert.ok(g.help <= g.vh, `Help is on screen at ${width}px`);
  }
});

test("the status line is visible after a copy at 1440 and 390 px", async (page, origin) => {
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 844 });
    await openKeys(page, origin);
    await rowButton(page, "alpha", "copy").click();
    await page.waitForFunction(() => /^Copied alpha\./.test(document.getElementById("status").textContent));
    assert.equal(await status(page), "Copied alpha. Clipboard wipes in 20 s.");
    const box = await page.locator("#status").evaluate((n) => {
      const r = n.getBoundingClientRect();
      return { w: r.width, h: r.height, left: r.left, right: r.right, top: r.top, bottom: r.bottom, vw: innerWidth, vh: innerHeight, live: n.getAttribute("aria-live") };
    });
    assert.ok(box.w > 0 && box.h > 0, `status has a size at ${width}px`);
    assert.ok(box.left >= 0 && box.right <= box.vw && box.top >= 0 && box.bottom <= box.vh, `status is on screen at ${width}px: ${JSON.stringify(box)}`);
    assert.equal(box.live, "polite");
    assert.ok(await page.locator("#status").isVisible());
  }
});

test("a model used by Claude Code and Droid is one series whose total counts both tools' rules", async (page, origin) => {
  localRows = [
    // Claude Code saw the model: 1,000 in, 400 cached read, 100 cache write, 200 out — 1,700
    // counted, its cache buckets billed and its log carrying no reasoning bucket.
    { model: "claude-sonnet-5", source: "claude-local", input_tokens: 1000, output_tokens: 200, cached_read_tokens: 400, cache_creation_tokens: 100, usd: null, usd_estimate: 0.02 },
    // Droid saw the same model: 100 in, 50 out, 25 reasoning — 175 counted, every bucket.
    { model: "claude-sonnet-5", source: "droid-local", input_tokens: 100, output_tokens: 50, reasoning_tokens: 25, usd: null, usd_estimate: null },
  ];
  await page.goto(`${origin}/?range=month`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.waitForFunction(() => document.querySelectorAll("#mix .mix-row").length === 1, null, { timeout: 5000 });
  assert.equal(await page.locator("#mix .mix-name").textContent(), "claude-sonnet-5",
    "one model id is one series whichever tool used it");
  // 1,700 under Claude's rule + 175 under Droid's: 1,875, a number no single rule over the
  // merged raw buckets could produce (Claude's rule would drop the 25 reasoning tokens).
  assert.match(await totalsText(page), /1\.9K tokens/);
  assert.equal((await page.locator("#mix .mix-val").first().textContent()).trim(), "1.9K");
  // The raw buckets of both tools stay on the row for the tooltip, and the totals line names
  // the reasoning bucket only the Droid part contributed.
  assert.match(await page.locator("#mix .mix-row").getAttribute("title"), /1,100 in, 250 out, 400 cached reads, 100 cache writes/);
  assert.match(await page.locator("#totals .totals-main").getAttribute("title"), /25 reasoning/);
  const labels = await page.locator("#daily-svg g.col").evaluateAll((g) => g.map((n) => n.getAttribute("aria-label")));
  assert.ok(labels.some((l) => /claude-sonnet-5 1\.9K/.test(l)), `the bar and the headline must agree: ${labels.join(" | ")}`);
});

test("the Droid chart's month total is the Droid row's Month figure", async (page, origin) => {
  await showDroidOnUsage(page);
  plans = [droidPlan()];
  localRows = droidFixtureRows();
  await page.goto(`${origin}/?range=month`);
  await page.waitForLoadState("networkidle");
  const month = page.locator('#live-status .live-row[data-source="droid"] .live-meter', { hasText: "Month" });
  await month.waitFor();
  const rowFigure = (await month.locator(".live-note").textContent()).trim();
  assert.equal(rowFigure, "75.3K tokens", "the fixture's Month figure");

  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#mix .mix-row").first().waitFor();
  await page.getByRole("radio", { name: "Droid", exact: true }).click();
  await page.waitForFunction(() => document.querySelector('#source-chips [data-source="droid"]').getAttribute("aria-checked") === "true");
  await page.waitForFunction((t) => document.querySelector("#totals .totals-main").textContent.includes(t), rowFigure,
    { timeout: 5000 });
  const chartTotal = (await page.locator("#totals .totals-main").textContent()).trim();
  assert.equal(chartTotal, rowFigure, "the chart's Droid month total equals the Droid row's Month figure");
  // The cache buckets Droid reports are in that total, not dropped by a family-based guess.
  assert.match(await page.locator("#totals .totals-main").getAttribute("title"), /71,000 cached input read/);
  assert.deepEqual(
    (await page.locator("#mix .mix-name").allTextContents()).sort(),
    ["claude-sonnet-5", "gpt-6-pro"],
  );
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
  await page.locator('#keys-body .key-row[data-name="alpha"]').waitFor();
  await page.getByRole("tab", { name: "Usage" }).click();
  assert.equal(await page.locator("#onboard").isHidden(), true, "an existing user is not onboarded");
});

// ---------- providers manager and agent recipes ----------

test("the providers manager adds, hides and removes", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  // Both the Add key and the Providers buttons belong to the Keys pane.
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body .key-row[data-name="alpha"]').waitFor();
  await page.getByRole("button", { name: "Providers", exact: true }).click();
  await waitDialog(page, "dlg-providers", true);
  await page.locator("#providers-list .provider-row").first().waitFor();
  const listing = await page.locator("#providers-list").textContent();
  assert.match(listing, /Labs/, "the shipped groups are listed");
  assert.match(listing, /retired/, "OpenAI is retired, not offered, but still shown");
  assert.doesNotMatch(listing, /Yours\s*Acme/, "nothing is yours yet");

  // Add a custom provider through the form; it lands under Yours.
  const form = page.locator("#provider-add-form");
  await form.locator("[name=id]").fill("acme");
  await form.locator("[name=name]").fill("Acme");
  await form.locator("[name=host]").fill("api.acme.dev");
  await form.locator("[name=api]").selectOption("openai");
  await form.locator("button[type=submit]").click();
  const mine = page.locator('#providers-list .provider-row:has(code:text-is("acme"))');
  await mine.waitFor();
  assert.match(await mine.textContent(), /yours/);
  assert.match(await mine.textContent(), /api\.acme\.dev/);

  // Hide a built-in provider: it leaves the Add dialog but its row says hidden.
  const groq = page.locator('#providers-list .provider-row:has(code:text-is("groq"))');
  await groq.getByRole("button", { name: "Hide" }).click();
  await page.waitForFunction(() => {
    const row = [...document.querySelectorAll("#providers-list .provider-row")]
      .find((r) => r.querySelector("code")?.textContent === "groq");
    return row?.textContent.includes("hidden");
  });
  assert.ok(requests.some((r) => r.method === "PATCH" && r.pathname === "/api/providers/groq"), "the hide reaches the engine");
  await page.locator("#dlg-providers [data-close]").click();
  await waitDialog(page, "dlg-providers", false);

  // The Add dialog's picker offers the new provider and no longer offers the hidden one.
  await page.locator("#btn-add").click();
  await waitDialog(page, "dlg-add", true);
  await page.locator("#add-form [name=provider]").click();
  const offeredText = await page.locator("#add-form .pick-list").textContent();
  // The listId prefix is always three dash-separated parts (name-pick-xxxxx), so the
  // provider id itself is everything after that; azure-openai must not count as openai.
  const offeredIds = await page.locator("#add-form .pick-list .pick-item")
    .evaluateAll((nodes) => nodes.map((n) => n.id.split("-").slice(3).join("-")));
  assert.ok(offeredIds.includes("acme"), "a provider you added is offered for new keys");
  assert.doesNotMatch(offeredText, /Groq/, "a hidden provider is not offered");
  assert.ok(!offeredIds.includes("openai"), "the retired provider is not offered either");
  // Escape closes the open picker list only; the dialog stays for its Cancel button.
  await page.keyboard.press("Escape");
  await waitDialog(page, "dlg-add", true);
  await page.locator("#dlg-add [data-close]").click();
  await waitDialog(page, "dlg-add", false);

  // A hidden provider still names existing keys in the table; the pane never left Keys.
  assert.equal(await rowCell(page, "alpha", "provider").textContent(), "OpenAI");

  // Removing yours is one click and reaches the engine.
  await page.getByRole("button", { name: "Providers", exact: true }).click();
  await waitDialog(page, "dlg-providers", true);
  const mineAgain = page.locator('#providers-list .provider-row:has(code:text-is("acme"))');
  await mineAgain.getByRole("button", { name: "Remove" }).click();
  await mineAgain.waitFor({ state: "detached" });
  assert.ok(requests.some((r) => r.method === "DELETE" && r.pathname === "/api/providers/acme"), "the removal reaches the engine");
});

test("the agents dialog personalizes each recipe to the chosen key", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  // Agents lives in Settings now that the header carries only status and help.
  await page.getByRole("tab", { name: "Settings" }).click();
  await page.getByRole("button", { name: "Agents", exact: true }).click();
  await waitDialog(page, "dlg-agents", true);
  const body = await page.locator("#agents-body").textContent();
  for (const name of ["Claude Code", "Codex", "Grok", "Droid", "cloud agent"]) {
    assert.match(body, new RegExp(name), `${name} has a section`);
  }
  const claude = page.locator("#agents-body .agent:has(summary:has-text('Claude Code'))");
  assert.equal((await claude.locator(".agent-cmd").first().textContent()), "keys agent claude alpha");

  // The vault never appears as a secret in a recipe, only its local URL and tokens.
  const droid = page.locator("#agents-body .agent:has(summary:has-text('Droid'))");
  assert.match(await droid.locator(".agent-cmd").first().textContent(), /keys setup droid --key alpha/);
  const cloud = page.locator("#agents-body .agent:has(summary:has-text('A cloud agent'))");
  assert.match(await cloud.textContent(), /keys client issue alpha/);
  assert.match(await cloud.textContent(), /keys tunnel/);
  // Both routes out: ssh for a machine you can reach, the relay for a managed agent you cannot.
  const cloudText = await cloud.textContent();
  assert.match(cloudText, /keys relay setup --url/);
  assert.match(cloudText, /docs\/relay\.md/);
  assert.match(cloudText, /https:\/\/<your worker>\/alpha/, "the Worker is the base URL, the key name its path");
  assert.doesNotMatch(cloudText, /cannot reach this Mac/, "the relay is the answer to that, not a dead end");

  // Choosing another key rewrites every recipe; the model field feeds the setup commands.
  await page.locator("#agents-key").selectOption("bravo");
  await page.waitForFunction(() =>
    [...document.querySelectorAll("#agents-body .agent-cmd")].some((n) => n.textContent.includes("keys agent claude bravo")));
  await page.locator("#agents-body [aria-label='Model id']").fill("grok-4.6");
  await page.waitForFunction(() =>
    [...document.querySelectorAll("#agents-body .agent-cmd")].some((n) => n.textContent.includes("--model grok-4.6")));
});

test("the first-use guide links to the agents dialog", async (page, origin) => {
  keys = [];
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  assert.match(await page.locator("#onboard").textContent(), /Wire up a coding agent/);
  await page.locator("#onboard [data-action='agents']").click();
  await waitDialog(page, "dlg-agents", true);
  // The cloned guide must keep working after the dialog closes.
  await page.locator("#dlg-agents [data-close]").click();
  await waitDialog(page, "dlg-agents", false);
});

test("four panes: the shortcuts and arrow keys reach Usage, Chart, Keys and Settings and nothing else", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  const tabNames = await page.locator("[role=tab]").allTextContents();
  assert.deepEqual(tabNames.map((t) => t.trim()), ["Usage", "Chart", "Keys", "Settings"]);
  const shown = () => page.evaluate(() =>
    [...document.querySelectorAll("main [role=tabpanel]")].filter((p) => !p.hidden).map((p) => p.id));
  await page.locator("body").click({ position: { x: 1, y: 1 } });
  for (const [key, pane] of [["2", "pane-chart"], ["3", "pane-keys"], ["4", "pane-settings"], ["1", "pane-usage"]]) {
    await page.keyboard.press(`ControlOrMeta+${key}`);
    await page.waitForFunction((id) => !document.getElementById(id).hidden, pane);
    assert.deepEqual(await shown(), [pane], `shortcut ${key}`);
  }
  await page.keyboard.press("ControlOrMeta+5");
  assert.deepEqual(await shown(), ["pane-usage"], "a fifth shortcut does not switch panes");
  await page.getByRole("tab", { name: "Settings" }).click();
  await page.keyboard.press("ArrowRight");
  await page.waitForFunction(() => !document.getElementById("pane-usage").hidden);
  assert.deepEqual(await shown(), ["pane-usage"], "the arrow keys wrap from Settings back to Usage");
  await page.getByRole("button", { name: "Keyboard shortcuts" }).click();
  await waitDialog(page, "dlg-help", true);
  const help = await page.locator("#dlg-help .shortcuts").textContent();
  assert.doesNotMatch(help, /Optimizer/);
  assert.match(help, /Settings/);
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
  await rowAct(page, "alpha", "delete");
  await page.locator("#delete-confirm").click();
  await page.waitForFunction(() => document.getElementById("delete-err").textContent !== "");
  assert.equal(await page.locator("#delete-err").textContent(), "This page is from an older launch. Reload it.");
});

test("an error body that is not JSON still produces a readable message", async (page, origin) => {
  await openKeys(page, origin);
  failures.set(rule("POST", "/api/keys/alpha/reveal"), { status: 500, raw: "upstream exploded" });
  await rowAct(page, "alpha", "reveal");
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
  await rowAct(page, "alpha", "reveal");
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
  await page.locator('#keys-body .key-row[data-name="foxtrot"]').waitFor();
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "foxtrot"]);

  // The slow reply, carrying the older vault, lands last.
  await page.waitForTimeout(1800);
  assert.deepEqual(await rowNames(page), ["alpha", "bravo", "foxtrot"],
    "a stale list must not restore a deleted key or drop a new one");
});

test("repeated reveals of different keys never show the wrong secret", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  await rowAct(page, "alpha", "reveal");
  await waitDialog(page, "dlg-reveal", true);
  assert.equal(await page.locator("#reveal-name").textContent(), "alpha");
  await page.locator("#dlg-reveal [data-close]").click();
  await waitDialog(page, "dlg-reveal", false);
  await page.waitForTimeout(100);

  await rowAct(page, "bravo", "reveal");
  await waitDialog(page, "dlg-reveal", true);
  assert.equal(await page.locator("#reveal-name").textContent(), "bravo");
  // The first key's countdown must not close the second key's dialog early.
  await page.clock.runFor(14000);
  assert.equal(await page.locator("#dlg-reveal").evaluate((d) => d.open), true);
  await page.clock.runFor(2000);
  await waitDialog(page, "dlg-reveal", false);
});

test("key sort orders the flat list across providers and survives a reload", async (page, origin) => {
  await openKeys(page, origin);
  await page.locator("#keys-body .key-row[data-name]").first().waitFor();
  const order = () => page.locator("#keys-body .key-row[data-name]").evaluateAll((rows) => rows.map((r) => r.dataset.name));
  const names = keys.map((k) => k.name).sort();
  assert.deepEqual(await order(), names, "name order is the default");
  const expect = {
    // Never-used keys go last, then by name.
    recent: [...keys].sort((a, b) => (b.last_used_at || "").localeCompare(a.last_used_at || "") || a.name.localeCompare(b.name)),
    most: [...keys].sort((a, b) => (b.gateway_month_calls || 0) - (a.gateway_month_calls || 0) || a.name.localeCompare(b.name)),
    newest: [...keys].sort((a, b) => b.created_at.localeCompare(a.created_at) || a.name.localeCompare(b.name)),
    oldest: [...keys].sort((a, b) => a.created_at.localeCompare(b.created_at) || a.name.localeCompare(b.name)),
  };
  for (const [value, sorted] of Object.entries(expect)) {
    await page.selectOption("#keys-sort", value);
    assert.deepEqual(await order(), sorted.map((k) => k.name), value);
  }
  // A fresh load of the page opens on another pane; go back to the keys.
  await openKeys(page, origin);
  await page.locator("#keys-body .key-row[data-name]").first().waitFor();
  assert.equal(await page.inputValue("#keys-sort"), "oldest");
  assert.deepEqual(await order(), expect.oldest.map((k) => k.name), "the choice is remembered");
});

test("long key metadata keeps every action inside the viewport", async (page, origin) => {
  keys[0].name = "acceptance-" + "long-key-name-".repeat(8);
  keys[0].host = "api.openai.com";
  keys[0].gateway_enabled = true;
  keys[0].gateway_url = "http://127.0.0.1:12767/" + keys[0].name;
  keys[0].last_check = { ok: false, checked_at: "2026-09-22T05:00:00Z", summary: "Provider rejected the synthetic key. " + "LongDiagnosticWithoutSpaces".repeat(12) };
  await openKeys(page, origin, { expectEmpty: true });
  await page.locator("#keys-body .key-row[data-name]").first().waitFor();
  // The key list is drawn again once grants arrive. Resolving the row
  // inside the same evaluate measures the table as it is now, not a row that redraw detached
  // (which reads as a zero-width button; seen only when the warm suite ran fast enough).
  await page.waitForLoadState("networkidle");
  for (const width of [390, 520, 521, 600, 720, 768, 1024, 1280, 1440, 1920]) {
    await page.setViewportSize({ width, height: 900 });
    const geometry = await page.evaluate(() => {
      const row = document.querySelector('#keys-body .key-row[data-name]');
      const box = (n) => { const r = n.getBoundingClientRect(); return { left: r.left, right: r.right, width: r.width }; };
      return {
        viewport: innerWidth,
        spill: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        listRight: document.querySelector('#keys-list').getBoundingClientRect().right,
        rowRight: row.getBoundingClientRect().right,
        name: box(row.querySelector('.key-name')),
        actions: [...row.querySelectorAll('.key-actions button, .key-gateway')].map(b => ({ name: b.dataset.act, ...box(b) })),
      };
    });
    assert.ok(geometry.spill <= 1, `the page scrolls sideways at ${width}: ${geometry.spill}`);
    assert.ok(geometry.listRight <= width + 1 && geometry.rowRight <= width + 1, `list overflows at ${width}: ${JSON.stringify(geometry)}`);
    assert.ok(geometry.name.right <= geometry.rowRight, `the long name runs out of its row at ${width}`);
    assert.ok(geometry.actions.length >= 2, "Copy and the gateway figure are measured");
    for (const action of geometry.actions) assert.ok(action.left >= 0 && action.right <= width + 1 && action.width > 0, `${action.name} outside viewport at ${width}: ${JSON.stringify(action)}`);
  }
});

// The width audit's other half: the same geometry in BOTH themes, narrow and wide, with a key
// whose name and host are far too long, plus the theme's computed palette on the Keys pane and
// the rail and logo at each width. The More menu is opened at the narrowest and widest widths.
test("the vault's rows, Copy and More stay inside the viewport in both themes from 390 to 1920 px, long name and host included", async (page, origin) => {
  keys[0].name = "acceptance-" + "long-key-name-".repeat(8);
  keys[0].host = "api.openai.com";
  const longName = keys[0].name;
  await openKeys(page, origin, { expectEmpty: true });
  await page.locator("#keys-body .key-row[data-name]").first().waitFor();
  await page.waitForLoadState("networkidle");
  const palettes = {
    dark: { bg: "rgb(17, 17, 19)", pane: "rgb(26, 26, 29)", blue: "#4c9aff" },
    light: { bg: "rgb(245, 245, 247)", pane: "rgb(255, 255, 255)", blue: "#0071e3" },
  };
  for (const theme of ["dark", "light"]) {
    if (theme === "light") {
      await page.getByRole("tab", { name: "Settings" }).click();
      await page.locator("#theme-switch").click();
      await page.getByRole("tab", { name: "Keys" }).click();
      await page.locator("#keys-body .key-row[data-name]").first().waitFor();
    }
    const palette = await page.evaluate(() => ({
      theme: document.documentElement.dataset.theme || "dark",
      bg: getComputedStyle(document.body).backgroundColor,
      pane: getComputedStyle(document.getElementById("pane-keys")).backgroundColor,
      blue: getComputedStyle(document.documentElement).getPropertyValue("--blue").trim(),
    }));
    assert.equal(palette.theme, theme);
    assert.deepEqual({ bg: palette.bg, pane: palette.pane, blue: palette.blue }, palettes[theme], `${theme}: the Keys pane wears the theme's palette`);
    for (const width of [390, 540, 1280, 1440, 1920]) {
      await page.setViewportSize({ width, height: 900 });
      const g = await page.evaluate((name) => {
        const rect = (n) => n.getBoundingClientRect();
        const row = document.querySelector(`#keys-body .key-row[data-name="${name}"]`);
        const box = (sel) => { const b = rect(row.querySelector(sel)); return { left: b.left, right: b.right, width: b.width }; };
        return {
          vw: innerWidth,
          spill: document.documentElement.scrollWidth - document.documentElement.clientWidth,
          rail: rect(document.querySelector(".rail")).width,
          logo: rect(document.querySelector(".brand-mark img")).width,
          rowRight: rect(row).right,
          copy: box('[data-act="copy"]'),
          menu: box('[data-act="menu"]'),
        };
      }, longName);
      const at = `${theme} ${width}px`;
      assert.ok(g.spill <= 1, `${at}: horizontal spill ${g.spill}px`);
      assert.equal(g.rail, width > 780 ? 78 : width > 540 ? 65 : 53, `${at}: rail width`);
      assert.equal(g.logo, width > 540 ? 48 : 40, `${at}: logo size`);
      assert.ok(g.rowRight <= width + 1, `${at}: the row runs past the viewport`);
      for (const [which, b] of [["Copy", g.copy], ["More", g.menu]]) {
        assert.ok(b.width > 0 && b.left >= 0 && b.right <= width + 1, `${at}: ${which} leaves the viewport: ${JSON.stringify(b)}`);
      }
      if (width === 390 || width === 1920) {
        await openRowMenu(page, longName);
        const m = await page.locator("#key-menu").evaluate((n) => {
          const b = n.getBoundingClientRect();
          return { left: b.left, right: b.right, top: b.top, bottom: b.bottom, vw: innerWidth, vh: innerHeight };
        });
        assert.ok(m.left >= 0 && m.right <= m.vw && m.top >= 0 && m.bottom <= m.vh, `${at}: the menu leaves the viewport: ${JSON.stringify(m)}`);
        await page.keyboard.press("Escape");
        await waitFocused(page, `${longName}:menu`);
      }
    }
    await page.setViewportSize({ width: 1440, height: 900 });
  }
});

// The CSP forbids inline styles and scripts and every off-origin resource; pin the served
// markup to that here as well as in the lint command, so the suite fails on a regression.
test("the served markup ships no inline styles, style blocks or external resources", async () => {
  const markup = fs.readFileSync(path.join(root, "Web", "index.html"), "utf8");
  assert.doesNotMatch(markup, /style="/i, "an inline style attribute crept into index.html");
  assert.doesNotMatch(markup, /<style/i, "a style block crept into index.html");
  assert.doesNotMatch(markup, /https?:\/\/[^"']*\.(css|js|png|svg|woff2?)/i, "an external resource crept into index.html");
});
// ---------- runner ----------

// The tester-army runner reuses this synthetic fixture, never the installed app.
module.exports = { server, reset };
if (require.main === module && process.env.KEYS_FIXTURE_PORT) {
  reset();
  server.listen(Number(process.env.KEYS_FIXTURE_PORT), "127.0.0.1");
} else if (require.main === module) {

// ---------- Settings: the app's relay ----------

// Settings reads the relay when it opens; going to another pane and back is a fresh read.
async function reopenSettings(page) {
  await page.getByRole("tab", { name: "Usage" }).click();
  await page.getByRole("tab", { name: "Settings" }).click();
}
const relayHintMatches = (page, pattern) =>
  page.waitForFunction((source) => new RegExp(source).test(document.getElementById("relay-hint").textContent), pattern.source);

test("Settings turns the app's relay on and off with the page token and says where it stands", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Settings" }).click();
  const sw = page.locator("#relay-switch");
  const awake = page.locator("#relay-awake-switch");
  await relayHintMatches(page, /^Off\. One Touch ID connects to keysrs-relay\.example\.workers\.dev until you turn it off or quit Keysrs\.$/);
  assert.equal(await sw.getAttribute("aria-checked"), "false");
  assert.equal(await sw.isDisabled(), false);
  assert.equal(await awake.getAttribute("aria-checked"), "false", "keeping the Mac awake is off by default");

  await sw.click();
  await page.waitForFunction(() => document.getElementById("relay-switch").getAttribute("aria-checked") === "true");
  await relayHintMatches(page, /^Connected to keysrs-relay\.example\.workers\.dev since \d\d:\d\d$/);
  const posts = requests.filter((r) => r.method === "POST" && r.pathname === "/api/relay");
  assert.equal(posts.length, 1, "one toggle, one call");
  assert.ok(posts[0].token, "the toggle carries the page token");
  assert.equal(relay.on, true);

  await awake.click();
  await page.waitForFunction(() => document.getElementById("relay-awake-switch").getAttribute("aria-checked") === "true");
  assert.equal(relay.stay_awake, true);
  assert.equal(relay.on, true, "the awake choice leaves the relay as it was");

  // Open calls and a held assertion are on the same line.
  Object.assign(relay, { inflight: 2, awake: true });
  await reopenSettings(page);
  await relayHintMatches(page, /since \d\d:\d\d · 2 calls open · keeping the Mac awake$/);

  // A dropped socket: the line says it is retrying, when, and why.
  Object.assign(relay, {
    state: "waiting", connected_since: null, inflight: 0, awake: false,
    retry_at: new Date(Date.now() + 8000).toISOString(),
    last_error: "connection to keysrs-relay.example.workers.dev lost: The network connection was lost.",
  });
  await reopenSettings(page);
  await relayHintMatches(page, /^Not connected; retrying at \d\d:\d\d\. connection to keysrs-relay\.example\.workers\.dev lost/);

  await sw.click();
  await page.waitForFunction(() => document.getElementById("relay-switch").getAttribute("aria-checked") === "false");
  assert.equal(relay.on, false);
  await relayHintMatches(page, /^Off\./);
  // The choice to keep the Mac awake outlives the relay being off.
  assert.equal(await awake.getAttribute("aria-checked"), "true");
});

test("the relay switch says why it cannot turn on: not set up, a Terminal relay, a refusal", async (page, origin) => {
  Object.assign(relay, { configured: false, url: null });
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Settings" }).click();
  const sw = page.locator("#relay-switch");
  await relayHintMatches(page, /^Not set up yet: deploy the Worker \(docs\/relay\.md\), then run keys relay setup --url/);
  assert.equal(await sw.isDisabled(), true);

  Object.assign(relay, { configured: true, url: "https://keysrs-relay.example.workers.dev", elsewhere: true, elsewhere_pid: 4242 });
  await reopenSettings(page);
  await relayHintMatches(page, /^keys relay is running in a Terminal \(process 4242\); stop it there/);
  assert.equal(await sw.isDisabled(), true);

  // The Terminal relay is gone by the time the page looks, and back by the time it asks.
  relay.elsewhere = false;
  await reopenSettings(page);
  await relayHintMatches(page, /^Off\./);
  relay.elsewhere = true;
  await sw.click();
  await page.waitForFunction(() => /keys relay is already running on this Mac \(process 4242\)/.test(document.getElementById("status").textContent));
  assert.equal(await sw.getAttribute("aria-checked"), "false");
  await relayHintMatches(page, /^keys relay is running in a Terminal \(process 4242\)/);
  assert.equal(relay.on, false);
});

// ---------- Settings: the Keysrs app's own choices ----------

// The meter, the menu-bar item and automatic updates are persisted in the catalog, not this
// browser, so the app menu shows the same values. Each write rides the page token and answers the
// whole persisted state; a reload reads the store, not a browser copy.
test("Settings shows the app's persisted choices and writes each one with the page token", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Settings" }).click();
  const meter = page.locator("#meter-switch");
  const menubar = page.locator("#menubar-item-switch");
  const autoUpdate = page.locator("#auto-update-switch");
  await page.waitForFunction(() => document.getElementById("meter-switch").getAttribute("aria-checked") === "true");
  assert.equal(await menubar.getAttribute("aria-checked"), "false", "the menu bar item starts off");
  assert.equal(await autoUpdate.getAttribute("aria-checked"), "true", "automatic updates start on");

  await menubar.click();
  await page.waitForFunction(() => document.getElementById("menubar-item-switch").getAttribute("aria-checked") === "true");
  const posts = requests.filter((r) => r.method === "POST" && r.pathname === "/api/preferences/menubar-item");
  assert.equal(posts.length, 1);
  assert.equal(posts[0].token, "test-token", "the write carries the page token");
  assert.deepEqual(posts[0].body, { on: true });
  assert.equal(preferences.menubar_item, true, "the engine stored the choice");

  await autoUpdate.click();
  await page.waitForFunction(() => document.getElementById("auto-update-switch").getAttribute("aria-checked") === "false");
  assert.equal(preferences.update_checks, false);
  assert.equal(preferences.show_usage_meter, true, "a write to one choice leaves the others alone");
  assert.equal(preferences.menubar_item, true);

  // A reload reads the persisted truth, not a browser copy.
  await page.reload();
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Settings" }).click();
  await page.waitForFunction(() => document.getElementById("menubar-item-switch").getAttribute("aria-checked") === "true");
  assert.equal(await autoUpdate.getAttribute("aria-checked"), "false");
});

// The meter is the Usage pane's plan windows. Hiding it takes them off screen only: the month's
// totals line and the Chart stay, and turning it back on renders them from the same status.
test("Show usage meter off hides the meter without removing the data, and on restores it", async (page, origin) => {
  plans = [subPlan()];
  localRows = subscriptionRows();
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.locator("#live-status .live-row").first().waitFor();
  assert.equal(await page.locator("#live-status .live-row").count(), 1);

  await page.getByRole("tab", { name: "Settings" }).click();
  await page.locator("#meter-switch").click();
  await page.waitForFunction(() => document.getElementById("meter-switch").getAttribute("aria-checked") === "false");
  assert.equal(preferences.show_usage_meter, false);

  await page.getByRole("tab", { name: "Usage" }).click();
  await page.waitForFunction(() => document.getElementById("live-status").hidden === true);
  assert.equal(await page.locator("#live-status .live-row").count(), 0, "the meter is hidden");
  assert.equal(await page.locator("#usage-empty").isHidden(), true, "a hidden meter does not read as no plan windows");
  // The month's totals line is not the meter, so it stays.
  await page.locator("#usage-totals b").first().waitFor();

  await page.getByRole("tab", { name: "Settings" }).click();
  await page.locator("#meter-switch").click();
  await page.waitForFunction(() => document.getElementById("meter-switch").getAttribute("aria-checked") === "true");
  await page.getByRole("tab", { name: "Usage" }).click();
  await page.locator("#live-status .live-row").first().waitFor();
  assert.equal(await page.locator("#live-status .live-row").count(), 1, "the meter returns from the same data");
});

// Quit and the relay controls are reachable from Settings while the window is shown, even with the
// menu-bar item off. Quit posts to the app's own route; it answers before it terminates, so the
// fetch sees its 200 rather than a dropped connection.
test("with the menu bar item off, Settings still carries Quit and the relay controls", async (page, origin) => {
  preferences.menubar_item = false;
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Settings" }).click();
  await page.waitForFunction(() => document.getElementById("menubar-item-switch").getAttribute("aria-checked") === "false");
  assert.equal(await page.locator("#relay-switch").isVisible(), true);
  assert.equal(await page.locator("#relay-switch").isDisabled(), false, "the relay is reachable though the menu bar item is off");
  assert.equal(await page.locator("#relay-awake-switch").isVisible(), true);
  assert.equal(await page.locator("#btn-quit").isVisible(), true);

  await page.locator("#btn-quit").click();
  await page.waitForFunction(() => /Quitting Keysrs/.test(document.getElementById("status").textContent));
  const posts = requests.filter((r) => r.method === "POST" && r.pathname === "/api/app/quit");
  assert.equal(posts.length, 1);
  assert.equal(posts[0].token, "test-token", "Quit carries the page token");
  assert.equal(await page.locator("#btn-quit").isDisabled(), true, "Quit is not clickable twice");
  assert.match(await page.locator("#quit-hint").textContent(), /Quitting Keysrs/);
});

// ---------- Settings: which cards Usage shows ----------

// Hiding a card is a display choice. The subscription, its history and the Chart stay as they were,
// so hidden never reads as zero and nothing is deleted on the engine's side.
test("hiding a usage card in Settings takes it off Usage only and survives a reload", async (page, origin) => {
  plans = [subPlan(), { ...subPlan({ subscription_id: "sub-2", title: "Copilot", source: "copilot" }) }];
  localRows = subscriptionRows();
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.locator("#live-status .live-row").nth(1).waitFor();
  assert.equal(await page.locator("#live-status .live-row").count(), 2);

  await page.getByRole("tab", { name: "Settings" }).click();
  const cursor = page.locator('#usage-cards-list [data-usage-id="sub-1"]');
  assert.equal(await cursor.getAttribute("aria-checked"), "true", "every card starts shown");
  await cursor.click();
  assert.equal(await cursor.getAttribute("aria-checked"), "false");

  await page.getByRole("tab", { name: "Usage" }).click();
  assert.equal(await page.locator("#live-status .live-row").count(), 1);
  assert.match(await page.locator("#live-status").textContent(), /Copilot/);
  assert.doesNotMatch(await page.locator("#live-status").textContent(), /Cursor/);
  // No "N cards hidden" count on the pane: Settings is where the choice lives and is undone.
  assert.equal(await page.locator("#usage-hidden").isHidden(), true);
  assert.doesNotMatch(await page.locator("#pane-usage").innerText(), /hidden/);
  assert.equal(requests.filter((r) => r.method === "DELETE").length, 0, "hiding deletes nothing");

  await page.reload();
  await page.waitForLoadState("networkidle");
  await page.locator("#live-status .live-row").first().waitFor();
  assert.equal(await page.locator("#live-status .live-row").count(), 1, "the choice is remembered");

  // The Chart still asks for everything; Settings is not a filter on history.
  const before = requests.filter((r) => r.pathname === "/api/spend").length;
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#mix .mix-row").first().waitFor();
  assert.ok(requests.filter((r) => r.pathname === "/api/spend").length >= before);
  assert.equal(await page.locator("#mix .mix-row").count() > 0, true);

  // Settings is where the card is turned on again.
  await page.getByRole("tab", { name: "Settings" }).click();
  assert.equal(await page.locator("#pane-settings").isVisible(), true);
  await page.locator('#usage-cards-list [data-usage-id="sub-1"]').click();
  await page.getByRole("tab", { name: "Usage" }).click();
  assert.equal(await page.locator("#live-status .live-row").count(), 2);
  assert.equal(await page.locator("#usage-hidden").isHidden(), true);
});

test("with every card hidden Usage says so instead of claiming there is nothing", async (page, origin) => {
  plans = [subPlan()];
  await page.addInitScript(() => { try { localStorage.setItem("ksf.hiddenUsage", JSON.stringify(["sub-1"])); } catch { /* fine */ } });
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.locator("#usage-hidden").waitFor();
  assert.match(await page.locator("#usage-hidden").textContent(), /All usage cards are hidden/);
  assert.equal(await page.locator("#live-status .live-row").count(), 0);
  assert.equal(await page.locator("#usage-empty").isHidden(), true, "hidden is not the same as empty");
});

test("Droid stays off Usage until Settings turns it on, and is never removed", async (page, origin) => {
  plans = [droidPlan(), subPlan()];
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.locator("#live-status .live-row").first().waitFor();
  assert.equal(await page.locator('#live-status .live-row[data-source="droid"]').count(), 0);
  // Off by default is not announced on the pane; the switch in Settings is where it lives.
  assert.equal(await page.locator("#usage-hidden").isHidden(), true);

  await page.getByRole("tab", { name: "Settings" }).click();
  const sw = page.locator("#droid-switch");
  assert.equal(await sw.getAttribute("aria-checked"), "false");
  assert.equal(await page.locator('#usage-cards-list [data-usage-id="droid"]').count(), 0, "Droid has its own switch");
  await sw.click();
  assert.equal(await sw.getAttribute("aria-checked"), "true");
  await page.getByRole("tab", { name: "Usage" }).click();
  await page.locator('#live-status .live-row[data-source="droid"]').waitFor();
  assert.equal(await page.locator("#usage-hidden").isHidden(), true);
  await page.reload();
  await page.waitForLoadState("networkidle");
  await page.locator('#live-status .live-row[data-source="droid"]').waitFor();
});

// ---------- key search ----------

test("key search filters by name, provider and host, counts what it shows and clears on Escape", async (page, origin) => {
  keys.find((k) => k.name === "bravo").host = "api.example.test";
  keys.find((k) => k.name === "charlie").gateway_host = "gw.typesafe.test";
  await page.goto(`${origin}/#keys`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator("#keys-body .key-row[data-name]").first().waitFor();
  const names = () => page.locator("#keys-body .key-row[data-name]").evaluateAll((rows) => rows.map((r) => r.dataset.name));
  assert.equal(await page.locator("#keys-body > :not(.key-row)").count(), 0, "a flat list, no provider headers");
  assert.equal(await page.locator("#keys-search").getAttribute("placeholder"), "Search keys or providers…");

  // "/" jumps to the search box from anywhere on the Keys pane.
  await page.locator("body").click();
  await page.keyboard.press("/");
  assert.equal(await page.evaluate(() => document.activeElement.id), "keys-search");

  await page.keyboard.type("open");
  assert.deepEqual(await names(), ["alpha"], "provider names match");
  assert.equal(await page.locator("#keys-count").textContent(), "1 of 3 keys");

  await page.locator("#keys-search").fill("CHAR");
  assert.deepEqual(await names(), ["charlie"], "case does not matter");

  // The grant host and the gateway host are matchable too, and so is the provider's group name
  // ("Labs" holds all three fixture providers; nothing else carries that string).
  await page.locator("#keys-search").fill("example.test");
  assert.deepEqual(await names(), ["bravo"], "hosts match");
  await page.locator("#keys-search").fill("gw.typesafe");
  assert.deepEqual(await names(), ["charlie"], "gateway hosts match");
  await page.locator("#keys-search").fill("labs");
  assert.deepEqual(await names(), ["alpha", "bravo", "charlie"], "provider group names match");

  await page.locator("#keys-search").fill("nothing-like-this");
  assert.deepEqual(await names(), []);
  assert.match(await page.locator("#keys-no-match").textContent(), /No keys match “nothing-like-this”/);
  assert.equal(await page.locator("#keys-empty").isHidden(), true, "a miss is not an empty vault");

  await page.locator("#keys-search").press("Escape");
  assert.equal(await page.locator("#keys-search").inputValue(), "");
  assert.deepEqual(await names(), ["alpha", "bravo", "charlie"]);
  assert.equal(await page.locator("#keys-count").textContent(), "3 keys");
  assert.equal(await page.locator("#keys-no-match").isHidden(), true);
  assert.doesNotMatch(await page.locator("#keys-body").textContent(), new RegExp(SECRET));
});

// The box jumped under the cursor: the count before it grew from "3 keys" to "1 of 3 keys" and
// pushed the box right, and a grow-to-fit width changed with it. Position and size are now fixed
// whatever the count says, whether results run out, and whatever appears below the table.
test("the search box keeps its place and size while typing, including on a miss", async (page, origin) => {
  await openKeys(page, origin);
  const box = page.locator("#keys-search");
  const rect = async () => {
    const r = await box.boundingBox();
    return { x: Math.round(r.x * 10) / 10, y: Math.round(r.y * 10) / 10, w: Math.round(r.width * 10) / 10, h: Math.round(r.height * 10) / 10 };
  };
  const start = await rect();
  const seen = [];
  for (const query of ["o", "open", "CHAR", "nothing-like-this", "", "anthropic", "zzz", ""]) {
    await box.fill(query);
    await page.waitForFunction((q) => {
      const count = document.getElementById("keys-count").textContent;
      return q ? /of 3 keys/.test(count) : /^3 keys/.test(count);
    }, query);
    seen.push([query, await page.locator("#keys-count").textContent(), await rect(), await page.locator("#keys-no-match").isVisible()]);
  }
  for (const [query, count, r] of seen) {
    assert.deepEqual(r, start, `after typing "${query}" (count "${count}") the box moved or resized`);
  }
  assert.match(seen[3][1], /0 of 3 keys/);
  assert.equal(seen[3][3], true, "the miss line showed on the miss and still moved nothing");
  // The count sits on the line below the box, so it cannot push the box around.
  const countBox = await page.locator("#keys-count").boundingBox();
  assert.ok(countBox.y >= start.y + start.h, "the count is below the box");
});

// A relayed or tunnelled call lands in the catalog with nobody touching the page. The Keys pane
// used to show the vault as it was when the pane was entered, so a key with fresh gateway calls
// showed no gateway calls until a reload or a pane switch.
test("a catalog change while the Keys pane is open refreshes the gateway figures", async (page, origin) => {
  await page.clock.install();
  await openKeys(page, origin);
  assert.equal(await gatewayText(page, "bravo"), null, "no figure before any call");
  const before = requests.filter((r) => r.pathname === "/api/keys").length;

  // Two calls arrive through the relay for bravo: the engine's month count and version move.
  keys.find((k) => k.name === "bravo").gateway_month_calls = 2;
  keys.find((k) => k.name === "bravo").last_used_at = "2026-09-20T12:30:00Z";
  catalogVersion += 1;
  await page.clock.runFor(16000);
  await page.waitForFunction(() => /2 requests/.test(document.querySelector('#keys-body .key-row[data-name="bravo"] .key-gateway')?.textContent));
  assert.ok(requests.filter((r) => r.pathname === "/api/keys").length > before, "the list was fetched again");

  // An unchanged version fetches nothing: the poll is not a reload loop.
  const after = requests.filter((r) => r.pathname === "/api/keys").length;
  await page.clock.runFor(16000);
  await page.waitForFunction(() => document.getElementById("keys-body").children.length > 0);
  assert.equal(requests.filter((r) => r.pathname === "/api/keys").length, after);
});

// Every action the engine audits has words here. client_issue, client_revoke and gateway_denied
// used to fall through as raw names, and a loopback gateway call was credited to the dashboard.
test("the key History drawer names every audited action and caller in words", async (page, origin) => {
  keyEvents = [
    { ts: "2026-09-20T12:04:00Z", action: "client_revoke", caller: "dashboard", detail: "#3" },
    { ts: "2026-09-20T12:03:00Z", action: "gateway_denied", caller: "gateway", detail: "grant_required" },
    { ts: "2026-09-20T12:02:00Z", action: "gateway_call", caller: "relay", detail: "claude-sonnet-5" },
    { ts: "2026-09-20T12:01:00Z", action: "gateway_call", caller: "gateway", detail: "claude-sonnet-5" },
    { ts: "2026-09-20T12:00:00Z", action: "client_issue", caller: "cli", detail: "#3 my script 30d POST" },
  ];
  await openKeys(page, origin);
  await rowAct(page, "alpha", "history");
  await page.locator("#keys-body .key-events li").first().waitFor();
  assert.deepEqual(await page.locator("#keys-body .key-events .ev-action").allTextContents(),
    ["client revoked", "gateway refused", "gateway call", "gateway call", "client issued"]);
  assert.deepEqual(await page.locator("#keys-body .key-events .ev-caller").allTextContents(),
    ["dashboard", "local gateway", "relay", "local gateway", "command line"]);
  assert.doesNotMatch(await page.locator("#keys-body .key-events").textContent(), /client_issue|gateway_denied|client_revoke/);
});

// "from Grok's own cost log" belongs to Grok's receipt alone. With Droid chosen, or Claude at
// $0.00, the USD totals bar and Copy totals used to say it because no estimate was above zero.
test("USD totals name Grok's cost log only when Grok alone has dollars, and Droid is not priced", async (page, origin) => {
  localRows = [
    { source: "claude-local", model: "claude-sonnet-5", input_tokens: 100, output_tokens: 50, usd: null, usd_estimate: 0 },
    { source: "droid-local", model: "gpt-6-pro", input_tokens: 400, output_tokens: 100, usd: null, usd_estimate: null },
    { source: "grok-local", model: "grok-4", input_tokens: 500, output_tokens: 200, usd: 0.01, usd_estimate: null },
  ];
  await page.goto(`${origin}/?range=week`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator("#mix .mix-row").first().waitFor();
  await chooseUsd(page);
  await page.evaluate(() => { window.__copied = ""; navigator.clipboard.writeText = async (t) => { window.__copied = t; }; });
  const copyTotals = async () => {
    await page.evaluate(() => { window.__copied = ""; });
    await page.keyboard.press("Shift+C");
    await page.waitForFunction(() => window.__copied);
    return page.evaluate(() => window.__copied);
  };
  const pick = async (name) => {
    await page.getByRole("radio", { name, exact: true }).click();
    await page.waitForFunction((n) => document.querySelector(`#source-chips [data-source="${n.toLowerCase()}"]`).getAttribute("aria-checked") === "true", name);
  };

  // All: Grok is the only tool with dollars, so its receipt is named.
  assert.match(await totalsText(page), /from Grok's own cost log/);

  await pick("Claude");
  await page.waitForFunction(() => !/Grok's own cost log/.test(document.getElementById("totals").textContent));
  const claude = await totalsText(page);
  assert.equal(await page.locator("#totals .totals-main").textContent(), "$0", "a zero estimate is still shown as the estimate it is: " + claude);
  assert.match(claude, /estimate from list prices/);
  const claudeMd = await copyTotals();
  assert.match(claudeMd, /Estimated from the tools' own local logs/);
  assert.doesNotMatch(claudeMd, /Grok's own cost log/);

  await pick("Droid");
  await page.waitForFunction(() => /not priced/.test(document.getElementById("totals").textContent));
  const droid = await totalsText(page);
  assert.match(droid, /Droid's own local log/);
  assert.doesNotMatch(droid, /\$0\.00|Grok's own cost log|estimate from list prices/, droid);
  const droidMd = await copyTotals();
  assert.match(droidMd, /Droid/);
  assert.match(droidMd, /not priced/);
  assert.doesNotMatch(droidMd, /\$0\.00|Grok's own cost log/, droidMd);

  await pick("Grok");
  await page.waitForFunction(() => /from Grok's own cost log/.test(document.getElementById("totals").textContent));
  assert.match(await copyTotals(), /From Grok's own cost log/);
});

// First run: an empty vault gets the walkthrough, every step a command you can copy as is; the
// same section lives under ? and behind Settings → Guide afterwards.
test("the first-use guide walks through the command line, a key, an agent, tokens and the relay", async (page, origin) => {
  keys = [];
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.locator("#onboard:visible").waitFor();
  const text = await page.locator("#onboard").textContent();
  assert.match(text, /Use with coding agents/);
  for (const needle of ["Install Command Line Tool", "keys --help", "keys add ", "keys agent claude", "keys setup codex", "keys setup droid",
    "keys grant ", "--paths /messages", "/v1/messages", "keys client issue", "http://127.0.0.1:12767/", "ANTHROPIC_BASE_URL",
    "keys relay setup --url", "docs/relay.md"]) {
    assert.ok(text.includes(needle), `the guide names ${JSON.stringify(needle)}`);
  }
  assert.doesNotMatch(text, /sk-|ksf_[0-9a-f]|ksfc_[0-9a-f]/, "no token or key value, real or invented");

  // Each Copy button copies exactly the static command beside it, never anything else.
  await page.evaluate(() => { window.__copied = ""; navigator.clipboard.writeText = async (t) => { window.__copied = t; }; });
  const buttons = page.locator("#onboard [data-copy-cmd]");
  const n = await buttons.count();
  assert.ok(n >= 7, `copyable commands: ${n}`);
  for (let i = 0; i < n; i++) {
    await page.evaluate(() => { window.__copied = ""; });
    await buttons.nth(i).click();
    await page.waitForFunction(() => window.__copied);
    const copied = await page.evaluate(() => window.__copied);
    assert.equal(copied, await page.locator("#onboard .cmd code").nth(i).textContent());
    assert.match(copied, /^(keys |export )/, copied);
  }
  assert.equal(await page.locator("#onboard .cmd code").evaluateAll((els) => els.filter((e) => e.id).length), 0, "the clone carries no ids");

  // Still there after the card is dismissed: under ?, and from Settings.
  await page.locator("#onboard-dismiss").click();
  await page.getByRole("tab", { name: "Settings" }).click();
  await page.getByRole("button", { name: "Guide", exact: true }).click();
  await waitDialog(page, "dlg-help", true);
  assert.match(await page.locator("#dlg-help").textContent(), /Use with coding agents/);
  assert.equal(await page.locator("#guide-agents-title").count(), 1, "one copy of the id, in the dialog");
});

test("arrow keys step through the flat list from the search box", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator("#keys-body .key-row[data-name]").first().waitFor();
  await page.locator("#keys-search").focus();
  // Nothing is selected yet on a fresh load; ArrowDown from the search box still lands on the
  // first key row rather than doing nothing.
  await page.keyboard.press("ArrowDown");
  const selected = () => page.evaluate(() => document.activeElement.closest(".key-row")?.dataset.name || null);
  assert.equal(await selected(), "alpha");
  await page.keyboard.press("ArrowDown");
  assert.equal(await selected(), "bravo", "the next key, whatever its provider");
  await page.keyboard.press("ArrowDown");
  assert.equal(await selected(), "charlie");
  await page.keyboard.press("ArrowUp");
  assert.equal(await selected(), "bravo");
  assert.equal(await page.locator('#keys-body [aria-current="true"]').getAttribute("data-name"), "bravo");
});



// ---------- imported cloud usage ----------

// Usage from a cloud session or a remote droid run is imported, never read off this Mac, so it
// has its own chip and the Usage line stops calling the total "from local logs".
test("the Cloud chip shows imported remote usage, kimi-k3 included, and names it on Usage", async (page, origin) => {
  localRows = [
    ...subscriptionRows(),
    { source: "droid-remote", model: "kimi-k3", input_tokens: 400, output_tokens: 50, cached_read_tokens: 2000, cache_creation_tokens: 0, reasoning_tokens: 10, usd: null, usd_estimate: null },
    { source: "droid-remote", model: "unattributed", input_tokens: 100, output_tokens: 100, cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 0, usd: null, usd_estimate: null },
  ];
  await page.goto(`${origin}/?range=week`);
  await page.waitForLoadState("networkidle");
  await page.locator("#usage-totals b").first().waitFor();
  const usage = await page.locator("#usage-totals").textContent();
  assert.match(usage, /This month from local logs\s*2\.4K tokens/, "the local share stands alone: " + usage);
  assert.match(usage, /2\.7K imported from cloud \(not priced\)/, "the imported share is separate: " + usage);

  // USD on Usage: local dollars, with the cloud tokens noted as not priced rather than dropped.
  await page.locator("#usage-totals").getByText("show USD").click();
  await page.waitForFunction(() => /tokens imported from cloud \(not priced\)/.test(document.getElementById("usage-totals").textContent));
  await page.locator("#usage-totals").getByText("show tokens").click().catch(() => {});

  await page.getByRole("tab", { name: "Chart" }).click();
  // All view with imports acknowledges them.
  await page.waitForFunction(() => /imported from the cloud/.test(document.getElementById("chart-caption").textContent));
  await page.locator('[data-source="cloud"]').click();
  await page.waitForFunction(() => document.querySelectorAll("#mix .mix-row").length === 2);
  // Tokens view on Cloud: imported wording, never "local logs".
  const cloudText = async () => (await page.locator("#chart-caption").textContent()) + " " + (await page.locator("#totals").textContent());
  let ct = await cloudText();
  assert.match(ct, /imported/i);
  assert.doesNotMatch(ct, /local logs|Grok's own cost log/, ct);
  // USD view on Cloud: "not priced", not a measured $0.00.
  await page.locator('[data-unit="usd"]').click();
  await page.waitForFunction(() => /not priced/.test(document.getElementById("totals").textContent));
  ct = await cloudText();
  assert.doesNotMatch(ct, /\$0\.00|local logs|Grok's own cost log/, ct);
  await page.evaluate(() => { window.__copied = ""; navigator.clipboard.writeText = async (t) => { window.__copied = t; }; });
  await page.keyboard.press("Shift+C");
  await page.waitForFunction(() => window.__copied);
  const copied = await page.evaluate(() => window.__copied);
  assert.ok(copied, "Copy totals produced text");
  assert.doesNotMatch(copied, /\$0\.00|local logs|Grok's own cost log/, copied);
  await page.locator('[data-unit="tokens"]').click();
  assert.ok(spendSearches().some((s) => s.includes("source=cloud")), "the chip reaches the engine as source=cloud");
  const mix = await page.locator("#mix").textContent();
  assert.match(mix, /kimi-k3/);
  assert.match(mix, /unattributed/, "a session total that cannot be split says so instead of borrowing a model");
  assert.doesNotMatch(mix, /claude-sonnet-5|grok-4/, "local rows stay out of Cloud");
  assert.match(page.url(), /source=cloud/);

  // Nothing imported in range: the empty state says how usage gets here.
  localRows = subscriptionRows();
  await page.reload();
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.waitForFunction(() => /No imported cloud usage/.test(document.getElementById("spend-empty").textContent));
  assert.equal(await page.locator('[data-source="cloud"]').getAttribute("aria-checked"), "true", "?source=cloud boots into the chip");
  assert.match(await page.locator("#spend-empty").textContent(), /keys usage import/);
});

test("a model with local and imported tokens: families stay local, the dollar row is partly priced", async (page, origin) => {
  localRows = [
    ...subscriptionRows(),
    { source: "claude-local", model: "claude-sonnet-5", input_tokens: 0, output_tokens: 0, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: null },
    { source: "claude-remote", model: "claude-sonnet-5", input_tokens: 5000, output_tokens: 0, cached_read_tokens: 0, cache_creation_tokens: 0, usd: null, usd_estimate: null },
  ];
  await page.goto(`${origin}/?range=week`);
  await page.waitForLoadState("networkidle");
  await page.locator("#usage-totals b").first().waitFor();
  const usage = await page.locator("#usage-totals").textContent();
  assert.match(usage, /1\.7K Claude/, "the Claude part is the local tokens only: " + usage);
  assert.match(usage, /5K imported from cloud \(not priced\)/, usage);
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.locator('[data-unit="usd"]').click();
  await page.waitForFunction(() => /partly priced/.test(document.getElementById("mix").textContent));
  const row = page.locator('#mix .mix-row[data-model="claude-sonnet-5"]');
  assert.match(await row.textContent(), /partly priced/);
  assert.match(await row.locator(".mix-usd").getAttribute("title"), /not priced/);
  assert.doesNotMatch(await page.locator('#mix .mix-row[data-model="grok-4"]').textContent(), /partly priced/);
});

test("the All empty state and the ingest wording name imported cloud usage and Droid", async (page, origin) => {
  localRows = [];
  emptyIngested = true;
  await page.goto(`${origin}/?range=week`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Chart" }).click();
  await page.waitForFunction(() => /Nothing in this range/.test(document.getElementById("spend-empty").textContent));
  assert.match(await page.locator("#spend-empty").textContent(), /imported cloud usage/);
  assert.match(await page.locator("#btn-ingest").getAttribute("title"), /Droid/);
  emptyIngested = false;
});

test("without imports the Usage line still says local logs", async (page, origin) => {
  localRows = subscriptionRows();
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.locator("#usage-totals b").first().waitFor();
  const text = await page.locator("#usage-totals").textContent();
  assert.match(text, /This month from local logs /);
  assert.doesNotMatch(text, /cloud imports/);
});

(async () => {
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
  } finally {
    await browser.close();
    server.close();
  }
  if (failed.length) {
    console.error(`\nKeys dashboard UI: ${failed.length} of ${checks.length} failed: ${failed.join(", ")}`);
    process.exit(1);
  }
  console.log(`\nKeys dashboard UI passed: ${checks.length} cases`);
})().catch((error) => { console.error(error); process.exit(1); });

}
