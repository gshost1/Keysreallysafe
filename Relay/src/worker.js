// The Keysrs relay Worker: a dumb pipe between a cloud agent and the gateway
// on the user's Mac. The Mac opens one WebSocket to /connect; every other
// request is framed over that socket and answered with whatever the Mac
// streams back. No provider key, grant check or usage record lives here:
// docs/relay.md describes the protocol, the limits and the threat model, and
// this file must keep matching it.
//
// Logging discipline: nothing in this file logs headers or bodies. The only
// console output is a one-line note on an unexpected frame, without payload.

export const PROTOCOL = "1";

export const FRAME = Object.freeze({
  REQUEST: 1,
  BODY: 2,
  END: 3,
  RESPONSE: 4,
  CANCEL: 5,
  ERROR: 6,
});

export const LIMITS = Object.freeze({
  requestBody: 8 * 1024 * 1024,
  inflight: 32,
  chunk: 64 * 1024,
  headTimeoutMs: 120_000,
  idleTimeoutMs: 300_000,
});

const DOCS = "https://github.com/gshost1/Keysreallysafe/blob/main/docs/relay.md";

// Hop-by-hop headers, the ones the Mac rewrites, and the ones Cloudflare adds
// about the agent's connection. Repeated on the Mac in case a Worker is ever
// replaced by something less careful.
const STRIP_REQUEST = new Set([
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
  "trailers", "transfer-encoding", "upgrade", "host", "content-length",
  "x-ksf-via", "x-real-ip", "cdn-loop", "true-client-ip",
]);

const STRIP_RESPONSE = new Set([
  "connection", "keep-alive", "transfer-encoding", "content-length", "upgrade", "trailers", "te",
]);

export function stripRequestHeader(name) {
  const n = name.toLowerCase();
  return STRIP_REQUEST.has(n) || n.startsWith("cf-") || n.startsWith("x-forwarded-");
}

const utf8 = new TextEncoder();
const utf8d = new TextDecoder();

export function encodeFrame(type, id, payload) {
  const body = payload instanceof Uint8Array ? payload : payload ? utf8.encode(payload) : new Uint8Array(0);
  const out = new Uint8Array(5 + body.byteLength);
  out[0] = type;
  new DataView(out.buffer).setUint32(1, id >>> 0, false);
  out.set(body, 5);
  return out;
}

export function decodeFrame(data) {
  const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (bytes.byteLength < 5) return null;
  return {
    type: bytes[0],
    id: new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(1, false),
    payload: bytes.subarray(5),
  };
}

function json(status, object, extraHeaders) {
  const headers = {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    ...(extraHeaders || {}),
  };
  return new Response(JSON.stringify(object), { status, headers });
}

class RelayError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/// Compares the presented bearer to the configured secret in constant time
/// over fixed-length digests, so neither the length nor a prefix leaks.
export async function secretMatches(given, expected) {
  if (typeof given !== "string" || typeof expected !== "string" || !given || !expected) return false;
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", utf8.encode(given)),
    crypto.subtle.digest("SHA-256", utf8.encode(expected)),
  ]);
  return crypto.subtle.timingSafeEqual(a, b);
}

function bearer(request) {
  const auth = request.headers.get("authorization") || "";
  const parts = auth.trim().split(/\s+/, 2);
  return parts.length === 2 && parts[0].toLowerCase() === "bearer" ? parts[1] : "";
}

function limitsFrom(env) {
  // The timeout knobs exist for the offline test suite only; production
  // deployments leave them unset and get the documented values.
  const num = (raw, fallback) => {
    const n = Number(raw);
    return Number.isInteger(n) && n > 0 ? n : fallback;
  };
  return {
    ...LIMITS,
    headTimeoutMs: num(env.RELAY_HEAD_TIMEOUT_MS, LIMITS.headTimeoutMs),
    idleTimeoutMs: num(env.RELAY_IDLE_TIMEOUT_MS, LIMITS.idleTimeoutMs),
  };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "") {
      return json(200, {
        relay: "keysrs",
        protocol: PROTOCOL,
        usage: "call https://<this worker>/<key name>/<provider path> with a Keysrs grant or client token as the API key",
        docs: DOCS,
      });
    }
    const hub = env.RELAY.get(env.RELAY.idFromName("mac"));
    if (url.pathname === "/connect") {
      if (request.method !== "GET") return json(405, { error: "method_not_allowed" }, { allow: "GET" });
      if (!(await secretMatches(bearer(request), env.RELAY_SECRET))) {
        return json(401, { error: "unauthorized" }, { "www-authenticate": 'Bearer realm="keysrs-relay"' });
      }
      if ((request.headers.get("upgrade") || "").toLowerCase() !== "websocket") {
        return json(426, { error: "upgrade_required", message: "/connect is the Mac's WebSocket endpoint" }, { upgrade: "websocket" });
      }
      if (request.headers.get("x-keysrs-relay-protocol") !== PROTOCOL) {
        return json(400, {
          error: "unsupported_protocol",
          message: `this Worker speaks relay protocol ${PROTOCOL}; update keys or redeploy the Worker from the same checkout`,
        });
      }
      // The Durable Object gets a bare upgrade request: the secret has done its
      // job and should travel no further than this function.
      return hub.fetch(new Request(url.origin + "/connect", { headers: { upgrade: "websocket" } }));
    }
    return hub.fetch(request);
  },
};

