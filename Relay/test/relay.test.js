// Offline tests: everything runs inside workerd with the throwaway secret from
// vitest.config.js. The "Mac" is a WebSocket the test holds; no real gateway,
// provider or Cloudflare account is involved.
import { SELF, env, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { FRAME, LIMITS, decodeFrame, encodeFrame, limitsFrom, secretMatches, stripRequestHeader } from "../src/protocol.js";

const ORIGIN = "https://relay.test";
const utf8 = new TextDecoder();
const utf8e = new TextEncoder();
const open = [];
const hub = () => env.RELAY.get(env.RELAY.idFromName("mac"));

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

async function connectMac(headers = {}) {
  const res = await SELF.fetch(`${ORIGIN}/connect`, {
    headers: {
      upgrade: "websocket",
      authorization: `Bearer ${env.RELAY_SECRET}`,
      "x-keysrs-relay-protocol": "1",
      ...headers,
    },
  });
  expect(res.status).toBe(101);
  const ws = res.webSocket;
  ws.accept();
  open.push(ws);
  const frames = [];
  const waiters = [];
  // The test-side socket is a browser-style client: binary messages arrive as
  // Blobs. Decode in arrival order before anyone is woken.
  let chain = Promise.resolve();
  ws.addEventListener("message", (event) => {
    chain = chain.then(async () => {
      const data = event.data;
      if (typeof data === "string") frames.push({ text: data });
      else frames.push(decodeFrame(data instanceof Blob ? await data.arrayBuffer() : data));
      for (const wake of waiters.splice(0)) wake();
    });
  });
  const closed = new Promise((resolve) => {
    ws.addEventListener("close", (event) => resolve({ code: event.code, reason: event.reason }));
  });
  async function next(type) {
    const matches = (f) => (type === undefined ? true : f.type === type);
    return withTimeout((async () => {
      for (;;) {
        const i = frames.findIndex(matches);
        if (i >= 0) return frames.splice(i, 1)[0];
        await new Promise((wake) => waiters.push(wake));
      }
    })(), 5000, `frame ${type}`);
  }
  const send = (type, id, payload) => ws.send(encodeFrame(type, id, payload));
  return { ws, next, send, closed, frames };
}

function head(frame) {
  return JSON.parse(utf8.decode(frame.payload));
}

/// Starts a test with no Mac connected. A socket an earlier test closed from its
/// end can still look open to the Durable Object for a moment, so close them
/// from the inside as well.
async function noMac() {
  await runInDurableObject(hub(), (h) => {
    for (const ws of h.ctx.getWebSockets()) {
      try { ws.close(1000, "test reset"); } catch { /* already closing */ }
    }
  });
}

/// Runs `body` with some of the hub's limits changed and puts them back after.
async function withLimits(changes, body) {
  const saved = await runInDurableObject(hub(), (h) => {
    const before = { ...h.limits };
    Object.assign(h.limits, changes);
    return before;
  });
  try {
    return await body();
  } finally {
    await runInDurableObject(hub(), (h) => { h.limits = saved; });
  }
}

const hubState = () => runInDurableObject(hub(), (h) => ({ pending: h.pending.size, heldBytes: h.heldBytes }));

async function until(check, what, ms = 5000) {
  const deadline = Date.now() + ms;
  for (;;) {
    if (await check()) return;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

function streamOf(text) {
  return new ReadableStream({
    start(controller) {
      controller.enqueue(utf8e.encode(text));
      controller.close();
    },
  });
}

describe("limits", () => {
  it("waits longer for a response head than the gateway's 30 s connect + 900 s request limit", () => {
    // Non-streaming generations send nothing until the answer is done.
    expect(LIMITS.headTimeoutMs).toBeGreaterThan((30 + 900) * 1000);
  });

  it("trusts a socket through one late ping but not past the Mac's own two-interval rule", () => {
    // Relay.swift pings every 30 s and drops a socket silent for 60 s.
    expect(LIMITS.macSilenceMs).toBeGreaterThan(30_000);
    expect(LIMITS.macSilenceMs).toBeLessThan(60_000);
  });

  it("reads RELAY_OFFLINE_GRACE_MS: 0 turns the wait off, nonsense falls back, the cap holds", () => {
    expect(limitsFrom({}).offlineGraceMs).toBe(60_000);
    expect(limitsFrom({ RELAY_OFFLINE_GRACE_MS: "0" }).offlineGraceMs).toBe(0);
    expect(limitsFrom({ RELAY_OFFLINE_GRACE_MS: 0 }).offlineGraceMs).toBe(0);
    expect(limitsFrom({ RELAY_OFFLINE_GRACE_MS: "15000" }).offlineGraceMs).toBe(15_000);
    for (const nonsense of ["", " ", "-1", "1.5", "soon", null]) {
      expect(limitsFrom({ RELAY_OFFLINE_GRACE_MS: nonsense }).offlineGraceMs, String(nonsense)).toBe(60_000);
    }
    expect(limitsFrom({ RELAY_OFFLINE_GRACE_MS: String(24 * 3600 * 1000) }).offlineGraceMs).toBe(LIMITS.maxOfflineGraceMs);
    // The knobs for the test suite still ignore what is not a positive integer.
    expect(limitsFrom({ RELAY_UPLOAD_TIMEOUT_MS: "0" }).uploadTimeoutMs).toBe(LIMITS.uploadTimeoutMs);
  });
});

describe("frames", () => {
  it("round-trip the type, id and payload", () => {
    const f = decodeFrame(encodeFrame(FRAME.BODY, 0xfeedbeef, new Uint8Array([1, 2, 3])));
    expect(f).toMatchObject({ type: FRAME.BODY, id: 0xfeedbeef });
    expect([...f.payload]).toEqual([1, 2, 3]);
    expect(decodeFrame(new Uint8Array([1, 2]))).toBeNull();
  });

  it("strip Cloudflare and hop-by-hop headers but keep the agent's token header", () => {
    for (const name of ["cf-connecting-ip", "CF-Ray", "x-forwarded-for", "host", "content-length", "x-ksf-via", "connection"]) {
      expect(stripRequestHeader(name), name).toBe(true);
    }
    for (const name of ["authorization", "x-api-key", "content-type", "anthropic-version", "x-ksf-pair"]) {
      expect(stripRequestHeader(name), name).toBe(false);
    }
  });

  it("compare secrets without accepting empty or partial ones", async () => {
    expect(await secretMatches("abc", "abc")).toBe(true);
    expect(await secretMatches("ab", "abc")).toBe(false);
    expect(await secretMatches("", "")).toBe(false);
    expect(await secretMatches(undefined, "abc")).toBe(false);
  });
});

describe("the front door", () => {
  it("describes itself at / without saying whether a Mac is connected", async () => {
    const res = await SELF.fetch(`${ORIGIN}/`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.relay).toBe("keysrs");
    expect(body.protocol).toBe("1");
    expect(JSON.stringify(body)).not.toMatch(/online|offline|connected/);
  });

  it("reveals no pairing state at / either", async () => {
    const res = await SELF.fetch(`${ORIGIN}/`);
    expect(res.status).toBe(200);
    expect(JSON.stringify(await res.json())).not.toMatch(/pair/i);
  });

  it("refuses /connect without the secret, with a wrong one, without an upgrade, or with another protocol", async () => {
    const base = { upgrade: "websocket", "x-keysrs-relay-protocol": "1" };
    let res = await SELF.fetch(`${ORIGIN}/connect`, { headers: base });
    expect(res.status).toBe(401);
    res = await SELF.fetch(`${ORIGIN}/connect`, { headers: { ...base, authorization: "Bearer nope" } });
    expect(res.status).toBe(401);
    expect(await res.text()).not.toContain(env.RELAY_SECRET);
    res = await SELF.fetch(`${ORIGIN}/connect`, {
      headers: { authorization: `Bearer ${env.RELAY_SECRET}`, "x-keysrs-relay-protocol": "1" },
    });
    expect(res.status).toBe(426);
    res = await SELF.fetch(`${ORIGIN}/connect`, {
      headers: { ...base, authorization: `Bearer ${env.RELAY_SECRET}`, "x-keysrs-relay-protocol": "7" },
    });
    expect(res.status).toBe(400);
    expect((await res.json()).error).toBe("unsupported_protocol");
    // (An upgrade request is always sent as GET by the client; a bare POST is the
    // way to reach the method check.)
    res = await SELF.fetch(`${ORIGIN}/connect`, { method: "POST", headers: { authorization: `Bearer ${env.RELAY_SECRET}` } });
    expect(res.status).toBe(405);
  });

  it("answers 503 mac_offline when no Mac is connected", async () => {
    await noMac();
    const res = await SELF.fetch(`${ORIGIN}/router/v1/messages`, {
      method: "POST",
      headers: { authorization: "Bearer ksfc_whatever" },
      body: "{}",
    });
    expect(res.status).toBe(503);
    const body = await res.json();
    expect(body.error).toBe("mac_offline");
    expect(body.message).toMatch(/asleep or offline/);
    expect(res.headers.get("retry-after")).toBe("30");
  });

  it("answers ping with pong", async () => {
    const mac = await connectMac();
    mac.ws.send("ping");
    const pong = await mac.next(undefined);
    expect(pong.text).toBe("pong");
  });
});

describe("relaying", () => {
  it("frames the agent's request, keeps its token header, drops Cloudflare's, and streams the Mac's response", async () => {
    const mac = await connectMac();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/messages?beta=true`, {
      method: "POST",
      headers: {
        authorization: "Bearer ksfc_0123456789abcdef0123456789abcdef0123456789abcdef",
        "content-type": "application/json",
        "cf-connecting-ip": "203.0.113.9",
        "x-forwarded-for": "203.0.113.9",
        "x-ksf-via": "forged",
      },
      body: '{"model":"claude","stream":true}',
    });

    const req = await mac.next(FRAME.REQUEST);
    const h = head(req);
    expect(h.method).toBe("POST");
    expect(h.target).toBe("/router/v1/messages?beta=true");
    const names = h.headers.map(([n]) => n);
    expect(names).toContain("authorization");
    expect(names).toContain("content-type");
    expect(names).not.toContain("host");
    expect(names).not.toContain("cf-connecting-ip");
    expect(names).not.toContain("x-forwarded-for");
    expect(names).not.toContain("x-ksf-via");
    expect(names).not.toContain("content-length");
    const bodyFrame = await mac.next(FRAME.BODY);
    expect(bodyFrame.id).toBe(req.id);
    expect(utf8.decode(bodyFrame.payload)).toBe('{"model":"claude","stream":true}');
    const end = await mac.next(FRAME.END);
    expect(end.id).toBe(req.id);

    mac.send(FRAME.RESPONSE, req.id, JSON.stringify({
      status: 200,
      headers: [["content-type", "text/event-stream"], ["request-id", "req_1"], ["connection", "close"], ["content-length", "999"]],
    }));
    mac.send(FRAME.BODY, req.id, "data: one\n\n");
    const res = await withTimeout(agent, 5000, "agent response");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    expect(res.headers.get("request-id")).toBe("req_1");
    expect(res.headers.get("content-length")).toBeNull();

    // The second chunk arrives after the head was delivered: streamed, not buffered.
    const reader = res.body.getReader();
    const first = await withTimeout(reader.read(), 5000, "first chunk");
    expect(utf8.decode(first.value)).toBe("data: one\n\n");
    mac.send(FRAME.BODY, req.id, "data: two\n\n");
    const second = await withTimeout(reader.read(), 5000, "second chunk");
    expect(utf8.decode(second.value)).toBe("data: two\n\n");
    mac.send(FRAME.END, req.id);
    const done = await withTimeout(reader.read(), 5000, "end of stream");
    expect(done.done).toBe(true);
  });

  it("sends END straight after REQUEST for a bodiless GET and returns no body for HEAD", async () => {
    const mac = await connectMac();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/models`, { method: "GET" });
    const req = await mac.next(FRAME.REQUEST);
    expect(head(req).method).toBe("GET");
    const end = await mac.next(FRAME.END);
    expect(end.id).toBe(req.id);
    expect(mac.frames.filter((f) => f.type === FRAME.BODY)).toHaveLength(0);
    mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 200, headers: [["content-type", "application/json"]] }));
    mac.send(FRAME.BODY, req.id, '{"data":[]}');
    mac.send(FRAME.END, req.id);
    const res = await withTimeout(agent, 5000, "agent response");
    expect(await res.text()).toBe('{"data":[]}');
  });

  it("turns a Mac ERROR frame into 502 with the Mac's code", async () => {
    const mac = await connectMac();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/models`);
    const req = await mac.next(FRAME.REQUEST);
    mac.send(FRAME.ERROR, req.id, JSON.stringify({ code: "gateway_unreachable", message: "the gateway on 127.0.0.1:12767 is not running" }));
    const res = await withTimeout(agent, 5000, "agent response");
    expect(res.status).toBe(502);
    const body = await res.json();
    expect(body.error).toBe("gateway_unreachable");
    expect(body.message).toContain("12767");
  });

  it("rejects a request body over the limit before reading it when the length is declared", async () => {
    const mac = await connectMac();
    const res = await SELF.fetch(`${ORIGIN}/router/v1/messages`, {
      method: "POST",
      headers: { "content-length": String(LIMITS.requestBody + 1) },
      body: new Uint8Array(LIMITS.requestBody + 1),
    });
    expect(res.status).toBe(413);
    expect((await res.json()).error).toBe("payload_too_large");
    await new Promise((r) => setTimeout(r, 50));
    expect(mac.frames.filter((f) => f.type === FRAME.REQUEST)).toHaveLength(0);
  });

  it("answers 504 relay_timeout when the Mac sends no head, and tells the Mac to cancel", async () => {
    const mac = await connectMac();
    const res = await withTimeout(SELF.fetch(`${ORIGIN}/router/v1/models`), 5000, "timeout response");
    expect(res.status).toBe(504);
    expect((await res.json()).error).toBe("relay_timeout");
    const req = mac.frames.find((f) => f.type === FRAME.REQUEST);
    const cancel = await mac.next(FRAME.CANCEL);
    expect(cancel.id).toBe(req.id);
    expect(head(cancel).reason).toBe("relay_timeout");
  });

  it("aborts a stream that goes silent and cancels it on the Mac", async () => {
    const mac = await connectMac();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/messages`, { method: "POST", body: "{}" });
    const req = await mac.next(FRAME.REQUEST);
    mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 200, headers: [["content-type", "text/event-stream"]] }));
    mac.send(FRAME.BODY, req.id, "data: one\n\n");
    const res = await withTimeout(agent, 5000, "agent response");
    expect(res.status).toBe(200);
    await expect(withTimeout(res.text(), 5000, "stream abort")).rejects.toThrow();
    const cancel = await mac.next(FRAME.CANCEL);
    expect(cancel.id).toBe(req.id);
  });

  it("fails in-flight requests with 502 mac_disconnected when the Mac drops, and says they may be retried", async () => {
    const mac = await connectMac();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/models`);
    await mac.next(FRAME.REQUEST);
    mac.ws.close(1001, "sleep");
    const res = await withTimeout(agent, 5000, "agent response");
    expect(res.status).toBe(502);
    const body = await res.json();
    expect(body).toMatchObject({ error: "mac_disconnected", retryable: true });
    expect(body.message).toMatch(/may be retried/);
  });

  it("lets a new Mac connection replace the old one, closing it with code 4000", async () => {
    const first = await connectMac();
    const second = await connectMac();
    const closed = await withTimeout(first.closed, 5000, "first socket close");
    expect(closed.code).toBe(4000);
    expect(closed.reason).toBe("replaced");
    const agent = SELF.fetch(`${ORIGIN}/router/v1/models`);
    const req = await second.next(FRAME.REQUEST);
    second.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 204, headers: [] }));
    const res = await withTimeout(agent, 5000, "agent response");
    expect(res.status).toBe(204);
  });

  it("ignores frames for unknown ids and refuses a malformed response head", async () => {
    const mac = await connectMac();
    mac.send(FRAME.BODY, 12345, "stray");
    mac.send(FRAME.END, 12345);
    const agent = SELF.fetch(`${ORIGIN}/router/v1/models`);
    const req = await mac.next(FRAME.REQUEST);
    mac.send(FRAME.RESPONSE, req.id, "not json");
    const res = await withTimeout(agent, 5000, "agent response");
    expect(res.status).toBe(502);
    expect((await res.json()).error).toBe("bad_response_frame");
  });

  it("ends the agent's stream when the Mac sends ERROR mid-body", async () => {
    const mac = await connectMac();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/messages`, { method: "POST", body: "{}" });
    const req = await mac.next(FRAME.REQUEST);
    mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 200, headers: [["content-type", "text/event-stream"]] }));
    mac.send(FRAME.BODY, req.id, "data: one\n\n");
    const res = await withTimeout(agent, 5000, "agent response");
    const reader = res.body.getReader();
    expect(utf8.decode((await withTimeout(reader.read(), 5000, "first chunk")).value)).toBe("data: one\n\n");
    mac.send(FRAME.ERROR, req.id, JSON.stringify({ code: "gateway_read_failed", message: "the gateway stopped responding mid-body" }));
    await expect(withTimeout(reader.read(), 2000, "stream failure")).rejects.toThrow(/gateway_read_failed/);
  });

  it("does not hang the agent when ERROR follows RESPONSE before the stream exists", async () => {
    // The head is resolved by RESPONSE; the stream is built when the fetch
    // continuation runs. An ERROR (or the Mac dropping) in between used to be
    // lost: rejectHead was a no-op and there was no stream to fail yet.
    const mac = await connectMac();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/messages`, { method: "POST", body: "{}" });
    const req = await mac.next(FRAME.REQUEST);
    mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 200, headers: [["content-type", "application/json"]] }));
    mac.send(FRAME.ERROR, req.id, JSON.stringify({ code: "gateway_read_failed", message: "mid-body" }));
    const res = await withTimeout(agent, 5000, "agent response");
    // Either the error won the race (502) or the stream was built first and
    // must then fail promptly instead of idling until the stream timeout.
    if (res.status === 200) {
      await expect(withTimeout(res.text(), 300, "stream failure")).rejects.toThrow(/gateway_read_failed/);
    } else {
      expect(res.status).toBe(502);
      expect((await res.json()).error).toBe("gateway_read_failed");
    }
  });

  it("returns no body for 205 (and 204, 304) instead of failing to build the response", async () => {
    const mac = await connectMac();
    for (const status of [205, 204, 304]) {
      const agent = SELF.fetch(`${ORIGIN}/router/v1/reset`, { method: "POST", body: "{}" });
      const req = await mac.next(FRAME.REQUEST);
      mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status, headers: [["x-note", "none"]] }));
      const res = await withTimeout(agent, 5000, `status ${status}`);
      expect(res.status).toBe(status);
      expect(res.headers.get("x-note")).toBe("none");
      expect(await res.text()).toBe("");
    }
  });

  it("tells the Mac to cancel when the agent stops reading the response", async () => {
    const mac = await connectMac();
    const aborter = new AbortController();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/messages`, { method: "POST", body: "{}", signal: aborter.signal });
    const req = await mac.next(FRAME.REQUEST);
    mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 200, headers: [["content-type", "text/event-stream"]] }));
    mac.send(FRAME.BODY, req.id, "data: one\n\n");
    const res = await withTimeout(agent, 5000, "agent response");
    expect(res.status).toBe(200);
    aborter.abort();
    const cancel = await mac.next(FRAME.CANCEL);
    expect(cancel.id).toBe(req.id);
    expect(head(cancel).reason).toBe("client_gone");
  });

  it("tells the Mac to cancel when the agent's upload fails mid-body, with no 502 for a healthy Mac", async () => {
    // A body stream that errors is what the Worker's reader sees when the
    // agent's connection drops or is aborted part-way through an upload. The
    // in-process fetch of the test harness turns such an error into a clean
    // end of body before it reaches the Durable Object, so the request is
    // handed to the hub directly, erroring stream and all.
    const mac = await connectMac();
    const url = new URL(`${ORIGIN}/router/v1/messages`);
    const stub = env.RELAY.get(env.RELAY.idFromName("mac"));
    // The stream has to be made inside the object: I/O objects do not cross
    // Durable Object contexts, even inside one isolate.
    const agent = runInDurableObject(stub, async (hub) => {
      let feed;
      const body = new ReadableStream({ start(controller) { feed = controller; } });
      feed.enqueue(new TextEncoder().encode('{"partial":'));
      const answer = hub.relay(new Request(url, { method: "POST", body, duplex: "half" }), url);
      await new Promise((r) => setTimeout(r, 100));
      feed.error(new Error("connection reset"));
      return answer;
    });
    const req = await mac.next(FRAME.REQUEST);
    const chunk = await mac.next(FRAME.BODY);
    expect(chunk.id).toBe(req.id);
    const res = await withTimeout(agent, 5000, "hub answer");
    expect(res.status).toBe(400);
    expect((await res.json()).error).toBe("client_gone");
    const cancel = await mac.next(FRAME.CANCEL);
    expect(cancel.id).toBe(req.id);
    expect(head(cancel).reason).toBe("client_gone");
    expect(mac.frames.filter((f) => f.type === FRAME.END && f.id === req.id)).toHaveLength(0);
    // The slot is free again and the socket is still good.
    const next = SELF.fetch(`${ORIGIN}/router/v1/models`);
    const again = await mac.next(FRAME.REQUEST);
    mac.send(FRAME.RESPONSE, again.id, JSON.stringify({ status: 204, headers: [] }));
    expect((await withTimeout(next, 5000, "next response")).status).toBe(204);
  });

  it("gives up on an upload that does not finish in time and frees the slot", async () => {
    const mac = await connectMac();
    let feed;
    const body = new ReadableStream({ start(controller) { feed = controller; } });
    feed.enqueue(new TextEncoder().encode('{"slow":'));
    const started = Date.now();
    const res = await withTimeout(SELF.fetch(`${ORIGIN}/router/v1/messages`, { method: "POST", body, duplex: "half" }), 5000, "upload timeout");
    expect(res.status).toBe(408);
    expect((await res.json()).error).toBe("upload_timeout");
    expect(Date.now() - started).toBeLessThan(3000);
    const req = await mac.next(FRAME.REQUEST);
    const cancel = await mac.next(FRAME.CANCEL);
    expect(cancel.id).toBe(req.id);
    expect(head(cancel).reason).toBe("upload_timeout");
    const next = SELF.fetch(`${ORIGIN}/router/v1/models`);
    const again = await mac.next(FRAME.REQUEST);
    mac.send(FRAME.RESPONSE, again.id, JSON.stringify({ status: 204, headers: [] }));
    expect((await withTimeout(next, 5000, "next response")).status).toBe(204);
  });

  it("closes the socket on an unexpected text frame", async () => {
    const mac = await connectMac();
    mac.ws.send("hello");
    const closed = await withTimeout(mac.closed, 5000, "close");
    expect(closed.code).toBe(1003);
  });
});

