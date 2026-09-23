// keysrs.com: static site plus the two endpoints that turn a Stripe purchase into
// a license key. Keys are Ed25519 signatures the Mac app verifies offline
// (Sources/KeysCore/License.swift is the other half of this format). Ed25519 is
// deterministic, so a buyer who reloads the page gets the same key again.
//
// Secrets (wrangler secret put): STRIPE_SECRET_KEY (restricted: Checkout
// Sessions read), STRIPE_WEBHOOK_SECRET, LICENSE_SIGNING_SEED (base64 32-byte
// Ed25519 seed). Bindings: ASSETS (the site), EMAIL (Cloudflare Email Sending).

const PREFIX = "keysrs1";
const MAJOR = 1;
const FROM = { email: "support@keysrs.com", name: "Keysrs" };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/license") return licensePage(request, env, url);
    if (url.pathname === "/api/stripe/webhook") return stripeWebhook(request, env);
    return env.ASSETS.fetch(request);
  },
};

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

It covers Keysrs ${MAJOR}.x on every Mac you use. Keep this email; the key can also be fetched again at https://keysrs.com/license?session_id=${license.id}

Refund within 14 days, no questions: reply to this email.
`;
  await env.EMAIL.send({
    to: license.email,
    from: FROM,
    replyTo: FROM.email,
    subject: "Your Keysrs license key",
    text,
    html: `<p>Thanks for buying Keysrs.</p><p>Your license key (one line, paste it whole):</p><pre style="white-space:pre-wrap;word-break:break-all;background:#f4f5f7;padding:12px;border-radius:8px">${escapeHTML(key)}</pre><p>Enter it in Keysrs: open the dashboard from the menu bar item and paste the key into the license box, or run <code>keys license set '${escapeHTML(key)}'</code>.</p><p>It covers Keysrs ${MAJOR}.x on every Mac you use. Keep this email; the key can also be fetched again at <a href="https://keysrs.com/license?session_id=${escapeHTML(license.id)}">keysrs.com/license</a>.</p><p>Refund within 14 days, no questions: reply to this email.</p>`,
  });
}

// --- the page after checkout ----------------------------------------------

async function licensePage(request, env, url) {
  // Each view is a Stripe API call, so a client gets a few a minute; a buyer reloading
  // after checkout never gets near it.
  if (env.LICENSE_LIMIT) {
    const { success } = await env.LICENSE_LIMIT.limit({ key: request.headers.get("cf-connecting-ip") || "unknown" });
    if (!success) return new Response("Too many requests. Wait a minute and reload.", { status: 429, headers: { "retry-after": "60", "cache-control": "no-store" } });
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
<p class="sub">Covers Keysrs ${MAJOR}.x on every Mac you use. Bookmark this page; it shows the same key again. Refund within 14 days: <a href="mailto:support@keysrs.com">support@keysrs.com</a>.</p>`
    : `<h1>No license here yet.</h1>
<p class="sub">This page shows a license once a checkout is paid. If you just paid, wait a few seconds and reload. If you reached this page another way, buy at <a href="/#pricing">keysrs.com</a> or write to <a href="mailto:support@keysrs.com">support@keysrs.com</a> with your receipt.</p>`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Your Keysrs license</title><meta name="robots" content="noindex"><link rel="stylesheet" href="/styles.css"><style>
main.lic{max-width:720px;margin:0 auto;padding:56px 24px 96px}main.lic h1{font-size:34px;margin-bottom:8px}main.lic h2{font-size:20px;margin:28px 0 8px}main.lic .sub{color:var(--ink-2)}main.lic pre{white-space:pre-wrap;word-break:break-all;background:var(--paper-2);border:1px solid var(--line);border-radius:10px;padding:14px 16px;font-size:13px;user-select:all}main.lic button{font:inherit;font-weight:600;padding:10px 18px;border-radius:999px;border:1px solid var(--brass);background:var(--brass);color:#fff;cursor:pointer}main.lic ol{color:var(--ink-2)}
</style></head><body><header class="top"><div class="wrap"><a class="brand" href="/"><svg viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="8" fill="#b8781e"/><circle cx="12" cy="16" r="5.5" fill="none" stroke="#fff" stroke-width="3"/><path d="M17 16h9m-3 0v4m-3-4v3" stroke="#fff" stroke-width="3" stroke-linecap="round"/></svg>Keysrs</a></div></header><main class="lic">${body}</main>
<script>var b=document.getElementById("copy"),k=document.getElementById("key");if(b&&k)b.addEventListener("click",function(){navigator.clipboard.writeText(k.textContent).then(function(){b.textContent="Copied"},function(){var r=document.createRange();r.selectNodeContents(k);var s=getSelection();s.removeAllRanges();s.addRange(r)})});</script></body></html>`;
  return new Response(html, {
    status: key ? 200 : 404,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer" },
  });
}

function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
