// keysrs.com's only Worker code: the "notify me when Linux or Windows lands"
// form. Every other path is a static asset; wrangler.jsonc sends only /api/*
// here. An address is kept only to send that one announcement (privacy.html).

const ORIGINS = new Set(["https://keysrs.com", "https://www.keysrs.com"]);
const PLATFORMS = new Set(["windows", "linux", "android", "ios", "mac", "other"]);
const MAX_BODY = 1024;

function reply(status, body, extra = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      ...extra,
    },
  });
}

// Deliberately plain: a mailbox, an @, a dotted domain, no spaces or the
// characters that would let an address smuggle a header or markup later.
export function validEmail(s) {
  if (typeof s !== "string") return false;
  if (s.length < 6 || s.length > 254) return false;
  const at = s.lastIndexOf("@");
  if (at < 1 || at > 64) return false;
  return /^[^\s@<>()[\]\\,;:"']+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/i.test(s);
}

async function notify(request, env) {
  if (request.method !== "POST") return reply(405, { error: "method not allowed" }, { allow: "POST" });
  // CSRF: only our own pages may post, and only as JSON, which a cross-site
  // form cannot send and a cross-site fetch cannot send without a preflight
  // this Worker never answers.
  if (!ORIGINS.has(request.headers.get("origin") || "")) return reply(403, { error: "forbidden" });
  if (!(request.headers.get("content-type") || "").toLowerCase().startsWith("application/json")) {
    return reply(415, { error: "send JSON" });
  }
  // The IP is only the rate-limit key; it is never stored.
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const { success } = await env.NOTIFY_LIMIT.limit({ key: `notify:${ip}` });
  if (!success) return reply(429, { error: "too many tries, please wait a minute" }, { "retry-after": "60" });

  const text = await request.text();
  if (text.length > MAX_BODY) return reply(413, { error: "too large" });
  let body;
  try { body = JSON.parse(text); } catch { return reply(400, { error: "please check the address" }); }
  if (!body || typeof body !== "object") return reply(400, { error: "please check the address" });
  // A hidden field people never see; a bot that fills it gets the same
  // answer as everyone, and nothing is stored.
  if (body.website) return reply(200, { ok: true });
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!validEmail(email)) return reply(400, { error: "please check the address" });
  const platform = PLATFORMS.has(body.platform) ? body.platform : "other";

  // One row per address, so a second sign-up only refreshes it and the
  // answer never tells anyone whether an address was already on the list.
  // The day, not the time: enough to delete rows by age.
  const day = new Date().toISOString().slice(0, 10);
  await env.NOTIFY.put(`email:${email}`, JSON.stringify({ platform, day }));
  return reply(200, { ok: true });
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    try {
      if (pathname === "/api/notify") return await notify(request, env);
    } catch {
      return reply(500, { error: "something went wrong, please try again later" });
    }
    return reply(404, { error: "not found" });
  },
};