describe("the Mac's pairing refusals", () => {
  // docs/relay.md, the pairing section: when relay_pairing_required is on, the
  // Mac refuses an unpaired, expired, revoked or out-of-scope request at
  // REQUEST time. The Worker presents that as 403: the fix is a new pairing or
  // scope on the Mac, so resending the identical request cannot help — no
  // retryable flag, no Retry-After.
  for (const [code, message] of [
    ["pairing_required", "this relay requires a paired agent; issue one with keys relay pair issue and send the credential as x-ksf-pair"],
    ["pairing_expired", "this pairing has expired; issue a new one with keys relay pair issue"],
    ["pairing_revoked", "this pairing was revoked on the Mac"],
    ["pairing_out_of_scope", "this pairing does not cover the key this request targets"],
  ]) {
    it(`answers 403 ${code} when the Mac refuses the pairing, without retry guidance`, async () => {
      const mac = await connectMac();
      const agent = SELF.fetch(`${ORIGIN}/router/v1/models`);
      const req = await mac.next(FRAME.REQUEST);
      mac.send(FRAME.ERROR, req.id, JSON.stringify({ code, message }));
      const res = await withTimeout(agent, 5000, "agent response");
      expect(res.status).toBe(403);
      expect(res.headers.get("content-type")).toBe("application/json; charset=utf-8");
      expect(res.headers.get("cache-control")).toBe("no-store");
      expect(res.headers.get("retry-after")).toBeNull();
      const body = await res.json();
      expect(body.error).toBe(code);
      expect(body.message).toBe(message);
      expect("retryable" in body).toBe(false);
    });
  }

  it("keeps answering 502 for the Mac's other error codes", async () => {
    const mac = await connectMac();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/models`);
    const req = await mac.next(FRAME.REQUEST);
    mac.send(FRAME.ERROR, req.id, JSON.stringify({ code: "relay_buffer_full", message: "the Mac's buffer of unfinished requests is full" }));
    const res = await withTimeout(agent, 5000, "agent response");
    expect(res.status).toBe(502);
    expect((await res.json()).error).toBe("relay_buffer_full");
  });

  it("passes x-ksf-pair through to the REQUEST frame untouched", async () => {
    const mac = await connectMac();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/models`, {
      headers: { "x-ksf-pair": "ksfp_0123456789abcdef0123456789abcdef0123456789abcdef" },
    });
    const req = await mac.next(FRAME.REQUEST);
    expect(head(req).headers).toContainEqual(["x-ksf-pair", "ksfp_0123456789abcdef0123456789abcdef0123456789abcdef"]);
    mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 204, headers: [] }));
    expect((await withTimeout(agent, 5000, "agent response")).status).toBe(204);
  });
});

