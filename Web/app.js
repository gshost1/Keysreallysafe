(() => {
  "use strict";

  // First, before anything paints: dark unless this browser chose light. An attribute plus
  // CSS variables, because the CSP allows no inline style to switch with.
  const readTheme = () => { try { return localStorage.getItem("ksf.theme") === "light" ? "light" : "dark"; } catch { return "dark"; } };
  const applyTheme = (name) => {
    if (name === "light") document.documentElement.dataset.theme = "light";
    else delete document.documentElement.dataset.theme;
  };
  applyTheme(readTheme());

  const $ = (id) => document.getElementById(id);
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");

  const readUnit = () => { try { return localStorage.getItem("ksf.unit") === "usd" ? "usd" : "tokens"; } catch { return "tokens"; } };
  // A link that names a key or a provider is a request to see that gateway ledger, so it lands in
  // the API keys scope unless the link says otherwise. `source=keys` is the wire name for that
  // scope; the four local sources are the subscription one. A link that asks for a local source
  // *and* carries a key or a provider asks for two things that cannot both be true: neither filter
  // describes a local log, and a key sent with a local source narrows those rows to nothing. The
  // explicit source wins and the gateway filters are dropped here, URL included, so a reload
  // cannot re-apply what this boot refused.
  const boot = (() => {
    const q = new URLSearchParams(location.search);
    const asked = q.get("source");
    const key = q.get("key") || null;
    const provider = q.get("provider") || null;
    if (["all", "grok", "claude", "openai", "droid", "cloud"].includes(asked)) return { source: asked, key: null, provider: null, dropped: Boolean(key || provider) };
    if (asked === "keys") return { source: "keys", key, provider, dropped: false };
    return { source: key || provider ? "keys" : "all", key, provider, dropped: false };
  })();

  const state = {
    pane: "usage",
    source: boot.source,
    range: ["today", "week", "month"].includes(new URLSearchParams(location.search).get("range")) ? new URLSearchParams(location.search).get("range") : "today",
    unit: readUnit(),
    key: boot.key,
    provider: boot.provider,
    // The subscription source to come back to when the scope leaves the API keys view.
    subSource: boot.source === "keys" ? "all" : boot.source,
    group: "model",
    eventsOpen: null,
    spend: null,
    monthSpend: null,
    series: [],
    keys: [],
    grants: [],
    clients: [],
    checkModels: [],
    selected: null,
    mixFilter: null,
    busy: false,
    colors: new Map(),
    slots: new Map(),
    providers: null,
    // The (provider, key name) pairs seen in the unfiltered API keys report, so the provider and
    // key pickers can offer every choice even while one of them is already applied. Names only:
    // a key's value never reaches this page.
    keyIndex: [],
    catalogVersion: null,
    status: null,
    // The app's relay (GET /api/relay) and what a toggle in progress is waiting for.
    relay: null,
    relayPending: null,
    // Session-only: a search is a momentary lookup, not a view to come back to.
    keySearch: "",
    keyProviderFilter: "",
  };

  // Hand-picked shades per family. It is a palette size, not a limit on how many models a family
  // may have: a fifth Claude model is still its own series, legend row and filter.
  const SLOTS = 4;
  // Family bases leave room for as many models as a family actually has, so the slot order that
  // sorts the legend and the stack can never run one family into the next.
  const FAM_BASE = { grok: 0, claude: 10000, openai: 20000, gemini: 30000, glm: 40000, kimi: 50000, deepseek: 60000, other: 70000 };
  const OTHER_SLOT = 900000;
  const OTHER = "Other models";
  const TOKEN = (document.querySelector('meta[name="ksf-token"]') || {}).content || "";

  // ---------- formatting ----------

  const trim = (x) => (x >= 100 ? x.toFixed(0) : x.toFixed(1)).replace(/\.0$/, "");
  const fmtTokens = (n) => {
    n = Number(n) || 0;
    if (n >= 1e9) return trim(n / 1e9) + "B";
    if (n >= 1e6) return trim(n / 1e6) + "M";
    if (n >= 1e3) return trim(n / 1e3) + "K";
    return String(Math.round(n));
  };
  const fmtInt = (n) => (Number(n) || 0).toLocaleString("en-US");
  const fmtUsd = (v) => {
    v = Number(v) || 0;
    if (v === 0) return "$0";
    if (v < 0.01) return "$" + v.toFixed(4);
    return "$" + v.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  };
  const fmtUsdAxis = (v) => {
    v = Number(v) || 0;
    if (v >= 1000) return "$" + trim(v / 1000) + "K";
    if (v >= 10) return "$" + Math.round(v);
    return "$" + trim(v);
  };
  const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const pad2 = (n) => String(n).padStart(2, "0");
  const isoDay = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  const parseDay = (iso) => {
    if (!iso) return null;
    const [y, m, d] = iso.split("-").map(Number);
    if (!y || !m || !d) return null;
    return { y, m, d, date: new Date(y, m - 1, d) };
  };
  const fmtDay = (iso) => {
    const p = parseDay(iso);
    if (!p) return iso || "";
    return p.date.toLocaleDateString("en-US", { month: "short", day: "numeric" });
  };
  const fmtRange = (startDay, endDay) => {
    const a = parseDay(startDay);
    const b = parseDay(endDay);
    if (!a || !b) return "";
    if (a.y === b.y && a.m === b.m) return `${MONTHS[a.m - 1]} ${a.d}–${b.d}, ${b.y}`;
    if (a.y === b.y) return `${MONTHS[a.m - 1]} ${a.d} – ${MONTHS[b.m - 1]} ${b.d}, ${b.y}`;
    return `${MONTHS[a.m - 1]} ${a.d}, ${a.y} – ${MONTHS[b.m - 1]} ${b.d}, ${b.y}`;
  };
  const fmtDate = (iso) => {
    if (!iso) return "—";
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return iso;
    return new Date(t).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
  };
  const relTime = (iso) => {
    if (!iso) return "Never";
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return iso;
    const s = (Date.now() - t) / 1000;
    if (s < 60) return "Just now";
    if (s < 3600) return Math.floor(s / 60) + " min ago";
    if (s < 86400) return Math.floor(s / 3600) + " h ago";
    if (s < 172800) return "Yesterday";
    if (s < 7 * 86400) return Math.floor(s / 86400) + " days ago";
    return new Date(t).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  };
  const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
  // "2026-09-04T15:00" -> "15:00"; tick labels use just the hour
  const fmtHour = (h) => (h || "").slice(11, 16);
  const fmtHourTick = (h) => String(Number((h || "").slice(11, 13)));

  // ---------- dom helpers ----------

  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v == null) continue;
        if (k === "class") node.className = v;
        else if (k === "text") node.textContent = v;
        else if (k === "style") {
          // CSP has no 'unsafe-inline', so a style attribute is dropped; go through CSSOM instead.
          for (const decl of String(v).split(";")) {
            const i = decl.indexOf(":");
            if (i > 0) node.style.setProperty(decl.slice(0, i).trim(), decl.slice(i + 1).trim());
          }
        }
        else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
        else node.setAttribute(k, v);
      }
    }
    for (const c of children) if (c != null) node.append(c);
    return node;
  }
  const svgEl = (tag, attrs) => {
    const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [k, v] of Object.entries(attrs || {})) node.setAttribute(k, v);
    return node;
  };
  const isTyping = (t) =>
    t && (t.tagName === "INPUT" || t.tagName === "SELECT" || t.tagName === "TEXTAREA" || t.isContentEditable);
  const openDialog = () => document.querySelector("dialog[open]");
  // The index an arrow key moves to, or -1 for any other key. Radio groups (tabs, chips, pickers)
  // wrap; lists (key rows, the mix) clamp and also take j/k, Home and End.
  function ringStep(key, i, n) {
    const dir = key === "ArrowRight" || key === "ArrowDown" ? 1 : key === "ArrowLeft" || key === "ArrowUp" ? -1 : 0;
    return dir ? (i + dir + n) % n : -1;
  }
  function listStep(key, i, n) {
    const j = key === "ArrowDown" || key === "j" ? i + 1 : key === "ArrowUp" || key === "k" ? i - 1
      : key === "Home" ? 0 : key === "End" ? n - 1 : null;
    return j === null ? -1 : Math.max(0, Math.min(n - 1, j));
  }

  let statusTimer = 0;
  function say(msg, sticky) {
    const node = $("status");
    node.textContent = msg || "";
    clearTimeout(statusTimer);
    if (msg && !sticky) statusTimer = setTimeout(() => { if (node.textContent === msg) node.textContent = ""; }, 4000);
  }

  // ---------- api (same origin only) ----------

  const UNREACHABLE = "Can't reach the local site. Is keys dashboard still running?";
  // Every mutating call carries the per-launch token the server printed into index.html.
  async function api(path, options) {
    options = options || {};
    const method = (options.method || "GET").toUpperCase();
    if (method !== "GET") {
      options.headers = Object.assign({ "X-KSF-Token": TOKEN }, options.headers || {});
    }
    let res;
    try {
      res = await fetch(path, options);
    } catch {
      setEngineDown(true);
      throw new Error(UNREACHABLE);
    }
    setEngineDown(false);
    const text = await res.text();
    let data = null;
    if (text) {
      try { data = JSON.parse(text); } catch { data = { error: text }; }
    }
    if (!res.ok) {
      const code = data && data.error;
      const err = new Error(friendly(code, res.status));
      err.status = res.status;
      throw err;
    }
    return data;
  }
  function friendly(code, status) {
    switch (code) {
      case "auth_failed": return "Mac authentication failed (Touch ID or password not accepted).";
      case "auth_cancelled": return "Mac authentication cancelled.";
      case "auth_unavailable": return "Mac authentication is not available here (no GUI session, or nothing enrolled).";
      case "not_checked": return "No check recorded yet.";
      case "not_found": return "That key no longer exists.";
      case "already_exists": return "A key with that name already exists.";
      case "forbidden": return "Blocked: request was not same-origin.";
      case "missing or bad token": return "This page is from an older launch. Reload it.";
      case "method_not_allowed": return "That endpoint is missing on the server.";
      default: return code || `Request failed (${status}).`;
    }
  }
  // analytics.js loads after this file and reuses its fetch wrapper and token format. Published
  // before the rest of startup so a later failure here cannot take the Privacy dialog down too.
  window.KeysUI = Object.freeze({ api, fmtTokens });
  // Each loader reports its last result in its own pane, so one loader's recovery can never
  // take down, or be hidden by, the other's failure, and the status line is left to transient
  // messages. An outage belongs to the banner alone: a pane never keeps a "Can't reach" that
  // would outlive the engine answering again through the status poll.
  function paneError(id, e) { $(id).textContent = e && e.message !== UNREACHABLE ? e.message : ""; }
  function setEngineDown(down) { $("engine-down").hidden = !down; }

  // ---------- panes ----------

  const panes = { usage: $("pane-usage"), chart: $("pane-chart"), keys: $("pane-keys"), settings: $("pane-settings") };
  const tabs = { usage: $("nav-usage"), chart: $("nav-chart"), keys: $("nav-keys"), settings: $("nav-settings") };
  const PANE_ORDER = ["usage", "chart", "keys", "settings"];
  // The analytics vocabulary (server allowlist and collector) knows these three views only.
  const COUNTED_VIEWS = new Set(["usage", "chart", "keys"]);

  function leaveHiddenPaneFocus(next) {
    const active = document.activeElement;
    if (!active || active === document.body) return;
    for (const key of Object.keys(panes)) {
      if (key === next) continue;
      if (panes[key].contains(active)) {
        tabs[next].focus();
        return;
      }
    }
  }

  function showPane(name, opts = {}) {
    const changed = state.pane !== name;
    if (name !== "keys") closeKeyMenu({ restoreFocus: false });
    state.pane = name;
    if (changed && COUNTED_VIEWS.has(name)) window.KeysAnalytics?.event(`view_${name}`);
    document.body.dataset.pane = name;
    for (const key of Object.keys(panes)) {
      const on = key === name;
      panes[key].hidden = !on;
      tabs[key].setAttribute("aria-selected", on ? "true" : "false");
      tabs[key].tabIndex = on ? 0 : -1;
      panes[key].classList.remove("fade");
    }
    if (changed && !opts.keyboard && !reduced.matches) {
      void panes[name].offsetWidth;
      panes[name].classList.add("fade");
    }
    if (opts.focusTab) tabs[name].focus();
    else if (changed) leaveHiddenPaneFocus(name);
    if (name === "usage") loadStatus();
    else if (name === "chart") loadSpend();
    else if (name === "keys") loadKeys({ focus: !!opts.keyboard && !opts.focusTab });
    else if (name === "settings") { renderSettings(); loadStatus(); loadRelay(); }
  }

  // Settings lives in the rail's foot, outside the tablist element, so each tab listens itself.
  // The step must not bubble on: the document handler would move a Down press on to the Keys
  // list as soon as the Keys pane came up.
  for (const [name, tab] of Object.entries(tabs)) {
    tab.addEventListener("click", () => showPane(name));
    tab.addEventListener("keydown", (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const j = ringStep(e.key, PANE_ORDER.indexOf(state.pane), PANE_ORDER.length);
      if (j < 0) return;
      e.preventDefault();
      e.stopPropagation();
      showPane(PANE_ORDER[j], { keyboard: true, focusTab: true });
    });
  }

  // ---------- chips (radiogroups) ----------

  function wireChips(attr, onChange) {
    const buttons = [...document.querySelectorAll(`.chips [${attr}]`)];
    const sync = (value) => {
      const btn = buttons.find((b) => b.getAttribute(attr) === value) || buttons[0];
      for (const b of buttons) {
        const on = b === btn;
        b.setAttribute("aria-checked", on ? "true" : "false");
        b.tabIndex = on ? 0 : -1;
      }
    };
    const set = (btn) => {
      sync(btn.getAttribute(attr));
      onChange(btn.getAttribute(attr));
    };
    for (const b of buttons) {
      b.addEventListener("click", () => set(b));
      b.addEventListener("keydown", (e) => {
        // A chip that does not apply to the current source is hidden; arrow keys skip it.
        const live = buttons.filter((x) => !x.hidden);
        const next = live[ringStep(e.key, live.indexOf(b), live.length)];
        if (!next || next === b) return;
        e.preventDefault();
        set(next);
        next.focus();
      });
    }
    return { sync };
  }

  // Two things this Mac pays for, and they are not the same kind of record. Subscriptions are the
  // tools' own local logs; API keys are the gateway's ledger of calls it routed. Picking between
  // them comes first, and only then does a narrower filter — a tool, or a provider and a key —
  // mean anything. A flat list would put Claude beside TypeSafe as if they were the same axis.
  const scopeChips = wireChips("data-scope", (value) => setScope(value));
  const sourceChips = wireChips("data-source", (value) => setSource(value));
  const keysMode = () => state.source === "keys";
  function setScope(value) {
    if (value === "keys" && keysMode()) return;
    if (value !== "keys" && !keysMode()) return;
    // Each scope's own filters are dropped on the way out: a provider or key means nothing to a
    // local log, and the project grouping means nothing to the gateway ledger.
    state.source = value === "keys" ? "keys" : state.subSource;
    state.key = null;
    state.provider = null;
    state.keyIndex = [];
    state.mixFilter = null;
    if (!keysMode() && state.unit === "requests") state.unit = readUnit();
    syncScopeChips();
    writeChartUrl();
    loadSpend();
  }
  function setSource(value) {
    state.source = value;
    state.subSource = value;
    // A tool chip is a local source, and a local source never carries a gateway filter — not even
    // one that arrived from outside the chart. Clearing here is what keeps `loadSpend` from
    // sending a key with a local source however the view got into one.
    state.key = null;
    state.provider = null;
    state.mixFilter = null;
    syncScopeChips();
    writeChartUrl();
    loadSpend();
  }
  // One place decides which filter rows belong to the current scope, so no row is ever left
  // showing a filter the request no longer sends.
  function syncScopeChips() {
    scopeChips.sync(keysMode() ? "keys" : "subs");
    // The tool row keeps the last subscription choice while it is hidden, so coming back out of
    // the API keys scope returns to where the user was rather than resetting to All.
    sourceChips.sync(state.subSource);
    $("source-chips").hidden = keysMode();
    syncGroupChips();
    syncUnitChips();
    renderProviderFilter();
    renderKeysFilter();
  }
  function writeChartUrl() {
    const url = new URL(location.href);
    url.searchParams.set("range", state.range);
    if (state.source === "all") url.searchParams.delete("source"); else url.searchParams.set("source", state.source);
    if (state.key) url.searchParams.set("key", state.key); else url.searchParams.delete("key");
    if (state.provider) url.searchParams.set("provider", state.provider); else url.searchParams.delete("provider");
    history.replaceState(null, "", url);
  }
  // The gateway filters an explicit local source refused above are struck from the URL now, so the
  // address bar says what the page is actually showing.
  if (boot.dropped) writeChartUrl();
  const rangeChips = wireChips("data-range", (value) => {
    state.range = value;
    writeChartUrl();
    loadSpend();
  });
  rangeChips.sync(state.range);
  // A key filter narrows both charts and the model list to calls that went through the gateway
  // with that key. It only means anything in the API keys source, so it takes the view there.
  function setKey(name) {
    applyKey(name);
    loadSpend();
  }
  // `keepProvider` is for the picker inside the chart, where the key list is already narrowed to
  // the chosen provider and the two filters agree by construction. A key named from outside the
  // chart agrees with nothing: it belongs to exactly one provider, which need not be the one still
  // filtering the view, and the pair would report an empty intersection for a key that has calls.
  function applyKey(name, keepProvider = true) {
    state.key = name;
    state.source = "keys";
    if (!keepProvider) state.provider = name ? keyProvider(name) : null;
    state.mixFilter = null;
    syncScopeChips();
    writeChartUrl();
  }
  // Providers and keys are one hierarchy: a vault key belongs to exactly one provider. Narrowing
  // the provider therefore drops a key that is not its own, rather than showing an empty chart
  // under two filters that cannot both be true.
  function setProvider(id) {
    const next = state.provider === id ? null : id;
    state.provider = next;
    state.mixFilter = null;
    if (next && state.key && keyProvider(state.key) && keyProvider(state.key) !== next) state.key = null;
    syncScopeChips();
    writeChartUrl();
    loadSpend();
  }
  const keyProvider = (name) => (state.keyIndex.find((e) => e.key === name) || {}).provider || null;
  // The Keys pane's gateway cell lands here: the named key, in the API keys view, every time. A
  // provider left over from an earlier look at the chart is not this key's, so it is derived from
  // the key or dropped rather than carried into a filter pair that cannot both hold.
  function showKeyInChart(name) {
    applyKey(name, false);
    showPane("chart");
  }
  // Every gateway call is one request, so requests are countable even when a provider reports no
  // tokens and no cost. Local logs do not always record a call count, so the unit is offered only
  // for the API keys source.
  const unitChips = wireChips("data-unit", (value) => setUnit(value));
  function syncUnitChips() {
    const chip = document.querySelector('[data-unit="requests"]');
    if (chip) chip.hidden = !keysMode();
    if (!keysMode() && state.unit === "requests") state.unit = readUnit();
    unitChips.sync(state.unit);
  }
  syncUnitChips();

  // A picker row: "All …" first, then one chip per recorded value. Choosing a chip reloads and
  // redraws the row, so keyboard focus follows the new choice rather than falling to the body.
  function renderPicker(boxId, attr, allLabel, allHint, options, current, choose) {
    const box = $(boxId);
    const hadFocus = box.contains(document.activeElement);
    box.hidden = !keysMode();
    box.replaceChildren();
    if (!keysMode() || !options.length) return;
    const chip = (value, label, hint, on) => el("button", {
      type: "button", role: "radio", "aria-checked": String(on), tabindex: on ? "0" : "-1",
      [attr]: value || "", "aria-label": hint, title: hint,
      onclick: () => { if (value !== current) choose(value); },
    }, label);
    box.append(chip(null, allLabel, allHint, !current));
    for (const o of options) box.append(chip(o.value, o.label, o.hint, current === o.value));
    if (hadFocus) box.querySelector('[aria-checked="true"]')?.focus();
  }
  function wirePickerKeys(boxId, attr) {
    $(boxId).addEventListener("keydown", (e) => {
      const chips = [...$(boxId).querySelectorAll(`[${attr}]`)];
      const i = chips.indexOf(e.target);
      const j = i < 0 ? -1 : ringStep(e.key, i, chips.length);
      if (j < 0) return;
      e.preventDefault();
      chips[j].click();
    });
  }

  // One chip per provider with recorded gateway calls, plus "All providers". Both TypeSafe and
  // the Vercel AI Gateway land here, and a model served by both appears under whichever
  // provider carried it, not as a source of its own.
  function renderProviderFilter() {
    const ids = [...new Set([...state.keyIndex.map((e) => e.provider), state.provider].filter(Boolean))];
    const options = ids
      .map((id) => ({ value: id, label: providerName(id), hint: "Show only calls routed to " + providerName(id) }))
      .sort((a, b) => a.label.localeCompare(b.label));
    renderPicker("provider-filter", "data-provider-filter", "All providers",
      "Show every provider these keys reached", options, state.provider, setProvider);
  }
  // One option per key with gateway usage, "All keys" first, in a native dropdown: a vault with
  // many keys made a chip row a long line, and a <select> is keyboard-operable as it stands.
  // Names only; a key value never appears. With a provider chosen the list is that provider's
  // keys, so the provider chips and this picker read as one path.
  function renderKeysFilter() {
    const box = $("keys-filter");
    const select = $("keys-filter-select");
    const names = [...new Set(state.keyIndex
      .filter((e) => !state.provider || e.provider === state.provider)
      .map((e) => e.key)
      .concat(state.key ? [state.key] : []))].sort();
    box.hidden = !keysMode() || !names.length;
    select.replaceChildren(
      el("option", { value: "", "data-key-filter": "", text: "All keys", title: "Show every key" }),
      ...names.map((n) => el("option", { value: n, "data-key-filter": n, text: n, title: "Show only key " + n })),
    );
    select.value = state.key || "";
  }
  $("keys-filter-select").addEventListener("change", (e) => {
    const value = e.target.value || null;
    if (value !== state.key) setKey(value);
  });
  wirePickerKeys("provider-filter", "data-provider-filter");

  // Projects are a Claude-only grouping (the only source with a project path); keys and
  // providers exist only in the gateway ledger. Each chip shows only where it means something.
  const groupChips = wireChips("data-group", (value) => setGroup(value));
  const groupAllowed = (value) => value === "model"
    || (value === "project" && state.source === "claude")
    || ((value === "key" || value === "provider") && keysMode());
  function setGroup(value) {
    state.group = groupAllowed(value) ? value : "model";
    groupChips.sync(state.group);
    state.mixFilter = null;
    loadSpend();
  }
  function syncGroupChips() {
    const show = state.source === "claude" || keysMode();
    $("group-chips").hidden = !show;
    document.querySelector('[data-group="project"]').hidden = state.source !== "claude";
    for (const g of ["key", "provider"]) document.querySelector(`[data-group="${g}"]`).hidden = !keysMode();
    if (!groupAllowed(state.group)) state.group = "model";
    groupChips.sync(state.group);
  }
  const routeGroup = () => keysMode() && (state.group === "key" || state.group === "provider") ? state.group : null;
  const todayMode = () => state.range === "today";
  function setRange(value) {
    rangeChips.sync(value);
    state.range = value;
    writeChartUrl();
    loadSpend();
  }

  function setUnit(value) {
    const wanted = value === "requests" && !keysMode() ? "tokens" : value;
    state.unit = wanted === "usd" ? "usd" : wanted === "requests" ? "requests" : "tokens";
    // "requests" belongs to the API keys source only, so it is not remembered for the next visit.
    if (state.unit !== "requests") { try { localStorage.setItem("ksf.unit", state.unit); } catch { /* fine */ } }
    unitChips.sync(state.unit);
    // One unit for the whole page: the chart, the key rows' gateway figures and the Usage
    // summary all answer in it, so switching in one place does not leave another contradicting it.
    if (state.keys.length) renderKeys();
    renderUsageTotals();
    // The plan cards are redrawn from the status already in hand, so the switch does not wait for
    // the next poll to take effect — and does not ask the engine again to change a unit.
    if (state.status) renderStatus();
    if (state.spend) { renderTotals(state.spend); renderMix(); drawChart(); }
  }
  $("keys-sort").addEventListener("change", (e) => {
    state.keySort = keySorts[e.target.value] ? e.target.value : "name";
    try { localStorage.setItem("ksf.keysort", state.keySort); } catch { /* fine */ }
    renderKeys();
  });
  $("keys-provider").addEventListener("change", (e) => {
    state.keyProviderFilter = e.target.value;
    renderKeys();
  });
  $("keys-search").addEventListener("input", (e) => {
    state.keySearch = e.target.value;
    renderKeys();
  });
  $("keys-search").addEventListener("keydown", (e) => {
    if (e.key === "Escape" && e.target.value) {
      e.preventDefault();
      e.stopPropagation();
      e.target.value = "";
      state.keySearch = "";
      renderKeys();
    } else if (e.key === "ArrowDown") {
      // Nothing may be selected yet (or the selection was filtered out); the first visible
      // key row is where the arrow should land then, not nowhere.
      const row = rowFor(state.selected) || keyRows()[0];
      if (row) { e.preventDefault(); selectRow(row.dataset.name, true); }
    }
  });
  const usdMode = () => state.unit === "usd";
  const requestMode = () => state.unit === "requests";

  // ---------- spend ----------

  let spendSeq = 0;
  async function loadSpend() {
    const seq = ++spendSeq;
    // A by=hour report carries the same model rows as by=model plus the hourly points Today draws.
    const q = new URLSearchParams({ range: state.range, by: routeGroup() || (todayMode() ? "hour" : projectMode() ? "project" : "model"), source: state.source });
    if (state.key) q.set("key", state.key);
    if (keysMode() && state.provider) q.set("provider", state.provider);
    try {
      // A filtered report only names the provider and key already chosen, so the pickers would
      // narrow to the current choice and strand the user there. The unfiltered report over the
      // same range is what lists every choice; it is only needed while a filter is applied.
      // A by=key or by=provider report names no key per row either, so it needs the index too.
      const filtered = keysMode() && (state.key || state.provider || routeGroup());
      const indexReq = filtered
        ? api("/api/spend?" + new URLSearchParams({ range: state.range, by: "model", source: "keys" }).toString()).catch(() => null)
        : null;
      const [data, index] = await Promise.all([api("/api/spend?" + q.toString()), indexReq]);
      if (seq !== spendSeq) return;
      state.spend = data;
      const indexReport = keysMode() ? (filtered ? index : data) : null;
      const indexRows = indexReport ? indexReport.rows || [] : null;
      if (indexRows) {
        const seen = new Map();
        for (const r of indexRows) if (r.key) seen.set(r.key, r.provider || null);
        state.keyIndex = [...seen].map(([key, provider]) => ({ key, provider })).sort((a, b) => a.key.localeCompare(b.key));
      }
      renderProviderFilter();
      renderKeysFilter();
      paneError("chart-error");
      renderSpend();
    } catch (e) {
      if (seq !== spendSeq) return;
      paneError("chart-error", e);
    }
  }

  async function loadModels() {
    try {
      const list = await api("/api/models");
      if (!Array.isArray(list)) return;
      state.slots = new Map(list.map((m) => [m.model, m.slot]));
    } catch { /* colours fall back to first-sighting order */ }
  }

  // The vendor a model id names — one family per vendor, and the family owns the palette, the
  // legend order and the token-rule fallback below. The prefixes are the public ids the tools
  // log (Droid included), matching the ingest's provider map; anything unrecognized is
  // "other", which has its own grey palette.
  const family = (m) => (/^grok/i.test(m) ? "grok" : /^claude/i.test(m) ? "claude" : /^(gpt-|o[1-9]|codex|chatgpt)/i.test(m) ? "openai"
    : /^gemini/i.test(m) ? "gemini" : /^glm/i.test(m) ? "glm" : /^kimi/i.test(m) ? "kimi" : /^deepseek/i.test(m) ? "deepseek" : "other");

  // Colour follows the model. The engine's colour registry gives every model a stable slot, so a
  // family's shades are handed out in slot order and never move between loads or restarts.
  // Colour capacity is not identity. Past the four hand-picked shades a family keeps going: the
  // same four are reused, each step lightened or darkened by a fixed amount, so the palette
  // extends as far as the models do and stays the same across loads and restarts. A known model
  // name is never dropped into "Other" because the page ran out of colours.
  function shadeFor(fam, i) {
    const base = `var(--s-${fam}-${(i % SLOTS) + 1})`;
    const level = Math.floor(i / SLOTS);
    if (level === 0) return base;
    const toward = level % 2 ? "#ffffff" : "#000000";
    const pct = Math.min(64, 22 * Math.ceil(level / 2));
    return `color-mix(in oklab, ${base} ${100 - pct}%, ${toward})`;
  }

  const PROJECT_PALETTE = ["claude-1", "grok-1", "openai-1", "claude-2", "grok-2", "openai-2", "claude-3", "grok-3", "openai-3", "claude-4", "grok-4", "openai-4"];
  function assignColors(models) {
    if (projectMode()) {
      state.colors = new Map();
      models.forEach((m, i) => {
        if (i >= PROJECT_PALETTE.length) return;
        state.colors.set(m, { color: `var(--s-${PROJECT_PALETTE[i]})`, slot: i, family: "project" });
      });
      return;
    }
    const byFam = new Map();
    for (const m of models) {
      const f = family(m);
      if (!byFam.has(f)) byFam.set(f, []);
      byFam.get(f).push(m);
    }
    state.colors = new Map();
    for (const [fam, list] of byFam) {
      list.sort((a, b) => (state.slots.get(a) ?? 1e9) - (state.slots.get(b) ?? 1e9) || a.localeCompare(b));
      list.forEach((m, i) => {
        state.colors.set(m, { color: shadeFor(fam, i), slot: FAM_BASE[fam] + i, family: fam });
      });
    }
  }
  const colorFor = (model) => (model === OTHER || model === "Other projects" ? { color: "var(--s-other)", slot: OTHER_SLOT, family: "other" } : state.colors.get(model) || null);

  // One identity for a row, a daily point and an hourly point alike. The gateway records model=""
  // when the caller named no model and the provider reported none, so the empty name is a real
  // bucket: it becomes "unknown" here, and every lookup has to ask the same question or those
  // requests would count in the totals and the mix while their bars went missing.
  const seriesId = (r) => (projectMode() ? (r.cwd || r.project || "unknown") : (r.model || "unknown"));

  // The engine's own token rule, applied to a row here so a headline, a legend row and the bars
  // the engine drew cannot disagree about the same range: Claude counts cache reads and writes
  // because they are billed separately, OpenAI, Codex and Grok count reasoning tokens instead,
  // and a gateway row follows the API its provider speaks. A row names its source where the
  // engine sends one; otherwise the model's family answers the same question.
  const anthropicApi = (id) => (providerById(id) || {}).api === "anthropic";
  function rowTokens(r, projects = false) {
    const input = r.input_tokens || 0;
    const output = r.output_tokens || 0;
    const cache = (r.cached_read_tokens || 0) + (r.cache_creation_tokens || 0);
    const reasoning = r.reasoning_tokens || 0;
    const src = r.source || "";
    // A project row is a folder's Claude sessions; it names no model, and Claude is the only
    // source with a project path.
    if (projects || src === "claude-local") return input + output + cache;
    if (src === "codex-local" || src === "grok-local") return input + output + reasoning;
    // Droid's log bills every bucket it reports, cache and thinking included.
    if (src === "droid-local" || src === "droid-remote") return input + output + cache + reasoning;
    if (src === "claude-remote") return input + output + cache;
    if (src === "gateway" || (!src && r.provider)) return input + output + (anthropicApi(r.provider) ? cache : reasoning);
    return input + output + (family(r.model || "") === "claude" ? cache : reasoning);
  }

  // What a report row counts. by=model rows group on the model id, so one row can mix tools —
  // a model Claude Code and Droid both used — and no single rule over its raw buckets can be
  // right for both (Claude's cache buckets and Droid's reasoning both count, each under its own
  // source). The engine states the answer once, in `counted_tokens`: each event counted under
  // its own source's rule before the grouping, the same `TokenTotals.normalized` the Usage row
  // reads. Only a payload without the field — an older engine, a hand-made fixture — falls back
  // to the family-based rule above.
  const rowCounted = (r, projects = false) => (typeof r.counted_tokens === "number" ? r.counted_tokens : rowTokens(r, projects));

  function buildSeries(rows) {
    // Families first, newest vendors after the three the chips name, unknown last: a stack
    // never interleaves one vendor's shades with another's.
    const order = { grok: 0, claude: 1, openai: 2, gemini: 3, glm: 4, kimi: 5, deepseek: 6, other: 7 };
    // Same accounting as the engine's totals: Claude counts every bucket (cache reads and
    // writes are billed separately), Grok's cached reads already sit inside input_tokens.
    // A gateway call is real even with no token counts: TypeSafe's System One protocol reports
    // neither tokens nor cost, and dropping those rows would hide calls that did happen.
    const isReal = (r) => ((r.input_tokens || 0) + (r.output_tokens || 0) + (r.cached_read_tokens || 0) + (r.cache_creation_tokens || 0)) > 0
      || (keysMode() && (r.model_calls || 0) > 0);
    // The engine sends one row per (model, key); daily points are per model. Merge rows by model
    // first so a model with local and gateway usage, or two keys, is one series and one bucket.
    const merged = new Map();
    for (const r of rows.filter(isReal)) {
      const id = seriesId(r);
      const m = merged.get(id);
      // Each row arrives already counted under its own sources' rules (`counted_tokens`), so a
      // model served by two tools or two providers is not re-counted under whichever one
      // happened to be named first.
      if (!m) { merged.set(id, { ...r, counted: rowCounted(r, projectMode()) }); continue; }
      m.counted += rowCounted(r, projectMode());
      m.remote_counted_tokens = (m.remote_counted_tokens || 0) + (Number(r.remote_counted_tokens) || 0);
      for (const f of ["input_tokens", "output_tokens", "cached_read_tokens", "cache_creation_tokens", "reasoning_tokens", "model_calls"]) m[f] = (m[f] || 0) + (r[f] || 0);
      if (r.usd != null) m.usd = (m.usd || 0) + r.usd;
      if (r.usd_estimate != null) m.usd_estimate = (m.usd_estimate || 0) + r.usd_estimate;
      m.key = m.key && r.key && m.key !== r.key ? m.key + ", " + r.key : m.key || r.key || null;
      // A model can be served by more than one provider — TypeSafe's evaluation model runs on
      // both TypeSafe and the Vercel gateway — so the merged row names each one rather than picking a winner.
      m.provider = m.provider && r.provider && m.provider !== r.provider
        ? m.provider + "," + r.provider : m.provider || r.provider || null;
    }
    const items = [...merged.values()].map((r) => ({
      model: seriesId(r),
      label: projectMode() ? (r.project || r.cwd || "unknown") : (r.model || "unknown"),
      cwd: r.cwd || null,
      tokens: r.counted || 0,
      input: r.input_tokens || 0,
      output: r.output_tokens || 0,
      cached: r.cached_read_tokens || 0,
      created: r.cache_creation_tokens || 0,
      reasoning: r.reasoning_tokens || 0,
      calls: r.model_calls || 0,
      key: r.key || null,
      provider: r.provider || null,
      usd: r.usd,
      est: r.usd_estimate,
      remote: Number(r.remote_counted_tokens) || 0,
    }));
    if (projectMode()) {
      items.sort((a, b) => b.tokens - a.tokens);
      // two projects with the same folder name: show the parent folder too
      const seen = new Map();
      for (const it of items) seen.set(it.label, (seen.get(it.label) || 0) + 1);
      for (const it of items) if (seen.get(it.label) > 1 && it.cwd) it.label = it.cwd.split("/").filter(Boolean).slice(-2).join("/");
    } else if (routeGroup()) {
      // Keys and providers have no vendor family to cluster by: biggest spend first, then calls.
      const cost = (it) => it.usd ?? it.est ?? 0;
      items.sort((a, b) => cost(b) - cost(a) || b.calls - a.calls || b.tokens - a.tokens);
    } else items.sort((a, b) => order[family(a.model)] - order[family(b.model)] || b.tokens - a.tokens);
    assignColors(items.map((it) => it.model));
    const out = [];
    let other = null;
    for (const it of items) {
      const entry = colorFor(it.model);
      if (entry) {
        out.push({ ...it, color: entry.color, slot: entry.slot, members: [it.model] });
      } else {
        if (!other) other = { model: projectMode() ? "Other projects" : OTHER, label: projectMode() ? "Other projects" : OTHER, tokens: 0, input: 0, output: 0, cached: 0, created: 0, reasoning: 0, calls: 0, usd: null, est: null, remote: 0, color: "var(--s-other)", slot: OTHER_SLOT + 1, members: [] };
        other.tokens += it.tokens; other.input += it.input; other.output += it.output;
        other.cached += it.cached; other.created += it.created; other.calls += it.calls || 0;
        other.reasoning += it.reasoning || 0;
        other.remote += it.remote || 0;
        if (it.usd != null) other.usd = (other.usd || 0) + it.usd;
        if (it.est != null) other.est = (other.est || 0) + it.est;
        other.members.push(it.model);
        other.labels = (other.labels || []).concat(it.label);
      }
    }
    if (other) out.push(other);
    // Colour slots follow vendor families, which mean nothing for keys and providers; those keep
    // the spend order set above.
    if (!routeGroup()) out.sort((a, b) => a.slot - b.slot);
    return out;
  }

  // dollars for a series or point: real when the vendor logs them (Grok), else the estimate
  // actual dollars (Grok's own log) plus any estimate for the part that has no actual figure
  const dollars = (x) => {
    const actual = x.usd != null ? Number(x.usd) : null;
    const est = x.est != null ? Number(x.est) : x.usd_estimate != null ? Number(x.usd_estimate) : null;
    if (actual == null && est == null) return null;
    return (actual || 0) + (est || 0);
  };

  function renderSpend() {
    const data = state.spend;
    const rows = data.rows || [];
    const empty = rows.length === 0;
    renderEmpty(empty, data);
    $("spend-empty").hidden = !empty;
    $("daily").hidden = empty;
    $("mix").hidden = empty;
    $("mix").setAttribute("aria-label", projectMode() ? "Project mix" : "Model mix");
    $("totals").hidden = empty;
    // The caption says which ledger is on screen. The subscription one is what the tools wrote to
    // their own logs on this Mac — an estimate from those logs, never a plan invoice, and the plan
    // windows themselves stay in the Usage pane rather than being redrawn here as bars.
    $("chart-caption").textContent = keysMode()
      ? "calls this Mac routed through the local gateway with a key from the vault"
        + (state.provider ? " · " + providerName(state.provider) : "")
        + " · click a model to see it alone"
      : ledgerCaption(data) + " · click a model to see it alone";
    renderInterval(data);
    if (empty) return;
    state.series = buildSeries(rows);
    renderTotals(data);
    renderMix();
    drawChart();
  }

  const projectMode = () => state.group === "project" && !todayMode();
  // Imported cloud tokens are counted inside totals.tokens but were never read off this Mac, so
  // every sentence that says "local logs" has to know whether they are in the view.
  const remoteTokens = (data) => Number(((data || {}).totals || {}).remote_tokens) || 0;
  const PARTLY_PRICED_NOTE = "Partly priced: this figure covers the local tokens only. Imported cloud tokens carry no dollar figure and are not priced.";
  const LOCAL_LEDGER = "estimated from the tools' own local logs on this Mac, not from plan invoices";
  const CLOUD_LEDGER = "imported cloud usage, recorded off this Mac and brought in with keys usage import · no dollar figure, so not priced";
  const MIXED_LEDGER = "estimated from the tools' own local logs on this Mac, plus usage imported from the cloud, which carries no dollar figure and is not priced";
  const ledgerCaption = (data) => state.source === "cloud" ? CLOUD_LEDGER : remoteTokens(data) > 0 ? MIXED_LEDGER : LOCAL_LEDGER;
  function renderEmpty(empty, data) {
    const node = $("spend-empty");
    if (!empty) return;
    node.replaceChildren();
    const ingested = data && data.last_ingest_at;
    // Only the local gateway sees a key being used. A provider called directly, from another
    // machine, or before the key was routed through Keys leaves nothing here to count.
    const onlyRouted = "Only requests routed through Keys are recorded here; a provider called directly is not observable.";
    if (state.key && keysMode()) {
      node.append(`No calls through the gateway with ${state.key} in this range. ${onlyRouted} `,
        el("button", { type: "button", class: "link", text: "Show every key", onclick: () => setKey(null) }));
    } else if (state.provider && keysMode()) {
      node.append(`No calls through the gateway to ${providerName(state.provider)} in this range. ${onlyRouted} `,
        el("button", { type: "button", class: "link", text: "Show every provider", onclick: () => setProvider(state.provider) }));
    } else if (keysMode()) {
      node.append(`No API key calls in this range. ${onlyRouted} `,
        el("button", { type: "button", class: "link", text: "Show subscriptions", onclick: () => { document.querySelector('[data-scope="subs"]').click(); } }));
    } else if (state.source !== "all") {
      const name = { grok: "Grok", claude: "Claude Code", openai: "Codex", droid: "Droid", cloud: "imported cloud" }[state.source] || state.source;
      if (state.source === "cloud") {
        // Nothing reaches Cloud on its own; say how usage gets here instead of implying a log was read.
        node.append("No imported cloud usage in this range. Cloud usage comes from files made with scripts/export-remote-usage.py and brought in with keys usage import. ");
        node.append(el("button", { type: "button", class: "link", text: "Show all", onclick: () => { document.querySelector('[data-source="all"]').click(); } }));
        return;
      }
      node.append(`No ${name} sessions in this range. `, el("button", { type: "button", class: "link", text: "Show all", onclick: () => { document.querySelector('[data-source="all"]').click(); } }));
    } else if (!ingested) {
      node.append("No sessions ingested yet. ", el("button", { type: "button", class: "link", text: "Ingest now", onclick: ingest }));
    } else {
      node.append("Nothing in this range. Claude Code, Grok, Codex and Droid logs were read, and no imported cloud usage falls in ",
        el("span", { text: state.range === "week" ? "this week." : state.range === "month" ? "this month." : "today." }));
    }
  }

  // Zero, unknown and partial are different things. usd_month is null when calls happened but
  // none could be priced; usd_month_kind says which case this is.
  // A key with no gateway calls this month gets no figure at all (null), rather than a dash or a
  // zero that would read as a measurement. The button opens the key in the Chart's API keys view.
  function gatewayMonthCell(k, tab) {
    const kind = k.usd_month_kind || (Number(k.usd_month) > 0 ? "estimate" : "none");
    const unpricedCalls = Number(k.gateway_month_unpriced_calls) || 0;
    const calls = Number(k.gateway_month_calls) || 0;
    const figure = (text, title, none) => el("button", {
      type: "button", class: "key-gateway" + (none ? " none" : ""), tabindex: tab, "data-act": "chart",
      text, title: title + " Click to chart.",
      "aria-label": `${text} this month through the gateway with ${k.name}; open in the chart`,
    });
    // The unit this page is in decides what the figure says. Requests are what a key's own row can
    // always answer for, and no dollar figure is put on screen unless USD was asked for (on the
    // Usage or Chart pane; the unit is shared by the whole page).
    if (!usdMode()) {
      if (!calls) return null;
      return figure(plural(calls, "request", "requests"), "This month, requests through the local gateway with this key.");
    }
    if (kind === "none") return null;
    if (kind === "unknown") {
      return figure(`${plural(calls, "call", "calls")}, unpriced`, "This month's gateway calls with this key had no usable cost receipt or list-price estimate, so the cost is unknown, not zero.", true);
    }
    const partial = kind === "partial" ? ` ${plural(unpricedCalls, "call", "calls")} unpriced and left out.` : "";
    return figure((kind === "partial" ? "≥ " : "") + fmtUsd(k.usd_month), "This month, calls through the local gateway with this key. Uses provider-reported cost where available, otherwise a list-price estimate." + partial);
  }

  // What the rows in view are made of. The chart's own figures come from the same merged series,
  // so the breakdown a tooltip offers is the breakdown behind the headline.
  const seriesBreakdown = () => state.series.reduce((a, s) => ({
    input: a.input + (s.input || 0),
    output: a.output + (s.output || 0),
    cached: a.cached + (s.cached || 0),
    created: a.created + (s.created || 0),
    reasoning: a.reasoning + (s.reasoning || 0),
    tokens: a.tokens + (s.tokens || 0),
    calls: a.calls + (s.calls || 0),
  }), { input: 0, output: 0, cached: 0, created: 0, reasoning: 0, tokens: 0, calls: 0 });
  // Cached input is re-read by every request that reuses it, so it is counted once per request.
  // It is not new output, and it is not free of tokens.
  const CACHE_NOTE = "Cached input is counted on each request that reads it again; it is reused input, not new output.";
  const breakdownTitle = (b) =>
    `${fmtInt(b.input)} input · ${fmtInt(b.output)} output · ${fmtInt(b.cached)} cached input read · ${fmtInt(b.created)} cache writes`
    + (b.reasoning ? ` · ${fmtInt(b.reasoning)} reasoning` : "") + `. ${CACHE_NOTE}`;
  const requestsPart = (n, title) => el("span", { class: "totals-part", title }, el("b", { text: fmtInt(n) }), " " + (n === 1 ? "request" : "requests"));

  // The API keys view is the gateway's own ledger, so requests lead: a call is always countable,
  // while tokens and dollars depend on what the provider reported. An unpriced call is shown as
  // unknown, never as $0, and a partly priced range is a floor.
  function renderKeysTotals(data) {
    const t = data.totals || {};
    const calls = Number(t.gateway_calls) || 0;
    const unpricedCalls = Number(t.gateway_unpriced_calls) || 0;
    const tokens = Number(t.gateway_tokens) || 0;
    const usd = t.gateway_usd_estimate != null ? Number(t.gateway_usd_estimate) : null;
    const partial = usd != null && unpricedCalls > 0;
    const main = usd == null
      ? (calls ? "cost unknown" : fmtUsd(0))
      : (partial ? "≥ ≈ " : "≈ ") + fmtUsd(usd);
    // Name what was counted, so a number under a filter is never read as the whole ledger.
    const scope = [
      state.key ? "key " + state.key : "every key",
      state.provider ? "at " + providerName(state.provider) : "at every provider",
    ].join(" ");
    // Tokens and requests are what this Mac measured; dollars are a price put on them afterwards.
    // Unless USD was asked for, no dollar figure goes on screen.
    if (!usdMode()) {
      const b = seriesBreakdown();
      const measured = Math.max(tokens, b.tokens);
      const reported = measured > 0;
      const tokenText = reported ? fmtTokens(measured) + " tokens" : calls ? "no reported tokens" : "0 tokens";
      // A provider that reports no token counts has not measured zero tokens. Saying "0" would
      // claim a measurement nobody made; the requests are the count that does exist.
      const tokenTitle = reported
        ? `Tokens the providers reported for ${scope}. ${breakdownTitle(b)}`
        : calls
          ? `These requests went through the gateway with ${scope}, but the providers reported no token counts. Unknown, not a measured zero — the requests themselves are counted.`
          : `No requests with ${scope} in this range.`;
      const nodes = [el("span", {
        class: "totals-main" + (requestMode() || reported ? "" : " none"),
        text: requestMode() ? plural(calls, "request", "requests") : tokenText,
        title: requestMode() ? `Requests routed through the local gateway with ${scope}.` : tokenTitle,
      })];
      appendParts(nodes, [requestMode()
        ? el("span", { class: "totals-part" + (reported ? "" : " none"), title: tokenTitle }, el("b", { text: reported ? fmtTokens(measured) : "—" }), " tokens")
        : requestsPart(calls, "Requests routed through the local gateway in this range."),
      ]);
      if (b.cached > 0) {
        nodes.push(el("span", { class: "totals-sep", text: "·" }));
        nodes.push(el("span", { class: "totals-note", text: fmtTokens(b.cached) + " cached input", title: CACHE_NOTE }));
      }
      nodes.push(el("span", { class: "totals-note", text: "routed through Keys only · choose USD above for cost" }));
      $("totals").replaceChildren(...nodes);
      return;
    }
    const nodes = [el("span", {
      class: "totals-main" + (usd == null ? " none" : " est"),
      text: main,
      title: usd == null
        ? `Calls with ${scope} went through the gateway, but none carried a cost receipt or matched a local price row. The cost is unknown, not zero.`
        : `Calls with ${scope} through the local gateway. Provider-reported cost where available, otherwise a list-price estimate.`,
    })];
    appendParts(nodes, [
      el("span", { class: "totals-part", title: "Requests routed through the local gateway in this range." },
        el("b", { text: fmtInt(calls) }), " " + (calls === 1 ? "request" : "requests")),
      el("span", { class: "totals-part", title: "Tokens the providers reported for those requests. A provider that reports none leaves this short of the request count." },
        el("b", { text: fmtTokens(tokens) }), " tokens"),
    ]);
    // A view-wide statement about this range, not about the current selection: a bucket that
    // mixes a priced and an unpriced call still carries a number, so no model, day or hour in
    // this view can be read as complete while any request here is unpriced.
    if (unpricedCalls > 0) {
      nodes.push(el("span", { class: "totals-sep", text: "·" }));
      nodes.push(el("span", {
        class: "totals-note warn",
        text: `partial cost · ${plural(unpricedCalls, "request", "requests")} unpriced`,
        title: "Some calls in this range have no cost receipt and no local price row, so they are"
          + " left out of every dollar figure here rather than counted as zero — including the ones"
          + " shown for a single model, day or hour: " + ((t.gateway_unpriced_models || []).join(", ") || "no model reported"),
      }));
    }
    nodes.push(el("span", { class: "totals-note", text: "routed through Keys only · ≈ estimate from list prices, not an invoice" }));
    $("totals").replaceChildren(...nodes);
  }
  const appendParts = (nodes, list) => list.forEach((p) => { nodes.push(el("span", { class: "totals-sep", text: "·" })); nodes.push(p); });

  // One line in the chosen unit: the headline figure first, then the parts that make it up.
  function renderTotals(data) {
    if (keysMode()) return renderKeysTotals(data);
    const t = data.totals || {};
    const src = state.source;
    const parts = [];
    // Tokens are what the tools' own logs measured; the dollar figure is this repo's price table
    // applied to them afterwards. Only an explicit USD choice puts money on screen.
    if (!usdMode()) {
      const b = seriesBreakdown();
      const byFamily = new Map();
      for (const s of state.series) {
        const f = projectMode() ? "project" : family(s.model || "");
        byFamily.set(f, (byFamily.get(f) || 0) + (s.tokens || 0));
      }
      const nodes = [el("span", {
        class: "totals-main" + (b.tokens ? "" : " none"),
        text: fmtTokens(b.tokens) + " tokens",
        title: breakdownTitle(b),
      })];
      if (src === "all" && !projectMode()) {
        // Every family a fixture can hold, so the parts always sum to the headline beside them.
        for (const [fam, label] of [["grok", "Grok"], ["claude", "Claude"], ["openai", "OpenAI"], ["gemini", "Gemini"], ["glm", "GLM"], ["kimi", "Kimi"], ["deepseek", "DeepSeek"], ["other", "other"]]) {
          const n = byFamily.get(fam) || 0;
          if (n > 0) parts.push(el("span", { class: "totals-part" }, el("b", { text: fmtTokens(n) }), " " + label));
        }
      }
      parts.forEach((p) => { nodes.push(el("span", { class: "totals-sep", text: "·" })); nodes.push(p); });
      if (b.cached > 0) {
        nodes.push(el("span", { class: "totals-sep", text: "·" }));
        nodes.push(el("span", { class: "totals-note", text: fmtTokens(b.cached) + " cached input", title: CACHE_NOTE }));
      }
      const rt = remoteTokens(data);
      nodes.push(el("span", { class: "totals-note", text: src === "cloud"
        ? "imported from the cloud, recorded off this Mac · not priced"
        : rt > 0 ? `counted from the tools' own local logs on this Mac plus ${fmtTokens(rt)} tokens imported from the cloud · choose USD above for cost`
        : "counted from the tools' own local logs on this Mac · choose USD above for cost" }));
      $("totals").replaceChildren(...nodes);
      return;
    }
    if (src === "cloud") {
      // Imported usage has no dollar figure; a measured-looking $0.00 would be a fake number.
      const tk = state.series.reduce((a, s) => a + s.tokens, 0);
      $("totals").replaceChildren(
        el("span", { class: "totals-main none", text: "not priced", title: "Imported cloud usage carries no dollar figure." }),
        el("span", { class: "totals-sep", text: "·" }),
        el("span", { class: "totals-part" }, el("b", { text: fmtTokens(tk) }), " tokens"),
        el("span", { class: "totals-note", text: "imported from the cloud, recorded off this Mac · choose Tokens above to compare" }));
      return;
    }
    if (src === "droid") {
      // Droid's log has no cost field and the engine puts no list price on its rows, so there is
      // no dollar figure to show: not $0.00, and not Grok's receipt either.
      const tk = state.series.reduce((a, s) => a + s.tokens, 0);
      $("totals").replaceChildren(
        el("span", { class: "totals-main none", text: "not priced", title: "Droid's local log carries no dollar figure." }),
        el("span", { class: "totals-sep", text: "·" }),
        el("span", { class: "totals-part" }, el("b", { text: fmtTokens(tk) }), " tokens"),
        el("span", { class: "totals-note", text: "counted from Droid's own local log on this Mac · choose Tokens above to compare" }));
      return;
    }
    const showGrok = src === "all" || src === "grok";
    const showClaude = src === "all" || src === "claude";
    const showOpenAI = src === "all" || src === "openai";
    const grok = showGrok ? Number(t.grok_usd) || 0 : 0;
    const claude = showClaude && t.claude_usd_estimate != null ? Number(t.claude_usd_estimate) : 0;
    const openai = showOpenAI && t.openai_usd_estimate != null ? Number(t.openai_usd_estimate) : 0;
    const total = grok + claude + openai;
    const anyEst = (showClaude && claude > 0) || (showOpenAI && openai > 0);
    const nodes = [el("span", { class: "totals-main" + (anyEst ? " est" : ""), text: (anyEst ? "≈ " : "") + fmtUsd(total) })];
    if (showGrok && src === "all") parts.push(el("span", { class: "totals-part" }, el("b", { text: fmtUsd(grok) }), " Grok"));
    if (showClaude && src === "all") parts.push(el("span", { class: "totals-part" }, el("b", { text: "≈ " + fmtUsd(claude) }), " Claude"));
    if (showOpenAI && src === "all") parts.push(el("span", { class: "totals-part" }, el("b", { text: "≈ " + fmtUsd(openai) }), " OpenAI"));
    const tokens = state.series.reduce((a, s) => a + s.tokens, 0);
    parts.push(el("span", { class: "totals-part" }, el("b", { text: fmtTokens(tokens) }), " tokens"));
    // Gateway dollars are a separate ledger: a routed Claude Code or Codex call is also in a local
    // log, so the engine never adds them into the headline figure.
    const gwCalls = Number(t.gateway_calls) || 0;
    const gwUnpriced = Number(t.gateway_unpriced_calls) || 0;
    if (src === "all" && (gwCalls > 0 || t.gateway_usd_estimate != null)) {
      const gw = t.gateway_usd_estimate != null ? Number(t.gateway_usd_estimate) : null;
      const label = gw == null ? "unpriced" : "≈ " + fmtUsd(gw);
      const why = gwUnpriced > 0
        ? `${plural(gwUnpriced, "gateway call", "gateway calls")} could not be priced (${(t.gateway_unpriced_models || []).join(", ") || "no model"}).`
        : "";
      parts.push(el("span", { class: "totals-part", title: ("Calls routed through the local gateway that no local log also recorded. Uses provider-reported cost where available, otherwise a list-price estimate. Not added to the total above. " + why).trim() },
        el("b", { text: label }), " via gateway"));
    }
    parts.forEach((p, i) => { if (i) nodes.push(el("span", { class: "totals-sep", text: "·" })); nodes.push(p); });
    const unpriced = unpricedModels(data);
    if (unpriced.length) {
      nodes.push(el("span", { class: "totals-sep", text: "·" }));
      nodes.push(el("span", { class: "totals-note warn", text: `${plural(unpriced.length, "model", "models")} unpriced`, title: "No local price row, left out of the estimate: " + unpriced.join(", ") }));
    }
    const rtUsd = remoteTokens(data);
    if (rtUsd > 0) {
      nodes.push(el("span", { class: "totals-sep", text: "·" }));
      nodes.push(el("span", { class: "totals-note warn", text: `partly priced · ${fmtTokens(rtUsd)} tokens imported from the cloud (not priced)`, title: "Imported cloud usage carries no dollar figure, so it is left out of the dollars here rather than counted as zero." }));
    }
    // Grok's receipt is named only when Grok is the only tool with dollars here. Claude or
    // OpenAI at $0.00 is still an estimate (of nothing), never Grok's log; all-zero says nothing.
    const grokOnly = src === "grok" || (src === "all" && !anyEst && grok > 0);
    const note = grokOnly ? "from Grok's own cost log" : (anyEst || src !== "all") ? "≈ estimate from list prices, not an invoice" : "";
    if (note) nodes.push(el("span", { class: "totals-note", text: note }));
    $("totals").replaceChildren(...nodes);
  }

  // Models the engine could not price.
  function unpricedModels(data) {
    if (projectMode()) return [];
    const t = data.totals || {};
    return [].concat(t.claude_unpriced_models || [], t.openai_unpriced_models || []);
  }

  function renderInterval(data) {
    const node = $("interval");
    const label = state.range === "week" ? "This week" : state.range === "month" ? "This month" : "Today";
    const startDay = data.start_day;
    const endDay = data.end_day;
    const dates = fmtRange(startDay, endDay);
    const a = parseDay(startDay);
    const b = parseDay(endDay);
    const crosses = a && b && (a.y !== b.y || a.m !== b.m);
    node.replaceChildren();
    node.hidden = state.range === "today";
    node.append(el("span", { text: label }));
    if (dates && state.range !== "today") {
      node.append(" ");
      node.append(el("span", {
        class: "interval-dates" + (crosses ? " interval-cross" : ""),
        text: dates,
      }));
    }
  }

  // The bar follows the chosen unit; the two other figures stay on the row, so a model whose
  // provider reported no tokens still shows its request count rather than reading as nothing.
  const seriesValue = (s) => (usdMode() ? dollars(s) || 0 : requestMode() ? s.calls || 0 : s.tokens);
  function renderMix() {
    const list = $("mix");
    const usd = usdMode();
    // A row's dollars are only the calls that could be priced. The engine reports unpriced calls
    // for the range, not per row, so while any exist no row's figure may be read as complete —
    // the row tooltip has to say so too, not just the totals line.
    const partial = keysMode() && Number((state.spend.totals || {}).gateway_unpriced_calls) > 0;
    const partialNote = "\nPartial: some calls in this range have no cost receipt and no list price,"
      + " and are left out of this figure rather than counted as zero";
    const max = Math.max(1e-9, ...state.series.map(seriesValue));
    const items = state.series.map((s) => {
      const d = dollars(s);
      const isEst = s.usd == null && s.est != null;
      // A dollar figure on a row that also holds imported cloud tokens covers only its local part.
      const partlyPriced = d != null && (s.remote || 0) > 0;
      const usdNode = d == null
        ? el("span", { class: "mix-usd none", text: "—", title: keysMode() ? "No cost receipt and no list price for this model: unknown, not zero." : null })
        : el("span", {
          class: "mix-usd" + (usd ? " mix-primary" : ""),
          text: (partlyPriced ? "partly priced · " : "") + (partial ? "≥ " : "") + (isEst ? "≈ " : "") + fmtUsd(d),
          title: partlyPriced ? PARTLY_PRICED_NOTE + (partial ? partialNote : "") : partial ? partialNote.trim() : null,
        });
      const noTokens = keysMode() && !s.tokens && (s.calls || 0) > 0;
      const tokNode = el("span", {
        class: "mix-val" + (usd ? "" : " mix-primary") + (!usd && noTokens && !requestMode() ? " none" : ""),
        text: requestMode()
          ? plural(s.calls || 0, "request", "requests")
          : noTokens ? "no reported tokens" : fmtTokens(s.tokens),
        title: noTokens && !requestMode() ? "This provider reported no token counts for these requests: unknown, not a measured zero." : null,
      });
      // In a token or request view the second figure is the other measured count, never a price.
      // Dollars appear on this row only when USD was chosen.
      const sideNode = usd ? tokNode : keysMode()
        ? el("span", { class: "mix-val", text: requestMode() ? (s.tokens ? fmtTokens(s.tokens) + " tok" : "—") : plural(s.calls || 0, "request", "requests") })
        : el("span", { class: "mix-val" });
      const barFrac = seriesValue(s) / max;
      const detail = (s.cwd ? s.cwd + "\n" : "")
        + (keysMode()
          ? `${plural(s.calls || 0, "request", "requests")}`
            + `${s.provider ? " · " + s.provider.split(",").map(providerName).join(", ") : ""}`
            + `${s.key ? " · key " + s.key : ""}\n`
          : "")
        + `${fmtInt(s.input)} in, ${fmtInt(s.output)} out, ${fmtInt(s.cached)} cached reads, ${fmtInt(s.created)} cache writes`
        + (s.cached ? "\n" + CACHE_NOTE : "")
        + (usd && isEst ? "\nUSD is an estimate from list prices" : "")
        + (usd && keysMode() && d == null ? "\nUSD unknown: no receipt and no list price" : "")
        + (usd && partial && d != null ? partialNote : "")
        + (usd && partlyPriced ? "\n" + PARTLY_PRICED_NOTE : "")
        + (s.members.length > 1 ? `\n${(s.labels || s.members).join(", ")}` : "");
      const on = state.mixFilter === s.model;
      const li = el("li", {
        class: "mix-row",
        title: detail,
        "data-model": s.model,
        role: "option",
        tabindex: on || (!state.mixFilter && s === state.series[0]) ? "0" : "-1",
        "aria-selected": String(on),
        "aria-label": (on ? "Showing only " : "Filter chart to ") + (s.label || s.model),
      },
        el("span", { class: "sw" }),
        el("span", { class: "mix-name", text: s.label || s.model }),
        el("span", { class: "mix-bar" }, el("i", { style: `width:${Math.max(0, barFrac * 100).toFixed(1)}%` })),
        usd ? usdNode : tokNode,
        sideNode,
      );
      li.style.setProperty("--c", s.color);
      return li;
    });
    // A long legend scrolls; no model is merged away to shorten it.
    list.classList.toggle("mix-many", items.length > 12);
    list.replaceChildren(...items);
  }

  function toggleMix(model, keepFocus) {
    state.mixFilter = state.mixFilter === model ? null : model;
    renderMix();
    drawChart();
    if (keepFocus) {
      const li = [...$("mix").querySelectorAll(".mix-row")].find((n) => n.dataset.model === model);
      if (li) li.focus();
    }
  }

  $("mix").addEventListener("click", (e) => {
    const li = e.target.closest(".mix-row");
    if (!li) return;
    toggleMix(li.dataset.model, false);
  });
  $("mix").addEventListener("keydown", (e) => {
    const li = e.target.closest(".mix-row");
    if (!li) return;
    const items = [...$("mix").querySelectorAll(".mix-row")];
    const j = listStep(e.key, items.indexOf(li), items.length);
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      toggleMix(li.dataset.model, true);
    } else if (j >= 0) {
      e.preventDefault();
      items[j].focus();
    }
  });

  // Only elapsed days: the axis runs from the range start to today (or the range end, if earlier).
  function axisDays(data) {
    const out = [];
    const today = new Date();
    const start = parseDay(data.start_day).date;
    let end = parseDay(data.end_day).date;
    const todayMidnight = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    if (end > todayMidnight) end = todayMidnight;
    const d = new Date(start);
    while (d <= end) { out.push(isoDay(d)); d.setDate(d.getDate() + 1); }
    for (const p of data.daily || []) if (p.day && !out.includes(p.day)) out.push(p.day);
    out.sort();
    return out;
  }

  function niceCeil(v) {
    if (v <= 0) return 1;
    const p = Math.pow(10, Math.floor(Math.log10(v)));
    const m = v / p;
    const step = m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10;
    return step * p;
  }

  function roundedTop(x, y, w, h, r) {
    r = Math.min(r, w / 2, h);
    return `M${x},${y + h} V${y + r} Q${x},${y} ${x + r},${y} H${x + w - r} Q${x + w},${y} ${x + w},${y + r} V${y + h} Z`;
  }

  // Stacked bars, one column per bucket, series = model. Shared by the daily and hourly charts.
  function drawBars(opts) {
    const { svg, tipId, buckets, points, keyOf, labelOf, tickOf, labelEvery, maxLabels } = opts;
    const usd = usdMode();
    const requests = requestMode();
    const fmt = usd ? fmtUsd : requests ? fmtInt : fmtTokens;
    // Requests are whole things: a gridline reading "2.5 requests" would be a lie about the data.
    const fmtAxis = usd ? fmtUsdAxis : requests ? (v) => fmtInt(Math.round(v)) : fmtTokens;

    const memberOf = new Map();
    for (const s of state.series) for (const m of s.members) memberOf.set(m, s);

    const byBucket = new Map(buckets.map((b) => [b, new Map()]));
    for (const p of points) {
      const s = memberOf.get(seriesId(p));
      if (!s) continue;
      const m = byBucket.get(keyOf(p));
      if (!m) continue;
      const v = usd ? (dollars(p) || 0) : requests ? Number(p.model_calls) || 0 : Number(p.tokens) || 0;
      m.set(s.model, (m.get(s.model) || 0) + v);
    }
    const totals = buckets.map((b) => {
      let sum = 0;
      for (const [model, v] of byBucket.get(b)) if (!state.mixFilter || model === state.mixFilter) sum += v;
      return sum;
    });
    const maxV = niceCeil(Math.max(0, ...totals));

    const W = Math.max(280, svg.clientWidth || 800);
    const H = svg.clientHeight || 200;
    const padL = 44, padR = 8, padT = 8, padB = 22;
    const plotW = W - padL - padR;
    const plotH = H - padT - padB;
    const base = padT + plotH;
    const slot = plotW / Math.max(1, buckets.length);
    const bw = Math.max(3, Math.min(22, Math.floor(slot * 0.72)));

    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    svg.replaceChildren();

    for (const f of [1, 0.5]) {
      const y = Math.round(base - plotH * f) + 0.5;
      svg.append(svgEl("line", { class: "grid", x1: padL, x2: W - padR, y1: y, y2: y }));
      const t = svgEl("text", { x: padL - 8, y: y + 4, "text-anchor": "end" });
      t.textContent = fmtAxis(maxV * f);
      svg.append(t);
    }
    svg.append(svgEl("line", { class: "base", x1: padL, x2: W - padR, y1: base + 0.5, y2: base + 0.5 }));
    const zero = svgEl("text", { x: padL - 8, y: base + 4, "text-anchor": "end" });
    zero.textContent = "0";
    svg.append(zero);

    const every = labelEvery || (buckets.length <= maxLabels ? 1 : Math.ceil(buckets.length / maxLabels));
    buckets.forEach((bucket, i) => {
      const x = padL + i * slot;
      const cx = x + slot / 2;
      const g = svgEl("g", { class: "col", tabindex: "0", role: "img" });
      const hit = svgEl("rect", { class: "hit", x: x + 1, y: padT - 4, width: Math.max(1, slot - 2), height: plotH + 4, rx: 3 });
      g.append(hit);

      const values = byBucket.get(bucket);
      let cum = 0;
      const segs = [];
      for (const s of state.series) {
        if (state.mixFilter && s.model !== state.mixFilter) continue;
        const v = values.get(s.model) || 0;
        if (v <= 0) continue;
        const hPx = (v / maxV) * plotH;
        segs.push({ s, v, y0: base - cum - hPx, h: hPx, first: cum === 0 });
        cum += hPx;
      }
      segs.forEach((seg, k) => {
        const top = k === segs.length - 1;
        const gap = seg.first ? 0 : 2;
        const h = Math.max(seg.h - gap, seg.v > 0 ? 2 : 0);
        if (h < 0.75) return;
        const bx = Math.round(cx - bw / 2);
        const shape = top
          ? svgEl("path", { d: roundedTop(bx, seg.y0, bw, h, 3), fill: seg.s.color })
          : svgEl("rect", { x: bx, y: seg.y0, width: bw, height: h, fill: seg.s.color });
        g.append(shape);
      });

      const lines = segs.map((seg) => `${seg.s.label || seg.s.model} ${fmt(seg.v)}`);
      g.setAttribute("aria-label", `${labelOf(bucket)}: ${lines.length ? lines.join(", ") : "nothing"}`);
      const last = i === buckets.length - 1 && (i % every) * 2 >= every;
      if (i % every === 0 || last) {
        const t = svgEl("text", { x: cx, y: H - 6, "text-anchor": "middle" });
        t.textContent = tickOf(bucket);
        g.append(t);
      }

      const show = () => showTip(tipId, labelOf(bucket), segs, cx, W, totals[i], fmt);
      g.addEventListener("pointerenter", show);
      g.addEventListener("focus", show);
      g.addEventListener("pointerleave", () => hideTip(tipId));
      g.addEventListener("blur", () => hideTip(tipId));
      svg.append(g);
    });
  }

  function unitLabel(per) {
    if (requestMode()) return "requests per " + per;
    if (!usdMode()) return "tokens per " + per + (keysMode() ? " · providers that report none are absent here" : "");
    if (keysMode()) return "USD per " + per + " · receipt where reported, else list-price estimate; unpriced calls absent";
    const grokOnly = state.source === "grok";
    return "USD per " + per + (grokOnly ? "" : " · estimate except Grok");
  }

  // The plot can only draw the chosen unit, and a gateway call may carry no tokens and no cost
  // at all. Saying so — and naming the unit that does have data — beats an empty plot that reads
  // as "nothing happened".
  function setChartNote(points, emptyText) {
    const node = $("chart-nothing");
    // A chosen mix row is part of the question: with one model selected the plot draws only that
    // model, so the explanation has to describe that model's requests and not the whole range's.
    const memberOf = new Map();
    for (const s of state.series) for (const m of s.members) memberOf.set(m, s.model);
    const pool = keysMode() && state.mixFilter
      ? points.filter((p) => memberOf.get(seriesId(p)) === state.mixFilter)
      : points;
    const value = (p) => (usdMode() ? dollars(p) || 0 : requestMode() ? p.model_calls || 0 : p.tokens || 0);
    const drawable = pool.some((p) => value(p) > 0);
    const routed = pool.filter((p) => (p.model_calls || 0) > 0);
    if (!drawable && keysMode() && !requestMode() && routed.length) {
      // Zero and unknown are different answers. A cost of zero the provider actually reported is
      // knowledge; calling it missing would contradict a totals line that reads $0.00. Only an
      // absent figure — dollars(p) === null — is a receipt this view never got.
      const known = usdMode() ? routed.filter((p) => dollars(p) != null).length : 0;
      // A bucket's dollars are a sum, so a priced figure of zero can still hide an unpriced call
      // beside it: one day, one model, a receipt of $0 plus a call with no receipt at all sums to
      // usd_estimate 0 with no per-bucket count of what went unpriced. Counting priced buckets
      // therefore cannot establish that nothing is missing. The range-wide unpriced count can:
      // while it is above zero, the flat "$0.00" claim is withheld and the doubt said out loud.
      const unpricedInRange = Number((state.spend.totals || {}).gateway_unpriced_calls) > 0;
      const why = !usdMode() ? "No tokens were reported for these requests."
        : known === 0 ? "No cost was reported for these requests."
          : known < routed.length ? "Part of these requests cost $0.00; no cost was reported for the rest."
            : unpricedInRange ? "The cost reported for these requests is $0.00; some calls in this range are unpriced."
              : "These requests cost $0.00.";
      node.textContent = why + " Switch to Requests to chart them.";
      node.hidden = false;
      return;
    }
    node.textContent = emptyText;
    node.hidden = drawable || !emptyText;
  }

  function drawChart() {
    const svg = $("daily-svg");
    const data = state.spend;
    if (!data || $("daily").hidden) return;
    if (todayMode()) {
      const points = data.points || [];
      $("daily-title").textContent = "Today by hour";
      $("daily-unit").textContent = unitLabel("hour");
      const now = new Date();
      const today = isoDay(now);
      const hours = [];
      for (let h = 0; h <= now.getHours(); h++) hours.push(`${today}T${pad2(h)}:00`);
      for (const p of points) if (p.hour && !hours.includes(p.hour)) hours.push(p.hour);
      hours.sort();
      setChartNote(points, "Nothing yet today.");
      drawBars({
        svg, tipId: "daily-tip", buckets: hours, points,
        keyOf: (p) => p.hour, labelOf: (h) => "Today " + fmtHour(h), tickOf: fmtHourTick,
        labelEvery: hours.length > 12 ? 3 : 1,
      });
      return;
    }
    $("daily-title").textContent = (state.range === "week" ? "This week by day" : "This month by day") + (projectMode() ? " · by project" : "");
    $("daily-unit").textContent = unitLabel("day");
    setChartNote(data.daily || [], "");
    const days = axisDays(data);
    drawBars({
      svg, tipId: "daily-tip", buckets: days, points: data.daily || [],
      keyOf: (p) => p.day, labelOf: fmtDay, tickOf: fmtDay, maxLabels: 10,
    });
  }

  function showTip(tipId, title, segs, cx, W, total, fmt) {
    const tip = $(tipId);
    const fig = tip.parentNode;
    const rows = segs.slice().reverse().map((seg) =>
      el("div", { class: "row" },
        el("span", { class: "sw", style: `--c:${seg.s.color}` }),
        el("span", { text: seg.s.label || seg.s.model }),
        el("span", { text: fmt(seg.v) })),
    );
    tip.replaceChildren(
      el("b", { text: title }),
      ...(rows.length ? rows : [el("div", { class: "row" }, el("span", { text: "nothing" }))]),
      ...(rows.length > 1 ? [el("div", { class: "total" }, el("span", { text: "total" }), el("span", { text: fmt(total) }))] : []),
      // A day or hour's dollars cover only the calls that could be priced, and the engine counts
      // unpriced calls for the range rather than per bucket. While any exist, say so here too.
      ...(usdMode() && keysMode() && Number((state.spend.totals || {}).gateway_unpriced_calls) > 0
        ? [el("div", { class: "row tip-note", text: "partial · some calls in this range are unpriced" })]
        : []),
    );
    tip.hidden = false;
    const fw = fig.clientWidth;
    const tw = tip.offsetWidth;
    const left = Math.max(0, Math.min(fw - tw, (cx / W) * fw - tw / 2));
    tip.style.left = left + "px";
  }
  function hideTip(tipId) { $(tipId).hidden = true; }

  new ResizeObserver(() => { if (state.pane === "chart") drawChart(); }).observe($("daily"));

  // ---------- keys ----------

  // Refreshes overlap: a copy defers one by 2.5 s, closing the reveal dialog
  // starts another, and every CRUD call ends with one. A slow reply carries the
  // vault as it was when the engine answered, so landing it after a newer reply
  // would resurrect a deleted key or drop one just added. Only the newest wins,
  // as in loadSpend.
  let keysSeq = 0;
  async function loadKeys(opts = {}) {
    const seq = ++keysSeq;
    try {
      const data = await api("/api/keys");
      if (seq !== keysSeq) return;
      state.keys = data.keys || [];
      paneError("keys-error");
      renderKeys(opts);
      loadGrants();
    } catch (e) {
      if (seq !== keysSeq) return;
      if (!opts.quiet) paneError("keys-error", e);
    }
  }

  // Per-viewer convenience only; the page works the same without storage.
  const keySorts = {
    name: (a, b) => a.name.localeCompare(b.name),
    // Keys never copied, revealed or proxied sort last rather than first.
    recent: (a, b) => (b.last_used_at || "").localeCompare(a.last_used_at || ""),
    most: (a, b) => (Number(b.gateway_month_calls) || 0) - (Number(a.gateway_month_calls) || 0),
    newest: (a, b) => (b.created_at || "").localeCompare(a.created_at || ""),
    oldest: (a, b) => (a.created_at || "\uffff").localeCompare(b.created_at || "\uffff"),
  };
  const readKeySort = () => { try { const v = localStorage.getItem("ksf.keysort"); return keySorts[v] ? v : "name"; } catch { return "name"; } };
  state.keySort = readKeySort();

  // Names and provider metadata only: the keys payload carries no secret to match against.
  function keyMatches(k, q) {
    if (!q) return true;
    const prov = providerById(k.provider);
    const group = prov && state.providers ? (state.providers.groups || []).find((g) => g.id === prov.group) : null;
    return [k.name, k.provider, providerName(k.provider), group && group.name, k.host, k.gateway_host]
      .some((v) => typeof v === "string" && v.toLowerCase().includes(q));
  }
  const keyRows = () => [...$("keys-body").querySelectorAll(".key-row")];
  let keyMenuFor = null;
  let menuFocusReturn = null;

  // A provider's tile shows initials, never a brand mark. The rule, from the display name (the
  // raw id when the catalog has none): split on spaces, "-", "_" and "."; keep only letters and
  // digits of each word; two or more words give the first letter of the first two, uppercased
  // ("Cloudflare AI Gateway" → "CA", "Moonshot (Kimi)" → "MK"); one word gives its first letter
  // uppercased and its second lowercased ("OpenAI" → "Op", "Anthropic" → "An"); nothing left
  // gives "?".
  function providerInitials(id) {
    const name = id ? providerName(id) : "";
    const words = name.split(/[\s\-_.]+/).map((w) => w.replace(/[^\p{L}\p{N}]/gu, "")).filter(Boolean);
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    if (words.length === 1) return words[0][0].toUpperCase() + (words[0][1] || "").toLowerCase();
    return "?";
  }
  // One of eight tints (styles.css .tint-0 … .tint-7, the chart's vendor colours), chosen by a
  // hash of the provider id so a provider keeps its colour across keys, sessions and themes.
  const TINTS = 8;
  function providerTint(id) {
    let h = 0;
    for (const c of id || "") h = (h * 31 + c.codePointAt(0)) >>> 0;
    return "tint-" + (h % TINTS);
  }

  function renderKeys(opts = {}) {
    const body = $("keys-body");
    const by = keySorts[state.keySort] || keySorts.name;
    const q = state.keySearch.trim().toLowerCase();
    const all = state.keys;
    renderKeysProviderFilter();
    // One flat list in the chosen order; equal keys fall back to their names.
    const keys = all.filter((k) => (!state.keyProviderFilter || k.provider === state.keyProviderFilter)
      && keyMatches(k, q)).sort((a, b) => by(a, b) || keySorts.name(a, b));
    $("keys-sort").value = state.keySort;
    const filtered = !!q || !!state.keyProviderFilter;
    $("keys-count").textContent = filtered
      ? `${keys.length} of ${plural(all.length, "key", "keys")}`
      : plural(all.length, "key", "keys");
    syncOnboard();
    $("keys-list").hidden = keys.length === 0;
    $("keys-sort-label").hidden = all.length === 0;
    $("keys-provider-label").hidden = all.length === 0;
    $("keys-search-box").hidden = all.length === 0 && !q;
    $("keys-empty").hidden = all.length > 0;
    $("keys-no-match").hidden = all.length === 0 || keys.length > 0;
    if (all.length > 0 && keys.length === 0) {
      $("keys-no-match").textContent = state.keyProviderFilter && !all.some((k) => k.provider === state.keyProviderFilter)
        ? `No keys for ${providerName(state.keyProviderFilter)}.`
        : `No keys match “${state.keySearch.trim()}”.`;
    }
    if (!keys.some((k) => k.name === state.selected)) state.selected = keys[0] ? keys[0].name : null;

    // A background refresh replaces the rows; if a row had focus, it would fall to <body> and the
    // next arrow key would be spent refocusing instead of moving.
    const hadFocus = body.contains(document.activeElement) && document.activeElement.classList.contains("key-row");
    if (keyMenuFor) closeKeyMenu({ restoreFocus: false });
    body.replaceChildren(...keys.map(keyRow).flat());
    if (state.eventsOpen) loadEvents(state.eventsOpen);
    if ((opts.focus || hadFocus) && state.selected) {
      const row = rowFor(state.selected);
      if (row) row.focus();
    }
  }

  function renderKeysProviderFilter() {
    const select = $("keys-provider");
    const ids = [...new Set(state.keys.map((k) => k.provider).filter(Boolean))]
      .sort((a, b) => providerName(a).localeCompare(providerName(b)));
    if (state.keyProviderFilter && !ids.includes(state.keyProviderFilter)) state.keyProviderFilter = "";
    select.replaceChildren(
      el("option", { value: "", text: "All providers" }),
      ...ids.map((id) => el("option", { value: id, text: providerName(id) })),
    );
    select.value = state.keyProviderFilter;
  }

  // Name, provider and last use, as the design shows them, plus only what is true of this key:
  // the gateway badge and URL when it is on, this month's gateway figure when there is one, the
  // host, the last check and the notes. The actions column keeps its full width even while it
  // holds only Copy, so adding a control there later does not move the rest of the row.
  function keyRow(k) {
    const selected = k.name === state.selected;
    const tab = selected ? "0" : "-1";
    const on = !!k.gateway_enabled;
    const row = el("div", {
      class: "key-row", role: "listitem", tabindex: tab, "data-name": k.name,
      "aria-current": selected ? "true" : null,
    });
    const gateway = gatewayMonthCell(k, tab);
    const meta = [
      gateway ? el("span", { class: "key-gateway-wrap" }, gateway, el("span", { class: "key-gateway-note", text: " this month" })) : null,
      k.last_check ? el("span", { class: "key-check", text: (k.last_check.ok ? "✓ " : "✗ ") + k.last_check.summary + " · " + relTime(k.last_check.checked_at), title: "Last read-only check " + k.last_check.checked_at }) : null,
    ].filter(Boolean);
    const names = el("div", { class: "key-names" },
      el("div", { class: "key-title" },
        el("span", { class: "key-name", text: k.name, title: k.name }),
        on ? el("span", { class: "badge", text: "Gateway on", title: "Requests to the local gateway use this key until the engine restarts" }) : null),
      el("div", { class: "key-sub", title: k.host ? "Requests bound to " + k.host : "No fixed host" },
        el("span", { class: "key-provider", text: k.provider ? providerName(k.provider) : "No provider" }),
        k.host ? el("span", { class: "key-host", text: k.host }) : null),
      meta.length ? el("div", { class: "key-meta" }, ...meta) : null,
      on && k.gateway_url ? el("span", { class: "key-notes gw-url", text: k.gateway_url, title: "Point the SDK base URL here. Select to copy." }) : null,
      k.notes ? el("span", { class: "key-notes", text: k.notes, title: k.notes }) : null,
    );
    const copy = el("button", {
      type: "button", class: "btn-copy", tabindex: tab, "data-act": "copy", "aria-label": "Copy " + k.name,
      title: "Copy to the clipboard after Touch ID; it is wiped after 20 s",
    }, svgIcon(COPY_ICON), el("span", { class: "btn-label", text: "Copy" }));
    const more = el("button", {
      type: "button", class: "btn-menu", tabindex: tab, "data-act": "menu",
      "aria-haspopup": "menu", "aria-expanded": "false", "aria-controls": "key-menu",
      "aria-label": "More actions for " + k.name, title: "More actions",
    }, svgIcon(MORE_ICON));
    row.append(
      el("div", { class: "key-identity" },
        el("span", { class: ["key-avatar", providerTint(k.provider)].join(" "), "aria-hidden": "true", text: providerInitials(k.provider) }),
        names),
      el("span", { class: "key-used", text: k.last_used_at ? relTime(k.last_used_at) : "Never used", title: k.last_used_at || "Never copied, revealed or proxied" }),
      el("div", { class: "key-actions" }, copy, more),
    );
    if (state.eventsOpen === k.name) return [row, eventsRow(k)];
    return row;
  }
  const COPY_ICON = ["M15 8V4a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h4", { rect: { x: "8", y: "8", width: "12", height: "12", rx: "2.2" } }];
  const MORE_ICON = [
    { circle: { cx: "5", cy: "12", r: "1", fill: "currentColor" } },
    { circle: { cx: "12", cy: "12", r: "1", fill: "currentColor" } },
    { circle: { cx: "19", cy: "12", r: "1", fill: "currentColor" } },
  ];
  function svgIcon(parts) {
    const svg = svgEl("svg", { class: "vicon", viewBox: "0 0 24 24", "aria-hidden": "true" });
    for (const p of parts) {
      if (typeof p === "string") svg.append(svgEl("path", { d: p }));
      else for (const [tag, attrs] of Object.entries(p)) svg.append(svgEl(tag, attrs));
    }
    return svg;
  }

  function selectRow(name, focus) {
    state.selected = name;
    for (const row of keyRows()) {
      const on = row.dataset.name === name;
      if (on) row.setAttribute("aria-current", "true"); else row.removeAttribute("aria-current");
      row.tabIndex = on ? 0 : -1;
      row.querySelectorAll("[data-act]").forEach((btn) => { btn.tabIndex = on ? 0 : -1; });
      if (on && focus) row.focus();
    }
  }
  const rowFor = (name) => keyRows().find((row) => row.dataset.name === name) || null;
  const btnFor = (name, act) => { const row = rowFor(name); return row ? row.querySelector(`[data-act="${act}"]`) : null; };

  function restoreKeysFocus(name, act) {
    if (state.pane !== "keys") return;
    const target = name || state.selected;
    if (menuFocusReturn && menuFocusReturn.name === target
        && (!act || menuFocusReturn.act === act)) {
      const more = btnFor(target, "menu");
      if (more) { more.focus(); return; }
    }
    if (act) {
      const btn = btnFor(target, act);
      if (btn) { btn.focus(); return; }
    }
    const row = rowFor(target);
    if (row) row.focus();
  }

  // One table for a row's buttons and its letter keys. Copy and reveal are list-only: from
  // elsewhere in the pane c and v stay free, so only PANE_KEYS reach the selected row there.
  // "chart" is the gateway figure's button and has no letter of its own.
  const ROW_ACT = { copy: copyKey, reveal: revealKey, edit: openEdit, gateway: toggleGateway, grant: openGrant, check: runCheck, history: toggleEvents, rotate: openRotate, delete: askDelete, chart: showKeyInChart };
  const PANE_KEYS = { e: "edit", g: "gateway", a: "grant", t: "check", h: "history", r: "rotate" };
  const LIST_KEYS = { ...PANE_KEYS, c: "copy", v: "reveal" };
  const KEY_MENU_ITEMS = [
    { act: "reveal", label: "Reveal key", shortcut: "V", icon: ["M2.5 12s3.5-6 9.5-6 9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6z", { circle: { cx: "12", cy: "12", r: "2.5" } }] },
    { act: "edit", label: "Edit details", shortcut: "E", icon: ["m14 5 5 5M4 20l4.5-1 12-12a2 2 0 0 0-5-5l-12 12z"] },
    null,
    { act: "grant", label: "Access & grants", shortcut: "A", icon: ["M7 14a4 4 0 1 1 2.8-6.8L21 18.4l-2.6 2.6-2-2-2 1-2-2 1-2-2-2"] },
    { act: "gateway", label: "", shortcut: "G", icon: ["M4 12a8 8 0 1 0 2.3-5.7", "M4 4v4h4"] },
    { act: "history", label: "Activity", shortcut: "H", icon: [{ circle: { cx: "12", cy: "12", r: "8.5" } }, "M12 7v5l3 2"] },
    { act: "check", label: "Check connection", shortcut: "T", icon: [{ circle: { cx: "12", cy: "12", r: "8.5" } }, "m8 12 3 3 5-6"] },
    { act: "rotate", label: "Rotate key…", shortcut: "R", icon: ["M20 10a8 8 0 1 0-2 8", "M20 4v6h-6"] },
    null,
    { act: "delete", label: "Delete key…", icon: ["M4 6h16M9 6V3h6v3M6 6l1 15h10l1-15M10 10v7m4-7v7"], destructive: true },
  ];

  function menuItemDisabled(act, key) {
    const provider = providerById(key.provider);
    return ((act === "gateway" || act === "grant") && provider && provider.gateway === false)
      || (act === "check" && !key.checkable);
  }
  function renderKeyMenu(key) {
    $("key-menu").replaceChildren(...KEY_MENU_ITEMS.map((item) => {
      if (!item) return el("div", { class: "key-menu-separator", role: "separator" });
      const disabled = menuItemDisabled(item.act, key);
      const label = item.act === "gateway"
        ? (key.gateway_enabled ? "Turn off gateway" : "Turn on gateway…")
        : item.label;
      return el("button", {
        type: "button", class: "key-menu-item" + (item.destructive ? " destructive" : ""),
        role: "menuitem", tabindex: "-1", "data-act": item.act,
        "aria-disabled": String(!!disabled),
      },
      svgIcon(item.icon),
      el("span", { class: "key-menu-label", text: label }),
      item.shortcut ? el("span", { class: "key-menu-shortcut", "aria-hidden": "true", text: item.shortcut }) : null);
    }));
  }
  function positionKeyMenu() {
    if (!keyMenuFor) return;
    const button = btnFor(keyMenuFor, "menu");
    const menu = $("key-menu");
    if (!button || !button.isConnected || menu.hidden) {
      closeKeyMenu({ restoreFocus: false });
      return;
    }
    const anchor = button.getBoundingClientRect();
    const box = menu.getBoundingClientRect();
    const margin = 8;
    const left = Math.max(margin, Math.min(anchor.right - box.width, innerWidth - box.width - margin));
    const below = anchor.bottom + 8;
    const above = anchor.top - box.height - 8;
    const top = below + box.height <= innerHeight - margin
      ? below
      : above >= margin
        ? above
        : Math.max(margin, Math.min(below, innerHeight - box.height - margin));
    menu.style.left = `${left}px`;
    menu.style.top = `${top}px`;
  }
  function closeKeyMenu({ restoreFocus = true } = {}) {
    if (!keyMenuFor) return;
    const name = keyMenuFor;
    const button = btnFor(name, "menu");
    const menu = $("key-menu");
    keyMenuFor = null;
    if (button) button.setAttribute("aria-expanded", "false");
    menu.hidden = true;
    menu.replaceChildren();
    menu.removeAttribute("aria-label");
    if (restoreFocus && button && button.isConnected) button.focus();
  }
  function openKeyMenu(name, button = btnFor(name, "menu")) {
    if (!button || !button.isConnected) return;
    if (keyMenuFor === name) { closeKeyMenu(); return; }
    if (keyMenuFor) closeKeyMenu({ restoreFocus: false });
    menuFocusReturn = null;
    selectRow(name, false);
    keyMenuFor = name;
    const key = state.keys.find((entry) => entry.name === name);
    if (!key) { keyMenuFor = null; return; }
    const menu = $("key-menu");
    renderKeyMenu(key);
    menu.setAttribute("aria-label", "More actions for " + name);
    button.setAttribute("aria-expanded", "true");
    menu.hidden = false;
    positionKeyMenu();
    menu.querySelector('[role="menuitem"]:not([aria-disabled="true"])')?.focus();
  }
  function activateKeyMenuItem(button) {
    if (!keyMenuFor || button.getAttribute("aria-disabled") === "true") return;
    const name = keyMenuFor, act = button.dataset.act;
    if (!ROW_ACT[act]) return;
    if (state.busy && ["reveal", "gateway", "check"].includes(act)) return;
    menuFocusReturn = { name, act };
    closeKeyMenu({ restoreFocus: false });
    ROW_ACT[act](name);
    if (act === "grant" && !$("dlg-grant").open && !$("dlg-host").open) {
      menuFocusReturn = null;
      restoreKeysFocus(name, "menu");
    }
  }

  $("key-menu").addEventListener("click", (e) => {
    const item = e.target.closest('[role="menuitem"]');
    if (!item) return;
    e.preventDefault();
    e.stopPropagation();
    activateKeyMenuItem(item);
  });
  $("key-menu").addEventListener("keydown", (e) => {
    const menu = $("key-menu");
    const enabled = [...menu.querySelectorAll('[role="menuitem"]:not([aria-disabled="true"])')];
    const current = enabled.indexOf(document.activeElement);
    let next = -1;
    if (e.key === "ArrowDown") next = (current + 1 + enabled.length) % enabled.length;
    else if (e.key === "ArrowUp") next = (current - 1 + enabled.length) % enabled.length;
    else if (e.key === "Home") next = 0;
    else if (e.key === "End") next = enabled.length - 1;
    if (next >= 0 && enabled.length) {
      e.preventDefault();
      e.stopPropagation();
      enabled[next].focus();
      return;
    }
    if (e.key === "Escape" || e.key === "Tab") {
      e.preventDefault();
      e.stopPropagation();
      closeKeyMenu();
      return;
    }
    if (e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) {
      const act = LIST_KEYS[e.key.toLowerCase()];
      const item = act && menu.querySelector(`[role="menuitem"][data-act="${act}"]`);
      if (item) {
        e.preventDefault();
        e.stopPropagation();
        activateKeyMenuItem(item);
        return;
      }
    }
    e.stopPropagation();
  });
  document.addEventListener("click", (e) => {
    if (!keyMenuFor) return;
    const button = btnFor(keyMenuFor, "menu");
    if ($("key-menu").contains(e.target) || button?.contains(e.target)) return;
    closeKeyMenu();
  });
  window.addEventListener("resize", positionKeyMenu);
  window.addEventListener("scroll", positionKeyMenu, true);

  $("keys-body").addEventListener("click", (e) => {
    const row = e.target.closest(".key-row");
    if (!row) return;
    selectRow(row.dataset.name, false);
    const btn = e.target.closest("[data-act]");
    if (btn?.dataset.act !== "menu") menuFocusReturn = null;
    if (btn?.dataset.act === "menu") openKeyMenu(row.dataset.name, btn);
    else if (btn) ROW_ACT[btn.dataset.act]?.(row.dataset.name);
  });

  // Kept apart from the document listener on purpose: its modifier, dialog and typing guards do
  // not apply here, so a focused row still answers Cmd+C as c.
  $("keys-body").addEventListener("keydown", (e) => {
    const row = e.target.closest(".key-row");
    if (!row) return;
    const onButton = e.target.closest("[data-act]");
    if ((e.key === "ContextMenu" || e.key === "Menu" || (e.key === "F10" && e.shiftKey))
        && (onButton?.dataset.act === "menu" || !onButton)) {
      e.preventDefault();
      e.stopPropagation();
      openKeyMenu(row.dataset.name, btnFor(row.dataset.name, "menu"));
      return;
    }
    const rows = keyRows();
    const j = listStep(e.key, rows.indexOf(row), rows.length);
    if (j >= 0) { e.preventDefault(); selectRow(rows[j].dataset.name, true); return; }
    let act = LIST_KEYS[e.key];
    if (e.key === "Enter") {
      if (onButton) return;
      act = "copy";
    } else if (e.key === "Backspace" || e.key === "Delete") {
      if (onButton && onButton.dataset.act !== "delete" && e.key === "Delete") return;
      act = "delete";
    }
    if (!act) return;
    e.preventDefault();
    menuFocusReturn = null;
    // History redraws the list synchronously, which detaches e.target; the document listener
    // would then no longer see it inside #keys-body and run the same letter a second time.
    e.stopPropagation();
    ROW_ACT[act](row.dataset.name);
  });

  // A button may keep an icon beside its words; only the .btn-label part is rewritten then.
  function setBtn(btn, text, disabled) {
    if (!btn) return;
    (btn.querySelector(".btn-label") || btn).textContent = text;
    btn.disabled = !!disabled;
  }

  async function copyKey(name) {
    if (state.busy) return;
    state.busy = true;
    const btn = btnFor(name, "copy");
    setBtn(btn, "Touch ID…", true);
    try {
      const r = await api("/api/keys/" + encodeURIComponent(name) + "/copy", { method: "POST" });
      const secs = r && r.wipes_in_s != null ? r.wipes_in_s : 20;
      setBtn(btn, "Copied");
      say(`Copied ${name}. Clipboard wipes in ${secs} s.`);
      const used = rowFor(name) && rowFor(name).querySelector(".key-used");
      if (used) used.textContent = "Just now";
      setTimeout(() => {
        const active = document.activeElement;
        const row = rowFor(name);
        const restore = row && row.contains(active);
        loadKeys().then(() => {
          selectRow(name, false);
          if (restore || !document.activeElement || document.activeElement === document.body) {
            restoreKeysFocus(name, "copy");
          }
        });
      }, 2500);
    } catch (e) {
      setBtn(btn, "Copy");
      say(e.message);
    } finally {
      state.busy = false;
    }
  }

  let revealTimer = 0;
  async function revealKey(name) {
    if (state.busy) return;
    state.busy = true;
    const btn = btnFor(name, "reveal");
    setBtn(btn, "Touch ID…", true);
    try {
      const r = await api("/api/keys/" + encodeURIComponent(name) + "/reveal", { method: "POST" });
      setBtn(btn, "Reveal");
      const dlg = $("dlg-reveal");
      $("reveal-name").textContent = name;
      $("reveal-secret").textContent = r.secret || "";
      let left = 15;
      const tick = () => { $("reveal-timer").textContent = `Hides in ${left} s. Select to copy by hand.`; };
      tick();
      clearInterval(revealTimer);
      revealTimer = setInterval(() => { left -= 1; if (left <= 0) dlg.close(); else tick(); }, 1000);
      dlg.showModal();
      const used = rowFor(name) && rowFor(name).querySelector(".key-used");
      if (used) used.textContent = "Just now";
    } catch (e) {
      setBtn(btn, "Reveal");
      say(e.message);
      if (menuFocusReturn?.name === name && menuFocusReturn.act === "reveal") restoreKeysFocus(name, "menu");
    } finally {
      state.busy = false;
    }
  }
  $("dlg-reveal").addEventListener("close", () => {
    clearInterval(revealTimer);
    $("reveal-secret").textContent = "";
    $("reveal-timer").textContent = "";
    loadKeys().then(() => restoreKeysFocus(state.selected, "reveal"));
  });

  // The add, edit, rotate, host and delete dialogs open the same way: a fresh form, no stale
  // error, the key named in the title. `fill` runs before showModal because the provider picker
  // redraws its list when it takes focus.
  function openKeyDialog(id, name, field, fill) {
    const dlg = $("dlg-" + id), form = $(id + "-form");
    form.reset();
    $(id + "-err").textContent = "";
    if (name != null) { $(id + "-name").textContent = name; dlg.dataset.name = name; }
    if (fill) fill(form);
    dlg.showModal();
    form.elements[field].focus();
  }
  // Closing wipes any secret field, then hands focus back to the row button that opened the
  // dialog unless the close itself moved focus somewhere in the pane (or to `keep`).
  function restoreOnClose(id, act, keep) {
    const form = $(id + "-form");
    $("dlg-" + id).addEventListener("close", () => {
      if (form.elements.secret) form.elements.secret.value = "";
      queueMicrotask(() => {
        if (state.pane !== "keys") return;
        const active = document.activeElement;
        if (active && (active === keep || $("pane-keys").contains(active))) return;
        restoreKeysFocus(state.selected, act);
      });
    });
  }

  function askDelete(name) { openKeyDialog("delete", name, "delete-confirm"); }
  $("delete-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const dlg = $("dlg-delete");
    const name = dlg.dataset.name;
    const btn = $("delete-confirm");
    setBtn(btn, "Deleting…", true);
    try {
      await api("/api/keys/" + encodeURIComponent(name), { method: "DELETE" });
      dlg.close();
      say(`Deleted ${name}.`);
      await loadKeys();
      restoreKeysFocus(state.selected);
    } catch (err) {
      $("delete-err").textContent = err.message;
    } finally {
      setBtn(btn, "Delete", false);
    }
  });
  restoreOnClose("delete");

  // ---------- providers (grouped picker fed by /api/providers) ----------

  async function loadProviders() {
    try {
      // The merged catalog: the shipped entries plus the ones added or hidden in this
      // catalog. Hidden records are still here so the key table can render their names.
      const data = await api("/api/providers");
      if (data && Array.isArray(data.providers)) {
        state.providers = data;
        renderKeys();
        // Until this lands the provider chips read as raw ids; redraw them with the real names.
        renderProviderFilter();
      }
    } catch { state.providers = null; }
  }
  const providerById = (id) => (state.providers ? state.providers.providers.find((p) => p.id === id) : null);
  const providerName = (id) => { if (!id) return "—"; const p = providerById(id); return p ? p.name : id; };
  function guessProvider(secret) {
    if (!state.providers || !secret) return null;
    let best = null;
    for (const p of state.providers.providers) {
      if (p.hidden) continue;
      if (p.key_prefix && secret.startsWith(p.key_prefix) && (!best || p.key_prefix.length > best.key_prefix.length)) best = p;
    }
    // "sk-" is shared by half the labs; only a longer, unique prefix is a real hint
    return best && best.key_prefix.length > 3 ? best : null;
  }

  // Combobox over a plain input: type to filter, arrows to move, Enter to pick, Esc to close.
  // Free text still works for a vendor that is not in the list.
  function enhancePicker(input) {
    const wrap = el("div", { class: "pick" });
    input.parentNode.insertBefore(wrap, input);
    wrap.append(input);
    const listId = input.name + "-pick-" + Math.random().toString(36).slice(2, 7);
    const list = el("ul", { class: "pick-list", id: listId, role: "listbox", hidden: "" });
    wrap.append(list);
    input.setAttribute("role", "combobox");
    input.setAttribute("aria-autocomplete", "list");
    input.setAttribute("aria-expanded", "false");
    input.setAttribute("aria-controls", listId);
    let items = [];
    let active = -1;

    const close = () => { list.hidden = true; input.setAttribute("aria-expanded", "false"); active = -1; };
    const pick = (p) => { input.value = p.id; input.dispatchEvent(new Event("change", { bubbles: true })); close(); };
    const setActive = (i) => {
      active = i;
      items.forEach((li, k) => li.setAttribute("aria-selected", String(k === i)));
      if (i >= 0) {
        input.setAttribute("aria-activedescendant", items[i].id);
        items[i].scrollIntoView({ block: "nearest" });
      } else input.removeAttribute("aria-activedescendant");
    };
    const render = () => {
      if (!state.providers) { close(); return; }
      const q = input.value.trim().toLowerCase();
      const groups = state.providers.groups;
      list.replaceChildren();
      items = [];
      let n = 0;
      for (const g of groups) {
        // Hidden (retired or hidden here) never shows for new keys; it still resolves for old ones.
        const hits = state.providers.providers.filter((p) => p.group === g.id && !p.hidden
          && (!q || p.id.includes(q) || p.name.toLowerCase().includes(q)));
        if (!hits.length) continue;
        list.append(el("li", { class: "pick-group", role: "presentation", text: g.name }));
        for (const p of hits) {
          const li = el("li", {
            class: "pick-item", role: "option", id: listId + "-" + p.id, "aria-selected": "false",
            onpointerdown: (e) => { e.preventDefault(); pick(p); },
          },
            el("span", { text: p.name }),
            p.gateway === false
              ? el("span", { class: "pick-off", text: "no gateway" })
              : el("span", { class: "pick-id", text: p.id }),
          );
          list.append(li);
          items.push(li);
          n++;
        }
      }
      if (!n) list.append(el("li", { class: "pick-none", role: "presentation", text: q ? `No match. "${q}" will be saved as typed.` : "No providers loaded." }));
      list.hidden = false;
      input.setAttribute("aria-expanded", "true");
      const exact = items.findIndex((li) => li.id === listId + "-" + q);
      setActive(exact >= 0 ? exact : (q && items.length ? 0 : -1));
    };

    input.addEventListener("focus", render);
    input.addEventListener("input", render);
    input.addEventListener("blur", () => setTimeout(close, 0));
    input.addEventListener("keydown", (e) => {
      if (list.hidden && (e.key === "ArrowDown" || e.key === "ArrowUp")) { e.preventDefault(); render(); return; }
      if (list.hidden) return;
      if (e.key === "ArrowDown") { e.preventDefault(); if (items.length) setActive((active + 1) % items.length); }
      else if (e.key === "ArrowUp") { e.preventDefault(); if (items.length) setActive((active - 1 + items.length) % items.length); }
      else if (e.key === "Enter") {
        if (active >= 0) { e.preventDefault(); pick(providerById(items[active].id.slice(listId.length + 1))); }
        else close();
      }
      else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(); }
      else if (e.key === "Tab") close();
    });
  }
  document.querySelectorAll("input[data-picker]").forEach(enhancePicker);

  // ---------- providers manager ----------

  function openProviders() {
    renderProvidersList();
    if (!$("dlg-providers").open) $("dlg-providers").showModal();
  }
  $("btn-providers").addEventListener("click", openProviders);

  function renderProvidersList() {
    const list = $("providers-list");
    list.replaceChildren();
    const data = state.providers;
    if (!data || !data.providers.length) {
      list.append(el("li", { class: "pick-none", text: "No providers loaded." }));
      return;
    }
    for (const group of data.groups) {
      const rows = data.providers.filter((p) => p.group === group.id);
      if (!rows.length) continue;
      list.append(el("li", { class: "providers-group", text: group.name }));
      for (const p of rows) {
        const stateText = p.custom ? "yours"
          : p.hidden === "app" ? "retired" : p.hidden === "user" ? "hidden" : "built-in";
        const actions = [];
        if (p.custom) {
          actions.push(el("button", { class: "link", type: "button", text: "Remove", onclick: () => removeProvider(p) }));
        } else if (p.hidden === "user") {
          actions.push(el("button", { class: "link", type: "button", text: "Unhide", onclick: () => hideProvider(p, false) }));
        } else if (!p.hidden) {
          actions.push(el("button", { class: "link", type: "button", text: "Hide", onclick: () => hideProvider(p, true) }));
        }
        list.append(el("li", { class: "provider-row" + (p.hidden ? " dim" : "") },
          el("span", { class: "provider-name", text: p.name }),
          el("code", { text: p.id }),
          el("span", { class: "provider-host", text: p.host || (p.gateway ? "host per key" : "not proxied") }),
          el("span", { class: "provider-state", text: stateText }),
          el("span", { class: "provider-actions" }, ...actions),
        ));
      }
    }
  }

  async function removeProvider(p) {
    try {
      await api(`/api/providers/${encodeURIComponent(p.id)}`, { method: "DELETE" });
      say(`Removed provider ${p.name}.`);
      await loadProviders();
      renderProvidersList();
      await loadKeys();
    } catch (e) { say(e.message); }
  }

  async function hideProvider(p, hidden) {
    try {
      await api(`/api/providers/${encodeURIComponent(p.id)}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ hidden }),
      });
      say(hidden ? `Hid ${p.name} from the Add dialog; keys using it keep working.` : `${p.name} is back in the Add dialog.`);
      await loadProviders();
      renderProvidersList();
    } catch (e) { say(e.message); }
  }

  $("provider-add-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.target;
    const err = $("provider-add-err");
    err.textContent = "";
    const payload = {
      id: form.elements.id.value.trim(),
      name: form.elements.name.value.trim(),
      host: form.elements.host.value.trim(),
      api: form.elements.api.value,
      auth_header: form.elements.auth_header.value.trim(),
      auth_prefix: form.elements.auth_prefix.value,
      path_prefix: form.elements.path_prefix.value.trim(),
      key_prefix: form.elements.key_prefix.value.trim(),
      note: form.elements.note.value.trim(),
      gateway: form.elements.gateway.checked,
    };
    try {
      await api("/api/providers", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      say(`Added provider ${payload.name}.`);
      form.reset();
      await loadProviders();
      renderProvidersList();
    } catch (e2) { err.textContent = e2.message; }
  });

  // ---------- agents (per-agent setup recipes) ----------

  function copyText(text, btn) {
    navigator.clipboard?.writeText(text).then(
      () => { btn.textContent = "Copied"; setTimeout(() => { btn.textContent = "Copy"; }, 1200); },
      () => say("Clipboard blocked by the browser. Select the text and copy by hand."),
    );
  }

  function agentRecipe(id, key, model) {
    const base = `http://127.0.0.1:12767/${key}`;
    switch (id) {
      case "claude":
        return [
          { text: "Launch it through the vault — one Touch ID, and the grant dies when it exits:", cmd: `keys agent claude ${key}` },
          { text: "Or export your own token (keys grant or keys client issue) and run claude yourself:", cmd: `export ANTHROPIC_BASE_URL=${base}\nexport ANTHROPIC_AUTH_TOKEN=<token>` },
        ];
      case "codex":
        return [
          { text: "Once: write the gateway into ~/.codex/config.toml (needs an OpenAI-compatible provider):", cmd: `keys setup codex --key ${key} --model ${model}` },
          { text: "Then launch codex on the vault key:", cmd: `keys agent codex ${key} -- codex` },
          { text: "Optional: make it the default provider:", cmd: `keys setup codex --key ${key} --model ${model} --set-default` },
        ];
      case "grok":
        return [
          { text: "Once: write a Keysrs model into ~/.grok/config.toml:", cmd: `keys setup grok --key ${key} --model ${model}` },
          { text: "Then launch grok on the vault key (pick the Keysrs model in the picker):", cmd: `keys agent grok ${key} -- grok` },
          { text: "Or use an xAI key directly as the environment variable:", cmd: `keys env ${key} XAI_API_KEY -- grok` },
        ];
      case "droid":
        return [
          { text: "Once: add a custom model pointing at the gateway in ~/.factory/settings.json:", cmd: `keys setup droid --key ${key} --model ${model}` },
          { text: "Then launch droid on the vault key, and pick the Keysrs model with /model:", cmd: `keys agent droid ${key} -- droid` },
          { text: "Unattended (headless droid exec, CI): a client token instead of per-launch grants:", cmd: `keys client issue ${key} --label droid --days 90\nexport KEYSRS_DROID_TOKEN=<token>` },
        ];
      case "cloud":
        return [
          { text: "Create a long-lived token (one Touch ID, revocable from the Keys pane):", cmd: `keys client issue ${key} --label "cloud agent" --days 30` },
          { text: "From this Mac, forward the gateway to the machine the agent runs on:", cmd: `keys tunnel user@server.example.com` },
          { text: "On that machine, the vault is a plain local URL — token as the API key:", cmd: `export OPENAI_BASE_URL=http://127.0.0.1:12767/${key}\nexport OPENAI_API_KEY=<token>` },
          { text: "Same recipe over Tailscale (ssh to the server's tailnet name) or for a self-hosted CI runner." },
          { text: "No ssh in (GitHub Actions, a Claude Code or Codex cloud session, Modal, E2B)? Use the relay: a small Worker you deploy in your own Cloudflare account (Relay/ in the repo, docs/relay.md). The Mac keeps one outbound connection to it while the relay is on in Keysrs (Settings → Relay), and the Worker never sees a key:", cmd: "keys relay setup --url https://keysrs-relay.<you>.workers.dev\nkeys relay on" },
          { text: "The agent then calls the Worker instead of a forwarded port, with the same client token:", cmd: `export OPENAI_BASE_URL=https://<your worker>/${key}\nexport OPENAI_API_KEY=<token>` },
        ];
    }
    return [];
  }

  function renderAgents() {
    const body = $("agents-body");
    body.replaceChildren();
    const keys = state.keys || [];
    const select = el("select", { id: "agents-key" },
      ...keys.map((k) => el("option", { value: k.name, text: `${k.name} (${providerName(k.provider)})` })));
    const model = el("input", { value: "claude-sonnet-4-5-20250929", placeholder: "model id", "aria-label": "Model id" });
    const sections = [["claude", "Claude Code"], ["codex", "Codex"], ["grok", "Grok"], ["droid", "Droid"], ["cloud", "A cloud agent"]];
    const stepsByAgent = new Map();
    const rerender = () => {
      const key = keys.length ? select.value : "<key name>";
      for (const [id] of sections) {
        const holder = stepsByAgent.get(id);
        if (holder) holder.replaceChildren(...agentRecipe(id, key, model.value.trim() || "claude-sonnet-4-5-20250929").map(stepLine));
      }
    };
    const stepLine = (step) => el("li", { class: "agent-step" },
      el("span", { class: "agent-step-text", text: step.text }),
      step.cmd
        ? el("code", { class: "agent-cmd", text: step.cmd })
        : null,
      step.cmd
        ? el("button", { class: "btn-row", type: "button", text: "Copy", onclick: (e) => copyText(step.cmd, e.target) })
        : null,
    );
    if (!keys.length) {
      body.append(el("p", { class: "hint", text: "Add a key first; the recipes below use <key name> until then." }));
    } else {
      body.append(
        el("label", { class: "agents-key-label" }, "Vault key ", select),
        el("label", { class: "agents-key-label" }, "Model ", model),
      );
      select.addEventListener("change", rerender);
      model.addEventListener("input", rerender);
    }
    for (const [id, name] of sections) {
      const holder = el("ul", { class: "agent-steps" });
      stepsByAgent.set(id, holder);
      body.append(el("details", { class: "agent", open: id === "claude" || id === "droid" ? "" : null },
        el("summary", {}, el("span", { text: name })),
        holder,
      ));
    }
    rerender();
  }

  function openAgents() {
    if (!state.keys) { say("Keys are still loading; try again in a moment."); return; }
    renderAgents();
    if (!$("dlg-agents").open) $("dlg-agents").showModal();
  }
  $("btn-agents").addEventListener("click", openAgents);
  // The guide (help dialog and the first-use onboard clone) links here; delegation covers both.
  document.addEventListener("click", (e) => {
    const link = e.target.closest('[data-action="agents"]');
    if (link) { e.preventDefault(); openAgents(); }
  });

  // ---------- add / edit ----------

  function openAdd() { openKeyDialog("add", null, "name"); }
  $("btn-add").addEventListener("click", openAdd);
  $("add-form").elements.secret.addEventListener("input", (e) => {
    const form = $("add-form");
    const prov = form.elements.provider;
    if (prov.value && prov.dataset.guessed !== "1") return;
    const p = guessProvider(e.target.value);
    prov.value = p ? p.id : "";
    prov.dataset.guessed = p ? "1" : "";
  });
  $("add-form").elements.provider.addEventListener("input", (e) => { e.target.dataset.guessed = ""; });
  $("add-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.target;
    const err = $("add-err");
    err.textContent = "";
    if (!form.elements.name.validity.valid) {
      err.textContent = "Name: lowercase letters, digits, dots, dashes or underscores, starting with a letter or digit.";
      form.elements.name.focus();
      return;
    }
    if (!form.elements.provider.value.trim()) { err.textContent = "Provider is required."; form.elements.provider.focus(); return; }
    if (!form.elements.secret.value) { err.textContent = "Secret is required."; form.elements.secret.focus(); return; }
    const payload = {
      name: form.elements.name.value.trim(),
      provider: form.elements.provider.value.trim(),
      kind: form.elements.kind.value,
      notes: form.elements.notes.value,
      secret: form.elements.secret.value,
    };
    const submit = form.querySelector('[type="submit"]');
    setBtn(submit, "Adding…", true);
    try {
      await api("/api/keys", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
      form.elements.secret.value = "";
      form.reset();
      $("dlg-add").close();
      say(`Added ${payload.name}.`);
      state.selected = payload.name;
      await loadKeys();
      restoreKeysFocus(payload.name);
    } catch (error) {
      err.textContent = error.message;
      if (error.status === 409) form.elements.name.focus();
    } finally {
      setBtn(submit, "Add key", false);
    }
  });
  restoreOnClose("add", undefined, $("btn-add"));

  function openEdit(name) {
    const k = state.keys.find((x) => x.name === name);
    if (!k) return;
    openKeyDialog("edit", name, "provider", (form) => {
      form.elements.provider.value = k.provider || "";
      form.elements.kind.value = k.kind === "billing" ? "billing" : "runtime";
      form.elements.notes.value = k.notes || "";
      // Only routers with a per-request price sort offer it (CheapestRouting.swift).
      $("edit-cheapest-row").hidden = !k.cheapest_supported;
      form.elements.cheapest.checked = !!k.gateway_cheapest;
    });
  }
  $("edit-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.target;
    const name = $("dlg-edit").dataset.name;
    const err = $("edit-err");
    err.textContent = "";
    if (!form.elements.provider.value.trim()) { err.textContent = "Provider is required."; form.elements.provider.focus(); return; }
    const k = state.keys.find((x) => x.name === name) || {};
    const payload = {};
    const provider = form.elements.provider.value.trim();
    if (provider !== (k.provider || "")) payload.provider = provider;
    if (form.elements.kind.value !== k.kind) payload.kind = form.elements.kind.value;
    if (form.elements.notes.value !== (k.notes || "")) payload.notes = form.elements.notes.value;
    const cheapest = !$("edit-cheapest-row").hidden && form.elements.cheapest.checked !== !!k.gateway_cheapest;
    if (!Object.keys(payload).length && !cheapest) { $("dlg-edit").close(); return; }
    const submit = form.querySelector('[type="submit"]');
    setBtn(submit, "Saving…", true);
    try {
      if (cheapest) {
        await api("/api/keys/" + encodeURIComponent(name) + "/cheapest", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ enabled: form.elements.cheapest.checked }) });
      }
      if (Object.keys(payload).length) {
        await api("/api/keys/" + encodeURIComponent(name), { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
      }
      $("dlg-edit").close();
      say(`Saved ${name}.`);
      await loadKeys();
      selectRow(name, false);
      restoreKeysFocus(name, "edit");
    } catch (error) {
      err.textContent = error.message;
    } finally {
      setBtn(submit, "Save", false);
    }
  });
  restoreOnClose("host", "gateway");
  restoreOnClose("edit", "edit");

  // ---------- key history (audit log the engine keeps; never the secret) ----------

  // Every action KeysService.recordKeyEvent writes, in plain words. An action missing here shows
  // its raw name, which is how client_issue and gateway_denied slipped through once.
  const ACTION_LABEL = {
    add: "added", copy: "copied", reveal: "revealed", env: "used in env", check: "checked", rotate: "rotated", rm: "deleted", patch: "edited",
    gateway_enable: "gateway on", gateway_disable: "gateway off", gateway_call: "gateway call", gateway_denied: "gateway refused",
    grant: "grant issued", grant_revoke: "grant revoked", client_issue: "client issued", client_revoke: "client revoked",
    gateway_cheapest: "cheapest upstream",
  };
  // Who did it, as the engine names it: the loopback gateway, the relay, the dashboard, the CLI.
  const CALLER_LABEL = { gateway: "local gateway", relay: "relay", dashboard: "dashboard", cli: "command line", system: "system", models: "model check", add: "command line", test: "test" };
  const fmtWhen = (iso) => {
    const t = Date.parse(iso || "");
    if (Number.isNaN(t)) return iso || "";
    return new Date(t).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  };
  function eventsRow(k) {
    // A sibling of the key's row, so the row's own grid and its divider stay as they are.
    const drawer = el("div", { class: "key-events-row", role: "listitem", "data-name": k.name, "aria-label": "History of " + k.name });
    drawer.append(el("div", { class: "key-events-cell" }, el("div", { class: "key-events-head", text: "Loading history…" })));
    return drawer;
  }
  async function loadEvents(name) {
    const tr = [...$("keys-body").querySelectorAll(".key-events-row")].find((r) => r.dataset.name === name);
    if (!tr) return;
    try {
      const r = await api("/api/keys/" + encodeURIComponent(name) + "/events?limit=50");
      const events = (r && r.events) || [];
      const cell = tr.firstChild;
      cell.replaceChildren();
      if (!events.length) {
        cell.append(el("div", { class: "key-events-empty", text: "No copy, reveal, env or gateway use recorded yet. History starts with today's engine." }));
        return;
      }
      cell.append(el("div", { class: "key-events-head", text: `Last ${plural(events.length, "event", "events")} · newest first` }));
      cell.append(el("ul", { class: "key-events" }, ...events.map((ev) => el("li", {},
        el("span", { text: fmtWhen(ev.ts), title: ev.ts || "" }),
        el("span", { class: "ev-action", text: ACTION_LABEL[ev.action] || ev.action }),
        el("span", { class: "ev-caller", text: CALLER_LABEL[ev.caller] || ev.caller || "" }),
        el("span", { class: "ev-detail", text: ev.detail || "" }),
      ))));
    } catch (e) {
      tr.firstChild.replaceChildren(el("div", { class: "key-events-empty", text: e.message }));
    }
  }
  function toggleEvents(name) {
    state.eventsOpen = state.eventsOpen === name ? null : name;
    renderKeys();
    selectRow(name, false);
    restoreKeysFocus(name, "history");
  }

  // ---------- rotate (new secret, same name; Touch ID on the server) ----------

  function openRotate(name) { openKeyDialog("rotate", name, "secret"); }
  $("rotate-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.target;
    const name = $("dlg-rotate").dataset.name;
    const err = $("rotate-err");
    err.textContent = "";
    if (!form.elements.secret.value) { err.textContent = "New secret is required."; form.elements.secret.focus(); return; }
    const submit = form.querySelector('[type="submit"]');
    setBtn(submit, "Touch ID…", true);
    try {
      const r = await api("/api/keys/" + encodeURIComponent(name) + "/rotate", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ secret: form.elements.secret.value }) });
      form.elements.secret.value = "";
      form.reset();
      $("dlg-rotate").close();
      say(`Rotated ${name}` + (r && r.version != null ? ` (version ${r.version}).` : "."));
      await loadKeys();
      selectRow(name, false);
      restoreKeysFocus(name, "rotate");
    } catch (error) {
      err.textContent = error.message;
    } finally {
      setBtn(submit, "Rotate", false);
    }
  });
  restoreOnClose("rotate", "rotate");

  // ---------- gateway (per key, one Touch ID to turn on; the engine forgets on restart) ----------

  async function toggleGateway(name, host) {
    if (state.busy) return;
    const k = state.keys.find((x) => x.name === name);
    if (!k) return;
    const prov = providerById(k.provider);
    if (prov && prov.gateway === false) { say(prov.name + " cannot be proxied (request signing)."); return; }
    const on = !!k.gateway_enabled;
    if (!on && prov && !prov.host && !host && !k.gateway_host) { askHost(name, prov); return; }
    state.busy = true;
    const btn = btnFor(name, "gateway");
    setBtn(btn, on ? "Turning off…" : "Touch ID…", true);
    try {
      const body = { enabled: !on };
      if (!on && (host || k.gateway_host)) body.host = host || k.gateway_host;
      const r = await api("/api/keys/" + encodeURIComponent(name) + "/gateway", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      say(on ? `Gateway off for ${name}.` : `Gateway on. Base URL ${(r && r.gateway_url) || "http://127.0.0.1:12767/" + name}. Callers need a client: keys client issue ${name}`);
      await loadKeys();
      selectRow(name, false);
      restoreKeysFocus(name, "gateway");
    } catch (e) {
      setBtn(btn, on ? "Gateway on" : "Gateway");
      say(e.message);
      if (menuFocusReturn?.name === name && menuFocusReturn.act === "gateway") restoreKeysFocus(name, "menu");
    } finally {
      state.busy = false;
    }
  }

  function askHost(name, prov) {
    $("host-hint").textContent = (prov && prov.note) || "This provider has one host per account.";
    openKeyDialog("host", name, "host");
  }
  $("host-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const host = e.target.elements.host.value.trim().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
    if (!host) { $("host-err").textContent = "Host is required."; return; }
    const name = $("dlg-host").dataset.name;
    $("dlg-host").close();
    toggleGateway(name, host);
  });

  // ---------- grants (temporary, scoped access; one Touch ID per task) ----------

  const fmtWhenShort = (iso) => { const d = new Date(iso); return isNaN(d) ? iso : d.toLocaleString([], { hour: "2-digit", minute: "2-digit", month: "short", day: "numeric" }); };
  const minutesLeft = (iso) => Math.max(0, Math.round((new Date(iso) - Date.now()) / 60000));

  async function loadGrants() {
    try {
      const r = await api("/api/grants");
      state.grants = (r && r.grants) || [];
    } catch { state.grants = []; }
    try {
      const lists = await Promise.all(state.keys.map((k) => api("/api/keys/" + encodeURIComponent(k.name) + "/clients").then((r) => (r && r.clients) || []).catch(() => [])));
      state.clients = lists.flat().filter((c) => c.active);
    } catch { state.clients = []; }
    renderGrants();
  }
  function renderGrants() {
    const box = $("grants");
    const list = state.grants || [];
    const clients = state.clients || [];
    box.hidden = list.length === 0 && clients.length === 0;
    $("grants-count").textContent = plural(list.length, "active grant", "active grants") + ", " + plural(clients.length, "client", "clients") + ".";
    $("clients-list").replaceChildren(...clients.map((c) => el("li", {},
      el("span", { class: "g-id", text: "#" + c.id + " " + (c.hint || "") }),
      el("span", { class: "g-key", text: c.key }),
      el("span", { class: "g-task", text: c.label || "client", title: c.label }),
      el("span", { class: "g-meta", text: `client · ${c.methods.join("/")} · ${c.path_prefix ? c.path_prefix : "any path"} · expires ${fmtWhenShort(c.expires_at)}${c.last_used_at ? " · used " + relTime(c.last_used_at) : ""}` }),
      el("button", { type: "button", class: "btn btn-row btn-danger", text: "Revoke", "aria-label": "Revoke client " + c.id, onclick: () => revokeClient(c.key, c.id) }),
    )));
    $("grants-list").replaceChildren(...list.map((g) => el("li", {},
      el("span", { class: "g-id", text: g.id }),
      el("span", { class: "g-key", text: g.key + " → " + g.host }),
      el("span", { class: "g-task", text: g.task, title: g.task }),
      el("span", { class: "g-meta", text: `${g.methods.length === 7 ? "any method" : g.methods.join("/")} · ${g.paths.length ? g.paths.join(", ") : "any path"} · ${g.requests} req${g.max_requests ? "/" + g.max_requests : ""} · ${grantUsd(g)}${g.max_usd ? "/" + fmtUsd(g.max_usd) : ""} · ${minutesLeft(g.expires_at)} min left` }),
      el("button", { type: "button", class: "btn btn-row btn-danger", text: "Revoke", "aria-label": "Revoke grant " + g.id, onclick: () => revokeGrant(g.id) }),
    )));
  }
  // An unpriced call is unknown money: the priced sum is only a floor, never "$0".
  function grantUsd(g) {
    const n = Number(g.unpriced_calls) || 0;
    if (!n) return fmtUsd(g.usd);
    const calls = n + (n === 1 ? " call" : " calls");
    return (Number(g.usd) > 0 ? "≥" + fmtUsd(g.usd) + " + " : "") + "unpriced (" + calls + ")";
  }
  async function revokeClient(key, id) {
    try {
      await api("/api/keys/" + encodeURIComponent(key) + "/clients/" + encodeURIComponent(id), { method: "DELETE" });
      say(`Client #${id} revoked.`);
      await loadKeys();
    } catch (e) { say(e.message); }
  }
  async function revokeGrant(id) {
    try {
      await api("/api/grants/" + encodeURIComponent(id), { method: "DELETE" });
      say(`Grant ${id} revoked.`);
      await loadKeys();
    } catch (e) { say(e.message); }
  }

  function openGrant(name) {
    const k = state.keys.find((x) => x.name === name);
    if (!k) return;
    const prov = providerById(k.provider);
    if (prov && prov.gateway === false) { say(prov.name + " cannot be proxied, so no grant."); return; }
    if (!k.host) { say("Set a gateway host for " + name + " first (Edit)."); return; }
    const dlg = $("dlg-grant");
    dlg.dataset.name = name;
    $("grant-form").reset();
    setGrantKind("grant");
    $("grant-form").hidden = false;
    $("grant-result").hidden = true;
    $("grant-err").textContent = "";
    $("grant-name").textContent = name;
    $("grant-target").textContent = `${providerName(k.provider)} at ${k.host}. Requests to any other host are refused and redirects are never followed.`;
    dlg.showModal();
    $("grant-form").elements.task.focus();
  }
  function grantKind() { return $("dlg-grant").dataset.kind || "grant"; }
  function setGrantKind(kind) {
    $("dlg-grant").dataset.kind = kind;
    document.querySelectorAll(".kind-switch [data-kind]").forEach((b) => b.setAttribute("aria-checked", String(b.dataset.kind === kind)));
    $("grant-fields").hidden = kind !== "grant";
    $("client-fields").hidden = kind !== "client";
    $("grant-submit").textContent = kind === "client" ? "Issue client" : "Grant";
    const f = $("grant-form").elements;
    (kind === "client" ? f.label : f.task).focus();
  }
  document.querySelectorAll(".kind-switch [data-kind]").forEach((b) => b.addEventListener("click", () => setGrantKind(b.dataset.kind)));

  async function issueClient(name, f) {
    const methods = [...f.cm].filter((c) => c.checked).map((c) => c.value);
    if (!methods.length) throw new Error("Pick at least one method.");
    const body = { label: f.label.value.trim(), days: Number(f.days.value), methods };
    if (f.path_prefix.value.trim()) body.path_prefix = f.path_prefix.value.trim();
    const r = await api("/api/keys/" + encodeURIComponent(name) + "/clients", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const c = r.client;
    const k = state.keys.find((x) => x.name === name) || {};
    const prov = providerById(k.provider) || {};
    $("gr-kind").textContent = "Client";
    $("gr-id").textContent = "#" + c.id + " " + (c.hint || "");
    $("gr-target").textContent = `${name} → ${providerName(k.provider)} at ${k.host || "?"}`;
    $("gr-scope").textContent = `${c.methods.join(", ")} · ${c.path_prefix ? c.path_prefix : "any path"}`;
    $("gr-expires").textContent = `${fmtWhenShort(c.expires_at)} (${body.days} days). Survives restarts and screen lock.`;
    $("gr-base").textContent = "http://127.0.0.1:12767/" + name + (prov.path_prefix || "");
    $("gr-token").textContent = r.token;
    $("gr-hint").textContent = `Use the token as the API key (${prov.auth_header || "Authorization"} header) and the base URL as the SDK endpoint. Shown once; only its hash is stored. Select to copy.`;
    $("dlg-grant").dataset.grantId = "";
    $("dlg-grant").dataset.clientId = String(c.id);
    say(`Client #${c.id} issued for ${name}.`);
  }

  async function issueGrant(name, f) {
    const body = { task: f.task.value.trim(), minutes: Number(f.minutes.value) };
    if (f.methods.value) body.methods = f.methods.value.split(",");
    const paths = f.paths.value.split(",").map((p) => p.trim()).filter(Boolean);
    if (paths.length) body.paths = paths;
    if (f.max_requests.value) body.max_requests = Number(f.max_requests.value);
    if (f.max_usd.value) body.max_usd = Number(f.max_usd.value);
    const g = await api("/api/keys/" + encodeURIComponent(name) + "/grants", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    $("gr-kind").textContent = "Grant";
    $("gr-id").textContent = g.id;
    $("gr-target").textContent = `${g.key} → ${providerName(g.provider)} at ${g.host}`;
    $("gr-scope").textContent = `${g.methods.length === 7 ? "any method" : g.methods.join(", ")} · ${g.paths.length ? g.paths.join(", ") : "any path"}${g.max_requests ? " · max " + g.max_requests + " requests" : ""}${g.max_usd ? " · max " + fmtUsd(g.max_usd) + ", ends on an unpriced call" : ""}`;
    $("gr-expires").textContent = `${fmtWhenShort(g.expires_at)} (${body.minutes} min), or earlier on screen lock, revoke or site restart`;
    $("gr-base").textContent = g.base_url;
    $("gr-token").textContent = g.token;
    $("gr-hint").textContent = `Use the token as the API key (${g.auth_header} header) and the base URL as the SDK endpoint. Shown once; it is not stored anywhere. Select to copy.`;
    $("dlg-grant").dataset.grantId = g.id;
    $("dlg-grant").dataset.clientId = "";
    say(`Grant ${g.id} issued for ${name}.`);
  }

  $("grant-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    if (state.busy) return;
    const client = grantKind() === "client";
    state.busy = true;
    $("grant-err").textContent = "";
    setBtn($("grant-submit"), "Touch ID…", true);
    try {
      await (client ? issueClient : issueGrant)($("dlg-grant").dataset.name, e.target.elements);
      $("grant-form").hidden = true;
      $("grant-result").hidden = false;
      await loadKeys();
    } catch (err) {
      $("grant-err").textContent = err.message;
    } finally {
      setBtn($("grant-submit"), client ? "Issue client" : "Grant", false);
      state.busy = false;
    }
  });
  $("gr-revoke").addEventListener("click", async () => {
    const id = $("dlg-grant").dataset.grantId;
    const cid = $("dlg-grant").dataset.clientId;
    if (id) await revokeGrant(id);
    else if (cid) await revokeClient($("dlg-grant").dataset.name, cid);
    $("dlg-grant").close();
  });
  $("dlg-grant").addEventListener("close", () => {
    $("gr-token").textContent = "";
    $("gr-base").textContent = "";
    restoreKeysFocus($("dlg-grant").dataset.name, "grant");
  });

  // ---------- provider check (read-only: auth status + model list) ----------

  function renderCheck(r, name) {
    $("check-name").textContent = name;
    $("check-target").textContent = `${providerName(r.provider)} at ${r.host}${r.endpoint ? " · GET " + r.endpoint : ""}`;
    const st = $("check-status");
    st.textContent = r.ok ? `OK · ${r.model_count} models` : r.summary;
    st.className = "check-status " + (r.ok ? "ok" : "bad");
    $("check-meta").textContent = `Checked ${fmtWhenShort(r.checked_at)}${r.request_id ? " · request id " + r.request_id : ""}${r.ok ? "" : " · " + hintFor(r.outcome)}`;
    state.checkModels = r.models || [];
    $("check-filter-label").hidden = !r.ok;
    $("check-filter").value = "";
    filterCheck();
  }
  function hintFor(outcome) {
    switch (outcome) {
      case "provider_auth_failed": return "The provider rejected this key. Rotate it, or check it belongs to this provider.";
      case "provider_refused": return "The key is recognised but this request was refused: wrong host, plan, region or headers. Not necessarily a bad key.";
      case "network": return "No answer from the host. Check the network and the host in Edit.";
      case "redirect": return "The host moved. Put the new host in Edit; the key was not sent to the redirect target.";
      case "no_check_endpoint": return "This provider has no read-only list endpoint; no paid request was made instead.";
      case "malformed": return "The host answered but not with a model list. Is the host right?";
      default: return "The provider returned an error.";
    }
  }
  function filterCheck() {
    const q = $("check-filter").value.trim().toLowerCase();
    const ids = (state.checkModels || []).filter((m) => !q || m.toLowerCase().includes(q));
    $("check-models").replaceChildren(...ids.map((m) => el("li", { text: m })));
    $("check-filter").setAttribute("aria-label", `Filter models, ${ids.length} shown`);
  }
  $("check-filter").addEventListener("input", filterCheck);
  async function runCheck(name, force) {
    if (state.busy) return;
    const k = state.keys.find((x) => x.name === name);
    if (!k) return;
    if (!k.checkable) { say("No read-only check endpoint for " + providerName(k.provider) + "; nothing is sent."); return; }
    const dlg = $("dlg-check");
    dlg.dataset.name = name;
    $("check-err").textContent = "";
    if (!force && k.last_check) {
      try {
        const cached = await api("/api/keys/" + encodeURIComponent(name) + "/check");
        renderCheck(cached, name);
        if (!dlg.open) dlg.showModal();
        return;
      } catch {}
    }
    state.busy = true;
    const btn = btnFor(name, "check");
    setBtn(btn, k.gateway_enabled ? "Checking…" : "Touch ID…", true);
    try {
      const r = await api("/api/keys/" + encodeURIComponent(name) + "/check", { method: "POST" });
      renderCheck(r, name);
      if (!dlg.open) dlg.showModal();
      loadKeys({ quiet: true });
    } catch (e) {
      if (dlg.open) $("check-err").textContent = e.message; else say(e.message);
      if (!dlg.open && menuFocusReturn?.name === name && menuFocusReturn.act === "check") restoreKeysFocus(name, "menu");
    } finally {
      setBtn(btn, "Check");
      state.busy = false;
    }
  }
  $("check-again").addEventListener("click", () => runCheck($("dlg-check").dataset.name, true));
  $("dlg-check").addEventListener("close", () => restoreKeysFocus($("dlg-check").dataset.name, "check"));

  // ---------- export ----------

  // The CSV is an explicit export of the rows as the engine reported them, so it keeps the raw
  // token and cost columns whatever unit the screen is in. Only the on-screen figures and the
  // copied totals line follow the unit.
  const csvCell = (v) => {
    if (v == null) return "";
    const s = String(v);
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  };
  // From Settings the Chart may never have loaded; fetch its current view first.
  async function ensureSpend() {
    if (!state.spend) await loadSpend();
  }
  async function exportCsv() {
    await ensureSpend();
    const data = state.spend;
    if (!data || !(data.rows || []).length) { say("Nothing to export in this range."); return; }
    const cols = projectMode()
      ? ["project", "cwd", "input_tokens", "output_tokens", "cached_read_tokens", "cache_creation_tokens", "usd", "usd_estimate"]
      : keysMode()
        // An empty usd_estimate means unpriced, not zero; the request count is always there.
        ? ["provider", "key", "model", "model_calls", "input_tokens", "output_tokens", "cached_read_tokens", "cache_creation_tokens", "usd", "usd_estimate"]
        : ["model", "input_tokens", "output_tokens", "cached_read_tokens", "cache_creation_tokens", "usd", "usd_estimate", "key"];
    const lines = [cols.join(",")];
    for (const r of data.rows) lines.push(cols.map((c) => csvCell(r[c])).join(","));
    const name = `keysreallysafe-${state.range}-${data.start_day || ""}-${data.end_day || ""}`
      + `${state.provider ? "-" + state.provider : ""}${state.key ? "-" + state.key : ""}.csv`;
    const blob = new Blob([lines.join("\n") + "\n"], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = el("a", { href: url, download: name });
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    say(`Saved ${name}, with the raw token and cost columns.`);
  }

  function totalsMarkdown() {
    const data = state.spend;
    if (!data) return "";
    const t = data.totals || {};
    const src = state.source;
    const rangeHead = state.range === "today" ? "Today " + fmtDay(data.start_day || isoDay(new Date()))
      : (state.range === "week" ? "This week " : "This month ") + fmtRange(data.start_day, data.end_day);
    // The copied line is the line on screen, so it carries the same unit. Dollars are copied only
    // when USD is the chosen unit.
    if (!usdMode()) {
      const b = seriesBreakdown();
      const scope = keysMode()
        ? ` · API keys${state.provider ? " · " + providerName(state.provider) : " · every provider"}${state.key ? " · key " + state.key : " · every key"}`
        : ` · Subscriptions${projectMode() ? " · by project" : ""}`;
      const head = `**Keysrs${scope} · ${rangeHead}**`;
      const measured = keysMode() ? Math.max(Number(t.gateway_tokens) || 0, b.tokens) : b.tokens;
      const tokens = measured > 0 ? `${fmtTokens(measured)} tokens` : keysMode() && b.calls ? "no reported tokens" : "0 tokens";
      const line = keysMode()
        ? `${fmtInt(Number(t.gateway_calls) || 0)} ${(Number(t.gateway_calls) || 0) === 1 ? "request" : "requests"} · ${tokens}`
        : `${tokens} · ${fmtInt(b.input)} in · ${fmtInt(b.output)} out · ${fmtInt(b.cached)} cached input read · ${fmtInt(b.created)} cache writes`;
      const foot = keysMode()
        ? "_Requests routed through the local gateway only; token counts are what the providers reported._"
        : src === "cloud" ? "_Imported cloud usage, recorded off this Mac; not a plan invoice._"
        : remoteTokens(data) > 0 ? `_Counted from the tools' own local logs on this Mac plus ${fmtTokens(remoteTokens(data))} tokens imported from the cloud, not a plan invoice._`
        : "_Counted from the tools' own local logs on this Mac, not a plan invoice._";
      return `${head}\n${line}\n${foot}\n`;
    }
    if (keysMode()) {
      const calls = Number(t.gateway_calls) || 0;
      const unpriced = Number(t.gateway_unpriced_calls) || 0;
      const usd = t.gateway_usd_estimate != null ? Number(t.gateway_usd_estimate) : null;
      const money = usd == null ? (calls ? "cost unknown" : fmtUsd(0)) : (unpriced > 0 ? "≥ ≈ " : "≈ ") + fmtUsd(usd);
      const head = `**Keysrs · API keys · ${rangeHead}`
        + `${state.provider ? " · " + providerName(state.provider) : " · every provider"}`
        + `${state.key ? " · key " + state.key : " · every key"}**`;
      const line = `${money} · ${fmtInt(calls)} ${calls === 1 ? "request" : "requests"} · ${fmtTokens(Number(t.gateway_tokens) || 0)} tokens`
        + (unpriced > 0 ? ` · ${plural(unpriced, "request", "requests")} unpriced` : "");
      return `${head}\n${line}\n_Calls routed through the local gateway only. Receipt where reported, else a list-price estimate; unpriced calls are left out rather than counted as zero._\n`;
    }
    if (src === "cloud") {
      const rangeCloud = state.range === "today" ? "Today " + fmtDay(data.start_day || isoDay(new Date()))
        : (state.range === "week" ? "This week " : "This month ") + fmtRange(data.start_day, data.end_day);
      return `**Keysrs · Subscriptions · Cloud · ${rangeCloud}**\nnot priced · ${fmtTokens(state.series.reduce((a, s) => a + s.tokens, 0))} tokens\n_Imported cloud usage, recorded off this Mac; it carries no dollar figure._\n`;
    }
    if (src === "droid") {
      const rangeDroid = state.range === "today" ? "Today " + fmtDay(data.start_day || isoDay(new Date()))
        : (state.range === "week" ? "This week " : "This month ") + fmtRange(data.start_day, data.end_day);
      return `**Keysrs · Subscriptions · Droid · ${rangeDroid}**\nnot priced · ${fmtTokens(state.series.reduce((a, s) => a + s.tokens, 0))} tokens\n_Counted from Droid's own local log on this Mac; it carries no dollar figure._\n`;
    }
    const showGrok = src === "all" || src === "grok";
    const showClaude = src === "all" || src === "claude";
    const showOpenAI = src === "all" || src === "openai";
    const grok = showGrok ? Number(t.grok_usd) || 0 : 0;
    const claude = showClaude ? Number(t.claude_usd_estimate) || 0 : 0;
    const openai = showOpenAI ? Number(t.openai_usd_estimate) || 0 : 0;
    const anyEst = claude > 0 || openai > 0;
    // The same rule as the totals bar: Grok's receipt is named only when Grok alone has dollars.
    const grokOnly = src === "grok" || (src === "all" && !anyEst && grok > 0);
    const parts = [];
    if (showGrok) parts.push(`${fmtUsd(grok)} Grok`);
    if (showClaude) parts.push(`≈ ${fmtUsd(claude)} Claude`);
    if (showOpenAI) parts.push(`≈ ${fmtUsd(openai)} OpenAI`);
    parts.push(`${fmtTokens(state.series.reduce((a, s) => a + s.tokens, 0))} tokens`);
    const rangeLabel = state.range === "today" ? "Today " + fmtDay(data.start_day || isoDay(new Date()))
      : (state.range === "week" ? "This week " : "This month ") + fmtRange(data.start_day, data.end_day);
    const head = `**Keysrs · Subscriptions · ${rangeLabel}${projectMode() ? " · by project" : ""}**`;
    const line = `${anyEst ? "≈ " : ""}${fmtUsd(grok + claude + openai)} total · ${parts.join(" · ")}`;
    const rtMd = remoteTokens(data);
    const foot = (grokOnly
      ? "_From Grok's own cost log; local logs only, not a plan invoice._"
      : "_Estimated from the tools' own local logs on this Mac, not a plan invoice._")
      + (rtMd > 0 ? `\n_Plus ${fmtTokens(rtMd)} tokens imported from the cloud (not priced)._` : "");
    return `${head}\n${line}\n${foot}\n`;
  }
  async function copyTotals() {
    await ensureSpend();
    const md = totalsMarkdown();
    if (!md) { say("Nothing to copy yet."); return; }
    try {
      await navigator.clipboard.writeText(md);
      say("Copied the totals line as Markdown.");
    } catch {
      say("Clipboard blocked by the browser. Select the totals line and copy by hand.");
    }
  }
  $("btn-export").addEventListener("click", exportCsv);
  $("btn-copy-totals").addEventListener("click", copyTotals);

  // ---------- ingest ----------

  async function ingest() {
    if (state.busy) return;
    state.busy = true;
    const btn = $("btn-ingest");
    btn.disabled = true;
    btn.textContent = "Ingesting…";
    say("Reading Grok, Claude Code, Codex and Droid session logs.", true);
    try {
      const r = await api("/api/ingest", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source: "all" }) });
      let inserted = 0, errors = 0, files = 0;
      for (const rep of Object.values(r || {})) {
        inserted += rep.inserted || 0; errors += rep.errors || 0; files += rep.files || 0;
      }
      say(`Ingested ${plural(inserted, "new row", "new rows")} from ${plural(files, "file", "files")}${errors ? `, ${plural(errors, "parse error", "parse errors")}` : ""}.`);
      await loadModels();
      if (state.pane === "chart") await loadSpend();
      if (state.pane === "usage" || state.pane === "settings") await loadStatus();
    } catch (e) {
      say(e.message);
    } finally {
      btn.disabled = false;
      btn.textContent = "Ingest now";
      state.busy = false;
    }
  }
  $("btn-ingest").addEventListener("click", ingest);
  document.querySelectorAll('[data-action="add"]').forEach((b) => b.addEventListener("click", openAdd));

  // ---------- dialogs ----------

  document.querySelectorAll("dialog [data-close]").forEach((b) => {
    b.addEventListener("click", () => b.closest("dialog").close());
  });
  document.querySelectorAll("dialog").forEach((d) => {
    d.addEventListener("click", (e) => { if (e.target === d) d.close(); });
  });
  const openHelp = () => { if (!$("dlg-help").open) $("dlg-help").showModal(); };
  $("btn-help").addEventListener("click", openHelp);
  $("btn-guide").addEventListener("click", openHelp);
  // The guide's Copy buttons copy the static command written in the HTML beside them, in the
  // help dialog and in its first-use clone alike. Nothing from the vault or a response is ever
  // in those blocks, so nothing else can be copied this way.
  document.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-copy-cmd]");
    if (!btn) return;
    const code = btn.parentElement?.querySelector("code");
    if (code) copyText(code.textContent, btn);
  });

  // ---------- first use ----------

  // The same three steps in two places would drift, so the card on the Usage pane is the help
  // dialog's own guide, cloned without its ids. The guide itself is always reachable from ?.
  function renderOnboard() {
    const body = $("onboard-body");
    if (body.childElementCount) return;
    const clone = $("guide").cloneNode(true);
    clone.removeAttribute("id");
    clone.removeAttribute("aria-labelledby");
    for (const node of clone.querySelectorAll("[id]")) node.removeAttribute("id");
    body.replaceChildren(clone);
  }
  const onboardDismissed = () => { try { return localStorage.getItem("ksf.onboarded") === "1"; } catch { return false; } };
  const dismissOnboard = () => {
    try { localStorage.setItem("ksf.onboarded", "1"); } catch { /* fine */ }
    $("onboard").hidden = true;
  };
  // First use only: an empty vault that has not dismissed this before. Someone who already has a
  // key has already done this, so the card never appears for them.
  function syncOnboard() {
    const show = !onboardDismissed() && state.keys.length === 0;
    if (show) renderOnboard();
    $("onboard").hidden = !show;
  }
  $("onboard-dismiss").addEventListener("click", dismissOnboard);
  $("onboard-help").addEventListener("click", openHelp);
  $("usage-empty-help").addEventListener("click", openHelp);
  $("keys-empty-help").addEventListener("click", openHelp);

  // ---------- keyboard ----------

  document.addEventListener("keydown", (e) => {
    const mod = e.metaKey || e.ctrlKey;
    if (mod && !e.shiftKey && !e.altKey) {
      if (openDialog() || isTyping(e.target)) return;
      if (e.key === "1") { e.preventDefault(); showPane("usage", { keyboard: true }); }
      else if (e.key === "2") { e.preventDefault(); showPane("chart", { keyboard: true }); }
      else if (e.key === "3") { e.preventDefault(); showPane("keys", { keyboard: true }); }
      else if (e.key === "4") { e.preventDefault(); showPane("settings", { keyboard: true }); }
      else if (e.key === "r" || e.key === "R") { e.preventDefault(); ingest(); }
      return;
    }
    if (e.altKey) return;
    const dlg = openDialog();
    if (dlg) {
      if (e.key === "?" && dlg.id === "dlg-help") { e.preventDefault(); dlg.close(); }
      return;
    }
    if (isTyping(e.target)) return;
    if (e.key === "?") { e.preventDefault(); $("dlg-help").showModal(); return; }
    if (state.pane === "chart") {
      // Tokens → USD → requests, with requests only where every call is countable.
      if (e.key === "t") {
        e.preventDefault();
        const cycle = keysMode() ? ["tokens", "usd", "requests"] : ["tokens", "usd"];
        setUnit(cycle[(cycle.indexOf(state.unit) + 1) % cycle.length]);
        return;
      }
      // The top-level choice gets a key of its own: it is the one that decides what the rest mean.
      if (e.key === "s") { e.preventDefault(); setScope(keysMode() ? "subs" : "keys"); return; }
      if (e.key === "d") { e.preventDefault(); setRange("today"); return; }
      if (e.key === "w") { e.preventDefault(); setRange("week"); return; }
      if (e.key === "m") { e.preventDefault(); setRange("month"); return; }
      if (e.key === "x") { e.preventDefault(); exportCsv(); return; }
      if (e.key === "p" && state.source === "claude") { e.preventDefault(); setGroup(projectMode() ? "model" : "project"); return; }
      if (e.key === "C" && e.shiftKey) { e.preventDefault(); copyTotals(); return; }
    }
    if (state.pane === "keys") {
      if (e.key === "n") { e.preventDefault(); openAdd(); return; }
      if (e.key === "/" && !$("keys-search-box").hidden) { e.preventDefault(); $("keys-search").focus(); return; }
      const act = PANE_KEYS[e.key];
      if (act && state.selected && !e.target.closest("#keys-body")) {
        e.preventDefault();
        menuFocusReturn = null;
        ROW_ACT[act](state.selected);
        return;
      }
      const inList = e.target.closest && e.target.closest("#keys-body");
      if (!inList && (e.key === "ArrowDown" || e.key === "ArrowUp" || e.key === "j" || e.key === "k")) {
        const tr = rowFor(state.selected);
        if (tr) { e.preventDefault(); tr.focus(); }
      }
    }
  });

  // ---------- plan rows: plan · % used · resets in ----------

  function resetsIn(iso) {
    if (!iso) return "";
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return "";
    const s = Math.floor((t - Date.now()) / 1000);
    if (s <= 0) return "reset due";
    if (s < 60) return "resets in " + s + "s";
    const m = Math.floor(s / 60);
    if (m < 60) return "resets in " + m + "m";
    const h = Math.floor(m / 60);
    if (h < 48) return "resets in " + h + "h " + (m % 60) + "m";
    return "resets in " + Math.floor(h / 24) + "d " + (h % 24) + "h";
  }

  // "as of 2 h ago" for snapshot-based numbers; empty when fresh or unknown
  function asOf(iso) {
    if (!iso) return "";
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return "";
    const m = Math.floor((Date.now() - t) / 60000);
    if (m < 30) return "";
    if (m < 120) return `as of ${m} min ago`;
    if (m < 48 * 60) return `as of ${Math.floor(m / 60)} h ago`;
    return "as of " + relTime(iso).toLowerCase();
  }

  function meter(label, pct, right) {
    const labelRow = el("div", { class: "live-meter-label" },
      el("span", { text: label }),
      typeof right === "string" ? el("span", { class: pct == null ? "live-note" : "", text: right }) : right,
    );
    if (pct == null) {
      return el("div", { class: "live-meter live-meter-plain" }, labelRow);
    }
    const fill = el("i", { class: "live-fill" + (Number(pct) >= 100 ? " live-fill-over" : "") });
    const width = Math.max(0, Math.min(100, Number(pct)));
    fill.style.width = width + "%";
    if (width > 0) fill.style.minWidth = "8px";
    return el("div", { class: "live-meter" },
      labelRow,
      el("div", { class: "live-track", role: "meter", "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(Math.round(width)), "aria-label": label + " used" }, fill),
    );
  }

  // right side of a plan meter: "22% used · resets in 2h 1m"
  function usedRight(pct, resetIso) {
    if (pct == null) return el("span", { class: "live-note", text: "Unavailable" });
    const reset = resetsIn(resetIso);
    return el("span", {},
      el("span", { class: "live-used", text: Math.round(pct) + "% used" }),
      reset ? el("span", { class: "live-reset", text: " · " + reset }) : null,
    );
  }

  function hasLocalMeasure(row) {
    if (!row) return false;
    // The Droid row is counted from the catalog, so its zeros are real zeros: it never falls
    // into "not tracked", which is for tools whose quota is not in any local file.
    if (row.source === "droid") return true;
    // A subscription row is a card the user pinned here; it shows a plan, never a measurement,
    // but it belongs in the list above the collapsed group, not inside it.
    if (row.subscription_id != null) return true;
    if (row.limit_remaining != null || row.usage_weekly != null) return true;
    if (row.source === "claude" || row.five_hour_pct != null || row.fable_pct != null || row.weekly_pct != null) return true;
    if (row.source === "grok" && row.weekly_usd != null) return true;
    if (typeof row.weekly_tokens === "number" && row.weekly_tokens > 0) return true;
    if (typeof row.weekly_prompts === "number" && row.weekly_prompts > 0) return true;
    if (typeof row.weekly_usd === "number" && row.weekly_usd > 0) return true;
    return false;
  }

  // ---------- Droid row: three windows, optional limits ----------

  const LIMIT_WINDOWS = ["five_hour", "weekly", "monthly"];
  // The row the Set limits dialog was opened for, kept here because the form cannot hold it.
  let limitsForRow = null;

  // The Droid row: 5-hour rolling, calendar week and calendar month, counted by the engine from
  // the records it ingested. A window with a limit the user set is a percent meter with
  // "X of Y tokens"; a window without one shows its tokens alone. Nothing is estimated: a zero
  // window says zero, and an empty catalog says so in the note.
  function renderDroidRow(row) {
    const windows = [
      { label: "5 hour", tokens: row.five_hour_tokens, limit: row.five_hour_limit, pct: row.five_hour_pct },
      { label: "Weekly", tokens: row.weekly_tokens, limit: row.weekly_limit, pct: row.weekly_pct },
      { label: "Month", tokens: row.monthly_tokens, limit: row.monthly_limit, pct: row.monthly_pct },
    ];
    const meters = windows.map(({ label, tokens, limit, pct }) => {
      if (limit != null && pct != null) {
        // The bar caps at 100%, the number does not: a blown limit stays honest past it.
        return meter(label, pct, el("span", {},
          el("span", { class: "live-used", text: pct + "%" }),
          el("span", { text: " · " + fmtTokens(tokens) + " of " + fmtTokens(limit) + " tokens" }),
        ));
      }
      return meter(label, null, fmtTokens(tokens) + " tokens");
    });
    const note = row.usage_note ? el("p", { class: "live-note", text: row.usage_note }) : null;
    // A Factory subscription attaches here rather than adding a row of its own: its plan
    // names the row, a token limit already is one window's limit, and a non-token limit
    // stays the one line of text it was entered as.
    const sub = row.subscription_id != null;
    return el("div", { class: "live-row", "data-source": row.source },
      el("div", { class: "live-head" },
        el("span", { class: "live-title", text: row.title || "Droid" }),
        row.plan ? el("span", { class: "live-plan", text: row.plan, title: "The plan on the Factory subscription pinned to this row" }) : null,
        row.limit_text ? el("span", { class: "live-plan", text: row.limit_text, title: "The limit on the Factory subscription; a token limit would be the window's meter instead" }) : null,
        el("span", { class: "row-actions live-limits" },
          sub ? el("button", {
            type: "button", class: "btn-row",
            title: "Edit the Factory subscription pinned to this row",
            onclick: () => openSubDialog(row),
          }, "Edit") : null,
          sub ? el("button", {
            type: "button", class: "btn-row",
            title: "Remove the Factory subscription from the Droid row",
            onclick: () => askRemoveSub(row),
          }, "Remove") : null,
          el("button", {
            type: "button", class: "btn-row",
            title: "Set optional token limits for the Droid windows",
            onclick: () => openLimits(row),
          }, "Set limits"),
        ),
      ),
      el("div", { class: "live-meters" }, ...meters),
      note,
    );
  }

  function openLimits(row) {
    limitsForRow = row;
    $("limits-err").textContent = "";
    const form = $("limits-form");
    for (const name of LIMIT_WINDOWS) {
      form.elements[name].value = row[name + "_limit"] != null ? String(row[name + "_limit"]) : "";
    }
    if (!$("dlg-limits").open) $("dlg-limits").showModal();
  }

  $("limits-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.target;
    const err = $("limits-err");
    err.textContent = "";
    const row = limitsForRow;
    if (!row) { $("dlg-limits").close(); return; }
    const ops = [];
    for (const name of LIMIT_WINDOWS) {
      const input = form.elements[name];
      const raw = input.value.trim();
      const prior = row[name + "_limit"];
      // A number field reports typed letters as an empty value; badInput keeps them from
      // passing as "no limit" and silently clearing the window.
      if (input.validity.badInput) {
        err.textContent = "Limits are whole token counts of 1 or more.";
        return;
      }
      if (!raw) {
        // An emptied field clears that window's limit; a window that never had one sends nothing.
        if (prior != null) ops.push(api(`/api/limits/${row.source}/${name}`, { method: "DELETE" }));
        continue;
      }
      const tokens = Number(raw);
      if (!Number.isInteger(tokens) || tokens <= 0) {
        err.textContent = "Limits are whole token counts of 1 or more.";
        return;
      }
      if (tokens !== prior) {
        ops.push(api(`/api/limits/${row.source}/${name}`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ tokens }),
        }));
      }
    }
    try {
      await Promise.all(ops);
      say("Saved Droid limits.");
      $("dlg-limits").close();
      await loadStatus();
    } catch (e2) { err.textContent = e2.message; }
  });

  // ---------- subscriptions (plans the user pins to the Usage pane) ----------

  const SUB_TOOLS = ["cursor", "gemini", "copilot", "perplexity", "chatgpt", "factory", "custom"];
  // The row being edited (its subscription_id addresses the record); null means a fresh add.
  let subEditing = null;
  let subRemoving = null;

  // One row per subscription: the plan and the optional limit as text, and the one honest
  // sentence about why no usage figure sits beside them. Never a percent: nothing on this
  // row is measured, so there is nothing a percent could be of.
  function renderSubRow(row) {
    return el("div", { class: "live-row", "data-source": row.source, "data-sub-id": row.subscription_id },
      el("div", { class: "live-head" },
        el("span", { class: "live-title", text: row.title || row.source }),
        row.plan ? el("span", { class: "live-plan", text: row.plan }) : null,
        row.limit_text ? el("span", { class: "live-plan", text: row.limit_text, title: "The limit you set; usage against it is not tracked locally" }) : null,
        el("span", { class: "row-actions live-limits" },
          el("button", {
            type: "button", class: "btn-row",
            title: "Edit this subscription",
            onclick: () => openSubDialog(row),
          }, "Edit"),
          el("button", {
            type: "button", class: "btn-row",
            title: "Remove this subscription",
            onclick: () => askRemoveSub(row),
          }, "Remove"),
        ),
      ),
      row.usage_note ? el("p", { class: "live-note", text: row.usage_note }) : null,
    );
  }

  function syncSubNameField(tool) {
    // Only a custom tool is named by its own name; the built-ins carry theirs in the picker.
    $("sub-name-label").hidden = tool !== "custom";
  }

  async function openSubDialog(row) {
    subEditing = row || null;
    $("sub-err").textContent = "";
    const dialog = $("dlg-sub");
    const form = $("sub-form");
    $("sub-title").textContent = row ? "Edit subscription" : "Add subscription";
    $("sub-submit").textContent = row ? "Save" : "Add subscription";
    // The tool is who the subscription is about; once the row exists it cannot change.
    form.elements.tool.disabled = Boolean(row);
    if (!dialog.open) dialog.showModal();
    // An edit fills from the stored record: the rendered row carries the plan and the limit
    // as text, and the raw amount, unit and period (and a Factory row's tool) live only in
    // the catalog.
    let sub = null;
    if (row) {
      try {
        const data = await api("/api/subscriptions");
        sub = ((data && data.subscriptions) || []).find((s) => s.id === row.subscription_id) || null;
        if (!sub) $("sub-err").textContent = "That subscription is no longer in the catalog; reload the page.";
      } catch (e) { $("sub-err").textContent = e.message; }
    }
    const tool = sub ? sub.tool : (row ? (row.source === "droid" ? "factory" : row.source) : "cursor");
    form.elements.tool.value = SUB_TOOLS.includes(tool) ? tool : "cursor";
    syncSubNameField(form.elements.tool.value);
    form.elements.name.value = sub ? (sub.name || "") : "";
    form.elements.plan.value = sub ? sub.plan : "";
    form.elements.limit_amount.value = sub && sub.limit_amount != null ? String(sub.limit_amount) : "";
    form.elements.limit_unit.value = sub ? (sub.limit_unit || "") : "";
    form.elements.limit_period.value = sub ? (sub.limit_period || "") : "";
  }

  $("btn-add-sub").addEventListener("click", () => openSubDialog(null));
  $("sub-form").elements.tool.addEventListener("change", (e) => syncSubNameField(e.target.value));

  $("sub-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.target;
    const err = $("sub-err");
    err.textContent = "";
    const tool = form.elements.tool.value;
    const name = form.elements.name.value.trim();
    if (tool === "custom" && !name) { err.textContent = "A custom tool needs a name."; return; }
    const plan = form.elements.plan.value.trim();
    if (!plan) { err.textContent = "Plan is required."; return; }
    // The limit is one fact in three fields; anything less is never sent anywhere.
    const amountInput = form.elements.limit_amount;
    const rawAmount = amountInput.value.trim();
    const unit = form.elements.limit_unit.value;
    const period = form.elements.limit_period.value;
    const body = {
      tool,
      name: tool === "custom" ? name : null,
      plan,
      limit_amount: null, limit_unit: null, limit_period: null,
    };
    if (rawAmount || unit || period) {
      if (!rawAmount || !unit || !period) {
        err.textContent = "A limit needs an amount, a unit and a period together.";
        return;
      }
      // A number field reports typed letters as an empty value; badInput keeps them from
      // passing as "no limit", the same guard the Droid limits dialog uses.
      if (amountInput.validity.badInput) { err.textContent = "The limit amount must be a number."; return; }
      const amount = Number(rawAmount);
      if (!Number.isFinite(amount) || amount <= 0) { err.textContent = "The limit amount must be greater than 0."; return; }
      if ((unit === "tokens" || unit === "requests") && !Number.isInteger(amount)) {
        err.textContent = "A " + unit + " limit is a whole number.";
        return;
      }
      body.limit_amount = amount;
      body.limit_unit = unit;
      body.limit_period = period;
    }
    try {
      if (subEditing) {
        await api("/api/subscriptions/" + encodeURIComponent(subEditing.subscription_id), {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        });
        say("Saved the subscription.");
      } else {
        await api("/api/subscriptions", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        });
        say("Added the subscription.");
      }
      $("dlg-sub").close();
      await loadStatus();
    } catch (e2) { err.textContent = e2.message; }
  });

  function askRemoveSub(row) {
    subRemoving = row;
    $("sub-remove-err").textContent = "";
    // A Factory subscription lives on the Droid row it is pinned to; the confirmation must ask
    // about the subscription, not name the row it sits on, so it cannot read "Remove Droid?".
    $("sub-remove-name").textContent = row.source === "droid"
      ? "the Factory subscription"
      : row.title || row.plan || "this subscription";
    $("sub-remove-hint").textContent = row.source === "droid"
      ? "The plan and limit come off the Droid row, and the window limit it drove is cleared with it."
      : "The row disappears from this pane and the built-in placeholder returns.";
    if (!$("dlg-sub-remove").open) $("dlg-sub-remove").showModal();
  }

  $("sub-remove-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    if (!subRemoving) { $("dlg-sub-remove").close(); return; }
    try {
      await api("/api/subscriptions/" + encodeURIComponent(subRemoving.subscription_id), { method: "DELETE" });
      say("Removed the subscription.");
      subRemoving = null;
      $("dlg-sub-remove").close();
      await loadStatus();
    } catch (e2) { $("sub-remove-err").textContent = e2.message; }
  });

  function renderLiveRow(row) {
    if (!row) return null;
    // The Droid row is its own layout: three windows, each optionally a meter of a limit the
    // user set, plus the controls that set them and, with a Factory subscription pinned to it,
    // that subscription's plan, limit text, Edit and Remove. The generic branches below stay
    // provider-shaped.
    if (row.source === "droid") return renderDroidRow(row);
    // A pinned subscription is a card of its own shape: plan, limit text, the honest note, and
    // Edit and Remove. No meters, no percents — nothing on it was measured.
    if (row.subscription_id != null) return renderSubRow(row);
    const meters = [];
    // The engine attaches its calendar-week period to every row with a weekly figure;
    // Claude and OpenRouter rows carry none.
    const weekly = "Weekly · " + (row.period ? row.period.label : "");
    if (row.five_hour_pct != null || row.source === "claude") {
      meters.push(meter("5 hour", row.five_hour_pct, usedRight(row.five_hour_pct, row.five_hour_resets_at)));
    }
    if (row.source === "claude") {
      meters.push(meter("Fable", row.fable_pct, usedRight(row.fable_pct, row.fable_resets_at)));
    }
    if (row.weekly_pct != null || row.source === "claude") {
      meters.push(meter("Weekly", row.weekly_pct, usedRight(row.weekly_pct, row.weekly_resets_at)));
    }
    // No provider percentage at all: one plain line with what the local logs say for the week.
    // These cards follow the page's unit too: tokens and percentages are what was measured, and a
    // dollar figure waits for an explicit USD choice. The switch is on the summary line below.
    const forUsd = " · choose USD below for the amount";
    if (row.source !== "claude" && row.five_hour_pct == null && row.fable_pct == null && row.weekly_pct == null) {
      const tokens = row.weekly_tokens != null ? fmtTokens(row.weekly_tokens) + " tokens" : null;
      if (usdMode() && row.weekly_usd != null) meters.push(meter(weekly, null, fmtUsd(row.weekly_usd) + (tokens ? " · " + tokens : "") + " · local logs"));
      else if (tokens) meters.push(meter(weekly, null, tokens + " · local logs"));
      else if (row.weekly_usd != null) meters.push(meter(weekly, null, "cost recorded in the local logs" + forUsd));
      else if (row.weekly_prompts != null) meters.push(meter(weekly, null, plural(row.weekly_prompts, "prompt", "prompts") + " sent · limit not tracked"));
    }
    if (row.source === "openrouter" && (row.limit_remaining != null || row.usage_weekly != null)) {
      if (row.limit != null && row.limit > 0 && row.limit_remaining != null) {
        const used = Math.max(0, row.limit - row.limit_remaining);
        // The share left is the same fact without naming a sum, so the meter stays informative.
        const text = usdMode()
          ? fmtUsd(row.limit_remaining) + " left of " + fmtUsd(row.limit)
          : trim((row.limit_remaining / row.limit) * 100) + "% of the credit limit left" + forUsd;
        meters.push(meter("Credit limit", (used / row.limit) * 100, el("span", {}, el("span", { class: "live-used", text }))));
      } else if (row.limit_remaining != null) {
        meters.push(meter("Credit", null, usdMode() ? fmtUsd(row.limit_remaining) + " left · no limit set" : "credit remaining, no limit set" + forUsd));
      }
      if (row.usage_weekly != null) {
        meters.push(meter("Weekly", null, usdMode() ? fmtUsd(row.usage_weekly) + " billed by OpenRouter" : "billed by OpenRouter" + forUsd));
      }
    }
    const note = row.usage_note ? el("p", { class: "live-note", text: row.usage_note }) : null;
    const stale = (row.five_hour_pct != null || row.fable_pct != null || row.weekly_pct != null || row.limit_remaining != null) ? asOf(row.snapshot_at) : "";
    const planText = row.plan || (row.kind === "api" ? "API" : "");
    return el("div", { class: "live-row", "data-source": row.source },
      el("div", { class: "live-head" },
        el("span", { class: "live-title", text: row.title || row.source }),
        planText ? el("span", { class: "live-plan", text: planText }) : null,
        stale ? el("span", { class: "live-note live-stale", text: stale, title: "Plan windows come from the last time the tool ran, not a live pull." }) : null,
      ),
      meters.length ? el("div", { class: "live-meters" }, ...meters) : null,
      note,
    );
  }

  async function loadStatus() {
    try {
      const data = await api("/api/status");
      const version = data.catalog_version;
      if (version != null && state.catalogVersion != null && version !== state.catalogVersion && state.pane === "chart") {
        loadModels().then(loadSpend);
      }
      if (version != null && state.catalogVersion != null && version !== state.catalogVersion) {
        loadUsageTotals();
        // A gateway call bumps the version without anyone touching this page: a relayed or
        // tunnelled call arrives while the Keys pane sits open, and its "Via gateway" cell
        // and "Last used" would otherwise show the vault as it was when the pane was entered.
        if (state.pane === "keys" && !state.busy) loadKeys({ quiet: true });
      }
      state.catalogVersion = version;
      state.status = data;
      renderStatus();
    } catch {
      $("live-status").hidden = true;
    }
  }

  function renderStatus() {
    const data = state.status;
    if (!data) return;
    renderSettings();
    const box = $("live-status");
    // Hidden cards leave this pane only: they are not zero and not "not tracked", and the
    // Chart, the totals and ingest never consult these preferences.
    if (!hiddenSynced) syncHiddenUsage(true);
    const hidden = hiddenUsage();
    const isHidden = (r) => (r.source === "droid" && !showDroid()) || hidden.has(usageId(r));
    const all = data.plans || [];
    const hiddenCount = all.filter(isHidden).length;
    // Only what this Mac measures is a card. A tool whose quota is in no local file is not
    // listed as "not tracked": + Add subscription is where a plan for one of those is pinned,
    // and it then appears here as the card the user made. Cards turned off in Settings are not
    // counted on this pane either; the one case that needs a word is every card being off,
    // which must not read as "nothing yet".
    const nodes = all.filter((r) => !isHidden(r) && hasLocalMeasure(r)).map(renderLiveRow).filter(Boolean);
    const allHidden = nodes.length === 0 && hiddenCount > 0;
    $("usage-empty").hidden = nodes.length > 0 || allHidden;
    $("usage-hidden").hidden = !allHidden;
    box.hidden = nodes.length === 0;
    box.replaceChildren(...nodes);
  }

  // ---------- settings ----------

  // Per-browser presentation preferences, like the unit and key sort. Nothing here reaches the
  // catalog or an /api endpoint; hiding a subscription never removes it.
  const showDroid = () => { try { return localStorage.getItem("ksf.showDroid") === "1"; } catch { return false; } };
  const hiddenUsage = () => {
    try {
      const v = JSON.parse(localStorage.getItem("ksf.hiddenUsage") || "[]");
      return new Set(Array.isArray(v) ? v.filter((x) => typeof x === "string") : []);
    } catch { return new Set(); }
  };
  // Two Cursor plans share a source, so a pinned subscription is told apart by its id.
  const usageId = (row) => row.subscription_id || row.source;

  function setShowDroid(on) {
    try { localStorage.setItem("ksf.showDroid", on ? "1" : "0"); } catch { /* fine */ }
    renderStatus();
  }
  function setUsageHidden(id, hide) {
    const set = hiddenUsage();
    if (hide) set.add(id); else set.delete(id);
    try { localStorage.setItem("ksf.hiddenUsage", JSON.stringify([...set])); } catch { /* fine */ }
    syncHiddenUsage();
    renderStatus();
  }
  // The menu bar has no browser storage, so the app keeps a mirror of this choice. Sent on
  // every change and once per page load, which carries over a choice made before the mirror.
  let hiddenSynced = false;
  function syncHiddenUsage(onLoad) {
    hiddenSynced = true;
    const hidden = [...hiddenUsage()];
    // Nothing hidden on a fresh load means nothing to carry over; the menu bar shows no Droid.
    if (onLoad && hidden.length === 0) return;
    api("/api/preferences/hidden-usage", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ hidden }),
    }).catch(() => { /* the menu bar keeps its last copy */ });
  }
  function setTheme(name) {
    applyTheme(name);
    try { localStorage.setItem("ksf.theme", name); } catch { /* fine */ }
    renderSettings();
    // Chart colours come from CSS variables read at draw time.
    if (state.spend) renderSpend();
  }

  const setSwitch = (btn, on) => btn.setAttribute("aria-checked", on ? "true" : "false");

  function renderSettings() {
    setSwitch($("theme-switch"), readTheme() === "light");
    setSwitch($("droid-switch"), showDroid());
    const status = state.status;
    const list = $("usage-cards-list");
    if (!status) {
      list.replaceChildren(el("p", { class: "muted", text: "Loading…" }));
      $("last-ingest").textContent = "";
      return;
    }
    $("last-ingest").textContent = status.last_ingest_at ? "Last ingest " + relTime(status.last_ingest_at) : "Not ingested yet";
    const hidden = hiddenUsage();
    const rows = (status.plans || []).filter((r) => r.source !== "droid");
    list.replaceChildren(...rows.map((r) => {
      const id = usageId(r);
      const labelId = "usage-card-" + id.replace(/[^a-z0-9_-]/gi, "-");
      return el("div", { class: "setting" },
        el("span", { class: "setting-label", id: labelId, text: r.plan ? `${r.title} · ${r.plan}` : r.title || r.source }),
        el("button", { type: "button", role: "switch", class: "switch", "data-usage-id": id, "aria-labelledby": labelId, "aria-checked": String(!hidden.has(id)) }),
      );
    }));
  }

  $("theme-switch").addEventListener("click", () => setTheme(readTheme() === "light" ? "dark" : "light"));
  $("droid-switch").addEventListener("click", () => setShowDroid(!showDroid()));
  $("usage-cards-list").addEventListener("click", (e) => {
    const btn = e.target.closest("[data-usage-id]");
    if (!btn) return;
    setUsageHidden(btn.dataset.usageId, btn.getAttribute("aria-checked") === "true");
  });
  document.querySelectorAll('[data-action="settings"]').forEach((b) => b.addEventListener("click", () => showPane("settings")));

  // ---------- relay (the app's own: one Touch ID to turn on, off again at every launch) ----------

  async function loadRelay() {
    try {
      state.relay = await api("/api/relay");
    } catch (e) {
      state.relay = null;
      $("relay-hint").textContent = e.message === UNREACHABLE ? "" : e.message;
      $("relay-switch").disabled = true;
      return;
    }
    renderRelay();
  }

  const hostOf = (url) => { try { return new URL(url).host; } catch { return "the Worker"; } };
  const clockOf = (iso) => {
    const t = Date.parse(iso || "");
    return Number.isNaN(t) ? "" : new Date(t).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  };

  function relayHint(r) {
    if (!r.on) {
      if (r.elsewhere) return "keys relay is running in a Terminal" + (r.elsewhere_pid ? ` (process ${r.elsewhere_pid})` : "") + "; stop it there to run the relay here. The Worker keeps one Mac connection.";
      if (!r.configured) return "Not set up yet: deploy the Worker (docs/relay.md), then run keys relay setup --url https://<your worker> in Terminal.";
      return `Off. One Touch ID connects to ${hostOf(r.url)} until you turn it off or quit Keysrs.`;
    }
    const host = hostOf(r.url);
    let line;
    if (r.state === "connected") {
      line = `Connected to ${host}` + (r.connected_since ? ` since ${clockOf(r.connected_since)}` : "");
      if (r.inflight > 0) line += ` · ${plural(r.inflight, "call", "calls")} open`;
    } else if (r.state === "connecting") {
      line = `Connecting to ${host}…`;
    } else {
      line = "Not connected; retrying" + (r.retry_at ? ` at ${clockOf(r.retry_at)}` : "") + (r.last_error ? `. ${r.last_error}` : "");
    }
    if (r.awake) line += " · keeping the Mac awake";
    return line;
  }

  function renderRelay() {
    const r = state.relay;
    if (!r) return;
    const sw = $("relay-switch");
    setSwitch(sw, r.on);
    sw.disabled = !!state.relayPending || (!r.on && (!r.configured || r.elsewhere));
    // The hint is a live region and the page polls: an unchanged line must not be read again.
    const hint = state.relayPending || relayHint(r);
    if ($("relay-hint").textContent !== hint) $("relay-hint").textContent = hint;
    const awake = $("relay-awake-switch");
    setSwitch(awake, r.stay_awake);
    awake.disabled = !!state.relayPending;
  }

  async function setRelay(body, pending) {
    if (state.relayPending) return;
    state.relayPending = pending;
    renderRelay();
    try {
      state.relay = await api("/api/relay", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    } catch (e) {
      say(e.message);
    } finally {
      state.relayPending = null;
    }
    // A refused toggle leaves the page's copy stale (a Terminal relay, a cancelled Touch ID).
    await loadRelay();
  }
  $("relay-switch").addEventListener("click", () => {
    if (!state.relay) return;
    const on = state.relay.on;
    setRelay({ enabled: !on }, on ? "Turning off…" : "Touch ID…");
  });
  $("relay-awake-switch").addEventListener("click", () => {
    if (!state.relay) return;
    setRelay({ stay_awake: !state.relay.stay_awake }, "Saving…");
  });

  // One quiet line under the plan rows: this month from the local logs, in the unit this page is
  // in. It is never a subscription invoice, and no dollar figure appears unless USD was chosen.
  async function loadUsageTotals() {
    try {
      state.monthSpend = await api("/api/spend?range=month");
      renderUsageTotals();
    } catch { state.monthSpend = null; $("usage-totals").replaceChildren(); }
  }
  function renderUsageTotals() {
    const data = state.monthSpend;
    const node = $("usage-totals");
    if (!data) return;
    const t = data.totals || {};
    const toggle = el("button", {
      type: "button", class: "link",
      text: usdMode() ? "show tokens" : "show USD",
      "aria-label": usdMode() ? "Show this month in tokens instead of USD" : "Show this month in USD instead of tokens",
      onclick: () => setUnit(usdMode() ? "tokens" : "usd"),
    });
    const chart = el("button", { type: "button", class: "link", text: "open the chart", onclick: () => showPane("chart") });
    if (!usdMode()) {
      const rows = data.rows || [];
      const byFamily = new Map();
      let cached = 0, hasRemoteField = false;
      for (const r of rows) {
        const f = family(r.model || "");
        // Imported cloud tokens are shown once, as their own share, so the families are local only.
        byFamily.set(f, (byFamily.get(f) || 0) + Math.max(0, rowCounted(r) - (Number(r.remote_counted_tokens) || 0)));
        if (r.remote_counted_tokens != null) hasRemoteField = true;
        cached += (r.cached_read_tokens || 0);
      }
      const total = [...byFamily.values()].reduce((a, n) => a + n, 0);
      const remote = Number(t.remote_tokens) || 0;
      const parts = [];
      for (const [fam, label] of [["grok", "Grok"], ["claude", "Claude"], ["openai", "OpenAI"], ["gemini", "Gemini"], ["glm", "GLM"], ["kimi", "Kimi"], ["deepseek", "DeepSeek"], ["other", "other"]]) {
        const n = byFamily.get(fam) || 0;
        if (n > 0) parts.push(el("span", {}, el("b", { text: fmtTokens(n) }), " " + label));
      }
      const nodes = [
        el("span", { text: "This month from local logs " }),
        el("b", { text: fmtTokens(hasRemoteField ? total : Math.max(0, total - remote)) + " tokens", title: cached ? CACHE_NOTE : null }),
      ];
      if (remote > 0) {
        nodes.push(el("span", { class: "totals-sep", text: "·" }),
          el("span", {}, el("b", { text: fmtTokens(remote) }), " imported from cloud (not priced)"));
      }
      for (const p of parts) { nodes.push(el("span", { class: "totals-sep", text: "·" })); nodes.push(p); }
      nodes.push(el("span", { class: "totals-sep", text: "·" }), toggle,
        el("span", { class: "totals-sep", text: "·" }), chart);
      node.replaceChildren(...nodes);
      return;
    }
    const grok = Number(t.grok_usd) || 0;
    const claude = Number(t.claude_usd_estimate) || 0;
    const openai = Number(t.openai_usd_estimate) || 0;
    const remoteUsd = Number(t.remote_tokens) || 0;
    node.replaceChildren(
      el("span", { text: "This month from local logs " }),
      el("b", { text: (claude + openai > 0 ? "≈ " : "") + fmtUsd(grok + claude + openai) }),
      el("span", { class: "totals-sep", text: "·" }),
      el("span", {}, el("b", { text: fmtUsd(grok) }), " Grok"),
      el("span", { class: "totals-sep", text: "·" }),
      el("span", {}, el("b", { text: "≈ " + fmtUsd(claude) }), " Claude"),
      el("span", { class: "totals-sep", text: "·" }),
      el("span", {}, el("b", { text: "≈ " + fmtUsd(openai) }), " OpenAI"),
      ...(remoteUsd > 0 ? [el("span", { class: "totals-sep", text: "·" }),
        el("span", {}, el("b", { text: fmtTokens(remoteUsd) }), " tokens imported from cloud (not priced)")] : []),
      el("span", { class: "totals-sep", text: "·" }),
      toggle,
      el("span", { class: "totals-sep", text: "·" }),
      chart,
    );
  }

  // ---------- start ----------

  loadProviders();
  syncScopeChips();
  loadModels();
  showPane("usage", { keyboard: true });
  document.addEventListener("DOMContentLoaded", () => window.KeysAnalytics?.event("view_usage"), { once: true });
  loadUsageTotals();
  loadKeys({ quiet: true });
  setInterval(loadStatus, 15000);
  // The relay's line moves on its own (a reconnect, a call opening), so it is read again while shown.
  setInterval(() => { if (state.pane === "settings" && !document.hidden && !state.relayPending) loadRelay(); }, 5000);
  setInterval(() => { if (state.pane === "chart" && !document.hidden && !state.busy) loadSpend(); }, 60000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden && state.pane === "chart") loadSpend(); });
})();
