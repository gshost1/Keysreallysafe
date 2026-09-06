(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");

  const readUnit = () => { try { return localStorage.getItem("ksf.unit") === "usd" ? "usd" : "tokens"; } catch { return "tokens"; } };

  const state = {
    pane: "usage",
    source: "all",
    range: ["today", "week", "month"].includes(new URLSearchParams(location.search).get("range")) ? new URLSearchParams(location.search).get("range") : "today",
    unit: readUnit(),
    key: new URLSearchParams(location.search).get("key") || null,
    group: "model",
    eventsOpen: null,
    spend: null,
    series: [],
    keys: [],
    selected: null,
    mixFilter: null,
    busy: false,
    colors: new Map(),
    slots: new Map(),
    providers: null,
    catalogVersion: null,
    status: null,
    engineDown: false,
  };

  const SLOTS = 4;
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

  let statusTimer = 0;
  function say(msg, sticky) {
    const node = $("status");
    node.textContent = msg || "";
    clearTimeout(statusTimer);
    if (msg && !sticky) statusTimer = setTimeout(() => { if (node.textContent === msg) node.textContent = ""; }, 4000);
  }

  // ---------- api (same origin only) ----------

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
      throw new Error("Can't reach the local site. Is keys dashboard still running?");
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
      err.code = code;
      throw err;
    }
    return data;
  }
  function friendly(code, status) {
    switch (code) {
      case "auth_failed": return "Touch ID cancelled or failed.";
      case "not_found": return "That key no longer exists.";
      case "already_exists": return "A key with that name already exists.";
      case "forbidden": return "Blocked: request was not same-origin.";
      case "missing or bad token": return "This page is from an older launch. Reload it.";
      case "method_not_allowed": return "That endpoint is missing on the server.";
      default: return code || `Request failed (${status}).`;
    }
  }
  function setEngineDown(down) {
    if (state.engineDown === down) return;
    state.engineDown = down;
    if (down) say("Engine is not answering. Run keys dashboard or keys menubar, then reload.", true);
    else if ($("status").textContent.startsWith("Engine is not")) say("");
  }

  // ---------- panes ----------

  const panes = { usage: $("pane-usage"), chart: $("pane-chart"), keys: $("pane-keys") };
  const tabs = { usage: $("nav-usage"), chart: $("nav-chart"), keys: $("nav-keys") };
  const PANE_ORDER = ["usage", "chart", "keys"];

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
    state.pane = name;
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
    else loadKeys({ focus: !!opts.keyboard && !opts.focusTab });
  }

  for (const [name, tab] of Object.entries(tabs)) {
    tab.addEventListener("click", () => showPane(name));
  }
  document.querySelector(".seg").addEventListener("keydown", (e) => {
    if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)) return;
    e.preventDefault();
    const i = PANE_ORDER.indexOf(state.pane);
    const dir = e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 1;
    showPane(PANE_ORDER[(i + dir + PANE_ORDER.length) % PANE_ORDER.length], { keyboard: true, focusTab: true });
  });

  // ---------- chips (radiogroups) ----------

  function wireChips(attr, onChange) {
    const buttons = [...document.querySelectorAll(`.chips [${attr}]`)];
    const set = (btn, keyboard) => {
      for (const b of buttons) {
        const on = b === btn;
        b.setAttribute("aria-checked", on ? "true" : "false");
        b.tabIndex = on ? 0 : -1;
      }
      onChange(btn.getAttribute(attr), keyboard);
    };
    for (const b of buttons) {
      b.addEventListener("click", () => set(b, false));
      b.addEventListener("keydown", (e) => {
        const i = buttons.indexOf(b);
        let next = null;
        if (e.key === "ArrowRight" || e.key === "ArrowDown") next = buttons[(i + 1) % buttons.length];
        if (e.key === "ArrowLeft" || e.key === "ArrowUp") next = buttons[(i - 1 + buttons.length) % buttons.length];
        if (!next) return;
        e.preventDefault();
        set(next, true);
        next.focus();
      });
    }
    return {
      sync(value) {
        const btn = buttons.find((b) => b.getAttribute(attr) === value) || buttons[0];
        for (const b of buttons) {
          const on = b === btn;
          b.setAttribute("aria-checked", on ? "true" : "false");
          b.tabIndex = on ? 0 : -1;
        }
      },
    };
  }

  wireChips("data-source", (value) => { state.source = value; state.mixFilter = null; syncGroupChips(); loadSpend(); });
  const rangeChips = wireChips("data-range", (value) => {
    state.range = value;
    const url = new URL(location.href);
    url.searchParams.set("range", value);
    history.replaceState(null, "", url);
    loadSpend();
  });
  rangeChips.sync(state.range);
  // A key filter narrows both charts and the model list to calls that went through the gateway with that key.
  function setKey(name) {
    state.key = state.key === name ? null : name;
    const url = new URL(location.href);
    if (state.key) url.searchParams.set("key", state.key); else url.searchParams.delete("key");
    history.replaceState(null, "", url);
    loadSpend();
  }
  function renderKeyChip() {
    const box = $("key-chip");
    box.hidden = !state.key;
    box.replaceChildren();
    if (!state.key) return;
    box.append(el("button", {
      type: "button", role: "button", class: "chip-clear", "aria-checked": "true", "aria-label": "Stop filtering by key " + state.key,
      onclick: () => setKey(state.key),
    }, el("span", { text: "key · " + state.key }), el("span", { class: "x", text: "×", "aria-hidden": "true" })));
  }
  const unitChips = wireChips("data-unit", (value) => setUnit(value));
  unitChips.sync(state.unit);

  // Projects are a Claude-only grouping (the only source with a project path). The chips hide otherwise.
  const groupChips = wireChips("data-group", (value) => setGroup(value));
  function setGroup(value) {
    state.group = value === "project" && state.source === "claude" ? "project" : "model";
    groupChips.sync(state.group);
    state.mixFilter = null;
    loadSpend();
  }
  function syncGroupChips() {
    const show = state.source === "claude";
    $("group-chips").hidden = !show;
    if (!show && state.group !== "model") { state.group = "model"; groupChips.sync("model"); }
  }
  const todayMode = () => state.range === "today";
  function setRange(value) {
    rangeChips.sync(value);
    state.range = value;
    const url = new URL(location.href);
    url.searchParams.set("range", value);
    history.replaceState(null, "", url);
    loadSpend();
  }

  function setUnit(value) {
    state.unit = value === "usd" ? "usd" : "tokens";
    try { localStorage.setItem("ksf.unit", state.unit); } catch { /* fine */ }
    unitChips.sync(state.unit);
    if (state.spend) { renderMix(); drawChart(); }
  }
  const usdMode = () => state.unit === "usd";

  // ---------- spend ----------

  let spendSeq = 0;
  async function loadSpend() {
    const seq = ++spendSeq;
    // Today draws by hour, which the engine only groups by model; the model list still needs rows.
    const q = new URLSearchParams({ range: state.range, by: projectMode() && !todayMode() ? "project" : "model", source: state.source });
    if (state.key) q.set("key", state.key);
    renderKeyChip();
    try {
      const reqs = [api("/api/spend?" + q.toString())];
      if (todayMode()) {
        const h = new URLSearchParams({ range: "today", by: "hour", source: state.source });
        if (state.key) h.set("key", state.key);
        reqs.push(api("/api/spend?" + h.toString()).catch(() => null));
      }
      const [data, hourly] = await Promise.all(reqs);
      if (seq !== spendSeq) return;
      state.spend = data;
      state.hourlyPoints = hourly ? hourly.points || [] : null;
      renderSpend();
    } catch (e) {
      if (seq !== spendSeq) return;
      say(e.message, true);
    }
  }

  async function loadModels() {
    try {
      const list = await api("/api/models");
      if (!Array.isArray(list)) return;
      state.slots = new Map(list.map((m) => [m.model, m.slot]));
    } catch { /* colours fall back to first-sighting order */ }
  }

  const family = (m) => (/^grok/i.test(m) ? "grok" : /^claude/i.test(m) ? "claude" : /^(gpt-|o[1-9]|codex|chatgpt)/i.test(m) ? "openai" : "other");

  // Colour follows the model. The engine's colour registry gives every model a stable slot, so a
  // family's shades are handed out in slot order and never move between loads or restarts.
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
        if (i >= SLOTS) return;
        const base = fam === "grok" ? 0 : fam === "claude" ? 10 : fam === "openai" ? 20 : 30;
        state.colors.set(m, { color: `var(--s-${fam}-${i + 1})`, slot: base + i, family: fam });
      });
    }
  }
  const colorFor = (model) => (model === OTHER || model === "Other projects" ? { color: "var(--s-other)", slot: 90, family: "other" } : state.colors.get(model) || null);

  function buildSeries(rows) {
    const order = { grok: 0, claude: 1, openai: 2, other: 3 };
    // Same accounting as the engine's totals: Claude counts every bucket (cache reads and
    // writes are billed separately), Grok's cached reads already sit inside input_tokens.
    const isReal = (r) => r.model !== "<synthetic>"
      && ((r.input_tokens || 0) + (r.output_tokens || 0) + (r.cached_read_tokens || 0) + (r.cache_creation_tokens || 0)) > 0;
    // The engine sends one row per (model, key); daily points are per model. Merge rows by model
    // first so a model with local and gateway usage, or two keys, is one series and one bucket.
    const merged = new Map();
    for (const r of rows.filter(isReal)) {
      const id = projectMode() ? (r.cwd || r.project || "unknown") : (r.model || "unknown");
      const m = merged.get(id);
      if (!m) { merged.set(id, { ...r }); continue; }
      for (const f of ["input_tokens", "output_tokens", "cached_read_tokens", "cache_creation_tokens"]) m[f] = (m[f] || 0) + (r[f] || 0);
      if (r.usd != null) m.usd = (m.usd || 0) + r.usd;
      if (r.usd_estimate != null) m.usd_estimate = (m.usd_estimate || 0) + r.usd_estimate;
      m.key = m.key && r.key && m.key !== r.key ? m.key + ", " + r.key : m.key || r.key || null;
    }
    const items = [...merged.values()].map((r) => ({
      model: projectMode() ? (r.cwd || r.project || "unknown") : (r.model || "unknown"),
      label: projectMode() ? (r.project || r.cwd || "unknown") : (r.model || "unknown"),
      cwd: r.cwd || null,
      tokens: (r.input_tokens || 0) + (r.output_tokens || 0)
        + (projectMode() || family(r.model || "") === "claude" ? (r.cached_read_tokens || 0) + (r.cache_creation_tokens || 0) : 0),
      input: r.input_tokens || 0,
      output: r.output_tokens || 0,
      cached: r.cached_read_tokens || 0,
      created: r.cache_creation_tokens || 0,
      usd: r.usd,
      est: r.usd_estimate,
    }));
    if (projectMode()) {
      items.sort((a, b) => b.tokens - a.tokens);
      // two projects with the same folder name: show the parent folder too
      const seen = new Map();
      for (const it of items) seen.set(it.label, (seen.get(it.label) || 0) + 1);
      for (const it of items) if (seen.get(it.label) > 1 && it.cwd) it.label = it.cwd.split("/").filter(Boolean).slice(-2).join("/");
    } else items.sort((a, b) => order[family(a.model)] - order[family(b.model)] || b.tokens - a.tokens);
    assignColors(items.map((it) => it.model));
    const out = [];
    let other = null;
    for (const it of items) {
      const entry = colorFor(it.model);
      if (entry) {
        out.push({ ...it, color: entry.color, slot: entry.slot, members: [it.model] });
      } else {
        if (!other) other = { model: projectMode() ? "Other projects" : OTHER, label: projectMode() ? "Other projects" : OTHER, tokens: 0, input: 0, output: 0, cached: 0, created: 0, usd: null, est: null, color: "var(--s-other)", slot: 99, members: [] };
        other.tokens += it.tokens; other.input += it.input; other.output += it.output;
        other.cached += it.cached; other.created += it.created;
        if (it.usd != null) other.usd = (other.usd || 0) + it.usd;
        if (it.est != null) other.est = (other.est || 0) + it.est;
        other.members.push(it.model);
        other.labels = (other.labels || []).concat(it.label);
      }
    }
    if (other) out.push(other);
    out.sort((a, b) => a.slot - b.slot);
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
    renderInterval(data);
    if (empty) return;
    state.series = buildSeries(rows);
    renderTotals(data);
    renderMix();
    drawChart();
  }

  const projectMode = () => state.group === "project" && !todayMode();
  function renderEmpty(empty, data) {
    const node = $("spend-empty");
    if (!empty) return;
    node.replaceChildren();
    const ingested = data && data.last_ingest_at;
    if (state.key) {
      node.append(`No calls through the gateway with ${state.key} in this range. `, el("button", { type: "button", class: "link", text: "Show everything", onclick: () => setKey(state.key) }));
    } else if (state.source !== "all") {
      const name = { grok: "Grok", claude: "Claude Code", openai: "Codex" }[state.source] || state.source;
      node.append(`No ${name} sessions in this range. `, el("button", { type: "button", class: "link", text: "Show all", onclick: () => { document.querySelector('[data-source="all"]').click(); } }));
    } else if (!ingested) {
      node.append("No sessions ingested yet. ", el("button", { type: "button", class: "link", text: "Ingest now", onclick: ingest }));
    } else {
      node.append("Nothing in this range. Claude Code, Grok and Codex logs were read; none fall in ",
        el("span", { text: state.range === "week" ? "this week." : state.range === "month" ? "this month." : "today." }));
    }
  }

  // Zero, unknown and partial are different things. usd_month is null when calls happened but
  // none could be priced; usd_month_kind says which case this is.
  function gatewayMonthCell(k, on) {
    const kind = k.usd_month_kind || (Number(k.usd_month) > 0 ? "estimate" : "none");
    const unpricedCalls = Number(k.gateway_month_unpriced_calls) || 0;
    const calls = Number(k.gateway_month_calls) || 0;
    const open = () => { setKey(k.name); showPane("chart"); };
    if (kind === "none") {
      return el("td", { class: "td-usd none", "data-label": "Via gateway", text: on ? "no calls yet" : "—", title: "Dollars appear once the gateway routes this key." });
    }
    if (kind === "unknown") {
      return el("td", { class: "td-usd none", "data-label": "Via gateway", text: `${plural(calls, "call", "calls")}, unpriced`, title: "This month's gateway calls with this key carried no model or no list price, so the cost is unknown, not zero. Click to chart.", onclick: open });
    }
    const partial = kind === "partial" ? ` ${plural(unpricedCalls, "call", "calls")} unpriced and left out.` : "";
    return el("td", { class: "td-usd", "data-label": "Via gateway", text: (kind === "partial" ? "≥ " : "") + fmtUsd(k.usd_month), title: "This month, calls through the local gateway with this key." + partial + " Click to chart.", onclick: open });
  }

  // One line: the dollar figure first, then the parts that make it up.
  function renderTotals(data) {
    const t = data.totals || {};
    const src = state.source;
    const parts = [];
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
      parts.push(el("span", { class: "totals-part", title: ("Calls routed through the local gateway that no local log also recorded. Not added to the total above. " + why).trim() },
        el("b", { text: label }), " via gateway"));
    }
    parts.forEach((p, i) => { if (i) nodes.push(el("span", { class: "totals-sep", text: "·" })); nodes.push(p); });
    const unpriced = unpricedModels(data, src);
    if (unpriced.length) {
      nodes.push(el("span", { class: "totals-sep", text: "·" }));
      nodes.push(el("span", { class: "totals-note warn", text: `${plural(unpriced.length, "model", "models")} unpriced`, title: "No local price row, left out of the estimate: " + unpriced.join(", ") }));
    }
    nodes.push(el("span", { class: "totals-note", text: anyEst ? (src === "grok" ? "" : "≈ estimate from list prices, not an invoice") : "from Grok's own cost log" }));
    $("totals").replaceChildren(...nodes);
  }

  // Models the engine could not price. Prefer its own list when it sends one; otherwise infer
  // from rows that have tokens but neither usd nor usd_estimate.
  function unpricedModels(data, src) {
    if (projectMode()) return [];
    const t = data.totals || {};
    const fromEngine = [].concat(t.claude_unpriced_models || [], t.openai_unpriced_models || []);
    if (fromEngine.length) return fromEngine;
    return (data.rows || [])
      .filter((r) => r.model !== "<synthetic>" && r.usd == null && r.usd_estimate == null)
      .filter((r) => (r.input_tokens || 0) + (r.output_tokens || 0) + (r.cached_read_tokens || 0) > 0)
      .filter((r) => src === "all" || family(r.model || "") === src)
      .filter((r) => family(r.model || "") !== "grok")
      .map((r) => r.model);
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

  function renderMix() {
    const list = $("mix");
    const usd = usdMode();
    const max = Math.max(1e-9, ...state.series.map((s) => (usd ? dollars(s) || 0 : s.tokens)));
    const items = state.series.map((s) => {
      const d = dollars(s);
      const isEst = s.usd == null && s.est != null;
      const usdNode = d == null
        ? el("span", { class: "mix-usd none", text: "—" })
        : el("span", { class: "mix-usd" + (usd ? " mix-primary" : ""), text: (isEst ? "≈ " : "") + fmtUsd(d) });
      const tokNode = el("span", { class: "mix-val" + (usd ? "" : " mix-primary"), text: fmtTokens(s.tokens) });
      const barFrac = (usd ? d || 0 : s.tokens) / max;
      const detail = (s.cwd ? s.cwd + "\n" : "") + `${fmtInt(s.input)} in, ${fmtInt(s.output)} out, ${fmtInt(s.cached)} cached reads, ${fmtInt(s.created)} cache writes`
        + (isEst ? "\nUSD is an estimate from list prices" : "")
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
        usd ? tokNode : usdNode,
      );
      li.style.setProperty("--c", s.color);
      return li;
    });
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
    const i = items.indexOf(li);
    const go = (j) => { const t = items[Math.max(0, Math.min(items.length - 1, j))]; if (t) t.focus(); };
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      toggleMix(li.dataset.model, true);
    } else if (e.key === "ArrowDown" || e.key === "j") {
      e.preventDefault();
      go(i + 1);
    } else if (e.key === "ArrowUp" || e.key === "k") {
      e.preventDefault();
      go(i - 1);
    } else if (e.key === "Home") {
      e.preventDefault();
      go(0);
    } else if (e.key === "End") {
      e.preventDefault();
      go(items.length - 1);
    }
  });

  // Only elapsed days: the axis runs from the range start to today (or the range end, if earlier).
  function axisDays(data) {
    const out = [];
    const today = new Date();
    const startP = parseDay(data.start_day);
    const endP = parseDay(data.end_day);
    let start, end;
    if (startP && endP) { start = startP.date; end = endP.date; }
    else if (state.range === "month") {
      start = new Date(today.getFullYear(), today.getMonth(), 1);
      end = new Date(today.getFullYear(), today.getMonth() + 1, 0);
    } else {
      start = new Date(today);
      start.setDate(today.getDate() - today.getDay());
      end = new Date(start);
      end.setDate(start.getDate() + 6);
    }
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
    const fmt = usd ? fmtUsd : fmtTokens;
    const fmtAxis = usd ? fmtUsdAxis : fmtTokens;

    const memberOf = new Map();
    for (const s of state.series) for (const m of s.members) memberOf.set(m, s);

    const byBucket = new Map(buckets.map((b) => [b, new Map()]));
    for (const p of points) {
      const s = memberOf.get(projectMode() ? (p.cwd || p.project || p.model) : p.model);
      if (!s) continue;
      const m = byBucket.get(keyOf(p));
      if (!m) continue;
      const v = usd ? (dollars(p) || 0) : Number(p.tokens) || 0;
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
    if (!usdMode()) return "tokens per " + per;
    const grokOnly = state.source === "grok";
    return "USD per " + per + (grokOnly ? "" : " · estimate except Grok");
  }

  function drawChart() {
    const svg = $("daily-svg");
    const data = state.spend;
    if (!data || $("daily").hidden) return;
    if (todayMode()) {
      const points = state.hourlyPoints || [];
      $("daily-title").textContent = "Today by hour";
      $("daily-unit").textContent = unitLabel("hour");
      const now = new Date();
      const today = isoDay(now);
      const hours = [];
      for (let h = 0; h <= now.getHours(); h++) hours.push(`${today}T${pad2(h)}:00`);
      for (const p of points) if (p.hour && !hours.includes(p.hour)) hours.push(p.hour);
      hours.sort();
      const any = points.some((p) => (usdMode() ? dollars(p) : p.tokens) > 0);
      $("chart-nothing").hidden = any;
      drawBars({
        svg, tipId: "daily-tip", buckets: hours, points,
        keyOf: (p) => p.hour, labelOf: (h) => "Today " + fmtHour(h), tickOf: fmtHourTick,
        labelEvery: hours.length > 12 ? 3 : 1,
      });
      return;
    }
    $("chart-nothing").hidden = true;
    $("daily-title").textContent = (state.range === "week" ? "This week by day" : "This month by day") + (projectMode() ? " · by project" : "");
    $("daily-unit").textContent = unitLabel("day");
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

  async function loadKeys(opts = {}) {
    try {
      const data = await api("/api/keys");
      state.keys = data.keys || [];
      renderKeys(opts);
    } catch (e) {
      if (!opts.quiet) say(e.message, true);
    }
  }

  const gatewayOn = (k) => !!(k.gateway_enabled || k.gateway_on);

  function renderKeys(opts = {}) {
    const body = $("keys-body");
    const keys = state.keys;
    $("keys-count").textContent = plural(keys.length, "key", "keys");
    $("keys-table").hidden = keys.length === 0;
    $("keys-empty").hidden = keys.length > 0;
    if (!keys.some((k) => k.name === state.selected)) state.selected = keys[0] ? keys[0].name : null;

    const rows = keys.map((k) => {
      const selected = k.name === state.selected;
      const tab = selected ? "0" : "-1";
      const tr = el("tr", { tabindex: selected ? "0" : "-1", "data-name": k.name, "aria-selected": String(selected) });
      const on = gatewayOn(k);
      const nameCell = el("td", { class: "td-name", "data-label": "Name" },
        el("span", { class: "key-name" }, k.name,
          on ? el("span", { class: "badge", text: "Gateway on", title: "Requests to the local gateway use this key until the engine restarts" }) : null),
      );
      if (k.notes) nameCell.append(el("span", { class: "key-notes", text: k.notes }));
      if (on && k.gateway_url) nameCell.append(el("span", { class: "key-notes gw-url", text: k.gateway_url, title: "Point the SDK base URL here. Select to copy." }));
      const prov = providerById(k.provider);
      const noGateway = prov && prov.gateway === false;
      tr.append(
        nameCell,
        el("td", { class: "td-provider", "data-label": "Provider", text: providerName(k.provider) }),
        el("td", { class: "td-kind", "data-label": "Kind", text: k.kind || "—" }),
        el("td", { class: "td-created", "data-label": "Created", text: fmtDate(k.created_at), title: k.created_at || null }),
        el("td", { class: "td-used", "data-label": "Last used", text: relTime(k.last_used_at), title: k.last_used_at || "Never copied or revealed" }),
        gatewayMonthCell(k, on),
        el("td", { class: "td-actions", "data-label": "Actions" },
          el("div", { class: "row-actions" },
            el("button", { type: "button", class: "btn btn-row", tabindex: tab, "data-act": "copy", "aria-label": "Copy " + k.name, text: "Copy" }),
            el("button", { type: "button", class: "btn btn-row", tabindex: tab, "data-act": "reveal", "aria-label": "Reveal " + k.name, text: "Reveal" }),
            el("button", { type: "button", class: "btn btn-row", tabindex: tab, "data-act": "edit", "aria-label": "Edit " + k.name, text: "Edit" }),
            el("button", { type: "button", class: "btn btn-row", tabindex: tab, "data-act": "history", "aria-pressed": String(state.eventsOpen === k.name), "aria-label": "History of " + k.name, text: "History" }),
            el("button", { type: "button", class: "btn btn-row", tabindex: tab, "data-act": "rotate", "aria-label": "Rotate " + k.name, text: "Rotate", title: "Replace the secret, keep the name" }),
            el("button", {
              type: "button", class: "btn btn-row", tabindex: tab, "data-act": "gateway", "aria-pressed": String(on),
              "aria-label": (on ? "Turn the gateway off for " : "Turn the gateway on for ") + k.name,
              text: on ? "Gateway on" : "Gateway",
              disabled: noGateway ? "" : null,
              title: noGateway ? (prov.name + " needs request signing; it cannot be proxied") : on ? "Stop proxying with this key" : "One Touch ID, then http://127.0.0.1:12767/" + k.name + " forwards to the provider with this key",
            }),
            el("span", { class: "act-div", "aria-hidden": "true" }),
            el("button", { type: "button", class: "btn btn-row btn-danger", tabindex: tab, "data-act": "delete", "aria-label": "Delete " + k.name, text: "Delete" }),
          ),
        ),
      );
      if (state.eventsOpen === k.name) return [tr, eventsRow(k)];
      return tr;
    });
    body.replaceChildren(...rows.flat());
    if (state.eventsOpen) loadEvents(state.eventsOpen);
    if (opts.focus && state.selected) {
      const tr = rowFor(state.selected);
      if (tr) tr.focus();
    }
  }

  function selectRow(name, focus) {
    state.selected = name;
    for (const tr of $("keys-body").rows) {
      const on = tr.dataset.name === name;
      tr.setAttribute("aria-selected", String(on));
      tr.tabIndex = on ? 0 : -1;
      tr.querySelectorAll("[data-act]").forEach((btn) => { btn.tabIndex = on ? 0 : -1; });
      if (on && focus) tr.focus();
    }
  }
  const rowFor = (name) => [...$("keys-body").rows].find((tr) => tr.dataset.name === name && !tr.classList.contains("key-events-row")) || null;
  const btnFor = (name, act) => { const tr = rowFor(name); return tr ? tr.querySelector(`[data-act="${act}"]`) : null; };

  function restoreKeysFocus(name, act) {
    if (state.pane !== "keys") return;
    const target = name || state.selected;
    if (act) {
      const btn = btnFor(target, act);
      if (btn) { btn.focus(); return; }
    }
    const tr = rowFor(target);
    if (tr) tr.focus();
  }

  $("keys-body").addEventListener("click", (e) => {
    const tr = e.target.closest("tr");
    if (!tr) return;
    selectRow(tr.dataset.name, false);
    const btn = e.target.closest("[data-act]");
    if (!btn) return;
    const name = tr.dataset.name;
    if (btn.dataset.act === "copy") copyKey(name);
    else if (btn.dataset.act === "reveal") revealKey(name);
    else if (btn.dataset.act === "edit") openEdit(name);
    else if (btn.dataset.act === "gateway") toggleGateway(name);
    else if (btn.dataset.act === "history") toggleEvents(name);
    else if (btn.dataset.act === "rotate") openRotate(name);
    else if (btn.dataset.act === "delete") askDelete(name);
  });

  $("keys-body").addEventListener("keydown", (e) => {
    const tr = e.target.closest("tr");
    if (!tr) return;
    const onButton = e.target.closest("[data-act]");
    if (tr.classList.contains("key-events-row")) return;
    const rows = [...$("keys-body").rows].filter((r) => !r.classList.contains("key-events-row"));
    const i = rows.indexOf(tr);
    const go = (j) => { const t = rows[Math.max(0, Math.min(rows.length - 1, j))]; if (t) selectRow(t.dataset.name, true); };
    switch (e.key) {
      case "ArrowDown": case "j": e.preventDefault(); go(i + 1); break;
      case "ArrowUp": case "k": e.preventDefault(); go(i - 1); break;
      case "Home": e.preventDefault(); go(0); break;
      case "End": e.preventDefault(); go(rows.length - 1); break;
      case "Enter": case "c":
        if (onButton && e.key === "Enter") return;
        e.preventDefault();
        copyKey(tr.dataset.name);
        break;
      case "v": e.preventDefault(); revealKey(tr.dataset.name); break;
      case "e": e.preventDefault(); openEdit(tr.dataset.name); break;
      case "g": e.preventDefault(); toggleGateway(tr.dataset.name); break;
      case "h": e.preventDefault(); toggleEvents(tr.dataset.name); break;
      case "r": e.preventDefault(); openRotate(tr.dataset.name); break;
      case "Backspace": case "Delete":
        if (onButton && onButton.dataset.act !== "delete" && e.key === "Delete") return;
        e.preventDefault();
        askDelete(tr.dataset.name);
        break;
      default: return;
    }
  });

  function setBtn(btn, text, disabled) {
    if (!btn) return;
    btn.textContent = text;
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
      const used = rowFor(name) && rowFor(name).querySelector(".td-used");
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
      const used = rowFor(name) && rowFor(name).querySelector(".td-used");
      if (used) used.textContent = "Just now";
    } catch (e) {
      setBtn(btn, "Reveal");
      say(e.message);
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

  function askDelete(name) {
    $("delete-name").textContent = name;
    $("delete-err").textContent = "";
    $("dlg-delete").dataset.name = name;
    $("dlg-delete").showModal();
    $("delete-confirm").focus();
  }
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

  // ---------- providers (grouped picker fed by /providers.json) ----------

  async function loadProviders() {
    try {
      const data = await api("/providers.json");
      if (data && Array.isArray(data.providers)) {
        state.providers = data;
        renderKeys();
      }
    } catch { state.providers = null; }
  }
  const providerById = (id) => (state.providers ? state.providers.providers.find((p) => p.id === id) : null);
  const providerName = (id) => { if (!id) return "—"; const p = providerById(id); return p ? p.name : id; };
  function guessProvider(secret) {
    if (!state.providers || !secret) return null;
    let best = null;
    for (const p of state.providers.providers) {
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
        const hits = state.providers.providers.filter((p) => p.group === g.id
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

  // ---------- add / edit ----------

  function openAdd() {
    const form = $("add-form");
    form.reset();
    $("add-err").textContent = "";
    $("dlg-add").showModal();
    form.elements.name.focus();
  }
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
  $("dlg-add").addEventListener("close", () => {
    $("add-form").elements.secret.value = "";
    queueMicrotask(() => {
      if (state.pane !== "keys") return;
      const active = document.activeElement;
      if (active && (active === $("btn-add") || $("pane-keys").contains(active))) return;
      restoreKeysFocus(state.selected);
    });
  });

  function openEdit(name) {
    const k = state.keys.find((x) => x.name === name);
    if (!k) return;
    const form = $("edit-form");
    form.reset();
    $("edit-err").textContent = "";
    $("edit-name").textContent = name;
    $("dlg-edit").dataset.name = name;
    form.elements.provider.value = k.provider || "";
    form.elements.kind.value = k.kind === "billing" ? "billing" : "runtime";
    form.elements.notes.value = k.notes || "";
    $("dlg-edit").showModal();
    form.elements.provider.focus();
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
    if (!Object.keys(payload).length) { $("dlg-edit").close(); return; }
    const submit = form.querySelector('[type="submit"]');
    setBtn(submit, "Saving…", true);
    try {
      await api("/api/keys/" + encodeURIComponent(name), { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
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
  $("dlg-host").addEventListener("close", () => {
    queueMicrotask(() => {
      if (state.pane !== "keys") return;
      const active = document.activeElement;
      if (active && $("pane-keys").contains(active) && active !== $("dlg-host")) return;
      restoreKeysFocus(state.selected, "gateway");
    });
  });
  $("dlg-edit").addEventListener("close", () => {
    queueMicrotask(() => {
      if (state.pane !== "keys") return;
      const active = document.activeElement;
      if (active && $("pane-keys").contains(active) && active !== $("dlg-edit")) return;
      restoreKeysFocus(state.selected, "edit");
    });
  });

  // ---------- key history (audit log the engine keeps; never the secret) ----------

  const ACTION_LABEL = { add: "added", copy: "copied", reveal: "revealed", env: "used in env", gateway_enable: "gateway on", gateway_disable: "gateway off", gateway_call: "gateway call", rotate: "rotated", rm: "deleted", patch: "edited" };
  const fmtWhen = (iso) => {
    const t = Date.parse(iso || "");
    if (Number.isNaN(t)) return iso || "";
    return new Date(t).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  };
  function eventsRow(k) {
    const tr = el("tr", { class: "key-events-row", "data-name": k.name });
    tr.append(el("td", { colspan: "7" }, el("div", { class: "key-events-head", text: "Loading history…" })));
    return tr;
  }
  async function loadEvents(name) {
    const tr = [...$("keys-body").rows].find((r) => r.classList.contains("key-events-row") && r.dataset.name === name);
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
        el("span", { text: ev.caller || "" }),
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

  function openRotate(name) {
    const form = $("rotate-form");
    form.reset();
    $("rotate-err").textContent = "";
    $("rotate-name").textContent = name;
    $("dlg-rotate").dataset.name = name;
    $("dlg-rotate").showModal();
    form.elements.secret.focus();
  }
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
  $("dlg-rotate").addEventListener("close", () => {
    $("rotate-form").elements.secret.value = "";
    queueMicrotask(() => {
      if (state.pane !== "keys") return;
      const active = document.activeElement;
      if (active && $("pane-keys").contains(active) && active !== $("dlg-rotate")) return;
      restoreKeysFocus(state.selected, "rotate");
    });
  });

  // ---------- gateway (per key, one Touch ID to turn on; the engine forgets on restart) ----------

  async function toggleGateway(name, host) {
    if (state.busy) return;
    const k = state.keys.find((x) => x.name === name);
    if (!k) return;
    const prov = providerById(k.provider);
    if (prov && prov.gateway === false) { say(prov.name + " cannot be proxied (request signing)."); return; }
    const on = gatewayOn(k);
    if (!on && prov && !prov.host && !host && !k.gateway_host) { askHost(name, prov); return; }
    state.busy = true;
    const btn = btnFor(name, "gateway");
    setBtn(btn, on ? "Turning off…" : "Touch ID…", true);
    try {
      const body = { enabled: !on };
      if (!on && (host || k.gateway_host)) body.host = host || k.gateway_host;
      const r = await api("/api/keys/" + encodeURIComponent(name) + "/gateway", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      say(on ? `Gateway off for ${name}.` : `Gateway on. Base URL ${(r && r.gateway_url) || "http://127.0.0.1:12767/" + name}`);
      await loadKeys();
      selectRow(name, false);
      restoreKeysFocus(name, "gateway");
    } catch (e) {
      setBtn(btn, on ? "Gateway on" : "Gateway");
      say(e.message);
    } finally {
      state.busy = false;
    }
  }

  function askHost(name, prov) {
    const form = $("host-form");
    form.reset();
    $("host-err").textContent = "";
    $("host-name").textContent = name;
    $("host-hint").textContent = (prov && prov.note) || "This provider has one host per account.";
    $("dlg-host").dataset.name = name;
    $("dlg-host").showModal();
    form.elements.host.focus();
  }
  $("host-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const host = e.target.elements.host.value.trim().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
    if (!host) { $("host-err").textContent = "Host is required."; return; }
    const name = $("dlg-host").dataset.name;
    $("dlg-host").close();
    toggleGateway(name, host);
  });

  // ---------- export ----------

  const csvCell = (v) => {
    if (v == null) return "";
    const s = String(v);
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  };
  function exportCsv() {
    const data = state.spend;
    if (!data || !(data.rows || []).length) { say("Nothing to export in this range."); return; }
    const cols = projectMode()
      ? ["project", "cwd", "input_tokens", "output_tokens", "cached_read_tokens", "cache_creation_tokens", "usd", "usd_estimate"]
      : ["model", "input_tokens", "output_tokens", "cached_read_tokens", "cache_creation_tokens", "usd", "usd_estimate", "key"];
    const lines = [cols.join(",")];
    for (const r of data.rows) {
      if (r.model === "<synthetic>") continue;
      lines.push(cols.map((c) => csvCell(r[c])).join(","));
    }
    const name = `keysreallysafe-${state.range}-${data.start_day || ""}-${data.end_day || ""}${state.key ? "-" + state.key : ""}.csv`;
    const blob = new Blob([lines.join("\n") + "\n"], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = el("a", { href: url, download: name });
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    say(`Saved ${name}.`);
  }

  function totalsMarkdown() {
    const data = state.spend;
    if (!data) return "";
    const t = data.totals || {};
    const src = state.source;
    const showGrok = src === "all" || src === "grok";
    const showClaude = src === "all" || src === "claude";
    const showOpenAI = src === "all" || src === "openai";
    const grok = showGrok ? Number(t.grok_usd) || 0 : 0;
    const claude = showClaude ? Number(t.claude_usd_estimate) || 0 : 0;
    const openai = showOpenAI ? Number(t.openai_usd_estimate) || 0 : 0;
    const anyEst = claude > 0 || openai > 0;
    const parts = [];
    if (showGrok) parts.push(`${fmtUsd(grok)} Grok`);
    if (showClaude) parts.push(`≈ ${fmtUsd(claude)} Claude`);
    if (showOpenAI) parts.push(`≈ ${fmtUsd(openai)} OpenAI`);
    parts.push(`${fmtTokens(state.series.reduce((a, s) => a + s.tokens, 0))} tokens`);
    const rangeLabel = state.range === "today" ? "Today " + fmtDay(data.start_day || isoDay(new Date()))
      : (state.range === "week" ? "This week " : "This month ") + fmtRange(data.start_day, data.end_day);
    const head = `**Keysreallysafe · ${rangeLabel}${state.key ? " · key " + state.key : ""}${projectMode() ? " · by project" : ""}**`;
    const line = `${anyEst ? "≈ " : ""}${fmtUsd(grok + claude + openai)} total · ${parts.join(" · ")}`;
    const foot = anyEst ? "_Estimate from list prices on local logs, not an invoice._" : "_From Grok's own cost log._";
    return `${head}\n${line}\n${foot}\n`;
  }
  async function copyTotals() {
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
    say("Reading Grok, Claude Code and Codex session logs.", true);
    try {
      const r = await api("/api/ingest", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source: "all" }) });
      let inserted = 0, errors = 0, files = 0;
      for (const rep of Object.values(r || {})) {
        inserted += rep.inserted || 0; errors += rep.errors || 0; files += rep.files || 0;
      }
      say(`Ingested ${plural(inserted, "new row", "new rows")} from ${plural(files, "file", "files")}${errors ? `, ${plural(errors, "parse error", "parse errors")}` : ""}.`);
      await loadModels();
      if (state.pane === "chart") await loadSpend();
      if (state.pane === "usage") await loadStatus();
    } catch (e) {
      say(e.message);
    } finally {
      btn.disabled = false;
      btn.textContent = "Ingest";
      state.busy = false;
    }
  }
  $("btn-ingest").addEventListener("click", ingest);
  document.querySelectorAll('[data-action="ingest"]').forEach((b) => b.addEventListener("click", ingest));
  document.querySelectorAll('[data-action="add"]').forEach((b) => b.addEventListener("click", openAdd));

  // ---------- dialogs ----------

  document.querySelectorAll("dialog [data-close]").forEach((b) => {
    b.addEventListener("click", () => b.closest("dialog").close());
  });
  document.querySelectorAll("dialog").forEach((d) => {
    d.addEventListener("click", (e) => { if (e.target === d) d.close(); });
  });
  $("btn-help").addEventListener("click", () => $("dlg-help").showModal());

  // ---------- keyboard ----------

  document.addEventListener("keydown", (e) => {
    const mod = e.metaKey || e.ctrlKey;
    if (mod && !e.shiftKey && !e.altKey) {
      if (openDialog() || isTyping(e.target)) return;
      if (e.key === "1") { e.preventDefault(); showPane("usage", { keyboard: true }); }
      else if (e.key === "2") { e.preventDefault(); showPane("chart", { keyboard: true }); }
      else if (e.key === "3") { e.preventDefault(); showPane("keys", { keyboard: true }); }
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
      if (e.key === "t") { e.preventDefault(); setUnit(usdMode() ? "tokens" : "usd"); return; }
      if (e.key === "d") { e.preventDefault(); setRange("today"); return; }
      if (e.key === "w") { e.preventDefault(); setRange("week"); return; }
      if (e.key === "m") { e.preventDefault(); setRange("month"); return; }
      if (e.key === "x") { e.preventDefault(); exportCsv(); return; }
      if (e.key === "p" && state.source === "claude") { e.preventDefault(); setGroup(projectMode() ? "model" : "project"); return; }
      if (e.key === "C" && e.shiftKey) { e.preventDefault(); copyTotals(); return; }
    }
    if (state.pane === "keys") {
      if (e.key === "n") { e.preventDefault(); openAdd(); return; }
      if (e.key === "e" && state.selected && !e.target.closest("#keys-body")) { e.preventDefault(); openEdit(state.selected); return; }
      if (e.key === "g" && state.selected && !e.target.closest("#keys-body")) { e.preventDefault(); toggleGateway(state.selected); return; }
      if (e.key === "h" && state.selected && !e.target.closest("#keys-body")) { e.preventDefault(); toggleEvents(state.selected); return; }
      if (e.key === "r" && state.selected && !e.target.closest("#keys-body")) { e.preventDefault(); openRotate(state.selected); return; }
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
    const reset = resetsIn(resetIso);
    return el("span", {},
      el("span", { class: "live-used", text: Math.round(pct) + "% used" }),
      reset ? el("span", { class: "live-reset", text: " · " + reset }) : null,
    );
  }

  function hasLocalMeasure(row) {
    if (!row) return false;
    if (row.limit_remaining != null || row.usage_weekly != null) return true;
    if (row.five_hour_pct != null || row.weekly_pct != null) return true;
    if (row.source === "grok" && row.weekly_usd != null) return true;
    if (typeof row.weekly_tokens === "number" && row.weekly_tokens > 0) return true;
    if (typeof row.weekly_usd === "number" && row.weekly_usd > 0) return true;
    return false;
  }

  // Locale calendar week (Sunday start, same as the engine's weekOfYear), unless the engine sends its own period.
  function weekSpan(row) {
    if (row.period && row.period.label) return row.period.label;
    if (row.period && row.period.start_day && row.period.end_day) return fmtRange(row.period.start_day, row.period.end_day);
    const today = new Date();
    const start = new Date(today.getFullYear(), today.getMonth(), today.getDate() - today.getDay());
    const end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + 6);
    const crosses = start.getMonth() !== today.getMonth() || end.getMonth() !== today.getMonth();
    return fmtRange(isoDay(start), isoDay(end)) + (crosses ? ", crosses the month" : "");
  }

  const sourceFamily = (source) => ({ grok: "grok", "xai-api": "grok", claude: "claude", openai: "openai", codex: "openai", chatgpt: "openai" })[source] || "other";

  // Where "open dashboard" goes for a vendor we cannot read locally. Plain links, no requests.
  const DASHBOARDS = {
    chatgpt: "https://chatgpt.com/#settings",
    cursor: "https://cursor.com/dashboard",
    gemini: "https://aistudio.google.com/usage",
    copilot: "https://github.com/settings/copilot",
    perplexity: "https://www.perplexity.ai/settings/account",
    openrouter: "https://openrouter.ai/activity",
    "xai-api": "https://console.x.ai",
  };

  function renderLiveRow(row) {
    if (!row) return null;
    const meters = [];
    const weekly = "Weekly · " + weekSpan(row);
    if (row.five_hour_pct != null) {
      meters.push(meter("5 hour", row.five_hour_pct, usedRight(row.five_hour_pct, row.five_hour_resets_at)));
    }
    if (row.weekly_pct != null) {
      meters.push(meter("Weekly", row.weekly_pct, usedRight(row.weekly_pct, row.weekly_resets_at)));
    }
    // No provider percentage at all: one plain line with what the local logs say for the week.
    if (row.five_hour_pct == null && row.weekly_pct == null) {
      if (row.weekly_usd != null) meters.push(meter(weekly, null, fmtUsd(row.weekly_usd) + (row.weekly_tokens != null ? " · " + fmtTokens(row.weekly_tokens) + " tokens" : "") + " · local logs"));
      else if (row.weekly_tokens != null) meters.push(meter(weekly, null, fmtTokens(row.weekly_tokens) + " tokens · local logs"));
    }
    if (row.source === "openrouter" && (row.limit_remaining != null || row.usage_weekly != null)) {
      if (row.limit != null && row.limit > 0 && row.limit_remaining != null) {
        const used = Math.max(0, row.limit - row.limit_remaining);
        meters.push(meter("Credit limit", (used / row.limit) * 100,
          el("span", {}, el("span", { class: "live-used", text: fmtUsd(row.limit_remaining) + " left of " + fmtUsd(row.limit) }))));
      } else if (row.limit_remaining != null) {
        meters.push(meter("Credit", null, fmtUsd(row.limit_remaining) + " left · no limit set"));
      }
      if (row.usage_weekly != null) meters.push(meter("Weekly", null, fmtUsd(row.usage_weekly) + " billed by OpenRouter"));
    }
    const note = row.usage_note ? el("p", { class: "live-note", text: row.usage_note }) : null;
    const stale = (row.five_hour_pct != null || row.weekly_pct != null || row.limit_remaining != null) ? asOf(row.snapshot_at) : "";
    const planText = row.plan || (row.kind === "api" ? "API" : row.kind === "local" ? "" : "");
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

  function renderAbsent(row) {
    const url = DASHBOARDS[row.source];
    const why = el("span", { class: "live-absent-why" }, el("span", { text: "not tracked" }));
    if (url) why.append(" · ", el("a", { class: "live-open", href: url, target: "_blank", rel: "noopener noreferrer", text: "open dashboard" }));
    if (row.usage_note) why.title = row.usage_note;
    return el("div", { class: "live-absent-row" },
      el("span", { class: "live-absent-name", text: row.title || row.source }),
      why,
    );
  }

  async function loadStatus() {
    try {
      const data = await api("/api/status");
      const version = data.catalog_version ?? data.last_ingest_at ?? null;
      if (version != null && state.catalogVersion != null && version !== state.catalogVersion && state.pane === "chart") {
        loadModels().then(loadSpend);
      }
      if (version != null && state.catalogVersion != null && version !== state.catalogVersion) loadUsageTotals();
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
    const box = $("live-status");
    let list = Array.isArray(data.plans) && data.plans.length
      ? data.plans
      : [data.grok, data.claude].filter(Boolean);
    // Codex is the same local token count the OpenAI row already carries; one row is enough.
    const openai = list.find((r) => r.source === "openai");
    if (openai && openai.weekly_tokens != null) {
      list = list.filter((r) => !(r.source === "codex" && r.weekly_tokens === openai.weekly_tokens));
    }
    const useful = [];
    const absent = [];
    for (const row of list) {
      if (hasLocalMeasure(row)) useful.push(row);
      else absent.push(row);
    }
    const nodes = useful.map(renderLiveRow).filter(Boolean);
    if (absent.length) {
      const details = el("details", { class: "live-more" },
        el("summary", { text: plural(absent.length, "provider", "providers") + " not tracked locally" }),
        el("div", { class: "live-absent" }, ...absent.map(renderAbsent)),
      );
      if (box.querySelector(".live-more")?.open) details.open = true;
      nodes.push(details);
    }
    $("usage-empty").hidden = nodes.length > 0;
    box.hidden = nodes.length === 0;
    box.replaceChildren(...nodes);
  }

  // One quiet line under the plan rows: this month's local dollars, not a subscription figure.
  async function loadUsageTotals() {
    try {
      const data = await api("/api/spend?range=month");
      const t = data.totals || {};
      const grok = Number(t.grok_usd) || 0;
      const claude = Number(t.claude_usd_estimate) || 0;
      const openai = Number(t.openai_usd_estimate) || 0;
      const node = $("usage-totals");
      node.replaceChildren(
        el("span", { text: "This month from local logs " }),
        el("b", { text: (claude + openai > 0 ? "≈ " : "") + fmtUsd(grok + claude + openai) }),
        el("span", { class: "totals-sep", text: "·" }),
        el("span", {}, el("b", { text: fmtUsd(grok) }), " Grok"),
        el("span", { class: "totals-sep", text: "·" }),
        el("span", {}, el("b", { text: "≈ " + fmtUsd(claude) }), " Claude"),
        el("span", { class: "totals-sep", text: "·" }),
        el("span", {}, el("b", { text: "≈ " + fmtUsd(openai) }), " OpenAI"),
        el("span", { class: "totals-sep", text: "·" }),
        el("button", { type: "button", class: "link", text: "open the chart", onclick: () => showPane("chart") }),
      );
    } catch { $("usage-totals").replaceChildren(); }
  }

  // ---------- start ----------

  loadProviders();
  syncGroupChips();
  loadModels();
  showPane("usage", { keyboard: true });
  loadUsageTotals();
  loadKeys({ quiet: true });
  setInterval(loadStatus, 15000);
  setInterval(() => { if (state.pane === "chart" && !document.hidden && !state.busy) loadSpend(); }, 60000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden && state.pane === "chart") loadSpend(); });
})();