describe("while the Mac is away", () => {
  afterEach(async () => {
    // Whatever a test left waiting must not reach the next test's Mac.
    await until(async () => (await hubState()).pending === 0, "no request left waiting");
    expect((await hubState()).heldBytes).toBe(0);
  });

  it("holds a request until a Mac connects, then sends it with its body and serves it", async () => {
    await noMac();
    await withLimits({ offlineGraceMs: 5000 }, async () => {
      const agent = SELF.fetch(`${ORIGIN}/router/v1/messages?beta=true`, {
        method: "POST",
        headers: { authorization: "Bearer ksfc_whatever", "content-type": "application/json" },
        body: '{"model":"claude","stream":true}',
      });
      let answered = false;
      agent.then(() => { answered = true; }, () => { answered = true; });
      await until(async () => (await hubState()).pending === 1, "the request to be held");
      await new Promise((r) => setTimeout(r, 100));
      expect(answered).toBe(false);
      expect((await hubState()).heldBytes).toBe(32);

      const mac = await connectMac();
      const req = await mac.next(FRAME.REQUEST);
      expect(head(req)).toMatchObject({ method: "POST", target: "/router/v1/messages?beta=true" });
      expect(head(req).headers.map(([n]) => n)).toContain("authorization");
      const body = await mac.next(FRAME.BODY);
      expect(body.id).toBe(req.id);
      expect(utf8.decode(body.payload)).toBe('{"model":"claude","stream":true}');
      expect((await mac.next(FRAME.END)).id).toBe(req.id);
      expect((await hubState()).heldBytes).toBe(0);

      mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 200, headers: [["content-type", "text/event-stream"]] }));
      mac.send(FRAME.BODY, req.id, "data: one\n\n");
      mac.send(FRAME.END, req.id);
      const res = await withTimeout(agent, 5000, "agent response");
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("data: one\n\n");
    });
  });

  it("answers 503 mac_offline with retry guidance once the window passes without a Mac", async () => {
    await noMac();
    const started = Date.now();
    const res = await withTimeout(SELF.fetch(`${ORIGIN}/router/v1/messages`, { method: "POST", body: "{}" }), 5000, "offline answer");
    expect(Date.now() - started).toBeGreaterThanOrEqual(450);
    expect(res.status).toBe(503);
    expect(res.headers.get("retry-after")).toBe("30");
    const body = await res.json();
    expect(body).toMatchObject({ error: "mac_offline", retryable: true });
    expect(body.message).toMatch(/within 500 ms: .*asleep or offline/);
    expect(await hubState()).toEqual({ pending: 0, heldBytes: 0 });
    // A Mac that connects afterwards is sent nothing for it.
    const mac = await connectMac();
    await new Promise((r) => setTimeout(r, 50));
    expect(mac.frames.filter((f) => f.type === FRAME.REQUEST)).toHaveLength(0);
  });

  it("answers mac_offline at once, as before, when the window is turned off", async () => {
    await noMac();
    await withLimits({ offlineGraceMs: 0 }, async () => {
      const started = Date.now();
      const res = await SELF.fetch(`${ORIGIN}/router/v1/messages`, { method: "POST", body: "{}" });
      expect(Date.now() - started).toBeLessThan(250);
      expect(res.status).toBe(503);
      expect(res.headers.get("retry-after")).toBe("30");
      const body = await res.json();
      expect(body.error).toBe("mac_offline");
      expect(body.message).toMatch(/^no Mac is connected to this relay: .*asleep or offline$/);
    });
  });

  it("counts waiting requests against the in-flight limit and sends them all when the Mac connects", async () => {
    await noMac();
    await withLimits({ offlineGraceMs: 5000 }, async () => {
      const agents = [];
      for (let i = 0; i < LIMITS.inflight; i++) agents.push(SELF.fetch(`${ORIGIN}/router/v1/models?n=${i}`));
      await until(async () => (await hubState()).pending === LIMITS.inflight, "every request to be held");
      const busy = await SELF.fetch(`${ORIGIN}/router/v1/models?n=over`);
      expect(busy.status).toBe(503);
      expect(busy.headers.get("retry-after")).toBe("5");
      expect(await busy.json()).toMatchObject({ error: "relay_busy", retryable: true });

      const mac = await connectMac();
      const targets = new Set();
      for (let i = 0; i < LIMITS.inflight; i++) {
        const req = await mac.next(FRAME.REQUEST);
        targets.add(head(req).target);
        mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 204, headers: [] }));
      }
      expect(targets.size).toBe(LIMITS.inflight);
      expect(targets.has("/router/v1/models?n=over")).toBe(false);
      const answers = await withTimeout(Promise.all(agents), 5000, "every held request");
      expect(answers.map((r) => r.status)).toEqual(new Array(LIMITS.inflight).fill(204));
    });
  });

  it("keeps a waiting request's body within the per-request cap and the budget all waiting requests share", async () => {
    await noMac();
    await withLimits({ offlineGraceMs: 5000, requestBody: 600, heldBytes: 1000 }, async () => {
      const url = `${ORIGIN}/router/v1/messages`;
      // Over the per-request cap, declared and streamed.
      let res = await SELF.fetch(url, { method: "POST", body: "x".repeat(601) });
      expect(res.status).toBe(413);
      res = await SELF.fetch(url, { method: "POST", body: streamOf("x".repeat(601)), duplex: "half" });
      expect(res.status).toBe(413);
      expect(await hubState()).toEqual({ pending: 0, heldBytes: 0 });

      const first = SELF.fetch(url, { method: "POST", body: "a".repeat(500) });
      await until(async () => (await hubState()).heldBytes === 500, "the first body to be kept");
      // Within the per-request cap but over what is left of the shared budget,
      // declared and streamed.
      res = await SELF.fetch(url, { method: "POST", body: "b".repeat(501) });
      expect(res.status).toBe(503);
      expect(await res.json()).toMatchObject({ error: "relay_busy", retryable: true });
      res = await SELF.fetch(url, { method: "POST", body: streamOf("c".repeat(501)), duplex: "half" });
      expect(res.status).toBe(503);
      expect((await res.json()).error).toBe("relay_busy");
      expect(await hubState()).toEqual({ pending: 1, heldBytes: 500 });

      // The one that fit is still delivered whole.
      const mac = await connectMac();
      const req = await mac.next(FRAME.REQUEST);
      expect(utf8.decode((await mac.next(FRAME.BODY)).payload)).toBe("a".repeat(500));
      expect((await mac.next(FRAME.END)).id).toBe(req.id);
      mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 204, headers: [] }));
      expect((await withTimeout(first, 5000, "held request")).status).toBe(204);
    });
  });

  it("splits a kept body into protocol-sized frames when it is sent", async () => {
    await noMac();
    await withLimits({ offlineGraceMs: 5000 }, async () => {
      const bytes = new Uint8Array(LIMITS.chunk * 2 + 10).fill(0x61);
      const agent = SELF.fetch(`${ORIGIN}/router/v1/messages`, { method: "POST", body: bytes });
      await until(async () => (await hubState()).heldBytes === bytes.byteLength, "the body to be kept");
      const mac = await connectMac();
      const req = await mac.next(FRAME.REQUEST);
      let got = 0;
      for (;;) {
        const frame = await mac.next();
        if (frame.type === FRAME.END) break;
        expect(frame.type).toBe(FRAME.BODY);
        expect(frame.payload.byteLength).toBeLessThanOrEqual(LIMITS.chunk);
        got += frame.payload.byteLength;
      }
      expect(got).toBe(bytes.byteLength);
      mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 204, headers: [] }));
      expect((await withTimeout(agent, 5000, "agent response")).status).toBe(204);
    });
  });

  it("gives a waiting request's upload the same deadline and frees its slot", async () => {
    await noMac();
    await withLimits({ offlineGraceMs: 5000 }, async () => {
      let feed;
      const body = new ReadableStream({ start(controller) { feed = controller; } });
      feed.enqueue(utf8e.encode('{"slow":'));
      const started = Date.now();
      const res = await withTimeout(SELF.fetch(`${ORIGIN}/router/v1/messages`, { method: "POST", body, duplex: "half" }), 5000, "upload timeout");
      expect(res.status).toBe(408);
      expect((await res.json()).error).toBe("upload_timeout");
      expect(Date.now() - started).toBeLessThan(3000);
      expect(await hubState()).toEqual({ pending: 0, heldBytes: 0 });
    });
  });

  it("returns a waiting request's budget when its agent gives up mid-upload", async () => {
    // As in the healthy-Mac case above, the erroring stream has to be made
    // inside the object and handed to the hub directly.
    await noMac();
    await withLimits({ offlineGraceMs: 5000 }, async () => {
      const url = new URL(`${ORIGIN}/router/v1/messages`);
      const res = await runInDurableObject(hub(), async (h) => {
        let feed;
        const body = new ReadableStream({ start(controller) { feed = controller; } });
        feed.enqueue(new TextEncoder().encode('{"partial":'));
        const answer = h.relay(new Request(url, { method: "POST", body, duplex: "half" }), url);
        await new Promise((r) => setTimeout(r, 50));
        const kept = h.heldBytes;
        feed.error(new Error("connection reset"));
        const r = await answer;
        return { status: r.status, error: (await r.json()).error, kept };
      });
      expect(res).toEqual({ status: 400, error: "client_gone", kept: 11 });
      expect(await hubState()).toEqual({ pending: 0, heldBytes: 0 });
    });
  });

  it("sends no new request into a socket the Mac has stopped pinging, and sends it once a ping arrives", async () => {
    const mac = await connectMac();
    await withLimits({ macSilenceMs: 300, holdRecheckMs: 20, offlineGraceMs: 5000 }, async () => {
      await new Promise((r) => setTimeout(r, 400));
      const agent = SELF.fetch(`${ORIGIN}/router/v1/models`);
      await until(async () => (await hubState()).pending === 1, "the request to be held");
      await new Promise((r) => setTimeout(r, 100));
      expect(mac.frames.filter((f) => f.type === FRAME.REQUEST)).toHaveLength(0);
      mac.ws.send("ping");
      const req = await mac.next(FRAME.REQUEST);
      mac.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 204, headers: [] }));
      expect((await withTimeout(agent, 5000, "agent response")).status).toBe(204);
    });
  });

  it("sends a waiting request to the Mac that replaces a silent socket", async () => {
    const silent = await connectMac();
    await withLimits({ macSilenceMs: 300, offlineGraceMs: 5000 }, async () => {
      await new Promise((r) => setTimeout(r, 400));
      const agent = SELF.fetch(`${ORIGIN}/router/v1/models`);
      await until(async () => (await hubState()).pending === 1, "the request to be held");
      const fresh = await connectMac();
      expect((await withTimeout(silent.closed, 5000, "the silent socket to close")).code).toBe(4000);
      const req = await fresh.next(FRAME.REQUEST);
      fresh.send(FRAME.RESPONSE, req.id, JSON.stringify({ status: 204, headers: [] }));
      expect((await withTimeout(agent, 5000, "agent response")).status).toBe(204);
      expect(silent.frames.filter((f) => f.type === FRAME.REQUEST)).toHaveLength(0);
    });
  });
});
