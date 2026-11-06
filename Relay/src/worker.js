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
import { BODYLESS_STATUS, DOORBELL, FRAME, PROTOCOL, STRIP_RESPONSE, decodeFrame, doorbellKey, encodeFrame, limitsFrom, ringCredentials, secretMatches, stripRequestHeader } from "./protocol.js";

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
const RETRY_AFTER = { mac_offline: "30", relay_busy: "5", doorbell_offline: "60", doorbell_busy: "10", doorbell_mac_locked: "300" };
const RETRYABLE = new Set([
  "mac_offline", "relay_busy", "mac_disconnected",
  "doorbell_offline", "doorbell_busy", "doorbell_mac_locked", "doorbell_not_now", "doorbell_unavailable",
]);
// The Mac's pairing refusals are the agent's to fix on the Mac (pair, renew,
// re-scope), so the agent hears 403 rather than the 502 every other Mac error
// gets (docs/relay.md, the pairing section). They are not in RETRYABLE or
// RETRY_AFTER: resending the identical request cannot change the answer.
const MAC_ERROR_STATUS = Object.freeze({
  pairing_required: 403,
  pairing_expired: 403,
  pairing_revoked: 403,
  pairing_out_of_scope: 403,
});
const NOT_RUNNING = "the Keysrs relay is off (Relay for Cloud Agents in its menu, or `keys relay on`) and `keys relay` is not running, or the Mac is asleep or offline";
const NO_MAC = `no Mac is connected to this relay: ${NOT_RUNNING}`;
const MAC_DROPPED = "the Mac dropped while this request was in flight; it may be retried";

const MiB = 1024 * 1024;
const duration = (ms) => (ms % 1000 === 0 ? `${ms / 1000} s` : `${ms} ms`);
const size = (n) => (n % MiB === 0 ? `${n / MiB} MiB` : `${n} bytes`);

function refusal(status, code, message, retryAfter) {
  const body = { error: code, message };
  if (RETRYABLE.has(code)) body.retryable = true;
  const wait = retryAfter ?? RETRY_AFTER[code];
  return json(status, body, wait ? { "retry-after": String(wait) } : undefined);
}

const NO_DOORBELL = "the Mac's doorbell is not connected: Keysrs is not running, its doorbell is off (keys relay doorbell on), or the Mac is asleep or offline";
const ASKING = "the Mac is asking for Touch ID; ring again in a while, or just call: a request waits up to a minute for the relay";

/// The Mac's answer to a ring as the ringer's response (docs/relay.md, The
/// doorbell). The Mac says only which case applies; the wording is the Worker's.
function ringAnswer(answer) {
  switch (answer.result) {
    case "on":
      return json(200, { relay: "on", message: "the relay is on; call https://<this worker>/<key name>/… as usual" });
    case "pending":
    case "timeout":
      return json(202, { relay: "off", state: "asking", message: ASKING, retryable: true }, { "retry-after": "15" });
    case "declined":
      return refusal(403, "doorbell_declined", "the person at the Mac declined to turn the relay on");
    case "refused":
      return refusal(403, "doorbell_refused", "the Mac does not know this client token or pairing as a live one, so it asked nobody");
    case "away":
      return refusal(503, "doorbell_mac_locked", "the Mac's screen is locked, so nobody is there to approve the relay");
    case "not_now": {
      const after = Number.isInteger(answer.retry_after) && answer.retry_after > 0 ? Math.min(answer.retry_after, 3600) : 600;
      return refusal(429, "doorbell_not_now", "the Mac asked recently and is not asking again yet", after);
    }
    case "unavailable":
      return refusal(503, "doorbell_unavailable", `the Mac could not turn the relay on${answer.message ? `: ${answer.message}` : ""}`);
    case "offline":
      return refusal(503, "doorbell_offline", NO_DOORBELL);
    default:
      return refusal(502, "doorbell_error", "the Mac answered the doorbell with something this Worker does not know");
  }
}

