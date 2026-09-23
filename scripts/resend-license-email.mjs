#!/usr/bin/env node
// Re-send the license email for a paid checkout (a buyer lost it, or the webhook
// was down). Posts a signed checkout.session.completed to the site's webhook; the
// Worker trusts it only as a trigger and re-reads the session from Stripe, so
// this cannot mint a key for an unpaid session. The signing secret comes from
// the environment, e.g. through the vault:
//   keys env stripe-keysrs-webhook STRIPE_WEBHOOK_SECRET -- node scripts/resend-license-email.mjs cs_live_…
import { createHmac } from "node:crypto";

const id = process.argv[2] || "";
const secret = process.env.STRIPE_WEBHOOK_SECRET || "";
if (!/^cs_(live|test)_[A-Za-z0-9]+$/.test(id)) { console.error("usage: resend-license-email.mjs <checkout session id>"); process.exit(2); }
if (!secret.startsWith("whsec_")) { console.error("STRIPE_WEBHOOK_SECRET is not set"); process.exit(2); }
const body = JSON.stringify({ type: "checkout.session.completed", data: { object: { id } } });
const t = Math.floor(Date.now() / 1000);
const v1 = createHmac("sha256", secret).update(`${t}.${body}`).digest("hex");
const res = await fetch("https://keysrs.com/api/stripe/webhook", {
  method: "POST",
  headers: { "content-type": "application/json", "stripe-signature": `t=${t},v1=${v1}` },
  body,
});
console.log(`${res.status} ${await res.text()}`);
process.exit(res.ok ? 0 : 1);
