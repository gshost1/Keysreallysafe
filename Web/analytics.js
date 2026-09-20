/* Local product-analytics preference UI. This file only calls Keys' loopback API. */
(() => {
  "use strict";

  const CONSENT_VERSION = 1;
  const EVENTS = new Set(["view_usage", "view_chart", "view_keys", "view_optimizer"]);
  const TOKEN = (document.querySelector('meta[name="ksf-token"]') || {}).content || "";
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
    const canChange = state.configured === true || state.enabled === true;
    checkbox.disabled = !canChange;
    save.disabled = !canChange;
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
      && typeof value.configured === "boolean"
      && (value.endpoint === null || typeof value.endpoint === "string")
      && value.consent_version === CONSENT_VERSION
      && Number.isInteger(value.pending_events) && value.pending_events >= 0
      && ["never", "sent", "failed", "disabled"].includes(value.last_result)
      && (value.preview === null || (typeof value.preview === "object" && !Array.isArray(value.preview)));
  }

  function render(next) {
    state = next;
    preview = next.preview && typeof next.preview === "object" && !Array.isArray(next.preview) ? next.preview : null;
    checkbox.checked = next.enabled === true;
    const configured = next.configured === true;
    const endpoint = typeof next.endpoint === "string" && next.endpoint ? next.endpoint : null;
    text("analytics-destination", configured && endpoint
      ? `Reports are sent to: ${endpoint}`
      : "No analytics destination is configured. Product analytics cannot be enabled until one is configured.");
    text("analytics-pending", String(Number.isInteger(next.pending_events) && next.pending_events >= 0 ? next.pending_events : 0));
    text("analytics-last-result", describeResult(next.last_result));
    text("analytics-preview", preview === null ? "No unsent reports available." : JSON.stringify(preview, null, 2));
    discard.hidden = next.enabled !== true && Number(next.pending_events || 0) === 0;
    text("analytics-state", next.enabled === true
      ? (configured ? "Enabled. Reports send automatically when ready." : "Enabled, waiting for an analytics destination.")
      : "Off. No new product analytics reports will be sent.");
  }

  async function request(path, options = {}) {
    const response = await fetch(path, {
      credentials: "same-origin",
      headers: options.body ? { "Content-Type": "application/json", "X-KSF-Token": TOKEN } : undefined,
      ...options,
    });
    if (!response.ok) throw new Error(`Request failed (${response.status})`);
    return response;
  }

  async function refresh() {
    const requestGeneration = ++generation;
    try {
      const response = await request("/api/analytics");
      const next = await response.json();
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
    if (enabled && state.configured !== true) {
      error("Product analytics needs a configured destination before it can be enabled.");
      checkbox.checked = false;
      return;
    }
    const requestGeneration = ++generation;
    busy(true);
    error();
    try {
      const response = await request("/api/analytics", {
        method: "POST",
        body: JSON.stringify({ enabled, consent_version: CONSENT_VERSION }),
      });
      const next = await response.json();
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
    link.download = "keys-pending-analytics-report.json";
    link.click();
    URL.revokeObjectURL(link.href);
  });

  window.KeysAnalytics = {
    refresh,
    event(name) {
      if (!EVENTS.has(name)) return;
      void request("/api/analytics/event", { method: "POST", body: JSON.stringify({ event: name }) }).catch(() => {});
    },
  };
})();
