(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const token = () => (document.querySelector('meta[name="ksf-token"]') || {}).content || "";
  const state = {
    loaded: false,
    loading: false,
    unlocked: false,
    sessionToken: null,
    expiresAt: null,
    status: null,
    capabilities: {},
    summary: null,
    projects: [],
    selectedProjectId: null,
    entries: [],
    candidates: [],
    candidateReviewState: "pending",
    candidateLoadGeneration: 0,
    selectedCandidate: false,
    selectedEntryId: null,
    selectedEntryData: null,
    loadingEntryId: null,
    view: "overview",
    includeArchived: false,
    query: "",
    entryLoading: false,
    sessionGeneration: 0,
    expiryTimer: null,
    countdownTimer: null,
    locking: false,
  };

  const el = (tag, attrs, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs || {})) {
      if (value == null) continue;
      if (key === "text") node.textContent = String(value);
      else if (key === "class") node.className = value;
      else if (key === "on") for (const [event, handler] of Object.entries(value)) node.addEventListener(event, handler);
      else node.setAttribute(key, String(value));
    }
    for (const child of children) if (child != null) node.append(child);
    return node;
  };
  const text = (value, fallback = "—") => value == null || value === "" ? fallback : String(value);
  const metric = (value) => value == null || value === "" || Number.isNaN(Number(value)) ? "Unknown" : Number(value).toLocaleString("en-US");
  const date = (value) => {
    if (!value) return "Never";
    const numeric = typeof value === "number" || /^\d+$/.test(String(value)) ? Number(value) * (Number(value) < 1e12 ? 1000 : 1) : Date.parse(value);
    return Number.isNaN(numeric) ? String(value) : new Date(numeric).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
  };
  const dateInputValue = (value) => {
    if (!value) return "";
    const raw = String(value);
    if (/^\d+$/.test(raw)) {
      const millis = Number(raw) * (Number(raw) < 1e12 ? 1000 : 1);
      const parsed = new Date(millis);
      return Number.isNaN(parsed.getTime()) ? "" : parsed.toISOString().slice(0, 10);
    }
    return raw.slice(0, 10);
  };
  const kindLabel = (kind) => kind === "plan" ? "Plan" : "Memory";
  const projectId = (project) => project && (project.id || project.project_id);
  const selectedProject = () => state.projects.find((project) => projectId(project) === state.selectedProjectId) || state.projects[0] || null;
  const selectedEntry = () => state.selectedEntryData
    || (state.selectedCandidate ? state.candidates : state.entries).find((entry) => (entry.id || entry.entry_id) === state.selectedEntryId)
    || null;
  const FEATURE_FLAGS = ["memory_retrieval", "plan_reuse", "tool_selection", "model_routing", "memory_assessment", "candidate_capture"];

  const compatibleKey = (key) => {
    if (!key || typeof key !== "object" || typeof key.name !== "string" || !/^[a-z0-9][a-z0-9._-]*$/.test(key.name)) return false;
    const features = Array.isArray(key.features) ? key.features.map((value) => String(value).toLowerCase()) : [];
    return features.some((value) => ["optimizer", "jev", "evaluation", "model_evaluation"].includes(value))
      || ["typesafe", "vercel-ai-gateway"].includes(String(key.provider || "").toLowerCase());
  };

  async function loadOptimizerKeys(preselect = null) {
    const select = $("optimizer-jev-key");
    const message = $("optimizer-key-state");
    const prior = preselect != null ? String(preselect) : select.value;
    select.disabled = true;
    message.textContent = "Loading compatible stored keys…";
    try {
      const data = await request("/api/optimizer/keys");
      const unavailable = new Set((Array.isArray(data.providers) ? data.providers : []).filter((provider) => provider && typeof provider === "object" && (provider.available === false || provider.enabled === false)).map((provider) => provider.id));
      const compatible = (Array.isArray(data.keys) ? data.keys : []).filter(compatibleKey);
      const keys = compatible.filter((key) => !unavailable.has(key.provider));
      select.replaceChildren(el("option", { value: "", text: "Local only · no provider evaluation" }), ...keys.map((key) => el("option", {
        value: key.name,
        text: `${key.name} · ${text(key.label, key.provider || "provider")}${key.model_id ? ` · ${key.model_id}` : ""}`,
      })));
      if (prior && keys.some((key) => key.name === prior)) select.value = prior;
      message.textContent = keys.length ? `${keys.length} compatible stored ${keys.length === 1 ? "key" : "keys"}. Selection never unlocks automatically.`
        : compatible.length ? "A compatible key exists, but its provider is currently unavailable. Local-only mode remains available."
          : "No compatible stored key is available. Local-only mode remains available.";
    } catch {
      select.replaceChildren(el("option", { value: "", text: "Local only · no provider evaluation" }));
      message.textContent = "Stored key metadata is unavailable. Refresh the Optimizer page to try again; local-only mode remains available.";
    } finally {
      select.disabled = false;
    }
  }

  window.optimizerPreselectKey = function optimizerPreselectKey(name) {
    loadOptimizerKeys(name);
    setAlert("Key selected for the next explicit unlock. No authorization has started.");
  };

  function setAlert(message, sticky = false) {
    const node = $("optimizer-alert");
    if (!node) return;
    node.textContent = message || "";
    node.hidden = !message;
    if (message && !sticky) setTimeout(() => { if (node.textContent === message) { node.textContent = ""; node.hidden = true; } }, 5000);
  }

  function epochMillis(value) {
    if (value == null || value === "") return null;
    if (typeof value === "number" || /^\d+$/.test(String(value))) {
      const numeric = Number(value);
      return Number.isFinite(numeric) ? numeric * (numeric < 1e12 ? 1000 : 1) : null;
    }
    const parsed = Date.parse(String(value));
    return Number.isNaN(parsed) ? null : parsed;
  }

  function scheduleExpiry() {
    if (state.expiryTimer) clearTimeout(state.expiryTimer);
    state.expiryTimer = null;
    const expiresAt = epochMillis(state.expiresAt);
    if (!state.unlocked || expiresAt == null) return;
    const generation = state.sessionGeneration;
    const sessionToken = state.sessionToken;
    const delay = Math.max(0, expiresAt - Date.now());
    state.expiryTimer = setTimeout(() => {
      if (!state.unlocked || state.sessionGeneration !== generation || state.sessionToken !== sessionToken) return;
      if (Date.now() < expiresAt) { scheduleExpiry(); return; }
      clearSession();
      setAlert("Optimizer session expired. Unlock again to continue.", true);
    }, Math.min(delay, 2147483647));
  }

  const plural = (count, unit) => `${count.toLocaleString("en-US")} ${unit}${count === 1 ? "" : "s"}`;

  // Rounds down so the label never promises more time than the session has.
  function remainingLabel(remaining) {
    if (remaining < 60000) return "Expires in less than a minute";
    const minutes = Math.floor(remaining / 60000);
    if (minutes < 60) return `Expires in ${plural(minutes, "minute")}`;
    const hours = Math.floor(minutes / 60);
    if (hours < 48) return `Expires in ${plural(hours, "hour")}${minutes % 60 ? ` ${plural(minutes % 60, "minute")}` : ""}`;
    return `Expires in ${plural(Math.floor(hours / 24), "day")}`;
  }

  // Renders from the expiry already held in memory and the local clock; it never contacts the server.
  function renderSessionStatus() {
    if (state.countdownTimer) clearTimeout(state.countdownTimer);
    state.countdownTimer = null;
    const node = $("optimizer-session");
    if (!node) return;
    if (!state.unlocked) {
      node.textContent = "Session inactive";
      node.removeAttribute("title");
      return;
    }
    const expiresAt = epochMillis(state.expiresAt);
    if (expiresAt == null) {
      node.textContent = "Session active · expiry time unknown";
      node.title = "The server did not report a usable expiry time for this session.";
      return;
    }
    const remaining = expiresAt - Date.now();
    node.title = `Expires ${new Date(expiresAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "long" })}`;
    if (remaining <= 0) {
      node.textContent = "Session expired";
      return;
    }
    node.textContent = `Session active · ${remainingLabel(remaining)}`;
    const generation = state.sessionGeneration;
    const sessionToken = state.sessionToken;
    state.countdownTimer = setTimeout(() => {
      state.countdownTimer = null;
      if (!state.unlocked || state.sessionGeneration !== generation || state.sessionToken !== sessionToken) return;
      renderSessionStatus();
    }, (remaining >= 60000 ? remaining % 60000 : remaining) + 50);
  }

  async function closeSession(sessionToken) {
    if (!sessionToken) return;
    try {
      await request("/api/optimizer/close", { method: "POST", optimizer: sessionToken, headers: { "Content-Type": "application/json" }, body: "{}" });
    } catch { /* The server may already have expired or revoked this exact session. */ }
  }

  function clearSession({ close = true } = {}) {
    const sessionToken = state.sessionToken;
    state.sessionGeneration += 1;
    if (state.expiryTimer) clearTimeout(state.expiryTimer);
    state.expiryTimer = null;
    state.unlocked = false;
    state.sessionToken = null;
    state.expiresAt = null;
    state.summary = null;
    state.projects = [];
    state.entries = [];
    state.candidates = [];
    state.candidateLoadGeneration += 1;
    state.selectedCandidate = false;
    state.selectedEntryId = null;
    state.selectedEntryData = null;
    state.loadingEntryId = null;
    state.selectedProjectId = null;
    state.query = "";
    state.includeArchived = false;
    for (const id of ["optimizer-summary-cards", "optimizer-accounting", "optimizer-projects", "optimizer-project-preview", "optimizer-activity", "optimizer-entries", "optimizer-capabilities"]) {
      const node = $(id);
      if (node) node.replaceChildren();
    }
    const projectSelect = $("optimizer-entry-project");
    if (projectSelect) projectSelect.replaceChildren();
    const candidates = $("optimizer-candidates");
    if (candidates) candidates.replaceChildren();
    const query = $("optimizer-entry-query");
    if (query) query.value = "";
    const archived = $("optimizer-include-archived");
    if (archived) archived.checked = false;
    const projectDialogNode = $("optimizer-project-dialog");
    if (projectDialogNode) {
      if (typeof projectDialogNode.close === "function" && projectDialogNode.open) projectDialogNode.close();
      projectDialogNode.remove();
    }
    $("optimizer-content").hidden = true;
    $("optimizer-locked").hidden = false;
    $("optimizer-unlock").disabled = state.locking;
    $("optimizer-lock").hidden = true;
    $("optimizer-live-badge").hidden = true;
    renderSessionStatus();
    $("optimizer-entry-detail").replaceChildren(el("div", { class: "optimizer-detail-empty" }, el("h2", { text: "Select an entry" }), el("p", { text: "Unlock to inspect stored content." })));
    // Close only the discarded capability. A later unlock may already be in flight.
    if (close) void closeSession(sessionToken);
  }

  function handleAuthError(error) {
    if (error && (error.stale || error.sessionInvalidated)) return true;
    if (error && error.payload && error.payload.error === "optimizer_locked") {
      error.sessionInvalidated = true;
      clearSession();
      setAlert("Optimizer session expired or is locked. Unlock again to continue.", true);
      return true;
    }
    return false;
  }

  async function request(path, options = {}) {
    const headers = new Headers(options.headers || {});
    const launchToken = token();
    if (launchToken) headers.set("X-KSF-Token", launchToken);
    if (options.optimizer) headers.set("X-KSF-Optimizer", String(options.optimizer));
    const response = await fetch(path, { ...options, headers });
    let data = null;
    const raw = await response.text();
    if (raw) {
      try { data = JSON.parse(raw); } catch { data = { error: raw }; }
    }
    if (!response.ok) {
      const error = new Error(data && (data.message || data.error) ? String(data.message || data.error) : `Request failed (${response.status})`);
      error.status = response.status;
      error.payload = data;
      throw error;
    }
    return data || {};
  }

  async function status() {
    try {
      const data = await request("/api/optimizer/status");
      state.status = data;
      state.capabilities = data.capabilities || {};
      renderCapabilities();
      return data;
    } catch (error) {
      setAlert("Optimizer status is unavailable. Keep the dashboard running and try again.", true);
      return null;
    }
  }

  async function checkFocusedStatus() {
    const generation = state.sessionGeneration;
    const sessionToken = state.sessionToken;
    try {
      const data = await request("/api/optimizer/status");
      if (state.sessionGeneration !== generation || state.sessionToken !== sessionToken || !state.unlocked) return;
      state.status = data;
      state.capabilities = data.capabilities || state.capabilities;
      renderCapabilities();
      if (data.unlocked === false) {
        clearSession();
        setAlert("The optimizer session is locked or expired. Unlock again to continue.", true);
      }
    } catch (error) {
      if (state.sessionGeneration !== generation || state.sessionToken !== sessionToken || !state.unlocked) return;
      handleAuthError(error);
    }
  }

  async function unlock() {
    if (state.locking || state.unlocked) return;
    const button = $("optimizer-unlock");
    const generation = state.sessionGeneration;
    button.disabled = true;
    setAlert("Waiting for Touch ID…", true);
    try {
      const data = await request("/api/optimizer/unlock", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-KSF-Native-Presence": "1" },
        body: JSON.stringify({ native_presence: true, jev_key: $("optimizer-jev-key").value.trim() || undefined }),
      });
      if (!data.token) throw new Error("Unlock did not return a session capability.");
      if (state.sessionGeneration !== generation) { void closeSession(String(data.token)); return; }
      state.sessionGeneration += 1;
      state.sessionToken = String(data.token);
      state.expiresAt = data.expires_at || null;
      state.unlocked = true;
      scheduleExpiry();
      $("optimizer-locked").hidden = true;
      $("optimizer-content").hidden = false;
      $("optimizer-lock").hidden = false;
      renderSessionStatus();
      setAlert("");
      await loadData();
    } catch (error) {
      if (state.sessionGeneration !== generation) return;
      if (!handleAuthError(error)) setAlert(error.message || "Touch ID could not unlock the optimizer.", true);
    } finally {
      button.disabled = state.locking;
    }
  }

  async function lock() {
    if (state.locking) return;
    const sessionToken = state.sessionToken;
    state.locking = true;
    clearSession({ close: false });
    try {
      if (sessionToken) {
        await request("/api/optimizer/lock", { method: "POST", optimizer: sessionToken, headers: { "Content-Type": "application/json" }, body: "{}" });
      }
    } catch (error) {
      await closeSession(sessionToken);
      setAlert("The optimizer could not confirm its global lock. This page's session has been closed where possible.", true);
    } finally {
      state.locking = false;
      $("optimizer-unlock").disabled = false;
    }
  }

  async function rpc(operation, payload = {}) {
    if (!state.sessionToken) throw Object.assign(new Error("Optimizer is locked."), { status: 423, payload: { error: "optimizer_locked" } });
    const generation = state.sessionGeneration;
    const sessionToken = state.sessionToken;
    try {
      const response = await request("/api/optimizer/rpc", {
        method: "POST",
        optimizer: sessionToken,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ operation, payload }),
      });
      if (!state.unlocked || state.sessionGeneration !== generation || state.sessionToken !== sessionToken) {
        throw Object.assign(new Error("Optimizer response arrived after the session was locked."), { status: 423, stale: true });
      }
      return response;
    } catch (error) {
      if (state.sessionGeneration !== generation || state.sessionToken !== sessionToken || !state.unlocked) error.stale = true;
      if (!error.stale && !handleAuthError(error)) setAlert(error.message || "Optimizer request failed.", true);
      throw error;
    }
  }

  const objectValue = (value) => value && typeof value === "object" && !Array.isArray(value) ? value : {};
  const firstValue = (object, keys) => {
    const source = objectValue(object);
    for (const key of keys) if (Object.prototype.hasOwnProperty.call(source, key) && source[key] != null) return source[key];
    return null;
  };
  const costMetric = (value) => {
    if (value == null || value === "" || Number.isNaN(Number(value))) return "Unknown";
    return `$${Number(value).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 4 })}`;
  };
  const groupMetric = (group, keys) => firstValue(group, keys);
  const unknownCount = (group, keys) => groupMetric(group, keys);
  const groupLabel = (group, label) => `${label}: in ${metric(groupMetric(group, ["input_tokens_known", "input_tokens", "total_input_tokens_known"]))} (unknown ${metric(groupMetric(group, ["input_tokens_unknown_events", "input_unknown_events"]))}) · out ${metric(groupMetric(group, ["output_tokens_known", "output_tokens", "total_output_tokens_known"]))} (unknown ${metric(groupMetric(group, ["output_tokens_unknown_events", "output_unknown_events"]))}) · cost ${costMetric(groupMetric(group, ["reported_cost_usd_known", "billed_cost_usd", "cost_usd"]))} (unknown ${metric(groupMetric(group, ["reported_cost_usd_unknown_events", "unknown_cost_events", "cost_unknown_events"]))})`;
  const decisionsLabel = (decisions) => {
    const entries = Object.entries(objectValue(decisions)).filter(([, value]) => value != null);
    return entries.length ? entries.map(([key, value]) => `${key.replaceAll("_", " ")} ${metric(value)}`).join(" · ") : "Unknown";
  };

  function renderSummary() {
    const summary = state.summary || {};
    const aggregate = objectValue(summary.aggregate || summary.totals);
    const client = objectValue(aggregate.client || aggregate.client_totals || summary.client);
    const optimizer = objectValue(aggregate.optimizer || aggregate.optimizer_totals || summary.optimizer);
    const scopeHeading = document.querySelector("#optimizer-view-overview .optimizer-panel-wide .optimizer-panel-head h2");
    if (scopeHeading) scopeHeading.textContent = "What is counted · all projects";
    const cards = [
      ["Tasks", summary.tasks_count ?? (Array.isArray(summary.tasks) ? summary.tasks.length : null), "Recorded task identities"],
      ["Client events", groupMetric(client, ["events", "event_count"]), "Events attributed to the client model"],
      ["Optimizer events", groupMetric(optimizer, ["events", "event_count", "decisions"]), "Optimizer decisions and overhead"],
      ["Measured savings", firstValue(summary, ["measured_savings", "savings"]) ?? firstValue(aggregate, ["measured_savings", "savings"]), "Comparison evidence required"],
    ];
    $("optimizer-summary-cards").replaceChildren(...cards.map(([label, value, note]) => el("div", { class: "optimizer-card" }, el("span", { class: "optimizer-card-label", text: label }), el("strong", { class: "optimizer-card-value", text: metric(value) }), el("span", { class: "optimizer-card-note", text: note }))));
    const accounting = [
      ["Client input tokens", groupMetric(client, ["input_tokens_known", "input_tokens", "total_input_tokens_known"])],
      ["Client output tokens", groupMetric(client, ["output_tokens_known", "output_tokens", "total_output_tokens_known"])],
      ["Optimizer input tokens", groupMetric(optimizer, ["input_tokens_known", "input_tokens", "total_input_tokens_known"])],
      ["Optimizer output tokens", groupMetric(optimizer, ["output_tokens_known", "output_tokens", "total_output_tokens_known"])],
      ["Client billed cost", groupMetric(client, ["reported_cost_usd_known", "billed_cost_usd", "cost_usd"]), true],
      ["Optimizer billed cost", groupMetric(optimizer, ["reported_cost_usd_known", "billed_cost_usd", "cost_usd"]), true],
      ["Client unknown cost events", unknownCount(client, ["reported_cost_usd_unknown_events", "unknown_cost_events", "cost_unknown_events"])],
      ["Optimizer unknown cost events", unknownCount(optimizer, ["reported_cost_usd_unknown_events", "unknown_cost_events", "cost_unknown_events"])],
      ["Exact cache hits", firstValue(aggregate, ["exact_cache_hits", "cache_hits"]) ?? groupMetric(optimizer, ["exact_cache_hits", "cache_hits"])],
      ["Decision status", decisionsLabel(aggregate.decisions_by_status || summary.decisions_by_status)],
    ];
    const rows = accounting.map(([label, value, isCost]) => el("div", { class: "optimizer-accounting-row" }, el("span", { class: "optimizer-accounting-label", text: label }), el("strong", { class: "optimizer-accounting-value", text: isCost ? costMetric(value) : typeof value === "string" ? value : metric(value) })));
    const diagnostics = el("div", { class: "optimizer-diagnostics-actions" }, el("span", { class: "optimizer-row-meta", text: "Diagnostics contain counts and storage health, never entry content." }), el("button", { type: "button", class: "btn btn-row", text: "Export diagnostics", on: { click: exportDiagnostics } }));
    $("optimizer-accounting").replaceChildren(...rows, diagnostics);
    const activities = Array.isArray(summary.tasks) ? summary.tasks : Array.isArray(summary.activity) ? summary.activity : [];
    renderActivity(activities);
  }

  function renderActivity(items) {
    const box = $("optimizer-activity");
    if (!items.length) {
      box.replaceChildren(el("p", { class: "optimizer-list-empty", text: "No task activity has been recorded yet." }));
      return;
    }
    box.replaceChildren(...items.slice(0, 12).map((item) => {
      const title = item.title || item.name || item.task_id || "Task";
      const statusText = item.status || item.outcome || "Recorded";
      const aggregate = objectValue(item.aggregate || item.usage);
      const client = objectValue(aggregate.client || aggregate.client_totals);
      const optimizer = objectValue(aggregate.optimizer || aggregate.optimizer_totals);
      const clientUnknown = unknownCount(client, ["reported_cost_usd_unknown_events", "unknown_cost_events", "cost_unknown_events"]);
      const optimizerUnknown = unknownCount(optimizer, ["reported_cost_usd_unknown_events", "unknown_cost_events", "cost_unknown_events"]);
      const coverage = `${groupLabel(client, "Client")} · ${groupLabel(optimizer, "Optimizer")} · unknown cost events ${metric((clientUnknown == null && optimizerUnknown == null) ? null : Number(clientUnknown || 0) + Number(optimizerUnknown || 0))}`;
      return el("div", { class: "optimizer-row" }, el("div", { class: "optimizer-row-main" }, el("span", { class: "optimizer-row-title", text: title }), el("span", { class: "optimizer-row-meta", text: `${statusText} · ${date(item.started_at || item.created_at)}` }), el("span", { class: "optimizer-row-meta optimizer-task-metrics", text: coverage })), el("span", { class: "optimizer-row-meta", text: `events ${metric(firstValue(aggregate, ["events", "event_count"]))}` }));
    }));
  }

  function renderProjects() {
    const boxes = [$("optimizer-projects"), $("optimizer-project-preview")];
    for (const box of boxes) {
      if (!box) continue;
      if (!state.projects.length) {
        box.replaceChildren(el("p", { class: "optimizer-list-empty", text: "No projects yet. Create one to configure optimizer behavior." }));
        continue;
      }
      box.replaceChildren(...state.projects.map((project) => projectRow(project)));
    }
    const select = $("optimizer-entry-project");
    if (select) {
      const current = state.selectedProjectId;
      select.replaceChildren(...state.projects.map((project) => el("option", { value: projectId(project), text: text(project.name, projectId(project)) })));
      if (current && state.projects.some((project) => projectId(project) === current)) select.value = current;
      else if (state.projects[0]) { state.selectedProjectId = projectId(state.projects[0]); select.value = state.selectedProjectId; }
    }
  }

  function projectRow(project) {
    const id = projectId(project);
    const mode = String(project.mode || "off").toLowerCase();
    const enabled = mode !== "off";
    return el("div", { class: "optimizer-row", "data-project-id": id },
      el("div", { class: "optimizer-row-main" }, el("span", { class: "optimizer-row-title", text: text(project.name, id) }), el("span", { class: "optimizer-row-meta" }, el("span", { text: text(project.root) }), el("span", { text: `ID ${id}` }), el("span", { class: "optimizer-mode", "data-mode": mode, text: mode }))),
      el("div", { class: "optimizer-row-actions" },
        el("button", { type: "button", class: "btn btn-row", text: "Entries", on: { click: () => selectProject(id) } }),
        enabled ? el("button", { type: "button", class: "btn btn-row", text: "Disable", on: { click: () => disableProject(project) } }) : null,
        el("button", { type: "button", class: "btn btn-row", text: "Edit", on: { click: () => openProjectDialog(project) } }),
        el("button", { type: "button", class: "btn btn-row optimizer-danger", text: "Delete", on: { click: () => deleteProject(project) } }),
      ),
    );
  }

  function renderCapabilities() {
    const box = $("optimizer-capabilities");
    const entries = Object.entries(state.capabilities || {});
    if (!entries.length) {
      box.replaceChildren(el("p", { class: "optimizer-list-empty", text: "Capability information is pending from the local adapter." }));
      return;
    }
    box.replaceChildren(...entries.map(([name, value]) => {
      const raw = typeof value === "string" ? value.trim().toLowerCase() : "";
      const object = value && typeof value === "object" && !Array.isArray(value) ? value : { available: Boolean(value) };
      const advisory = ["suggestions", "suggestion", "suggestions only", "advisory"].includes(raw);
      const available = advisory || object.available === true || object.enabled === true || object.supported === true;
      const note = advisory ? "Suggestions only" : available ? text(object.note, "Available") : text(object.reason, "Unavailable");
      return el("div", { class: "optimizer-capability", "data-available": available ? "true" : "false" }, el("span", { class: "optimizer-capability-dot", "aria-hidden": "true" }), el("div", {}, el("span", { class: "optimizer-capability-name", text: name.replaceAll("_", " ") }), el("span", { class: "optimizer-capability-note", text: note })));
    }));
  }

  async function exportDiagnostics() {
    try {
      const data = await rpc("diagnostics", {});
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const anchor = el("a", { href: url, download: `keys-optimizer-diagnostics-${new Date().toISOString().slice(0, 10)}.json` });
      document.body.append(anchor); anchor.click(); anchor.remove(); URL.revokeObjectURL(url);
      setAlert("Diagnostics exported.");
    } catch (error) { if (!handleAuthError(error)) setAlert(error.message || "Diagnostics could not be exported.", true); }
  }

  async function loadSummary() {
    state.summary = await rpc("summary");
    if (state.summary && state.summary.pending_live === false) $("optimizer-live-badge").hidden = true;
    else $("optimizer-live-badge").hidden = false;
    renderSummary();
  }

  async function loadProjects() {
    const data = await rpc("summary");
    state.summary = data;
    state.projects = Array.isArray(data.projects) ? data.projects : [];
    if (!state.selectedProjectId || !state.projects.some((project) => projectId(project) === state.selectedProjectId)) state.selectedProjectId = state.projects[0] ? projectId(state.projects[0]) : null;
    renderSummary();
    renderProjects();
  }

  async function loadEntries() {
    const box = $("optimizer-entries");
    const project = selectedProject();
    if (!project) {
      box.replaceChildren(el("p", { class: "optimizer-list-empty", text: "Create a project before saving an entry." }));
      $("optimizer-entry-detail").replaceChildren(el("div", { class: "optimizer-detail-empty" }, el("h2", { text: "No project selected" }), el("p", { text: "Memory and plans belong to a project." })));
      return;
    }
    state.entryLoading = true;
    box.replaceChildren(el("p", { class: "optimizer-list-empty", text: "Loading entries…" }));
    try {
      const data = await rpc("entry_list", { project_id: projectId(project), query: state.query.trim() || undefined, include_archived: state.includeArchived });
      state.entries = Array.isArray(data.entries) ? data.entries : [];
      if (state.selectedEntryId && !state.selectedCandidate && !state.entries.some((entry) => (entry.id || entry.entry_id) === state.selectedEntryId)) state.selectedEntryId = null;
      if (!state.selectedCandidate) state.selectedEntryData = null;
      renderEntries();
      renderEntryDetail();
    } catch (error) {
      if (error.stale) return;
      if (!handleAuthError(error)) box.replaceChildren(el("p", { class: "optimizer-list-empty", text: "Could not load entries." }));
    } finally { state.entryLoading = false; }
  }

  async function loadCandidates() {
    const box = $("optimizer-candidates");
    const project = selectedProject();
    const generation = ++state.candidateLoadGeneration;
    const requestedProjectId = projectId(project);
    const requestedReviewState = state.candidateReviewState;
    if (!project) {
      state.candidates = [];
      box.replaceChildren(el("p", { class: "optimizer-list-empty", text: "Create a project before reviewing candidates." }));
      return;
    }
    box.replaceChildren(el("p", { class: "optimizer-list-empty", text: "Loading candidates…" }));
    try {
      const data = await rpc("candidate_list", { project_id: requestedProjectId, review_state: requestedReviewState });
      if (generation !== state.candidateLoadGeneration || projectId(selectedProject()) !== requestedProjectId || state.candidateReviewState !== requestedReviewState) return;
      state.candidates = Array.isArray(data.candidates) ? data.candidates : [];
      renderCandidates();
    } catch (error) {
      if (error.stale || generation !== state.candidateLoadGeneration || projectId(selectedProject()) !== requestedProjectId || state.candidateReviewState !== requestedReviewState) return;
      if (!handleAuthError(error)) box.replaceChildren(el("p", { class: "optimizer-list-empty", text: "Candidate review is unavailable." }));
    }
  }

  function renderCandidates() {
    const box = $("optimizer-candidates");
    if (!state.candidates.length) {
      box.replaceChildren(el("p", { class: "optimizer-list-empty", text: `No ${state.candidateReviewState} candidates.` }));
      return;
    }
    box.replaceChildren(...state.candidates.map((candidate) => {
      const id = candidate.id || candidate.entry_id;
      return el("button", { type: "button", class: "optimizer-row optimizer-entry-row optimizer-candidate-row", "data-candidate-id": id, on: { click: () => {
        state.selectedEntryId = id;
        state.selectedEntryData = null;
        state.selectedCandidate = true;
        renderEntryDetail();
      } } },
      el("span", { class: "optimizer-entry-kind optimizer-review-state", text: text(candidate.review_state, state.candidateReviewState) }),
      el("span", { class: "optimizer-row-main" }, el("span", { class: "optimizer-row-title", text: text(candidate.title, "Untitled candidate") }), el("span", { class: "optimizer-row-meta", text: `Version ${text(candidate.version)} · captured ${date(candidate.created_at || candidate.updated_at)}` })));
    }));
  }

  async function loadData() {
    if (!state.unlocked) return;
    try {
      await loadProjects();
      await loadCandidates();
      await loadEntries();
      renderCapabilities();
    } catch (error) {
      if (error.stale) return;
      if (!handleAuthError(error)) setAlert(error.message || "Could not load optimizer data.", true);
    }
  }

  function renderEntries() {
    const box = $("optimizer-entries");
    if (!state.entries.length) {
      box.replaceChildren(el("p", { class: "optimizer-list-empty", text: state.includeArchived ? "No entries match this search." : "No active entries yet." }));
      return;
    }
    box.replaceChildren(...state.entries.map((entry) => {
      const id = entry.id || entry.entry_id;
      const archived = Boolean(entry.archived);
      const tags = Array.isArray(entry.tags) ? entry.tags.join(", ") : "";
      return el("div", { class: "optimizer-row optimizer-entry-row", role: "button", tabindex: "0", "aria-selected": id === state.selectedEntryId ? "true" : "false" },
        el("span", { class: "optimizer-entry-kind", text: kindLabel(entry.kind) }),
        el("div", { class: "optimizer-row-main" }, el("span", { class: "optimizer-row-title", text: text(entry.title, "Untitled entry") }), el("span", { class: "optimizer-row-meta", text: `${archived ? "Archived" : "Active"}${tags ? ` · ${tags}` : ""} · updated ${date(entry.updated_at || entry.created_at)}` })),
        entry.pinned ? el("span", { class: "optimizer-row-meta", text: "Pinned" }) : null,
      );
    }));
    // Rebuild listeners separately to keep all dynamic strings text-only.
    [...box.children].forEach((row, index) => {
      const entry = state.entries[index];
      const choose = () => { state.selectedEntryId = entry.id || entry.entry_id; state.selectedEntryData = null; state.selectedCandidate = false; renderEntries(); renderEntryDetail(); };
      row.addEventListener("click", choose);
      row.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); choose(); } });
    });
  }

  function renderEntryDetail() {
    const box = $("optimizer-entry-detail");
    const entry = selectedEntry();
    if (!entry) {
      box.replaceChildren(el("div", { class: "optimizer-detail-empty" }, el("h2", { text: "Select an entry" }), el("p", { text: "Choose a memory or plan to inspect provenance, constraints, dependencies, and verification evidence." })));
      return;
    }
    const id = entry.id || entry.entry_id;
    if (!String(id).startsWith("new-") && (!state.selectedEntryData || (state.selectedEntryData.id || state.selectedEntryData.entry_id) !== id)) {
      box.replaceChildren(el("div", { class: "optimizer-detail-empty" }, el("h2", { text: "Loading entry…" }), el("p", { text: "The entry body is retrieved only inside the unlocked session." })));
      loadEntryDetail(id);
      return;
    }
    const form = state.selectedCandidate ? candidateDetail(entry) : entryForm(entry);
    box.replaceChildren(form);
  }

  async function loadEntryDetail(id) {
    if (state.loadingEntryId === id || !state.unlocked) return;
    state.loadingEntryId = id;
    try {
      const data = await rpc("entry_get", { project_id: projectId(selectedProject()), id });
      const entry = data.entry || data;
      if (state.selectedEntryId === id && state.unlocked) {
        state.selectedEntryData = entry;
        renderEntryDetail();
      }
    } catch (error) {
      if (error.stale) return;
      if (!handleAuthError(error)) setAlert(error.message || "Entry detail could not be loaded.", true);
    } finally { state.loadingEntryId = null; }
  }

  function candidateDetail(entry) {
    const id = entry.id || entry.entry_id;
    const reviewState = text(entry.review_state, state.candidateReviewState);
    const box = el("section", { class: "optimizer-candidate-detail" },
      el("h2", { text: text(entry.title, "Untitled candidate") }),
      el("p", { class: "optimizer-row-meta", text: `${kindLabel(entry.kind)} · ${reviewState} · version ${text(entry.version)}` }),
      el("div", { class: "optimizer-candidate-body", text: text(entry.content, "No candidate content.") }),
      el("p", { class: "optimizer-row-meta", text: `Source: ${text(entry.source, "Not recorded")} · captured from task: ${text(entry.captured_from_task_id, "Unknown")}` }),
      el("p", { class: "optimizer-row-meta", text: `Verification: ${Array.isArray(entry.verification) && entry.verification.length ? entry.verification.join(" · ") : "No verification evidence recorded"}` }),
    );
    const metadata = el("dl", { class: "optimizer-candidate-metadata" });
    const list = (values) => Array.isArray(values) && values.length ? values.join("\n") : "None recorded";
    for (const [label, value] of [
      ["Constraints", list(entry.constraints)],
      ["Required tools", list(entry.required_tools)],
      ["Dependencies", Object.entries(objectValue(entry.dependencies)).map(([path, fingerprint]) => `${path}: ${fingerprint}`).join("\n") || "None recorded"],
      ["Tags", list(entry.tags)],
      ["Expires", date(entry.expires_at)],
    ]) metadata.append(el("dt", { text: label }), el("dd", { text: value }));
    box.append(metadata);
    if (reviewState === "pending") {
      const actions = el("div", { class: "optimizer-form-actions-right" });
      for (const decision of ["reject", "approve"]) {
        actions.append(el("button", { type: "button", class: decision === "approve" ? "btn btn-primary" : "btn btn-row optimizer-danger", text: decision === "approve" ? "Approve for reuse" : "Reject", on: { click: () => reviewCandidate(entry, decision) } }));
      }
      box.append(el("div", { class: "optimizer-form-actions" }, el("span", { class: "optimizer-row-meta", text: "Approval changes review state only; it does not execute or unlock anything." }), actions));
    }
    return box;
  }

  async function reviewCandidate(entry, decision) {
    const project = selectedProject();
    const id = entry.id || entry.entry_id;
    try {
      await rpc("candidate_review", { project_id: projectId(project), id, decision, expected_version: entry.version });
      state.selectedEntryId = null;
      state.selectedEntryData = null;
      state.selectedCandidate = false;
      setAlert(decision === "approve" ? "Candidate approved for reuse." : "Candidate rejected.");
      await loadCandidates();
      await loadEntries();
    } catch (error) {
      if (error.stale) return;
      if (error.status === 409) {
        setAlert("This candidate changed while it was open. The review list has been refreshed.", true);
        await loadCandidates();
        return;
      }
      if (!handleAuthError(error)) setAlert(error.message || "Candidate review could not be saved.", true);
    }
  }

  function inputField(label, name, value, options = {}) {
    const control = options.textarea ? el("textarea", { name, rows: options.rows || "3" }) : el("input", { name, type: options.type || "text", value: value == null ? "" : value, placeholder: options.placeholder });
    if (options.textarea) control.value = value == null ? "" : value;
    const wrapper = el("label", {}, label, control);
    return wrapper;
  }

  function entryForm(entry) {
    const id = entry.id || entry.entry_id;
    const dependencies = entry.dependencies && typeof entry.dependencies === "object" ? JSON.stringify(entry.dependencies, null, 2) : text(entry.dependencies, "");
    const form = el("form", { class: "optimizer-form", novalidate: "" });
    form.append(el("h2", { text: `${kindLabel(entry.kind)} · ${text(entry.title, "Untitled entry")}` }));
    const grid = el("div", { class: "optimizer-form-grid" });
    const kind = el("select", { name: "kind" }, el("option", { value: "memory", text: "Memory" }), el("option", { value: "plan", text: "Plan" })); kind.value = entry.kind === "plan" ? "plan" : "memory";
    const kindLabelNode = el("label", {}, "Type", kind);
    grid.append(kindLabelNode, inputField("Title", "title", entry.title));
    grid.append(inputField("Source", "source", entry.source, { placeholder: "task, file, or user" }), inputField("Tags", "tags", Array.isArray(entry.tags) ? entry.tags.join(", ") : entry.tags));
    grid.append(inputField("Expires", "expires_at", dateInputValue(entry.expires_at), { type: "date" }), inputField("Required tools", "required_tools", Array.isArray(entry.required_tools) ? entry.required_tools.join(", ") : entry.required_tools));
    grid.append(inputField("Content", "content", entry.content, { textarea: true, rows: "6" }));
    grid.lastChild.classList.add("optimizer-form-grid-wide");
    grid.append(inputField("Constraints", "constraints", Array.isArray(entry.constraints) ? entry.constraints.join("\n") : entry.constraints, { textarea: true }), inputField("Verification steps", "verification", Array.isArray(entry.verification) ? entry.verification.join("\n") : entry.verification, { textarea: true }));
    const dependencyField = inputField("Dependencies (JSON)", "dependencies", dependencies, { textarea: true });
    const dependencyPaths = inputField("Fingerprint project files", "dependency_paths", Object.keys(entry.dependencies || {}).join("\n"), { textarea: true, rows: "2" });
    const fingerprint = el("button", { type: "button", class: "btn btn-row", text: "Fingerprint files", on: { click: async () => {
      const project = selectedProject();
      const paths = String(form.elements.dependency_paths.value || "").split("\n").map((value) => value.trim()).filter(Boolean);
      if (!paths.length) { setAlert("Add one or more project-relative paths first.", true); return; }
      try {
        const data = await rpc("dependency_fingerprints", { project_id: projectId(project), paths });
        form.elements.dependencies.value = JSON.stringify(data.dependencies || {}, null, 2);
        setAlert("Dependency fingerprints updated.");
      } catch (error) { if (!handleAuthError(error)) setAlert(error.message || "Dependency fingerprints could not be loaded.", true); }
    } } });
    const dependencyWrap = el("div", { class: "optimizer-dependency-wrap" }, dependencyPaths, fingerprint);
    grid.append(dependencyField, el("fieldset", {}, el("legend", { text: "Status" }), el("label", { class: "optimizer-check" }, el("input", { type: "checkbox", name: "pinned", checked: entry.pinned ? "checked" : null }), " Pin this entry")));
    grid.append(dependencyWrap);
    grid.lastChild.classList.add("optimizer-form-grid-wide");
    form.append(grid, el("p", { class: "optimizer-form-help", text: "Content is sent only through the unlocked local optimizer session. Keep secrets and credentials out of stored entries. Project retention permanently deletes entries after the configured number of days since their last update, including pinned entries." }));
    const actionRight = el("div", { class: "optimizer-form-actions-right" });
    actionRight.append(el("button", { type: "button", class: "btn btn-row optimizer-danger", text: entry.archived ? "Restore" : "Archive", on: { click: () => archiveEntry(entry, !entry.archived) } }));
    actionRight.append(el("button", { type: "button", class: "btn btn-row optimizer-danger", text: "Delete", on: { click: () => deleteEntry(entry) } }));
    actionRight.append(el("button", { type: "button", class: "btn btn-row", text: "Export", on: { click: () => exportEntry(entry) } }));
    actionRight.append(el("button", { type: "submit", class: "btn btn-primary", text: "Save" }));
    form.append(el("div", { class: "optimizer-form-actions" }, el("span", { class: "optimizer-row-meta", text: `Updated ${date(entry.updated_at || entry.created_at)}` }), actionRight));
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const data = new FormData(form);
      let dependenciesValue = {};
      try { dependenciesValue = data.get("dependencies") ? JSON.parse(String(data.get("dependencies"))) : {}; } catch { setAlert("Dependencies must be valid JSON.", true); return; }
      const project = selectedProject();
      try {
        const persistentId = String(id).startsWith("new-") ? undefined : id;
        const expiry = data.get("expires_at");
        // entry_save replaces the entry; omitted source/expiry also clear prior values.
        await rpc("entry_save", { project_id: projectId(project), id: persistentId, kind: data.get("kind"), title: data.get("title"), content: data.get("content"), tags: String(data.get("tags") || "").split(",").map((value) => value.trim()).filter(Boolean), source: String(data.get("source") || "").trim() || undefined, constraints: String(data.get("constraints") || "").split("\n").map((value) => value.trim()).filter(Boolean), required_tools: String(data.get("required_tools") || "").split(",").map((value) => value.trim()).filter(Boolean), dependencies: dependenciesValue, verification: String(data.get("verification") || "").split("\n").map((value) => value.trim()).filter(Boolean), expires_at: expiry ? `${expiry}T00:00:00Z` : undefined, pinned: data.get("pinned") === "on" });
        setAlert("Entry saved.");
        await loadEntries();
      } catch (error) { if (!handleAuthError(error)) setAlert(error.message || "Entry could not be saved.", true); }
    });
    return form;
  }

  function selectProject(id) {
    state.selectedProjectId = id;
    state.selectedEntryId = null;
    state.selectedEntryData = null;
    state.selectedCandidate = false;
    state.candidates = [];
    state.candidateLoadGeneration += 1;
    switchView("library");
    renderProjects();
    renderCandidates();
    renderEntryDetail();
    loadCandidates();
    loadEntries();
  }

  function projectDialog() {
    let dialog = $("optimizer-project-dialog");
    if (dialog) return dialog;
    dialog = el("dialog", { id: "optimizer-project-dialog", class: "dlg optimizer-dialog" });
    document.body.append(dialog);
    return dialog;
  }

  function openProjectDialog(project = null) {
    const dialog = projectDialog();
    const form = el("form", { class: "optimizer-form", novalidate: "" });
    form.append(el("h2", { text: project ? "Edit project" : "New project" }), el("p", { class: "optimizer-form-help", text: "These controls apply only to the selected project root." }));
    const grid = el("div", { class: "optimizer-form-grid" });
    grid.append(inputField("Name", "name", project && project.name, { placeholder: "my-project" }), inputField("Root", "root", project && project.root, { placeholder: "/Users/me/src/project" }));
    const mode = el("select", { name: "mode" }, el("option", { value: "off", text: "Off" }), el("option", { value: "observe", text: "Observe" }), el("option", { value: "suggest", text: "Suggest" }), el("option", { value: "auto", text: "Auto · pending validation", disabled: "disabled" })); mode.value = project && project.mode ? project.mode : "off";
    grid.append(el("label", {}, "Mode", mode));
    const retention = inputField("Retention (days)", "retention_days", project && project.retention_days, { type: "number", placeholder: "30" });
    retention.append(el("span", { class: "optimizer-retention-help", text: "Permanently deletes entries after this many days since their last update, including pinned entries. Default: 30 days." }));
    grid.append(retention, inputField("Max optimizer requests", "max_requests", project && project.max_requests, { type: "number", placeholder: "1000" }), inputField("Max input tokens", "max_input_tokens", project && project.max_input_tokens, { type: "number", placeholder: "1000000" }));
    grid.lastChild.classList.add("optimizer-form-grid-wide");
    form.append(grid);
    const existingFlags = project && (project.feature_flags || project.featureFlags) || {};
    const featureFieldset = el("fieldset", {}, el("legend", { text: "Features" }), el("div", { class: "optimizer-inline-checks optimizer-feature-checks" }));
    const featureBox = featureFieldset.lastChild;
    for (const name of FEATURE_FLAGS) {
      const checkbox = el("input", { type: "checkbox", name: `feature_${name}` });
      checkbox.checked = name === "candidate_capture" ? existingFlags[name] === true : existingFlags[name] !== false;
      featureBox.append(el("label", {}, checkbox, ` ${name.replaceAll("_", " ")}`));
    }
    form.append(featureFieldset);
    const options = el("fieldset", {}, el("legend", { text: "Privacy and provider" }), el("div", { class: "optimizer-inline-checks" }));
    const optionRow = options.lastChild;
    const storage = el("input", { type: "checkbox", name: "storage_enabled" }); storage.checked = project ? project.storage_enabled !== false : false;
    const provider = el("input", { type: "checkbox", name: "provider_enabled" }); provider.checked = project ? project.provider_enabled === true : false;
    optionRow.append(el("label", {}, storage, " Store task content"), el("label", {}, provider, " Allow provider evaluation"));
    form.append(options, el("p", { class: "optimizer-form-help", text: "Provider evaluation is separate from local storage. Auto mode remains unavailable until validation passes." }));
    const actions = el("div", { class: "actions" }, el("button", { type: "button", class: "btn", text: "Cancel", on: { click: () => dialog.close() } }), el("button", { type: "submit", class: "btn btn-primary", text: project ? "Save changes" : "Create project" }));
    form.append(actions);
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const data = new FormData(form);
      const feature_flags = Object.fromEntries(FEATURE_FLAGS.map((name) => [name, form.elements[`feature_${name}`].checked]));
      const payload = { id: projectId(project) || undefined, name: data.get("name"), root: data.get("root"), mode: data.get("mode"), storage_enabled: storage.checked, provider_enabled: provider.checked, feature_flags, retention_days: numberOrNull(data.get("retention_days")) ?? 30, max_requests: numberOrNull(data.get("max_requests")) ?? 1000, max_input_tokens: numberOrNull(data.get("max_input_tokens")) ?? 1000000 };
      try { await rpc("project_save", payload); dialog.close(); setAlert("Project saved."); await loadProjects(); if (state.selectedProjectId) await loadEntries(); } catch (error) { if (!handleAuthError(error)) setAlert(error.message || "Project could not be saved.", true); }
    });
    dialog.replaceChildren(form);
    dialog.showModal();
  }

  const numberOrNull = (value) => value == null || value === "" ? null : Number(value);

  async function disableProject(project) {
    if (!window.confirm(`Disable optimization for ${text(project.name, "this project")} ?`)) return;
    try { await rpc("project_save", { id: projectId(project), name: project.name, root: project.root, mode: "off", storage_enabled: project.storage_enabled !== false, provider_enabled: project.provider_enabled === true, feature_flags: project.feature_flags || project.featureFlags || {}, retention_days: project.retention_days ?? 30, max_requests: project.max_requests ?? 1000, max_input_tokens: project.max_input_tokens ?? 1000000 }); setAlert("Project disabled."); await loadProjects(); } catch (error) { if (!handleAuthError(error)) setAlert(error.message || "Project could not be disabled.", true); }
  }

  async function deleteProject(project) {
    const name = text(project.name, projectId(project));
    if (!window.confirm(`Delete ${name} and its stored entries permanently?`)) return;
    try {
      await rpc("project_delete", { project_id: projectId(project) });
      if (state.selectedProjectId === projectId(project)) {
        state.selectedProjectId = null;
        state.selectedEntryId = null;
        state.selectedEntryData = null;
        state.selectedCandidate = false;
        state.candidates = [];
        state.candidateLoadGeneration += 1;
      }
      setAlert("Project deleted.");
      await loadProjects();
      await loadCandidates();
      await loadEntries();
    } catch (error) { if (!handleAuthError(error)) setAlert(error.message || "Project could not be deleted.", true); }
  }

  async function archiveEntry(entry, archived) {
    try { await rpc("entry_archive", { project_id: projectId(selectedProject()), id: entry.id || entry.entry_id, archived }); setAlert(archived ? "Entry archived." : "Entry restored."); await loadEntries(); } catch (error) { if (!handleAuthError(error)) setAlert(error.message || "Entry status could not be changed.", true); }
  }

  async function deleteEntry(entry) {
    if (!window.confirm(`Delete ${text(entry.title, "this entry")} permanently?`)) return;
    try { await rpc("entry_delete", { project_id: projectId(selectedProject()), id: entry.id || entry.entry_id }); state.selectedEntryId = null; setAlert("Entry deleted."); await loadEntries(); } catch (error) { if (!handleAuthError(error)) setAlert(error.message || "Entry could not be deleted.", true); }
  }

  async function exportEntry(entry) {
    if (!window.confirm("Export this entry and its provenance as JSON?")) return;
    try {
      const data = await rpc("entry_export", { project_id: projectId(selectedProject()), id: entry.id || entry.entry_id });
      const exported = data.entry || data.export || (Array.isArray(data.entries) ? data.entries.find((item) => (item.id || item.entry_id) === (entry.id || entry.entry_id)) || data.entries[0] : data);
      const blob = new Blob([JSON.stringify(exported || {}, null, 2)], { type: "application/json;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const anchor = el("a", { href: url, download: text(data.filename, `${text(entry.title, "entry")}.json`) });
      document.body.append(anchor); anchor.click(); anchor.remove(); URL.revokeObjectURL(url);
      setAlert("Entry exported.");
    } catch (error) { if (!handleAuthError(error)) setAlert(error.message || "Entry could not be exported.", true); }
  }

  function newEntry() {
    const project = selectedProject();
    if (!project) { setAlert("Create a project before saving an entry.", true); switchView("projects"); return; }
    const fresh = { id: `new-${Date.now()}`, kind: "memory", title: "", content: "", tags: [], source: "", constraints: [], required_tools: [], dependencies: {}, verification: [], pinned: false };
    state.entries = [fresh, ...state.entries]; state.selectedEntryId = fresh.id; state.selectedEntryData = null; state.selectedCandidate = false; switchView("library", { skipLoad: true }); renderEntries(); renderEntryDetail();
  }

  function switchView(view, options = {}) {
    state.view = view;
    document.querySelectorAll("[data-optimizer-view]").forEach((tab) => { const selected = tab.getAttribute("data-optimizer-view") === view; tab.setAttribute("aria-selected", selected ? "true" : "false"); tab.tabIndex = selected ? 0 : -1; });
    document.querySelectorAll(".optimizer-view").forEach((panel) => { panel.hidden = panel.id !== `optimizer-view-${view}`; });
    if (view === "library" && state.unlocked && !state.entryLoading && !options.skipLoad) loadEntries();
  }

  function wire() {
    $("optimizer-unlock").addEventListener("click", unlock);
    $("optimizer-lock").addEventListener("click", lock);
    document.querySelectorAll("[data-optimizer-view]").forEach((tab) => tab.addEventListener("click", () => switchView(tab.getAttribute("data-optimizer-view"))));
    document.querySelectorAll('[data-action="new-project"]').forEach((button) => button.addEventListener("click", () => openProjectDialog()));
    document.querySelectorAll('[data-action="new-entry"]').forEach((button) => button.addEventListener("click", newEntry));
    $("optimizer-entry-project").addEventListener("change", (event) => { state.selectedProjectId = event.target.value; state.selectedEntryId = null; state.selectedEntryData = null; state.selectedCandidate = false; state.candidates = []; state.candidateLoadGeneration += 1; renderCandidates(); renderEntryDetail(); loadCandidates(); loadEntries(); });
    $("optimizer-candidate-state").addEventListener("change", (event) => { state.candidateReviewState = event.target.value; state.selectedEntryId = null; state.selectedEntryData = null; state.selectedCandidate = false; loadCandidates(); renderEntryDetail(); });
    $("optimizer-candidate-refresh").addEventListener("click", loadCandidates);
    $("optimizer-entry-query").addEventListener("input", (event) => { state.query = event.target.value; loadEntries(); });
    $("optimizer-include-archived").addEventListener("change", (event) => { state.includeArchived = event.target.checked; loadEntries(); });
    window.addEventListener("focus", checkFocusedStatus);
    document.addEventListener("visibilitychange", () => { if (!document.hidden && state.unlocked) renderSessionStatus(); });
  }

  window.optimizerLoad = async function optimizerLoad() {
    if (state.loading) return;
    state.loading = true;
    try {
      await status();
      if (state.unlocked) await loadData();
    } finally { state.loading = false; }
  };

  wire();
  loadOptimizerKeys();
  status();
})();
