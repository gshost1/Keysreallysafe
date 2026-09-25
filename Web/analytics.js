/* Local product-analytics preference UI. This file only calls Keys' loopback API. */
(() => {
  "use strict";

  const CONSENT_VERSION = 2;
  const { api, fmtTokens } = window.KeysUI;
  const $ = (id) => document.getElementById(id);
  const dialog = $("dlg-privacy");
  const button = $("btn-privacy");
  const checkbox = $("analytics-enabled");
  const save = $("analytics-save");
  const discard = $("analytics-disable-discard");
  const download = $("analytics-download");
  let state = null;
  let preview = null;
  let generation = 0;

  function text(id, value) { $(id).textContent = value; }
  function error(value = "") { text("analytics-error", value); }
  function busy(value) {
    if (!value) return availability();
    checkbox.disabled = true;
    save.disabled = true;
    discard.disabled = true;
    download.disabled = true;
  }
  function availability() {
    if (!state) {
      checkbox.disabled = true;
      save.disabled = true;
      discard.disabled = true;
      download.disabled = true;
      return;
    }
    checkbox.disabled = false;
    save.disabled = false;
    discard.disabled = state.enabled !== true && Number(state.pending_events || 0) === 0;
    download.disabled = preview === null;
  }
  function unknown(message) {
    state = null;
    text("analytics-state", "Current preference unknown. Reopen Privacy to refresh.");
    error(message);
    availability();
  }

  function describeResult(value) {
    return ({ never: "Never sent", sent: "Sent", failed: "Last send failed", disabled: "Disabled" })[value] || "Unknown";
  }
  function validStatus(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
      && typeof value.enabled === "boolean"
      && typeof value.endpoint === "string"
      && value.consent_version === CONSENT_VERSION
      && Number.isInteger(value.pending_events) && value.pending_events >= 0
      && ["never", "sent", "failed", "disabled"].includes(value.last_result)
      && (value.preview === null || (typeof value.preview === "object" && !Array.isArray(value.preview)))
      && (value.compare === undefined || value.compare === null || (typeof value.compare === "object" && !Array.isArray(value.compare)));
  }

  const TOOLS = { claude_code: "Claude Code", codex: "Codex", grok: "Grok" };
  const WINDOWS = { "5h": "5-hour limit", weekly: "weekly limit", fable: "Fable limit" };
  function standing(percent) {
    if (percent >= 95) return "in the top 5% of shared days";
    if (percent <= 0) return "in the lowest 5% of shared days";
    return `more than ${percent}% of shared days`;
  }
  // Text only (textContent): nothing from the server is ever parsed as HTML.
  function renderCompare(compare) {
    const node = $("usage-compare");
    if (!node) return;
    const rows = compare && Array.isArray(compare.sources) ? compare.sources.filter((row) =>
      row && TOOLS[row.source] && Number.isInteger(row.typical_day_tokens) && Number.isInteger(row.higher_than_percent)) : [];
    if (!rows.length) { node.hidden = true; node.textContent = ""; return; }
    const parts = rows.map((row) => {
      let line = `${TOOLS[row.source]}: your typical day ${fmtTokens(row.typical_day_tokens)} tokens, ${standing(row.higher_than_percent)}`;
      for (const cap of Array.isArray(row.cap_hits) ? row.cap_hits : []) {
        if (WINDOWS[cap.window] && typeof cap.hit_rate === "number" && cap.hit_rate >= 0 && cap.hit_rate <= 1) {
          line += `; sharers hit the ${WINDOWS[cap.window]} on ${Math.round(cap.hit_rate * 100)}% of days`;
        }
      }
      return line;
    });
    const days = Number.isInteger(compare.window_days) ? compare.window_days : 28;
    node.textContent = `Compared with people who share usage (last ${days} days) · ${parts.join(" · ")}`;
    node.title = "Your typical day is the median of your active days in the last week, measured on this Mac. The shared figures come from anonymous daily reports; a figure appears only when at least 50 reports contribute to it.";
    node.hidden = false;
  }
  async function loadCompare() {
    try {
      const next = await api("/api/analytics");
      renderCompare(validStatus(next) && next.enabled === true ? next.compare : null);
    } catch (_) { renderCompare(null); }
  }

  function render(next) {
    state = next;
    preview = next.preview && typeof next.preview === "object" && !Array.isArray(next.preview) ? next.preview : null;
    checkbox.checked = next.enabled === true;
    text("analytics-destination", `Reports are sent to: ${next.endpoint}`);
    text("analytics-pending", String(Number.isInteger(next.pending_events) && next.pending_events >= 0 ? next.pending_events : 0));
    text("analytics-last-result", describeResult(next.last_result));
    text("analytics-preview", preview === null ? "No unsent reports available." : JSON.stringify(preview, null, 2));
    discard.hidden = next.enabled !== true && Number(next.pending_events || 0) === 0;
    text("analytics-state", next.enabled === true
      ? "Enabled. Reports send automatically when ready."
      : "Off. No new product analytics reports will be sent.");
    renderCompare(next.enabled === true ? next.compare : null);
  }

  const post = (path, body) => api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

  async function refresh() {
    const requestGeneration = ++generation;
    try {
      const next = await api("/api/analytics");
      if (!validStatus(next)) throw new Error("Invalid analytics status");
      if (requestGeneration !== generation) return false;
      render(next);
      error();
      return true;
    } catch (_) {
      if (requestGeneration !== generation) return false;
      unknown("Analytics settings are unavailable. Reopen Privacy to try again.");
      return false;
    }
  }

  async function setEnabled(enabled) {
    if (!state) return;
    const requestGeneration = ++generation;
    busy(true);
    error();
    try {
      const next = await post("/api/analytics", { enabled, consent_version: CONSENT_VERSION });
      if (!validStatus(next)) throw new Error("Invalid analytics status");
      if (requestGeneration !== generation) return;
      render(next);
      busy(false);
    } catch (_) {
      if (requestGeneration !== generation) return;
      unknown("Could not confirm the current preference after saving. Reopen Privacy to refresh.");
    }
  }

  button.addEventListener("click", async () => {
    dialog.showModal();
    busy(true);
    if (await refresh()) busy(false);
  });
  dialog.addEventListener("close", () => { generation += 1; });
  dialog.querySelectorAll("[data-close]").forEach((control) => control.addEventListener("click", () => dialog.close()));
  save.addEventListener("click", () => {
    if (!state) return;
    void setEnabled(checkbox.checked);
  });
  discard.addEventListener("click", () => void setEnabled(false));
  download.addEventListener("click", () => {
    if (preview === null) return;
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([JSON.stringify(preview, null, 2) + "\n"], { type: "application/json" }));
    link.download = "keysrs-pending-analytics-report.json";
    link.click();
    URL.revokeObjectURL(link.href);
  });

  document.addEventListener("DOMContentLoaded", () => void loadCompare(), { once: true });
  setInterval(() => void loadCompare(), 30 * 60 * 1000);

  window.KeysAnalytics = {
    refresh,
    // The server keeps the allowlist of page-originated events; anything else gets a 400.
    event(name) { void post("/api/analytics/event", { event: name }).catch(() => {}); },
  };
})();
