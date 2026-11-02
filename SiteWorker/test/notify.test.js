// Offline tests: workerd with a simulated KV namespace and rate limiter. No
// Cloudflare account, no network. Each test posts from its own IP so the
// rate limiter's per-minute window never spills from one test into another.
import { SELF, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { validEmail } from "../src/worker.js";

let n = 0;
const nextIp = () => `203.0.113.${++n}`;

function post(body, { origin = "https://keysrs.com", type = "application/json", ip = nextIp(), method = "POST" } = {}) {
  const headers = { "cf-connecting-ip": ip };
  if (origin) headers.origin = origin;
  if (type) headers["content-type"] = type;
  return SELF.fetch("https://keysrs.com/api/notify", {
    method,
    headers,
    body: method === "GET" ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
}

const stored = async email => {
  const v = await env.NOTIFY.get(`email:${email}`);
  return v && JSON.parse(v);
};

describe("POST /api/notify", () => {
  it("stores a valid address, lowercased, with platform and day only", async () => {
    const res = await post({ email: "  Ada@Example.COM ", platform: "linux" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    expect(res.headers.get("cache-control")).toBe("no-store");
    const row = await stored("ada@example.com");
    expect(row).toEqual({ platform: "linux", day: new Date().toISOString().slice(0, 10) });
    // the IP is a rate-limit key, never part of what is kept
    expect(JSON.stringify(row)).not.toContain("203.0.113");
  });

  it("answers the same for an address already on the list", async () => {
    await post({ email: "twice@example.com", platform: "windows" });
    const res = await post({ email: "twice@example.com", platform: "android" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    expect((await stored("twice@example.com")).platform).toBe("android");
  });

  it("files an unknown platform as other", async () => {
    await post({ email: "plat@example.com", platform: "<script>" });
    expect((await stored("plat@example.com")).platform).toBe("other");
  });

  it("refuses other origins and a missing origin without storing", async () => {
    for (const origin of ["https://evil.example", "http://keysrs.com", "https://keysrs.com.evil.example", null]) {
      const res = await post({ email: "csrf@example.com" }, { origin });
      expect(res.status).toBe(403);
      expect(await res.json()).toEqual({ error: "forbidden" });
    }
    expect(await stored("csrf@example.com")).toBeNull();
  });

  it("accepts www.keysrs.com", async () => {
    const res = await post({ email: "www@example.com" }, { origin: "https://www.keysrs.com" });
    expect(res.status).toBe(200);
  });

  it("refuses a form post (not JSON)", async () => {
    const res = await post("email=form%40example.com", { type: "application/x-www-form-urlencoded" });
    expect(res.status).toBe(415);
    expect(await stored("form@example.com")).toBeNull();
  });

  it("only takes POST", async () => {
    const res = await post(null, { method: "GET" });
    expect(res.status).toBe(405);
    expect(res.headers.get("allow")).toBe("POST");
  });

  it("rejects bad addresses with one generic message", async () => {
    for (const email of ["", "nope", "a@b", "a b@example.com", "x@example", "<a>@example.com", "a@example.com\r\nBcc: z@z.com", 42, null, "x".repeat(250) + "@example.com"]) {
      const res = await post({ email });
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: "please check the address" });
    }
  });

  it("rejects broken JSON and oversized bodies without internals", async () => {
    const bad = await post("{not json");
    expect(bad.status).toBe(400);
    expect(await bad.text()).not.toMatch(/SyntaxError|JSON\.parse|at /);
    const big = await post({ email: "big@example.com", pad: "x".repeat(2000) });
    expect(big.status).toBe(413);
    expect(await stored("big@example.com")).toBeNull();
  });

  it("drops a filled honeypot silently", async () => {
    const res = await post({ email: "bot@example.com", website: "http://spam.example" });
    expect(res.status).toBe(200);
    expect(await stored("bot@example.com")).toBeNull();
  });

  it("rate-limits one IP after five tries a minute", async () => {
    const ip = nextIp();
    const codes = [];
    for (let i = 0; i < 7; i++) codes.push((await post({ email: `rl${i}@example.com` }, { ip })).status);
    expect(codes.slice(0, 5)).toEqual([200, 200, 200, 200, 200]);
    expect(codes.slice(5)).toEqual([429, 429]);
    expect(await stored("rl6@example.com")).toBeNull();
    // another IP is unaffected
    expect((await post({ email: "other@example.com" })).status).toBe(200);
  });
});

describe("routing", () => {
  it("answers other /api paths with a JSON 404", async () => {
    const res = await SELF.fetch("https://keysrs.com/api/other");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not found" });
  });
});

describe("validEmail", () => {
  it("takes ordinary addresses", () => {
    for (const e of ["a.b+tag@example.co.uk", "dev@sub-domain.example.org", "x_y@example.io"]) expect(validEmail(e)).toBe(true);
  });
});
