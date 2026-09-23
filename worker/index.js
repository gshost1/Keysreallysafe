// keysrs.com: static site plus the two endpoints that turn a Stripe purchase into
// a license key. Keys are Ed25519 signatures the Mac app verifies offline
// (Sources/KeysCore/License.swift is the other half of this format). Ed25519 is
// deterministic, so a buyer who reloads the page gets the same key again.
//
// A key activates on at most SEATS Macs. Activation returns a short-lived token
// signed with the same Ed25519 key ("keysrsa1.", so it can never pass as a
// license key); the app checks in every CHECKIN_DAYS and stops after GRACE_DAYS
// more without one, which is how a revoked or leaked key stops working.
//
// Secrets (wrangler secret put): STRIPE_SECRET_KEY (restricted: Checkout
// Sessions read), STRIPE_WEBHOOK_SECRET, LICENSE_SIGNING_SEED (base64 32-byte
// Ed25519 seed). Bindings: ASSETS (the site), EMAIL (Cloudflare Email Sending),
// DB (D1 keysrs-licenses: activations, revoked), LICENSE_LIMIT (rate limit).

const PREFIX = "keysrs1";
const ACTIVATION_PREFIX = "keysrsa1";
const PUBLIC_KEY = "JBXZvujkBlQx/ckElnqn4/ove5ZT95thR6OkLZaNscw=";
const MAJOR = 1;
export const SEATS = 2;
const CHECKIN_DAYS = 30;
const GRACE_DAYS = 14;
const FROM = { email: "support@keysrs.com", name: "Keysrs" };
const SITE_ORIGINS = ["https://keysrs.com", "https://www.keysrs.com"];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/license") return licensePage(request, env, url);
    if (url.pathname === "/api/stripe/webhook") return stripeWebhook(request, env);
    if (url.pathname === "/api/license/activate") return activateRoute(request, env);
    if (url.pathname === "/api/license/deactivate") return deactivateRoute(request, env);
    if (url.pathname === "/api/license/release") return releaseRoute(request, env);
    if (url.pathname.startsWith("/api/")) return json(404, { error: "not_found" });
    return env.ASSETS.fetch(request);
  },
};

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}

async function rateLimited(request, env) {
  if (!env.LICENSE_LIMIT) return false;
  const { success } = await env.LICENSE_LIMIT.limit({ key: request.headers.get("cf-connecting-ip") || "unknown" });
  return !success;
}

// --- key signing -----------------------------------------------------------

function b64url(bytes) {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64decode(text) {
  const bin = atob(text);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64urlDecode(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]*$/.test(text)) return null;
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  try { return b64decode(padded); } catch { return null; }
}

async function signingKey(env) {
  const seed = b64decode(env.LICENSE_SIGNING_SEED);
  if (seed.length !== 32) throw new Error("LICENSE_SIGNING_SEED must be a 32-byte seed");
  // PKCS#8 wrapper for an Ed25519 seed (RFC 8410).
  const header = b64decode("MC4CAQAwBQYDK2VwBCIEIA==");
  const pkcs8 = new Uint8Array(header.length + 32);
  pkcs8.set(header); pkcs8.set(seed, header.length);
  return crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, false, ["sign"]);
}

// The payload is JSON with sorted keys, matching Swift's .sortedKeys encoder.
async function issueKey(env, { id, email, iat }) {
  const payload = JSON.stringify({ email, iat, id, major: MAJOR, v: 1 });
  const payloadPart = b64url(new TextEncoder().encode(payload));
  const key = await signingKey(env);
  const sig = await crypto.subtle.sign({ name: "Ed25519" }, key, new TextEncoder().encode(`${PREFIX}.${payloadPart}`));
  return `${PREFIX}.${payloadPart}.${b64url(sig)}`;
}

async function signToken(env, prefix, object) {
  const sorted = Object.fromEntries(Object.keys(object).sort().map((k) => [k, object[k]]));
  const payloadPart = b64url(new TextEncoder().encode(JSON.stringify(sorted)));
  const sig = await crypto.subtle.sign({ name: "Ed25519" }, await signingKey(env), new TextEncoder().encode(`${prefix}.${payloadPart}`));
  return `${prefix}.${payloadPart}.${b64url(sig)}`;
}

