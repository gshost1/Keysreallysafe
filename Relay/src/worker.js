// The Keysrs relay Worker: a dumb pipe between a cloud agent and the gateway
// on the user's Mac. The Mac opens one WebSocket to /connect; every other
// request is framed over that socket and answered with whatever the Mac
// streams back, and a request that arrives while no Mac is connected waits a
// bounded while for one. No provider key, grant check or usage record lives
// here: docs/relay.md describes the protocol, the limits and the threat model,
// and this file must keep matching it.
//
// Logging discipline: nothing in this file logs headers or bodies. The only
// console output is a one-line note on an unexpected frame, without payload.

import { DurableObject } from "cloudflare:workers";
import { BODYLESS_STATUS, FRAME, PROTOCOL, STRIP_RESPONSE, decodeFrame, encodeFrame, limitsFrom, secretMatches, stripRequestHeader } from "./protocol.js";

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

// The Worker's own answers an agent may simply send again, and how long to wait
// first where a wait makes sense (docs/relay.md, the error table).
const RETRY_AFTER = { mac_offline: "30", relay_busy: "5" };
const RETRYABLE = new Set(["mac_offline", "relay_busy", "mac_disconnected"]);
const NO_MAC = "no Mac is connected to this relay: `keys relay` is not running, or the Mac is asleep or offline";

const MiB = 1024 * 1024;
const duration = (ms) => (ms % 1000 === 0 ? `${ms / 1000} s` : `${ms} ms`);
const size = (n) => (n % MiB === 0 ? `${n / MiB} MiB` : `${n} bytes`);

