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
let keys, ledger, localRows, plans, failures, delays, requests, unexpected, fixtureSecrets, rotations, customProviders, hiddenUsers, limits, subscriptions, nextSubId;

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
  if (keyMatch && leaf === "/events") return [200, { events: [] }];
  if (keyMatch && leaf === "/clients") return [200, { clients: [] }];
  if (pathname === "/api/grants") return [200, { grants: [] }];
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
  if (pathname === "/api/status") return [200, { plans }];
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

// Droid is off the Usage pane by default (Settings → Show Droid on Usage); the tests about its
// card turn it on before the page loads.
const showDroidOnUsage = (page) => page.addInitScript(() => { try { localStorage.setItem("ksf.showDroid", "1"); } catch { /* fine */ } });

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
  // Grouped by provider name (Anthropic, OpenAI, TypeSafe), then by name inside a group.
  assert.deepEqual(await rowNames(page), ["bravo", "alpha", "charlie"]);
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
  assert.deepEqual(await rowNames(page), ["bravo", "alpha"]);
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
  assert.deepEqual(await rowNames(page), ["bravo", "alpha", "delta", "charlie"]);
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
  assert.deepEqual(await rowNames(page), ["bravo", "alpha", "charlie"], "nothing is removed optimistically");

  failures.delete(rule("DELETE", "/api/keys/charlie"));
  await page.locator("#delete-confirm").click();
  await waitDialog(page, "dlg-delete", false);
  await page.waitForFunction(() => !document.querySelector('#keys-body tr[data-name="charlie"]'));
  assert.deepEqual(await rowNames(page), ["bravo", "alpha"]);
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
  // Rows are grouped by provider: bravo (Anthropic), alpha (OpenAI), charlie (TypeSafe). The
  // group label rows between them are never a stop.
  await focusRow(page, "bravo");
  await page.keyboard.press("ArrowDown");
  assert.equal(await focused(page), "alpha");
  await page.keyboard.press("End");
  assert.equal(await focused(page), "charlie");
  await page.keyboard.press("j");
  assert.equal(await focused(page), "charlie", "the list clamps at the end");
  await page.keyboard.press("Home");
  await page.keyboard.press("k");
  assert.equal(await focused(page), "bravo", "and at the start");

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

  plans = [{ source: "grok-bot", title: "Grok Bot", kind: "subscription", weekly_prompts: 0, usage_note: "No Grok Bot prompts this week." }];
  await page.reload();
  await page.waitForLoadState("networkidle");
  await page.locator("#live-status .live-more").waitFor();
  assert.equal(await page.locator('#live-status .live-row[data-source="grok-bot"]').count(), 0);
  assert.match(await page.locator("#live-status .live-absent").textContent(), /Grok Bot/);
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
  // The placeholder Cursor row is gone from the collapsed group; a tool without a subscription
  // keeps its own placeholder.
  const absent = await page.locator("#live-status .live-absent").textContent();
  assert.doesNotMatch(absent, /Cursor/);
  assert.match(absent, /Gemini/);
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
  assert.match(await page.locator("#live-status .live-absent").textContent(), /Cursor/, "the placeholder Cursor returns to the collapsed group");
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
  // Dark blue is the default face; Claude's orange there is the lighter shade that reads on it.
  assert.equal(palette.claude, "#e08a6a", "Claude's shade is orange in the dark-blue face");
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
test("dark blue is the default, Settings switches to the site's light look and it survives a reload", async (page, origin) => {
  // The OS preference never decides: a light system still opens dark blue.
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
  }));
  const dark = await read();
  assert.equal(dark.attr, null);
  assert.equal(dark.meta, "dark light");
  assert.equal(dark.scheme, "dark");
  assert.equal(dark.bodyBg, "rgb(14, 23, 48)", "the page sits on the dark-blue #0e1730");
  assert.equal(dark.bodyInk, "rgb(232, 237, 248)");
  assert.equal(dark.paneRadius, "18px", "the pane is still a rounded card");
  assert.equal(dark.blue, "#4c9aff");

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

test("every pane fits the viewport at 390, 1280 and 1920 px, and nothing loads off-origin", async (page, origin) => {
  const foreign = [];
  page.on("request", (r) => { if (new URL(r.url()).origin !== origin) foreign.push(r.url()); });
  plans = [droidPlan()];
  localRows = subscriptionRows();
  await showDroidOnUsage(page);
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  for (const width of [390, 1280, 1920]) {
    await page.setViewportSize({ width, height: 900 });
    for (const pane of ["Usage", "Chart", "Keys", "Settings"]) {
      await page.getByRole("tab", { name: pane, exact: true }).click();
      if (pane === "Usage") await page.locator("#live-status .live-row").first().waitFor();
      else if (pane === "Chart") await page.locator("#daily-svg").waitFor();
      else if (pane === "Keys") await page.locator("#keys-body tr[data-name]").first().waitFor();
      else await page.locator("#theme-switch").waitFor();
      const spill = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(spill <= 1, `${pane} pane spills ${spill}px at ${width}px`);
    }
  }
  assert.deepEqual(foreign, [], "every request stays on the dashboard's own origin");
});