class RelayError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/// The Mac's verdict as the agent's answer. fail() stores it on the entry, so a
/// request the Mac refused carries the Mac's own status and code whatever the
/// body it was still uploading did next.
function macVerdict(entry) {
  const { status, code, message } = entry.refusal;
  return refusal(status, code, message);
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
    if (url.pathname === DOORBELL.listenPath) {
      if (request.method !== "GET") return json(405, { error: "method_not_allowed" }, { allow: "GET" });
      // The doorbell key is derived from the relay secret, so a Worker without
      // one has no doorbell either.
      const expected = await doorbellKey(env.RELAY_SECRET);
      if (!(await secretMatches(bearer(request), expected))) {
        return json(401, { error: "unauthorized" }, { "www-authenticate": 'Bearer realm="keysrs-relay"' });
      }
      if ((request.headers.get("upgrade") || "").toLowerCase() !== "websocket") {
        return json(426, { error: "upgrade_required", message: `${DOORBELL.listenPath} is the Mac's doorbell WebSocket endpoint` }, { upgrade: "websocket" });
      }
      if (request.headers.get("x-keysrs-relay-protocol") !== PROTOCOL) {
        return json(400, {
          error: "unsupported_protocol",
          message: `this Worker speaks relay protocol ${PROTOCOL}; update keys or redeploy the Worker from the same checkout`,
        });
      }
      return hub.fetch(new Request(url.origin + DOORBELL.listenPath, { headers: { upgrade: "websocket" } }));
    }
    if (url.pathname === DOORBELL.ringPath) {
      if (request.method !== "POST") return json(405, { error: "method_not_allowed" }, { allow: "POST" });
      // Only the hashes travel on: the Durable Object, and the Mac after it,
      // never hold the ringer's token.
      const credentials = await ringCredentials(request.headers);
      if (!credentials.client && !credentials.pair) {
        return refusal(401, "doorbell_credential_required", "ring with the client token (Authorization: Bearer ksfc_…) or the pairing (X-KSF-Pair: ksfp_…) this Mac gave you");
      }
      const wait = url.searchParams.get("wait");
      const ring = new URL(url.origin + DOORBELL.ringPath);
      if (wait !== null) ring.searchParams.set("wait", wait);
      return hub.fetch(new Request(ring, {
        method: "POST",
        headers: { "x-ring-client": credentials.client || "", "x-ring-pair": credentials.pair || "" },
      }));
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
    // In-flight slots taken. Each entry's slot has two holders, its relay()
    // call and the entry itself, and is given back when both have released it
    // (relay()'s finally and finish(); see relay() and docs/relay.md, limits
    // and timeouts).
    this.active = 0;
    /** Bytes of request body kept for requests that are waiting for a Mac. */
    this.heldBytes = 0;
    /** @type {Set<() => void>} wakes the requests waiting for a Mac */
    this.waiters = new Set();
    // The one ring waiting for the Mac's answer, and when the last ring was
    // sent to it (docs/relay.md, The doorbell). Memory only: a ring is an
    // open HTTP request, which keeps this object awake for as long as it waits.
    /** @type {{ id: string, ws: WebSocket, resolve: (answer: object) => void } | null} */
    this.ringing = null;
    this.lastRingAt = 0;
    // Answered by the runtime without waking a hibernated object.
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/connect") return this.connect();
    if (url.pathname === DOORBELL.listenPath) return this.listen();
    if (url.pathname === DOORBELL.ringPath) return this.ring(request, url);
    return this.relay(request, url);
  }

  /// The Mac's socket: the most recently accepted one that is still open and
  /// that the Mac has shown itself on within the silence limit. A Mac that went
  /// to sleep or lost its network leaves its socket open here, and a request sent
  /// into it would hang until the Mac came back only to fail.
  mac() {
    return this.newest("mac");
  }

  /// The Mac's doorbell socket, by the same rule as its relay socket.
  doorbell() {
    return this.newest("doorbell");
  }

  /// The most recently accepted open socket of one kind that has been heard
  /// from within the silence limit.
  newest(tag) {
    const now = Date.now();
    let best = null;
    let bestAt = -1;
    for (const ws of this.ctx.getWebSockets(tag)) {
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
    for (const old of this.ctx.getWebSockets("mac")) {
      this.failAll(old, 502, "mac_disconnected", "the Mac reconnected while this request was in flight; it may be retried");
      try { old.close(4000, "replaced"); } catch { /* already gone */ }
    }
    this.ctx.acceptWebSocket(server, ["mac"]);
    server.serializeAttachment({ connectedAt: Date.now(), kind: "mac" });
    // The requests that arrived while no Mac was here go to this one.
    for (const wake of [...this.waiters]) wake();
    // A ring waiting for the Mac's answer has its answer: the relay is here.
    this.ringing?.resolve({ result: "on" });
    return new Response(null, { status: 101, webSocket: client });
  }

  /// The Mac's doorbell socket. Like the relay, a newcomer replaces the old one.
  listen() {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    for (const old of this.ctx.getWebSockets("doorbell")) {
      if (this.ringing?.ws === old) this.ringing.resolve({ result: "offline" });
      try { old.close(4000, "replaced"); } catch { /* already gone */ }
    }
    this.ctx.acceptWebSocket(server, ["doorbell"]);
    server.serializeAttachment({ connectedAt: Date.now(), kind: "doorbell" });
    return new Response(null, { status: 101, webSocket: client });
  }

  /// One ring: sent to the Mac's doorbell, answered with the Mac's word, or
  /// with "asking" once the ringer's wait is over. The Mac decides everything
  /// about a ring; what this does is keep rings rare and one at a time.
  async ring(request, url) {
    if (this.mac()) return ringAnswer({ result: "on" });
    const bell = this.doorbell();
    if (!bell) return refusal(503, "doorbell_offline", NO_DOORBELL);
    if (this.ringing) return refusal(503, "doorbell_busy", "another ring is waiting for the Mac's answer");
    const now = Date.now();
    const since = now - this.lastRingAt;
    if (since < DOORBELL.ringIntervalMs) {
      return refusal(503, "doorbell_busy", "the Mac was rung moments ago", Math.ceil((DOORBELL.ringIntervalMs - since) / 1000));
    }
    let waitMs = DOORBELL.ringWaitMs;
    const asked = url.searchParams.get("wait");
    if (asked !== null && /^[0-9]{1,4}$/.test(asked)) waitMs = Math.min(Number(asked) * 1000, DOORBELL.maxRingWaitMs);

    const id = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
    let timer = null;
    const answered = new Promise((resolve) => {
      const ring = {
        id,
        ws: bell,
        resolve: (answer) => {
          if (this.ringing === ring) this.ringing = null;
          clearTimeout(timer);
          resolve(answer);
        },
      };
      this.ringing = ring;
      timer = setTimeout(() => ring.resolve({ result: "timeout" }), waitMs);
    });
    this.lastRingAt = now;
    try {
      bell.send(JSON.stringify({
        type: "ring",
        id,
        client: request.headers.get("x-ring-client") || null,
        pair: request.headers.get("x-ring-pair") || null,
      }));
    } catch {
      this.ringing?.resolve({ result: "offline" });
    }
    return ringAnswer(await answered);
  }

  allocId() {
    const buf = new Uint32Array(1);
    for (;;) {
      crypto.getRandomValues(buf);
      const id = buf[0];
      if (id !== 0 && !this.pending.has(id)) return id;
    }
  }

  /// One request, from arrival to its answer. Its in-flight slot is taken when
  /// forward() creates the entry and has two holders: this call, until it has
  /// chosen the agent's answer, and the entry, until finish() forgets it. The
  /// slot goes back when both have let go, so a refused body still being
  /// drained and a response still streaming both count (docs/relay.md, limits
  /// and timeouts).
  async relay(request, url) {
    const ticket = { entry: null };
    try {
      return await this.forward(request, url, ticket);
    } finally {
      if (ticket.entry) this.releaseSlot(ticket.entry);
    }
  }

  releaseSlot(entry) {
    entry.slotHolders -= 1;
    if (entry.slotHolders === 0) this.active -= 1;
  }

  /// The rest of relay(): the body in, END sent, then the head waited for and
  /// the answer built.
  async forward(request, url, ticket) {
    const arrived = Date.now();
    const mac = this.mac();
    if (!mac && this.limits.offlineGraceMs === 0) return refusal(503, "mac_offline", NO_MAC);
    // A request waiting for a Mac holds its slot like one in flight, so the
    // wait cannot grow into an unbounded queue.
    if (this.active >= this.limits.inflight) {
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
      id,
      // The Mac's verdict, kept after it forgets the entry: forward() may
      // still be reading the agent's body when it arrives, and that body must
      // not replace it with a timeout or an abort.
      refusal: null,
      // null while the request waits for a Mac; its body is then kept in
      // `upload` and sent whole once one connects.
      ws: mac,
      upload: mac ? null : [],
      heldBytes: 0,
      controller: null,
      buffered: [],
      bodyDone: false,
      // Set when the Mac's RESPONSE head is accepted: from then on an ERROR
      // reaches the agent through the stream, so fail() stores no verdict.
      headResolved: false,
      // relay() and the entry itself; see relay().
      slotHolders: 2,
      // Set when the Mac fails the request after RESPONSE was accepted but
      // before the stream exists; start() then errors the stream instead of
      // leaving the agent with a 200 that never ends.
      failed: null,
      // The error failAll() ended the request with when the Mac's socket
      // dropped or was replaced; the upload loop answers with it at once.
      dropped: null,
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
    // The slot is taken only now, with nothing left that can throw before the
    // try below, whose every exit reaches finish().
    this.pending.set(id, entry);
    this.active += 1;
    ticket.entry = entry;
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
        // The Mac can refuse a request at REQUEST time, before any of its body
        // is buffered, and finish() then drops the entry while this loop is
        // still reading. From then on the body is drained, not forwarded and
        // not cancelled: an HTTP/1.1 client writes its whole body before it
        // reads the answer, and a reader cancelled underneath it turns the
        // Mac's refusal into a connection reset. The Mac's verdict answers.
        //
        // The drain keeps a forwarded body's bounds. Past the body limit or
        // the upload deadline, or once the agent aborts, the body is not read
        // any further, as for any request, and the verdict still answers.
        const abandonBody = () => {
          reader.cancel().catch(() => {});
          return macVerdict(entry);
        };
        try {
          for (;;) {
            let step;
            try {
              // The refusal is checked between reads rather than raced
              // against, so a long body leaves no reaction per chunk on a
              // promise that only settles when the entry ends.
              step = await Promise.race([reader.read(), deadline]);
            } catch (error) {
              // The Mac's verdict outranks the body's own fate: a body that
              // aborts, or overruns its deadline, after the refusal is still
              // answered with the Mac's word.
              if (entry.refusal) return abandonBody();
              if (error instanceof RelayError) throw error;
              throw new RelayError(400, "client_gone", "the request body ended before it was complete");
            }
            // A dropped or replaced socket fails the upload now, whether or not
            // a send into it would have thrown.
            if (entry.dropped) throw entry.dropped;
            if (step.done) break;
            total += step.value.byteLength;
            if (total > this.limits.requestBody) {
              if (entry.refusal) return abandonBody();
              throw new RelayError(413, "payload_too_large", `request body over ${this.limits.requestBody} bytes`);
            }
            if (entry.refusal) continue;
            if (entry.ws) bodyToMac(step.value);
            else this.hold(entry, step.value);
          }
        } finally {
          clearTimeout(uploadTimer);
        }
        if (entry.refusal) return macVerdict(entry);
      }
      if (!entry.ws) {
        // The whole body is here; what is missing is a Mac to give it to. It
        // goes over in one piece, so the Mac never buffers it half-finished.
        entry.ws = await this.awaitMac(arrived + this.limits.offlineGraceMs);
        if (!entry.ws) {
          throw new RelayError(503, "mac_offline", `no Mac connected to this relay within ${duration(this.limits.offlineGraceMs)}: ${NOT_RUNNING}`);
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
      if (this.pending.get(id) === entry) this.cancel(id, relayError.code);
      return refusal(relayError.status, relayError.code, relayError.message);
    }

    entry.headTimer = setTimeout(() => {
      entry.rejectHead(new RelayError(504, "relay_timeout", `the Mac sent no response within ${this.limits.headTimeoutMs} ms`));
    }, this.limits.headTimeoutMs);
    let head;
    try {
      head = await entry.head;
    } catch (error) {
      // An entry the Mac already ended is gone from `pending`, so this asks
      // for a CANCEL only for one still in it.
      if (this.pending.get(id) === entry) this.cancel(id, error.code || "error");
      if (error instanceof RelayError) return refusal(error.status, error.code, error.message);
      return refusal(502, "mac_disconnected", MAC_DROPPED);
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
  fail(entry, code, status, message, verdict = false) {
    const error = new RelayError(status || 502, code, message || code);
    // A Mac ERROR (`verdict`) is kept on the entry as well, because the frame
    // that sees it may not be the one that answers: a request still uploading
    // its body is inside forward() when it lands, and forward() must answer
    // with it rather than with whatever its body did next. A dropped socket is
    // not a verdict: the next send fails at once and the agent can retry.
    // Once a head is accepted the stream is the answer, so nothing is stored.
    if (verdict && !entry.headResolved) entry.refusal = { status: error.status, code, message: error.message };
    entry.rejectHead(error);
    const streamError = new Error(code);
    if (entry.controller) {
      try { entry.controller.error(streamError); } catch { /* already closed */ }
    } else {
      entry.failed = streamError;
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
    // The id is forgotten here, but forward() may still be draining the
    // agent's body; it has the verdict on the entry, and the slot stays taken
    // until relay() has answered too.
    this.pending.delete(id);
    this.releaseSlot(entry);
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
      entry.dropped = new RelayError(status, code, message);
      this.fail(entry, code, status, message);
      this.finish(id);
    }
  }

  webSocketMessage(ws, message) {
    if (ws.deserializeAttachment()?.kind === "doorbell") {
      this.doorbellMessage(ws, message);
      return;
    }
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
        entry.headResolved = true;
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
        this.fail(entry, code, MAC_ERROR_STATUS[code] ?? 502, text, true);
        this.finish(frame.id);
        return;
      }
      default:
        console.warn(`relay: unexpected frame type ${frame.type} from the Mac`);
    }
  }

  /// The doorbell speaks text: the keepalive and the Mac's JSON answers. A
  /// binary frame, or an answer to a ring that is not waiting, is ignored or
  /// closes the socket; it can never reach a ringer it was not meant for.
  doorbellMessage(ws, message) {
    if (typeof message !== "string") {
      ws.close(1003, "binary frames are not part of the doorbell");
      return;
    }
    if (message === "ping") {
      try { ws.send("pong"); } catch { /* closing */ }
      return;
    }
    let answer;
    try {
      answer = message.length <= 2048 ? JSON.parse(message) : null;
    } catch {
      answer = null;
    }
    if (!answer || answer.type !== "answer" || typeof answer.id !== "string") return;
    const ring = this.ringing;
    if (!ring || ring.ws !== ws || ring.id !== answer.id) return;
    ring.resolve({
      result: typeof answer.result === "string" ? answer.result : "",
      retry_after: answer.retry_after,
      message: typeof answer.message === "string" && answer.message.length <= 512 ? answer.message : "",
    });
  }

  webSocketClose(ws) {
    if (this.ringing?.ws === ws) this.ringing.resolve({ result: "offline" });
    this.failAll(ws, 502, "mac_disconnected", MAC_DROPPED);
  }

  webSocketError(ws) {
    if (this.ringing?.ws === ws) this.ringing.resolve({ result: "offline" });
    this.failAll(ws, 502, "mac_disconnected", "the Mac's connection failed while this request was in flight; it may be retried");
  }
}
