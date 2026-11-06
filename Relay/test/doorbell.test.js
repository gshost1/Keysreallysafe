// The doorbell (docs/relay.md, The doorbell), offline inside workerd like the
// relay suite. The "Mac" here holds two sockets the test opens itself: the
// doorbell and, where a test needs it, the relay.
import { SELF, env, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DOORBELL, doorbellKey, ringCredentials, sha256Hex } from "../src/protocol.js";

const ORIGIN = "https://relay.test";
const hub = () => env.RELAY.get(env.RELAY.idFromName("mac"));
const open = [];

// Shapes the Mac mints; never real credentials.
const CLIENT = "ksfc_" + "ab".repeat(24);
const CLIENT_HASH = "5a973ced9266a68474a00fddbe4ee925fcf572a98b55d8a5cf32b1f004511ed7";
const PAIR = "ksfp_" + "cd".repeat(24);
const PAIR_HASH = "b44ce610e52b8257c00c602edcdbd676521d3bade907dfc0321ced7d88e414b3";
// HMAC-SHA256(RELAY_SECRET from vitest.config.js, DOORBELL.keyContext); the
// Swift side's DoorbellKey test pins the same value.
const KEY = "ksfd_8e08d4cec8c525bf32a5136871d5275b83fa0d3a18a18025153bc5108c6a5bcf";

beforeEach(async () => {
  // Every test starts with no socket and no ring throttle: the 10 s spacing is
  // the Worker's rule, and tests that check it set it up themselves.
  await runInDurableObject(hub(), (h) => {
    for (const ws of h.ctx.getWebSockets()) {
      try { ws.close(1000, "test reset"); } catch { /* already closing */ }
    }
    h.ringing = null;
    h.lastRingAt = 0;
  });
});

afterEach(() => {
  for (const ws of open.splice(0)) {
    try { ws.close(1000, "test done"); } catch { /* already closed */ }
  }
});

function withTimeout(promise, ms, what) {
  let timer;
  const bomb = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
  });
  return Promise.race([promise, bomb]).finally(() => clearTimeout(timer));
}

function socketOf(res) {
  const ws = res.webSocket;
  ws.accept();
  open.push(ws);
  const messages = [];
  const waiters = [];
  ws.addEventListener("message", (event) => {
    messages.push(event.data);
    for (const wake of waiters.splice(0)) wake();
  });
  const closed = new Promise((resolve) => {
    ws.addEventListener("close", (event) => resolve({ code: event.code, reason: event.reason }));
  });
  async function next() {
    return withTimeout((async () => {
      for (;;) {
        if (messages.length) return messages.shift();
        await new Promise((wake) => waiters.push(wake));
      }
    })(), 5000, "a doorbell message");
  }
  return { ws, next, closed, messages };
}

async function listen(headers = {}) {
  const res = await SELF.fetch(`${ORIGIN}${DOORBELL.listenPath}`, {
    headers: { upgrade: "websocket", authorization: `Bearer ${KEY}`, "x-keysrs-relay-protocol": "1", ...headers },
  });
  expect(res.status).toBe(101);
  return socketOf(res);
}

async function connectRelay() {
  const res = await SELF.fetch(`${ORIGIN}/connect`, {
    headers: { upgrade: "websocket", authorization: `Bearer ${env.RELAY_SECRET}`, "x-keysrs-relay-protocol": "1" },
  });
  expect(res.status).toBe(101);
  return socketOf(res);
}

function ring(headers = { authorization: `Bearer ${CLIENT}` }, query = "") {
  return SELF.fetch(`${ORIGIN}${DOORBELL.ringPath}${query}`, { method: "POST", headers });
}

/// Rings, reads the ring the Mac got, answers it with `answer`, and returns
/// the ringer's response.
async function ringAnswered(answer, headers) {
  const bell = await listen();
  const pending = ring(headers);
  const got = JSON.parse(await bell.next());
  bell.ws.send(JSON.stringify({ type: "answer", id: got.id, ...answer }));
  return { res: await pending, got, bell };
}

