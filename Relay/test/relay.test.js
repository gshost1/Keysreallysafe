// Offline tests: everything runs inside workerd with the throwaway secret from
// vitest.config.js. The "Mac" is a WebSocket the test holds; no real gateway,
// provider or Cloudflare account is involved.
import { SELF, env } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { FRAME, LIMITS, decodeFrame, encodeFrame, secretMatches, stripRequestHeader } from "../src/worker.js";

const ORIGIN = "https://relay.test";
const utf8 = new TextDecoder();
const open = [];

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
    for (const name of ["authorization", "x-api-key", "content-type", "anthropic-version"]) {
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

  it("fails in-flight requests with 502 mac_disconnected when the Mac drops", async () => {
    const mac = await connectMac();
    const agent = SELF.fetch(`${ORIGIN}/router/v1/models`);
    await mac.next(FRAME.REQUEST);
    mac.ws.close(1001, "sleep");
    const res = await withTimeout(agent, 5000, "agent response");
    expect(res.status).toBe(502);
    expect((await res.json()).error).toBe("mac_disconnected");
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

  it("closes the socket on an unexpected text frame", async () => {
    const mac = await connectMac();
    mac.ws.send("hello");
    const closed = await withTimeout(mac.closed, 5000, "close");
    expect(closed.code).toBe(1003);
  });
});