// The Worker checks keys against the same public key the app embeds.
async function verifyLicenseKey(raw) {
  if (typeof raw !== "string") return null;
  const key = raw.trim();
  const parts = key.split(".");
  if (key.length > 2048 || parts.length !== 3 || parts[0] !== PREFIX) return null;
  const payloadBytes = b64urlDecode(parts[1]), sig = b64urlDecode(parts[2]);
  if (!payloadBytes || !sig || sig.length !== 64) return null;
  const pub = await crypto.subtle.importKey("raw", b64decode(PUBLIC_KEY), { name: "Ed25519" }, false, ["verify"]);
  if (!(await crypto.subtle.verify({ name: "Ed25519" }, pub, sig, new TextEncoder().encode(`${PREFIX}.${parts[1]}`)))) return null;
  let payload;
  try { payload = JSON.parse(new TextDecoder().decode(payloadBytes)); } catch { return null; }
  if (!payload || payload.v !== 1 || payload.major !== MAJOR || typeof payload.id !== "string" || !payload.id || payload.id.length > 128) return null;
  return payload;
}

// --- activation --------------------------------------------------------------

const INSTALL_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MODEL = /^[A-Za-z0-9,._ -]{0,32}$/;

async function readJSON(request) {
  if (request.method !== "POST") return { error: json(405, { error: "method" }) };
  const text = await request.text();
  if (text.length > 4096) return { error: json(413, { error: "too_large" }) };
  try {
    const body = JSON.parse(text);
    return body && typeof body === "object" ? { body } : { error: json(400, { error: "bad_json" }) };
  } catch { return { error: json(400, { error: "bad_json" }) }; }
}

async function macsFor(env, licenseId) {
  const { results } = await env.DB.prepare(
    "SELECT install_id, model, created_at, last_seen FROM activations WHERE license_id = ? ORDER BY created_at"
  ).bind(licenseId).all();
  return results || [];
}

async function isRevoked(env, licenseId) {
  return !!(await env.DB.prepare("SELECT 1 AS r FROM revoked WHERE license_id = ?").bind(licenseId).first());
}

// First activation and every 30-day check-in are the same call: a Mac already
// on the list is refreshed, a new one takes a free seat or is refused.
async function activateRoute(request, env) {
  if (await rateLimited(request, env)) return json(429, { error: "rate_limited" });
  const { body, error } = await readJSON(request);
  if (error) return error;
  const license = await verifyLicenseKey(body.key);
  if (!license) return json(400, { error: "invalid_license" });
  const installId = body.install_id, model = typeof body.model === "string" ? body.model : "";
  if (typeof installId !== "string" || !INSTALL_ID.test(installId) || !MODEL.test(model)) return json(400, { error: "bad_request" });
  if (await isRevoked(env, license.id)) return json(403, { error: "revoked" });
  const now = Math.floor(Date.now() / 1000);
  const refreshed = await env.DB.prepare(
    "UPDATE activations SET last_seen = ?, model = ? WHERE license_id = ? AND install_id = ?"
  ).bind(now, model, license.id, installId).run();
  if (!refreshed.meta.changes) {
    // The seat count and the insert are one statement, so two Macs activating
    // at once cannot both take the last seat.
    const inserted = await env.DB.prepare(
      "INSERT INTO activations (license_id, install_id, model, created_at, last_seen) " +
      "SELECT ?1, ?2, ?3, ?4, ?4 WHERE (SELECT COUNT(*) FROM activations WHERE license_id = ?1) < ?5"
    ).bind(license.id, installId, model, now, SEATS).run();
    if (!inserted.meta.changes) {
      const macs = await macsFor(env, license.id);
      return json(409, { error: "seat_limit", seats: SEATS, macs: macs.map(({ model, created_at, last_seen }) => ({ model, created_at, last_seen })) });
    }
  }
  const activation = await signToken(env, ACTIVATION_PREFIX, {
    v: 1, lid: license.id, iid: installId, iat: now,
    due: now + CHECKIN_DAYS * 86400, exp: now + (CHECKIN_DAYS + GRACE_DAYS) * 86400,
  });
  return json(200, { activation, seats: SEATS });
}