describe("the doorbell key", () => {
  it("is HMAC-SHA256 of the relay secret under the fixed context, as the Mac derives it", async () => {
    expect(await doorbellKey(env.RELAY_SECRET)).toBe(KEY);
    expect(await doorbellKey("")).toBe("");
    expect(await doorbellKey(undefined)).toBe("");
  });

  it("opens the doorbell and nothing else: the relay secret is refused there, the doorbell key at /connect", async () => {
    const wrong = await SELF.fetch(`${ORIGIN}${DOORBELL.listenPath}`, {
      headers: { upgrade: "websocket", authorization: `Bearer ${env.RELAY_SECRET}`, "x-keysrs-relay-protocol": "1" },
    });
    expect(wrong.status).toBe(401);
    const relay = await SELF.fetch(`${ORIGIN}/connect`, {
      headers: { upgrade: "websocket", authorization: `Bearer ${KEY}`, "x-keysrs-relay-protocol": "1" },
    });
    expect(relay.status).toBe(401);
  });

  it("answers the listen handshake's other mistakes like /connect does", async () => {
    const noUpgrade = await SELF.fetch(`${ORIGIN}${DOORBELL.listenPath}`, { headers: { authorization: `Bearer ${KEY}` } });
    expect(noUpgrade.status).toBe(426);
    const oldProtocol = await SELF.fetch(`${ORIGIN}${DOORBELL.listenPath}`, {
      headers: { upgrade: "websocket", authorization: `Bearer ${KEY}`, "x-keysrs-relay-protocol": "0" },
    });
    expect(oldProtocol.status).toBe(400);
    const post = await SELF.fetch(`${ORIGIN}${DOORBELL.listenPath}`, { method: "POST" });
    expect(post.status).toBe(405);
  });
});

describe("ring credentials", () => {
  it("are read from the gateway's headers and kept only as SHA-256 hex", async () => {
    expect(await sha256Hex(CLIENT)).toBe(CLIENT_HASH);
    expect(await ringCredentials(new Headers({ authorization: `Bearer ${CLIENT}`, "x-ksf-pair": PAIR }))).toEqual({ client: CLIENT_HASH, pair: PAIR_HASH });
    expect(await ringCredentials(new Headers({ "x-api-key": CLIENT }))).toEqual({ client: CLIENT_HASH, pair: null });
    expect(await ringCredentials(new Headers({ "x-ksf-pair": PAIR }))).toEqual({ client: null, pair: PAIR_HASH });
  });

  it("ignore anything not shaped like a Keysrs token: a provider key, a grant, upper-case hex", async () => {
    for (const value of ["sk-ant-api03-not-a-keysrs-token", "ksf_" + "ab".repeat(24), "ksfc_" + "AB".repeat(24), "ksfc_short"]) {
      expect(await ringCredentials(new Headers({ authorization: `Bearer ${value}`, "x-api-key": value }))).toEqual({ client: null, pair: null });
    }
  });
});