// The header used to carry every control, so on the Keys pane with a status message the right
// column spilled under the tabs. It now holds only the status line and help.
test("the header stays one row and never slides under the tabs from 760 px up", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.evaluate(() => { document.getElementById("status").textContent = "Ingested 1,234 new rows from 56 files, 3 parse errors. ".repeat(3); });
  for (const width of [760, 900, 1180, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    for (const pane of ["Usage", "Chart", "Keys", "Settings"]) {
      await page.getByRole("tab", { name: pane, exact: true }).click();
      const g = await page.evaluate(() => {
        const r = (sel) => document.querySelector(sel).getBoundingClientRect();
        const seg = r("nav.seg"), end = r(".toolbar-end"), brand = r(".brand"), header = r("header.toolbar");
        const hit = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
        return { height: header.height, endHits: hit(seg, end), brandHits: hit(seg, brand) };
      });
      assert.ok(Math.abs(g.height - 48) <= 2, `${pane} at ${width}px: header is ${g.height}px tall`);
      assert.ok(!g.endHits, `${pane} at ${width}px: the header end overlaps the tabs`);
      assert.ok(!g.brandHits, `${pane} at ${width}px: the brand overlaps the tabs`);
    }
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
  await page.locator('#keys-body tr[data-name="alpha"]').waitFor();
  await page.getByRole("tab", { name: "Usage" }).click();
  assert.equal(await page.locator("#onboard").isHidden(), true, "an existing user is not onboarded");
});

// ---------- providers manager and agent recipes ----------

test("the providers manager adds, hides and removes", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  // Both the Add key and the Providers buttons belong to the Keys pane.
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator('#keys-body tr[data-name="alpha"]').waitFor();
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
  const tabNames = await page.locator(".seg [role=tab]").allTextContents();
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
  assert.deepEqual(await rowNames(page), ["bravo", "alpha", "foxtrot"]);

  // The slow reply, carrying the older vault, lands last.
  await page.waitForTimeout(1800);
  assert.deepEqual(await rowNames(page), ["bravo", "alpha", "foxtrot"],
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

test("key sort orders rows and survives a reload", async (page, origin) => {
  // One provider group, so the chosen sort alone decides the order inside it.
  for (const k of keys) k.provider = "openai";
  await openKeys(page, origin);
  await page.locator("#keys-body tr[data-name]").first().waitFor();
  const order = () => page.locator("#keys-body tr[data-name]").evaluateAll((rows) => rows.map((r) => r.dataset.name));
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
  await page.locator("#keys-body tr[data-name]").first().waitFor();
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
  }
});

// ---------- runner ----------

// The tester-army runner reuses this synthetic fixture, never the installed app.
module.exports = { server, reset };
if (require.main === module && process.env.KEYS_FIXTURE_PORT) {
  reset();
  server.listen(Number(process.env.KEYS_FIXTURE_PORT), "127.0.0.1");
} else if (require.main === module) {

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
  assert.match(await page.locator("#usage-hidden").textContent(), /1 card hidden/);
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

  // The link on Usage goes back to Settings, where the card can be turned on again.
  await page.getByRole("tab", { name: "Usage" }).click();
  await page.locator("#usage-hidden").getByRole("button", { name: "Settings" }).click();
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
  // Off by default still counts as hidden, so a Droid user has a pointer to where it lives.
  assert.match(await page.locator("#usage-hidden").textContent(), /1 card hidden/);

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
  await page.goto(`${origin}/#keys`);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator("#keys-body tr[data-name]").first().waitFor();
  const names = () => page.locator("#keys-body tr[data-name]").evaluateAll((rows) => rows.map((r) => r.dataset.name));
  const groups = () => page.locator("#keys-body tr.key-group").evaluateAll((rows) => rows.map((r) => r.textContent.trim()));
  assert.equal((await groups()).length, 3, "one header row per provider");

  // "/" jumps to the search box from anywhere on the Keys pane.
  await page.locator("body").click();
  await page.keyboard.press("/");
  assert.equal(await page.evaluate(() => document.activeElement.id), "keys-search");

  await page.keyboard.type("open");
  assert.deepEqual(await names(), ["alpha"], "provider names match");
  assert.match(await page.locator("#keys-count").textContent(), /1 of 3 keys/);
  assert.deepEqual((await groups()).length, 1);

  await page.locator("#keys-search").fill("CHAR");
  assert.deepEqual(await names(), ["charlie"], "case does not matter");

  await page.locator("#keys-search").fill("nothing-like-this");
  assert.deepEqual(await names(), []);
  assert.match(await page.locator("#keys-no-match").textContent(), /No keys match “nothing-like-this”/);
  assert.equal(await page.locator("#keys-empty").isHidden(), true, "a miss is not an empty vault");

  await page.locator("#keys-search").press("Escape");
  assert.equal(await page.locator("#keys-search").inputValue(), "");
  assert.deepEqual(await names(), ["bravo", "alpha", "charlie"]);
  assert.match(await page.locator("#keys-count").textContent(), /^3 keys/);
  assert.equal(await page.locator("#keys-no-match").isHidden(), true);
  assert.doesNotMatch(await page.locator("#keys-body").textContent(), new RegExp(SECRET));
});

test("arrow keys step over the provider header rows", async (page, origin) => {
  await page.goto(origin);
  await page.waitForLoadState("networkidle");
  await page.getByRole("tab", { name: "Keys" }).click();
  await page.locator("#keys-body tr[data-name]").first().waitFor();
  await page.locator("#keys-search").focus();
  await page.keyboard.press("ArrowDown");
  const selected = () => page.evaluate(() => document.activeElement.closest("tr")?.dataset.name || null);
  assert.equal(await selected(), "bravo");
  await page.keyboard.press("ArrowDown");
  assert.equal(await selected(), "alpha", "the OpenAI header between them is skipped");
  await page.keyboard.press("ArrowDown");
  assert.equal(await selected(), "charlie");
  await page.keyboard.press("ArrowUp");
  assert.equal(await selected(), "alpha");
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