// The app frees its own seat when the key is removed on that Mac.
async function deactivateRoute(request, env) {
  if (await rateLimited(request, env)) return json(429, { error: "rate_limited" });
  const { body, error } = await readJSON(request);
  if (error) return error;
  const license = await verifyLicenseKey(body.key);
  if (!license || typeof body.install_id !== "string" || !INSTALL_ID.test(body.install_id)) return json(400, { error: "bad_request" });
  await env.DB.prepare("DELETE FROM activations WHERE license_id = ? AND install_id = ?").bind(license.id, body.install_id).run();
  return json(200, { ok: true });
}

// The buyer frees a seat for a Mac they no longer have, from the license page.
// The checkout session id is the same bearer that shows the key on that page.
async function releaseRoute(request, env) {
  if (!SITE_ORIGINS.includes(request.headers.get("origin") || "")) return json(403, { error: "forbidden" });
  if (await rateLimited(request, env)) return json(429, { error: "rate_limited" });
  const { body, error } = await readJSON(request);
  if (error) return error;
  if (typeof body.install_id !== "string" || !INSTALL_ID.test(body.install_id)) return json(400, { error: "bad_request" });
  let session;
  try { session = await checkoutSession(env, body.session_id); } catch { return json(503, { error: "unavailable" }); }
  const license = paidLicenseFrom(session);
  if (!license) return json(404, { error: "not_found" });
  await env.DB.prepare("DELETE FROM activations WHERE license_id = ? AND install_id = ?").bind(license.id, body.install_id).run();
  return json(200, { ok: true });
}

// --- Stripe ----------------------------------------------------------------