describe("ringing", () => {
  it("needs a client token or a pairing before anything reaches the Mac", async () => {
    const bell = await listen();
    const res = await ring({});
    expect(res.status).toBe(401);
    expect((await res.json()).error).toBe("doorbell_credential_required");
    const get = await SELF.fetch(`${ORIGIN}${DOORBELL.ringPath}`);
    expect(get.status).toBe(405);
    expect(bell.messages).toEqual([]);
  });

  it("says when no doorbell is listening, as a retryable 503", async () => {
    const res = await ring();
    expect(res.status).toBe(503);
    expect(res.headers.get("retry-after")).toBe("60");
    expect(await res.json()).toMatchObject({ error: "doorbell_offline", retryable: true });
  });

  it("hands the Mac the hashes, never the token, and answers 200 once the Mac says on", async () => {
    const { res, got } = await ringAnswered({ result: "on" }, { authorization: `Bearer ${CLIENT}`, "x-ksf-pair": PAIR });
    expect(got).toEqual({ type: "ring", id: expect.stringMatching(/^[0-9a-f]{32}$/), client: CLIENT_HASH, pair: PAIR_HASH });
    expect(JSON.stringify(got)).not.toContain(CLIENT);
    expect(JSON.stringify(got)).not.toContain(PAIR);
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ relay: "on" });
  });

  it("maps each of the Mac's answers to its documented status", async () => {
    const cases = [
      [{ result: "declined" }, 403, "doorbell_declined", undefined],
      [{ result: "refused" }, 403, "doorbell_refused", undefined],
      [{ result: "away" }, 503, "doorbell_mac_locked", "300"],
      [{ result: "not_now", retry_after: 420 }, 429, "doorbell_not_now", "420"],
      [{ result: "not_now", retry_after: 999999 }, 429, "doorbell_not_now", "3600"],
      [{ result: "unavailable", message: "the gateway is not running" }, 503, "doorbell_unavailable", undefined],
      [{ result: "something new" }, 502, "doorbell_error", undefined],
    ];
    for (const [answer, status, code, retryAfter] of cases) {
      await runInDurableObject(hub(), (h) => { h.lastRingAt = 0; });
      const { res, bell } = await ringAnswered(answer);
      expect(res.status, code).toBe(status);
      const body = await res.json();
      expect(body.error).toBe(code);
      if (retryAfter) expect(res.headers.get("retry-after")).toBe(retryAfter);
      if (answer.result === "unavailable") expect(body.message).toContain("the gateway is not running");
      if (answer.result === "declined" || answer.result === "refused") expect(body.retryable).toBeUndefined();
      bell.ws.close(1000, "next case");
    }
  });

  it("answers 202 asking while the Mac's prompt is up, and when the ringer's wait runs out", async () => {
    const { res } = await ringAnswered({ result: "pending" });
    expect(res.status).toBe(202);
    expect(await res.json()).toMatchObject({ relay: "off", state: "asking", retryable: true });

    await runInDurableObject(hub(), (h) => { h.lastRingAt = 0; });
    const bell = await listen();
    const quick = await ring(undefined, "?wait=1");
    expect(quick.status).toBe(202);
    expect(JSON.parse(bell.messages[0]).type).toBe("ring");
  });

  it("answers 200 at once while the relay is connected, without ringing the Mac", async () => {
    const bell = await listen();
    await connectRelay();
    const res = await ring();
    expect(res.status).toBe(200);
    expect(bell.messages).toEqual([]);
  });

  it("answers 200 when the relay connects while the ring waits, even before the Mac's answer", async () => {
    const bell = await listen();
    const pending = ring();
    expect(JSON.parse(await bell.next()).type).toBe("ring");
    await connectRelay();
    const res = await pending;
    expect(res.status).toBe(200);
    // The relay connecting does not close the doorbell, nor the other way round.
    expect(bell.ws.readyState).toBe(1);
    const second = await listen();
    await runInDurableObject(hub(), (h) => {
      expect(h.ctx.getWebSockets("mac").length).toBe(1);
      expect(h.ctx.getWebSockets("doorbell").filter((ws) => ws.readyState === 1).length).toBe(1);
    });
    expect((await bell.closed).code).toBe(4000);
    expect(second.ws.readyState).toBe(1);
  });

  it("rings one at a time and no more than every ten seconds", async () => {
    const bell = await listen();
    const first = ring();
    const got = JSON.parse(await bell.next());
    const busy = await ring();
    expect(busy.status).toBe(503);
    expect((await busy.json()).error).toBe("doorbell_busy");
    bell.ws.send(JSON.stringify({ type: "answer", id: got.id, result: "declined" }));
    expect((await first).status).toBe(403);
    const soon = await ring();
    expect(soon.status).toBe(503);
    expect((await soon.json()).error).toBe("doorbell_busy");
    expect(Number(soon.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(Number(soon.headers.get("retry-after"))).toBeLessThanOrEqual(10);
    expect(bell.messages).toEqual([]);
  });

  it("fails a waiting ring with doorbell_offline when the doorbell drops", async () => {
    const bell = await listen();
    const pending = ring();
    await bell.next();
    bell.ws.close(1000, "Mac went away");
    const res = await pending;
    expect(res.status).toBe(503);
    expect((await res.json()).error).toBe("doorbell_offline");
  });

  it("ignores an answer for another ring, and closes a doorbell that sends binary", async () => {
    const bell = await listen();
    const pending = ring(undefined, "?wait=1");
    const got = JSON.parse(await bell.next());
    bell.ws.send(JSON.stringify({ type: "answer", id: "0".repeat(32), result: "on" }));
    bell.ws.send("not json");
    const res = await pending;
    expect(res.status).toBe(202);
    expect(got.id).not.toBe("0".repeat(32));
    bell.ws.send(new Uint8Array([1, 2, 3]));
    expect((await bell.closed).code).toBe(1003);
  });

  it("answers the keepalive on the doorbell", async () => {
    const bell = await listen();
    bell.ws.send("ping");
    expect(await bell.next()).toBe("pong");
  });
});
