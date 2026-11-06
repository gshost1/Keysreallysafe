// PostHog for keysrs.com (the website only; the Mac app sends nothing unless its own
// opt-in is on). Until a visitor says yes in the banner it stays cookieless: no cookie
// or localStorage identity, a visit counted per page load, no recording. After yes it
// remembers the visitor in a first-party cookie and localStorage, records the session
// with every bit of text and input masked, and adds web vitals and dead/rage clicks.
// The choice itself is the one thing kept before consent, so the banner asks once.
// The project key is a public client token. Kept in a file so the CSP needs no
// 'unsafe-inline' script.
!function(t,e){var o,n,p,r;e.__SV||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host.replace(".i.posthog.com","-assets.i.posthog.com")+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],u.toString=function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e},u.people.toString=function(){return u.toString(1)+".people (stub)"},o="init capture register register_once register_for_session unregister unregister_for_session getFeatureFlag getFeatureFlagPayload isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSurveysLoaded onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey canRenderSurveyAsync identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty createPersonProfile opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing debug getPageViewId captureTraceFeedback captureTraceMetric".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);

// Our own visits (keysrs.com/?internal=1, set by site.js) never reach PostHog.
(function () {
  try { if (localStorage.getItem("keysrs-internal") === "1") return; } catch (e) {}

  var CONSENT_KEY = "keysrs-analytics-consent";
  function readConsent() { try { return localStorage.getItem(CONSENT_KEY); } catch (e) { return null; } }
  function writeConsent(v) { try { if (v) localStorage.setItem(CONSENT_KEY, v); else localStorage.removeItem(CONSENT_KEY); } catch (e) {} }

  var FULL = {
    persistence: "localStorage+cookie",
    person_profiles: "always",
    disable_session_recording: false,
    session_recording: {
      maskAllInputs: true,
      maskTextSelector: "*",
      // The notify form sends the visitor's address in a fetch body while this
      // recording runs, and privacy.html promises it never reaches PostHog and
      // lists no network payloads. An explicit false here wins over the project's
      // remote body/header setting, and the mask drops /api/notify from the replay
      // and strips any body or header a future recorder still hands it.
      recordBody: false,
      recordHeaders: false,
      maskCapturedNetworkRequestFn: function (r) {
        if (!r || String(r.name || "").indexOf("/api/") !== -1) return null;
        delete r.requestBody; delete r.responseBody;
        delete r.requestHeaders; delete r.responseHeaders;
        return r;
      }
    },
    // The project has console logs and network timings on; privacy.html promises
    // neither, so the site turns them off here rather than relying on that setting.
    enable_recording_console_log: false,
    capture_performance: { web_vitals: true, network_timing: false },
    capture_dead_clicks: true,
    rageclick: true
  };
  var COOKIELESS = {
    persistence: "memory",
    person_profiles: "identified_only",
    disable_session_recording: true,
    capture_performance: false,
    capture_dead_clicks: false,
    rageclick: false
  };

  var config = {
    api_host: "https://us.i.posthog.com",
    autocapture: false,
    disable_surveys: true,
    capture_pageview: true,
    capture_pageleave: true
  };
  var base = readConsent() === "yes" ? FULL : COOKIELESS;
  for (var k in base) config[k] = base[k];
  posthog.init("phc_sjUPiZsiJoN6asBQyAXsnteDMAgnsqi6FjqLXj49FvCb", config);

  function accept() {
    writeConsent("yes");
    posthog.set_config(FULL);
    posthog.startSessionRecording();
  }
  function decline() {
    var had = readConsent() === "yes";
    writeConsent("no");
    if (had) { posthog.reset(); posthog.set_config(COOKIELESS); posthog.stopSessionRecording(); }
  }

  function banner() {
    if (document.getElementById("consent")) return;
    var box = document.createElement("div");
    box.id = "consent";
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-label", "Analytics on this website");
    var p = document.createElement("p");
    p.appendChild(document.createTextNode("Can this website remember you and record your visit, with all text masked? It helps us see what's confusing. Say no and we only count page loads. "));
    var a = document.createElement("a");
    a.href = "/privacy#website"; a.textContent = "Details";
    p.appendChild(a);
    var row = document.createElement("div");
    function button(label, primary, fn) {
      var b = document.createElement("button");
      b.type = "button"; b.textContent = label; if (primary) b.className = "primary";
      b.addEventListener("click", function () { fn(); box.remove(); });
      row.appendChild(b);
    }
    button("No thanks", false, decline);
    button("OK", true, accept);
    box.appendChild(p); box.appendChild(row);
    document.body.appendChild(box);
  }

  function ready(fn) { if (document.readyState !== "loading") fn(); else document.addEventListener("DOMContentLoaded", fn); }
  ready(function () {
    if (!readConsent()) banner();
    // the privacy page offers to change the answer
    document.querySelectorAll("[data-consent-reset]").forEach(function (el) {
      el.addEventListener("click", function (e) { e.preventDefault(); banner(); });
    });
  });

  // A link we post elsewhere carries ?ref=<label> so clicks can be told apart
  // by channel. Only a short lowercase label is kept; anything else is dropped.
  var ref = (new URLSearchParams(location.search).get("ref") || "").toLowerCase();
  if (!/^[a-z0-9_-]{1,32}$/.test(ref)) ref = "";
  // The few clicks the site counts, each with the platform site.js worked out
  // (mac, windows, linux, ios, android, other). Named events only: autocapture
  // stays off, as privacy.html says.
  function track(name, extra) {
    var p = { platform: document.documentElement.getAttribute("data-platform") || "other" };
    if (ref) p.ref = ref;
    for (var k in extra) p[k] = extra[k];
    posthog.capture(name, p);
  }
  // Copying an install command: brew_copy as before for brew, and install_copy
  // for either, naming only which of the two ("brew" or "curl").
  // Only the two install rows count: the agent plugin rows below them are
  // not installs, and privacy.html lists no event for them.
  var installIds = { "brew-cmd": "brew", "curl-cmd": "curl" };
  function trackCopy(id, via) {
    var method = installIds[id]; if (!method) return;
    if (method === "brew") track("brew_copy", { via: via });
    track("install_copy", { method: method, via: via });
  }
  document.addEventListener("click", function (e) {
    var cp = e.target.closest("[data-copy]");
    if (cp) return trackCopy(cp.getAttribute("data-copy"), "button");
    var a = e.target.closest("a[href]"); if (!a) return;
    var h = a.getAttribute("href") || "";
    var named = a.getAttribute("data-event");
    if (named) track(named);
    else if (/Keysrs-arm64\.dmg$/.test(h)) track("dmg_download");
    else if (h.indexOf("https://github.com/gshost1/") === 0) track(a.classList.contains("star") ? "star_click" : "github_click");
  });
  // site.js fires this after the Worker stored an address; the address
  // itself never reaches PostHog.
  document.addEventListener("keysrs:notify", function () { track("notify_submit"); });
  // Selecting the command and pressing ⌘C counts as much as the button.
  document.addEventListener("copy", function (e) {
    var n = getSelection().anchorNode;
    var code = n && (n.nodeType === 1 ? n : n.parentElement).closest(".irow code");
    if (code) trackCopy(code.id, "select");
  });
})();