// null means "no such session"; a Stripe or configuration failure throws, so the
// webhook answers 500 and Stripe retries instead of the email being lost.
async function checkoutSession(env, id) {
  if (typeof id !== "string" || !/^cs_(live|test)_[A-Za-z0-9]+$/.test(id)) return null;
  if (!env.STRIPE_SECRET_KEY) throw new Error("STRIPE_SECRET_KEY is not set");
  const res = await fetch(`https://api.stripe.com/v1/checkout/sessions/${id}`, {
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` },
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Stripe checkout session lookup failed: ${res.status}`);
  return res.json();
}

async function sessionForPaymentIntent(env, paymentIntent) {
  if (typeof paymentIntent !== "string" || !/^pi_[A-Za-z0-9]+$/.test(paymentIntent)) return null;
  if (!env.STRIPE_SECRET_KEY) throw new Error("STRIPE_SECRET_KEY is not set");
  const res = await fetch(`https://api.stripe.com/v1/checkout/sessions?payment_intent=${paymentIntent}&limit=1`, {
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` },
  });
  if (!res.ok) throw new Error(`Stripe checkout session search failed: ${res.status}`);
  const list = await res.json();
  return (list.data && list.data[0] && list.data[0].id) || null;
}

function paidLicenseFrom(session) {
  if (!session || session.payment_status !== "paid" || session.status !== "complete") return null;
  const email = session.customer_details && session.customer_details.email;
  if (!email) return null;
  return { id: session.id, email, iat: session.created };
}

async function stripeWebhook(request, env) {
  if (request.method !== "POST") return new Response("method", { status: 405 });
  const body = await request.text();
  if (!(await verifyStripeSignature(body, request.headers.get("stripe-signature"), env.STRIPE_WEBHOOK_SECRET))) {
    return new Response("bad signature", { status: 400 });
  }
  const event = JSON.parse(body);
  // A full refund or a dispute revokes the license: it activates nowhere new and
  // stops on each Mac at its next check-in.
  if (event.type === "charge.refunded" || event.type === "charge.dispute.created") {
    const object = event.data.object;
    if (event.type === "charge.refunded" && !object.refunded) return new Response("partial refund", { status: 200 });
    const sessionId = await sessionForPaymentIntent(env, object.payment_intent);
    if (!sessionId) return new Response("no checkout", { status: 200 });
    const reason = event.type === "charge.refunded" ? "refunded" : "disputed";
    await env.DB.prepare("INSERT OR IGNORE INTO revoked (license_id, reason, revoked_at) VALUES (?, ?, ?)")
      .bind(sessionId, reason, Math.floor(Date.now() / 1000)).run();
    return new Response("revoked", { status: 200 });
  }
  // Card payments are paid at "completed"; delayed methods (bank debits) arrive
  // unpaid there and paid later in "async_payment_succeeded". Either one mails the key.
  if (event.type !== "checkout.session.completed" && event.type !== "checkout.session.async_payment_succeeded") {
    return new Response("ignored", { status: 200 });
  }
  // Trust the webhook only as a trigger: re-read the session from Stripe.
  const session = await checkoutSession(env, event.data.object.id);
  const license = paidLicenseFrom(session);
  if (!license) return new Response("not paid", { status: 200 });
  const key = await issueKey(env, license);
  await sendLicenseEmail(env, license, key);
  return new Response("sent", { status: 200 });
}

async function verifyStripeSignature(body, header, secret) {
  if (!header || !secret) return false;
  // Stripe sends one v1 per active secret (several while a secret is being rolled).
  let t = null;
  const signatures = [];
  for (const part of header.split(",")) {
    const eq = part.indexOf("=");
    const name = part.slice(0, eq).trim(), value = part.slice(eq + 1).trim();
    if (name === "t") t = value;
    else if (name === "v1") signatures.push(value);
  }
  if (!t || signatures.length === 0 || !(Math.abs(Date.now() / 1000 - Number(t)) <= 300)) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${body}`));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  let match = false;
  for (const v1 of signatures) {
    if (v1.length !== hex.length) continue;
    let diff = 0;
    for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ v1.charCodeAt(i);
    match = match || diff === 0;
  }
  return match;
}

// --- email -----------------------------------------------------------------

async function sendLicenseEmail(env, license, key) {
  if (!env.EMAIL) return;
  const text = `Thanks for buying Keysrs.

Your license key (one line, paste it whole):

${key}

Enter it in Keysrs: open the dashboard from the menu bar item and paste the key into the license box, or run:

  keys license set '${key}'

It covers Keysrs ${MAJOR}.x on up to ${SEATS} Macs. Keep this email; the key can also be fetched again at https://keysrs.com/license?session_id=${license.id}

Refund within 14 days, no questions: reply to this email.
`;
  await env.EMAIL.send({
    to: license.email,
    from: FROM,
    replyTo: FROM.email,
    subject: "Your Keysrs license key",
    text,
    html: `<p>Thanks for buying Keysrs.</p><p>Your license key (one line, paste it whole):</p><pre style="white-space:pre-wrap;word-break:break-all;background:#f4f5f7;padding:12px;border-radius:8px">${escapeHTML(key)}</pre><p>Enter it in Keysrs: open the dashboard from the menu bar item and paste the key into the license box, or run <code>keys license set '${escapeHTML(key)}'</code>.</p><p>It covers Keysrs ${MAJOR}.x on up to ${SEATS} Macs. Keep this email; the key can also be fetched again at <a href="https://keysrs.com/license?session_id=${escapeHTML(license.id)}">keysrs.com/license</a>.</p><p>Refund within 14 days, no questions: reply to this email.</p>`,
  });
}

// --- the page after checkout ----------------------------------------------

async function licensePage(request, env, url) {
  // Each view is a Stripe API call, so a client gets a few a minute; a buyer reloading
  // after checkout never gets near it.
  if (await rateLimited(request, env)) {
    return new Response("Too many requests. Wait a minute and reload.", { status: 429, headers: { "retry-after": "60", "cache-control": "no-store" } });
  }
  const id = url.searchParams.get("session_id") || "";
  let session = null;
  try {
    session = await checkoutSession(env, id);
  } catch {
    return new Response("The license service is briefly unavailable. Reload in a minute; your key is also on its way by email.", { status: 503, headers: { "retry-after": "60", "cache-control": "no-store" } });
  }
  const license = paidLicenseFrom(session);
  const key = license ? await issueKey(env, license) : null;
  const macs = license ? await macsFor(env, license.id) : [];
  const revoked = license ? await isRevoked(env, license.id) : false;
  const day = (t) => new Date(t * 1000).toISOString().slice(0, 10);
  const macRows = macs.length
    ? `<ul class="macs">${macs.map((m) => `<li><span>${escapeHTML(m.model || "Mac")} · activated ${day(m.created_at)} · last seen ${day(m.last_seen)}</span> <button type="button" class="release" data-install="${escapeHTML(m.install_id)}">Remove</button></li>`).join("")}</ul>`
    : `<p class="sub">Not active on any Mac yet.</p>`;
  const body = key
    ? `<h1>Thanks. Here is your Keysrs license.</h1>
<p class="sub">It was also emailed to <strong>${escapeHTML(license.email)}</strong>. Paste the whole line into Keysrs.</p>
<pre id="key">${escapeHTML(key)}</pre>
<p><button id="copy" type="button">Copy key</button></p>
<h2>Enter it</h2>
<ol>
<li>Open Keysrs from the menu bar (or <a href="http://127.0.0.1:12766/">127.0.0.1:12766</a>).</li>
<li>Paste the key into the license box at the top and press <strong>Activate</strong>.</li>
</ol>
<p class="sub">Or in a terminal: <code>keys license set '${escapeHTML(key)}'</code></p>
<h2>Your Macs (${macs.length} of ${SEATS})</h2>
${revoked ? `<p class="sub">This license has been revoked (refunded, disputed or shared publicly) and no longer activates.</p>` : ""}
${macRows}
<p class="sub">A license covers Keysrs ${MAJOR}.x on up to ${SEATS} Macs. Remove a Mac you no longer use to free its place. Bookmark this page; it shows the same key again. Refund within 14 days: <a href="mailto:support@keysrs.com">support@keysrs.com</a>.</p>`
    : `<h1>No license here yet.</h1>
<p class="sub">This page shows a license once a checkout is paid. If you just paid, wait a few seconds and reload. If you reached this page another way, buy at <a href="/#pricing">keysrs.com</a> or write to <a href="mailto:support@keysrs.com">support@keysrs.com</a> with your receipt.</p>`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Your Keysrs license</title><meta name="robots" content="noindex"><link rel="stylesheet" href="/styles.css"><style>
main.lic{max-width:720px;margin:0 auto;padding:56px 24px 96px}main.lic h1{font-size:34px;margin-bottom:8px}main.lic h2{font-size:20px;margin:28px 0 8px}main.lic .sub{color:var(--ink-2)}main.lic pre{white-space:pre-wrap;word-break:break-all;background:var(--paper-2);border:1px solid var(--line);border-radius:10px;padding:14px 16px;font-size:13px;user-select:all}main.lic button{font:inherit;font-weight:600;padding:10px 18px;border-radius:999px;border:1px solid var(--brass);background:var(--brass);color:#fff;cursor:pointer}main.lic ol{color:var(--ink-2)}main.lic ul.macs{list-style:none;padding:0}main.lic ul.macs li{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:10px 0;border-bottom:1px solid var(--line)}main.lic button.release{background:transparent;color:var(--ink);border-color:var(--line);padding:6px 14px}
</style></head><body><header class="top"><div class="wrap"><a class="brand" href="/"><svg viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="8" fill="#b8781e"/><circle cx="12" cy="16" r="5.5" fill="none" stroke="#fff" stroke-width="3"/><path d="M17 16h9m-3 0v4m-3-4v3" stroke="#fff" stroke-width="3" stroke-linecap="round"/></svg>Keysrs</a></div></header><main class="lic">${body}</main>
<script>var b=document.getElementById("copy"),k=document.getElementById("key");if(b&&k)b.addEventListener("click",function(){navigator.clipboard.writeText(k.textContent).then(function(){b.textContent="Copied"},function(){var r=document.createRange();r.selectNodeContents(k);var s=getSelection();s.removeAllRanges();s.addRange(r)})});
document.querySelectorAll("button.release").forEach(function(btn){btn.addEventListener("click",function(){if(btn.dataset.armed!=="1"){btn.dataset.armed="1";btn.textContent="Confirm remove";return}btn.disabled=true;fetch("/api/license/release",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({session_id:new URLSearchParams(location.search).get("session_id"),install_id:btn.dataset.install})}).then(function(r){if(r.ok)location.reload();else{btn.textContent="Could not remove";btn.disabled=false}})})});</script></body></html>`;
  return new Response(html, {
    status: key ? 200 : 404,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer" },
  });
}

function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