function refusal(status, code, message) {
  const body = { error: code, message };
  if (RETRYABLE.has(code)) body.retryable = true;
  return json(status, body, RETRY_AFTER[code] ? { "retry-after": RETRY_AFTER[code] } : undefined);
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
    /** @type {Map<number, object>} request id -> in-flight entry, waiting ones included */
    this.pending = new Map();
    /** Bytes of request body kept for requests that are waiting for a Mac. */
    this.heldBytes = 0;
    /** @type {Set<() => void>} wakes the requests waiting for a Mac */
    this.waiters = new Set();
    // Answered by the runtime without waking a hibernated object.
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/connect") return this.connect();
    return this.relay(request, url);
  }

  /// The Mac's socket: the most recently accepted one that is still open and
  /// that the Mac has shown itself on within the silence limit. A Mac that went
  /// to sleep or lost its network leaves its socket open here, and a request sent
  /// into it would hang until the Mac came back only to fail.
  mac() {
    const now = Date.now();
    let best = null;
    let bestAt = -1;
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState !== 1 /* OPEN */) continue;
      const at = ws.deserializeAttachment()?.connectedAt ?? 0;
      if (!this.heardRecently(ws, at, now)) continue;
      if (at > bestAt) {
        best = ws;
        bestAt = at;
      }
    }
    return best;
  }

  /// Whether the Mac has shown itself on `ws` within the silence limit, by its
  /// last keepalive ping (the auto-response records when it answered one,
  /// without waking this object) or by the connect itself. A runtime that
  /// cannot say is trusted, as every socket was before this check.
  heardRecently(ws, connectedAt, now) {
    if (typeof this.ctx.getWebSocketAutoResponseTimestamp !== "function") return true;
    const pinged = this.ctx.getWebSocketAutoResponseTimestamp(ws);
    return now - Math.max(connectedAt, pinged ? pinged.getTime() : 0) <= this.limits.macSilenceMs;
  }

  /// A Mac to send a waiting request to, as soon as one is connected and
  /// alive, or null once `until` has passed. A connecting Mac wakes every
  /// waiting request at once.
  async awaitMac(until) {
    for (;;) {
      const mac = this.mac();
      if (mac) return mac;
      const left = until - Date.now();
      if (left <= 0) return null;
      await new Promise((resolve) => {
        let timer = null;
        const wake = () => {
          clearTimeout(timer);
          this.waiters.delete(wake);
          resolve();
        };
        timer = setTimeout(wake, Math.min(left, this.limits.holdRecheckMs));
        this.waiters.add(wake);
      });
    }
  }

  connect() {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    // One Mac per relay: a reconnecting Mac must not wait for a stale socket
    // to time out, so the newcomer wins and the old socket is told why.
    for (const old of this.ctx.getWebSockets()) {
      this.failAll(old, 502, "mac_disconnected", "the Mac reconnected while this request was in flight; it may be retried");
      try { old.close(4000, "replaced"); } catch { /* already gone */ }
    }
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ connectedAt: Date.now() });
    // The requests that arrived while no Mac was here go to this one.
    for (const wake of [...this.waiters]) wake();
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
    const arrived = Date.now();
    const mac = this.mac();
    if (!mac && this.limits.offlineGraceMs === 0) return refusal(503, "mac_offline", NO_MAC);
    // A request waiting for a Mac holds its slot like one in flight, so the
    // wait cannot grow into an unbounded queue.
    if (this.pending.size >= this.limits.inflight) {
      return refusal(503, "relay_busy", `${this.limits.inflight} requests are already in flight or waiting for the Mac`);
    }
    const declared = Number(request.headers.get("content-length"));
    if (Number.isFinite(declared) && declared > this.limits.requestBody) {
      return refusal(413, "payload_too_large", `request body over ${this.limits.requestBody} bytes`);
    }
    if (!mac && Number.isFinite(declared) && declared > this.limits.heldBytes - this.heldBytes) {
      return refusal(503, "relay_busy", this.holdFullMessage());
    }

    const id = this.allocId();
    const entry = {
      // null while the request waits for a Mac; its body is then kept in
      // `upload` and sent whole once one connects.
      ws: mac,
      upload: mac ? null : [],
      heldBytes: 0,
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
    // in its buffer for the life of the socket. A request waiting for a Mac has
    // sent nothing yet; its deadline still runs from arrival, and when no Mac
    // comes within the grace window the answer is 503.
    const requestFrame = encodeFrame(FRAME.REQUEST, id, JSON.stringify({
      method: request.method,
      target: url.pathname + url.search,
      headers,
    }));
    const toMac = (frame) => {
      try {
        entry.ws.send(frame);
      } catch {
        throw new RelayError(502, "mac_disconnected", "the Mac dropped while this request was being sent; it may be retried");
      }
    };
    const bodyToMac = (bytes) => {
      for (let off = 0; off < bytes.byteLength; off += this.limits.chunk) {
        toMac(encodeFrame(FRAME.BODY, id, bytes.subarray(off, Math.min(off + this.limits.chunk, bytes.byteLength))));
      }
    };
    let reader = null;
    let uploadTimer = null;
    try {
      if (entry.ws) toMac(requestFrame);
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
          if (entry.ws) bodyToMac(step.value);
          else this.hold(entry, step.value);
        }
      }
      clearTimeout(uploadTimer);
      if (!entry.ws) {
        // The whole body is here; what is missing is a Mac to give it to. It
        // goes over in one piece, so the Mac never buffers it half-finished.
        entry.ws = await this.awaitMac(arrived + this.limits.offlineGraceMs);
        if (!entry.ws) {
          throw new RelayError(503, "mac_offline", `no Mac connected to this relay within ${duration(this.limits.offlineGraceMs)}: \`keys relay\` is not running, or the Mac is asleep or offline`);
        }
        toMac(requestFrame);
        for (const chunk of entry.upload) bodyToMac(chunk);
        this.release(entry);
      }
      toMac(encodeFrame(FRAME.END, id));
    } catch (error) {
      clearTimeout(uploadTimer);
      if (reader) reader.cancel().catch(() => {});
      const relayError = error instanceof RelayError ? error : new RelayError(500, "relay_error", "the relay could not forward this request");
      this.cancel(id, relayError.code);
      return refusal(relayError.status, relayError.code, relayError.message);
    }

    entry.headTimer = setTimeout(() => {
      entry.rejectHead(new RelayError(504, "relay_timeout", `the Mac sent no response within ${this.limits.headTimeoutMs} ms`));
    }, this.limits.headTimeoutMs);
    let head;
    try {
      head = await entry.head;
    } catch (error) {
      this.cancel(id, error.code || "error");
      if (error instanceof RelayError) return refusal(error.status, error.code, error.message);
      return refusal(502, "mac_disconnected", "the Mac dropped while this request was in flight; it may be retried");
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

  /// Tells the Mac to drop the request and forgets it here. A request still
  /// waiting for a Mac has nothing on any Mac to drop.
  cancel(id, reason) {
    const entry = this.pending.get(id);
    if (!entry) return;
    if (entry.ws) {
      try { entry.ws.send(encodeFrame(FRAME.CANCEL, id, JSON.stringify({ reason }))); } catch { /* socket gone */ }
    }
    this.finish(id);
  }

  finish(id) {
    const entry = this.pending.get(id);
    if (!entry) return;
    clearTimeout(entry.headTimer);
    clearTimeout(entry.idleTimer);
    this.release(entry);
    this.pending.delete(id);
  }

  /// Keeps a chunk of a waiting request's body, within the budget every waiting
  /// request shares.
  hold(entry, chunk) {
    if (this.heldBytes + chunk.byteLength > this.limits.heldBytes) {
      throw new RelayError(503, "relay_busy", this.holdFullMessage());
    }
    entry.upload.push(chunk);
    entry.heldBytes += chunk.byteLength;
    this.heldBytes += chunk.byteLength;
  }

  /// Returns a request's kept body to the shared budget: sent, or given up on.
  release(entry) {
    this.heldBytes -= entry.heldBytes;
    entry.heldBytes = 0;
    entry.upload = null;
  }

  holdFullMessage() {
    return `the relay is already keeping ${size(this.limits.heldBytes)} of request bodies until the Mac is back`;
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
    this.failAll(ws, 502, "mac_disconnected", "the Mac dropped while this request was in flight; it may be retried");
  }

  webSocketError(ws) {
    this.failAll(ws, 502, "mac_disconnected", "the Mac's connection failed while this request was in flight; it may be retried");
  }
}
