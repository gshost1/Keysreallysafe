// The Keysrs relay Worker: a dumb pipe between a cloud agent and the gateway
// on the user's Mac. The Mac opens one WebSocket to /connect; every other
// request is framed over that socket and answered with whatever the Mac
// streams back. No provider key, grant check or usage record lives here:
// docs/relay.md describes the protocol, the limits and the threat model, and
// this file must keep matching it.
//
// Logging discipline: nothing in this file logs headers or bodies. The only
// console output is a one-line note on an unexpected frame, without payload.

import { DurableObject } from "cloudflare:workers";
import { BODYLESS_STATUS, FRAME, LIMITS, PROTOCOL, STRIP_RESPONSE, decodeFrame, encodeFrame, secretMatches, stripRequestHeader } from "./protocol.js";

const DOCS = "https://github.com/gshost1/Keysreallysafe/blob/main/docs/relay.md";
const utf8d = new TextDecoder();

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
    uploadTimeoutMs: num(env.RELAY_UPLOAD_TIMEOUT_MS, LIMITS.uploadTimeoutMs),
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

export class RelayHub extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
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
      // Set when the Mac fails the request after RESPONSE was accepted but
      // before the stream exists; start() then errors the stream instead of
      // leaving the agent with a 200 that never ends.
      failed: null,
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
    // Three things can end the upload early and each needs its own answer: the
    // Mac's socket failing (502), the agent stopping mid-body (an abort or a
    // dropped connection: nobody is left to answer, but the Mac must be told
    // to drop what it buffered) and the upload outrunning its deadline (408).
    // In every case the Mac gets a CANCEL, so a half-sent request never stays
    // in its buffer for the life of the socket.
    const toMac = (frame) => {
      try {
        mac.send(frame);
      } catch {
        throw new RelayError(502, "mac_disconnected", "the Mac dropped while this request was being sent");
      }
    };
    let reader = null;
    let uploadTimer = null;
    try {
      toMac(encodeFrame(FRAME.REQUEST, id, JSON.stringify({
        method: request.method,
        target: url.pathname + url.search,
        headers,
      })));
      if (request.body) {
        reader = request.body.getReader();
        const deadline = new Promise((_, reject) => {
          uploadTimer = setTimeout(() => {
            reject(new RelayError(408, "upload_timeout", `the request body did not finish arriving within ${this.limits.uploadTimeoutMs} ms`));
          }, this.limits.uploadTimeoutMs);
        });
        deadline.catch(() => {});
        let total = 0;
        for (;;) {
          let step;
          try {
            step = await Promise.race([reader.read(), deadline]);
          } catch (error) {
            if (error instanceof RelayError) throw error;
            throw new RelayError(400, "client_gone", "the request body ended before it was complete");
          }
          if (step.done) break;
          total += step.value.byteLength;
          if (total > this.limits.requestBody) {
            throw new RelayError(413, "payload_too_large", `request body over ${this.limits.requestBody} bytes`);
          }
          for (let off = 0; off < step.value.byteLength; off += this.limits.chunk) {
            toMac(encodeFrame(FRAME.BODY, id, step.value.subarray(off, Math.min(off + this.limits.chunk, step.value.byteLength))));
          }
        }
      }
      toMac(encodeFrame(FRAME.END, id));
    } catch (error) {
      clearTimeout(uploadTimer);
      if (reader) reader.cancel().catch(() => {});
      const relayError = error instanceof RelayError ? error : new RelayError(500, "relay_error", "the relay could not forward this request");
      this.cancel(id, relayError.code);
      return json(relayError.status, { error: relayError.code, message: relayError.message });
    }
    clearTimeout(uploadTimer);

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
    if (request.method === "HEAD" || BODYLESS_STATUS.has(head.status)) {
      this.finish(id);
      return new Response(null, { status: head.status, headers: responseHeaders });
    }
    // The body is an IdentityTransformStream, not a ReadableStream driven by a
    // controller: workerd pumps it natively, and aborting the writer ends the
    // agent's download cleanly, whereas controller.error() on a stream the agent
    // is reading leaves two unhandled rejections behind in this isolate.
    const hub = this;
    const { readable, writable } = new IdentityTransformStream();
    const writer = writable.getWriter();
    const sink = {
      enqueue(chunk) { writer.write(chunk).catch(() => {}); },
      close() { writer.close().catch(() => {}); },
      error(error) { writer.abort(error).catch(() => {}); },
    };
    // The agent going away surfaces here, as the writer's side failing; a
    // request this hub already finished (its own abort included) is left alone.
    writer.closed.then(() => {}, () => {
      if (hub.pending.get(id) === entry) hub.cancel(id, "client_gone");
    });
    if (entry.failed) {
      sink.error(entry.failed);
      this.finish(id);
    } else {
      entry.controller = sink;
      for (const chunk of entry.buffered) sink.enqueue(chunk);
      entry.buffered = [];
      if (entry.bodyDone) {
        sink.close();
        this.finish(id);
      } else {
        this.armIdle(id, entry);
      }
    }
    return new Response(readable, { status: head.status, headers: responseHeaders });
  }

  armIdle(id, entry) {
    clearTimeout(entry.idleTimer);
    entry.idleTimer = setTimeout(() => {
      this.fail(entry, "relay_timeout");
      this.cancel(id, "relay_timeout");
    }, this.limits.idleTimeoutMs);
  }

  /// Ends the agent's side of a request with `code`, whichever stage it is in:
  /// still waiting for the head, streaming, or between the two (RESPONSE
  /// accepted, stream not yet constructed), which is the window `failed` covers.
  fail(entry, code, status, message) {
    entry.rejectHead(new RelayError(status || 502, code, message || code));
    const error = new Error(code);
    if (entry.controller) {
      try { entry.controller.error(error); } catch { /* already closed */ }
    } else {
      entry.failed = error;
    }
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
      this.fail(entry, code, status, message);
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
        this.fail(entry, code, 502, text);
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