export class RelayHub {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.limits = limitsFrom(env);
    /** @type {Map<number, object>} request id -> in-flight entry */
    this.pending = new Map();
    // Answered by the runtime without waking a hibernated object.
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/connect") return this.connect();
    return this.relay(request, url);
  }

  /// The Mac's socket: the most recently accepted one that is still open.
  mac() {
    let best = null;
    let bestAt = -1;
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState !== 1 /* OPEN */) continue;
      const at = ws.deserializeAttachment()?.connectedAt ?? 0;
      if (at > bestAt) {
        best = ws;
        bestAt = at;
      }
    }
    return best;
  }

  connect() {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    // One Mac per relay: a reconnecting Mac must not wait for a stale socket
    // to time out, so the newcomer wins and the old socket is told why.
    for (const old of this.ctx.getWebSockets()) {
      this.failAll(old, 502, "mac_disconnected", "the Mac reconnected while this request was in flight");
      try { old.close(4000, "replaced"); } catch { /* already gone */ }
    }
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ connectedAt: Date.now() });
    return new Response(null, { status: 101, webSocket: client });
  }

  allocId() {
    const buf = new Uint32Array(1);
    for (;;) {
      crypto.getRandomValues(buf);
      const id = buf[0];
      if (id !== 0 && !this.pending.has(id)) return id;
    }
  }

  async relay(request, url) {
    const mac = this.mac();
    if (!mac) {
      return json(503, {
        error: "mac_offline",
        message: "no Mac is connected to this relay: `keys relay` is not running, or the Mac is asleep or offline",
      }, { "retry-after": "30" });
    }
    if (this.pending.size >= this.limits.inflight) {
      return json(503, { error: "relay_busy", message: `${this.limits.inflight} requests are already in flight` }, { "retry-after": "5" });
    }
    const declared = Number(request.headers.get("content-length"));
    if (Number.isFinite(declared) && declared > this.limits.requestBody) {
      return json(413, { error: "payload_too_large", message: `request body over ${this.limits.requestBody} bytes` });
    }

    const id = this.allocId();
    const entry = {
      ws: mac,
      controller: null,
      buffered: [],
      bodyDone: false,
      headTimer: null,
      idleTimer: null,
      resolveHead: null,
      rejectHead: null,
    };
    entry.head = new Promise((resolve, reject) => {
      entry.resolveHead = resolve;
      entry.rejectHead = reject;
    });
    // A rejection nobody awaits yet (the body is still streaming in) must not
    // surface as an unhandled rejection.
    entry.head.catch(() => {});
    this.pending.set(id, entry);

    const headers = [];
    for (const [name, value] of request.headers) {
      if (!stripRequestHeader(name)) headers.push([name, value]);
    }
    try {
      mac.send(encodeFrame(FRAME.REQUEST, id, JSON.stringify({
        method: request.method,
        target: url.pathname + url.search,
        headers,
      })));
      if (request.body) {
        const reader = request.body.getReader();
        let total = 0;
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          total += value.byteLength;
          if (total > this.limits.requestBody) {
            reader.cancel().catch(() => {});
            this.cancel(id, "payload_too_large");
            return json(413, { error: "payload_too_large", message: `request body over ${this.limits.requestBody} bytes` });
          }
          for (let off = 0; off < value.byteLength; off += this.limits.chunk) {
            mac.send(encodeFrame(FRAME.BODY, id, value.subarray(off, Math.min(off + this.limits.chunk, value.byteLength))));
          }
        }
      }
      mac.send(encodeFrame(FRAME.END, id));
    } catch {
      this.finish(id);
      return json(502, { error: "mac_disconnected", message: "the Mac dropped while this request was being sent" });
    }

    entry.headTimer = setTimeout(() => {
      entry.rejectHead(new RelayError(504, "relay_timeout", `the Mac sent no response within ${this.limits.headTimeoutMs} ms`));
    }, this.limits.headTimeoutMs);
    let head;
    try {
      head = await entry.head;
    } catch (error) {
      this.cancel(id, error.code || "error");
      if (error instanceof RelayError) return json(error.status, { error: error.code, message: error.message });
      return json(502, { error: "mac_disconnected", message: "the Mac dropped while this request was in flight" });
    } finally {
      clearTimeout(entry.headTimer);
    }

    const responseHeaders = new Headers();
    for (const [name, value] of head.headers) {
      if (STRIP_RESPONSE.has(String(name).toLowerCase())) continue;
      try { responseHeaders.append(name, value); } catch { /* an invalid header name or value is dropped */ }
    }
    if (request.method === "HEAD" || head.status === 204 || head.status === 304) {
      this.finish(id);
      return new Response(null, { status: head.status, headers: responseHeaders });
    }
    const hub = this;
    const stream = new ReadableStream({
      start(controller) {
        entry.controller = controller;
        for (const chunk of entry.buffered) controller.enqueue(chunk);
        entry.buffered = [];
        if (entry.bodyDone) {
          controller.close();
          hub.finish(id);
        } else {
          hub.armIdle(id, entry);
        }
      },
      cancel() {
        hub.cancel(id, "client_gone");
      },
    });
    return new Response(stream, { status: head.status, headers: responseHeaders });
  }

  armIdle(id, entry) {
    clearTimeout(entry.idleTimer);
    entry.idleTimer = setTimeout(() => {
      try { entry.controller?.error(new Error("relay_timeout")); } catch { /* already closed */ }
      this.cancel(id, "relay_timeout");
    }, this.limits.idleTimeoutMs);
  }

  /// Tells the Mac to drop the request and forgets it here.
  cancel(id, reason) {
    const entry = this.pending.get(id);
    if (!entry) return;
    try { entry.ws.send(encodeFrame(FRAME.CANCEL, id, JSON.stringify({ reason }))); } catch { /* socket gone */ }
    this.finish(id);
  }

  finish(id) {
    const entry = this.pending.get(id);
    if (!entry) return;
    clearTimeout(entry.headTimer);
    clearTimeout(entry.idleTimer);
    this.pending.delete(id);
  }

  failAll(ws, status, code, message) {
    for (const [id, entry] of [...this.pending]) {
      if (entry.ws !== ws) continue;
      entry.rejectHead(new RelayError(status, code, message));
      try { entry.controller?.error(new Error(code)); } catch { /* already closed */ }
      this.finish(id);
    }
  }

  webSocketMessage(ws, message) {
    if (typeof message === "string") {
      // The auto-response table normally answers this; a runtime without it
      // still gets a pong. Anything else is not part of the protocol.
      if (message === "ping") {
        try { ws.send("pong"); } catch { /* closing */ }
        return;
      }
      ws.close(1003, "text frames are not part of the relay protocol");
      return;
    }
    const frame = decodeFrame(message);
    if (!frame) return;
    const entry = this.pending.get(frame.id);
    if (!entry || entry.ws !== ws) return;
    switch (frame.type) {
      case FRAME.RESPONSE: {
        let head;
        try {
          head = JSON.parse(utf8d.decode(frame.payload));
        } catch {
          head = null;
        }
        const status = Number(head?.status);
        if (!head || !Number.isInteger(status) || status < 200 || status > 599 || !Array.isArray(head.headers)) {
          entry.rejectHead(new RelayError(502, "bad_response_frame", "the Mac sent a malformed response head"));
          return;
        }
        clearTimeout(entry.headTimer);
        entry.resolveHead({ status, headers: head.headers.filter((h) => Array.isArray(h) && h.length === 2) });
        return;
      }
      case FRAME.BODY: {
        const chunk = frame.payload.slice();
        if (entry.controller) {
          try { entry.controller.enqueue(chunk); } catch { /* consumer gone; cancel() follows */ }
          this.armIdle(frame.id, entry);
        } else {
          entry.buffered.push(chunk);
        }
        return;
      }
      case FRAME.END: {
        entry.bodyDone = true;
        if (entry.controller) {
          try { entry.controller.close(); } catch { /* already closed */ }
          this.finish(frame.id);
        }
        // Without a controller yet, start() closes the stream and finishes.
        return;
      }
      case FRAME.ERROR: {
        let detail;
        try {
          detail = JSON.parse(utf8d.decode(frame.payload));
        } catch {
          detail = {};
        }
        const code = typeof detail?.code === "string" && detail.code.length <= 64 ? detail.code : "mac_error";
        const text = typeof detail?.message === "string" && detail.message.length <= 512 ? detail.message : "the Mac could not serve this request";
        entry.rejectHead(new RelayError(502, code, text));
        try { entry.controller?.error(new Error(code)); } catch { /* already closed */ }
        this.finish(frame.id);
        return;
      }
      default:
        console.warn(`relay: unexpected frame type ${frame.type} from the Mac`);
    }
  }

  webSocketClose(ws) {
    this.failAll(ws, 502, "mac_disconnected", "the Mac dropped while this request was in flight");
  }

  webSocketError(ws) {
    this.failAll(ws, 502, "mac_disconnected", "the Mac's connection failed while this request was in flight");
  }
}
