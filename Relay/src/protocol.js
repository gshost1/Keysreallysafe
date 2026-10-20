// The wire protocol shared by the Worker and its tests (docs/relay.md, and
// Sources/KeysCore/Relay.swift on the Mac). Kept out of worker.js because the
// Workers runtime accepts only handlers and Durable Object classes as named
// exports of the entry module.

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
  // An in-flight slot is taken before the body arrives, so the upload itself
  // needs a deadline or a few slow senders hold every slot.
  uploadTimeoutMs: 60_000,
  // Longer than the gateway's own 30 s connect + 900 s request limit, so a
  // slow non-streaming generation ends with the gateway's answer, not ours.
  headTimeoutMs: 960_000,
  idleTimeoutMs: 300_000,
});

// Statuses whose response has no body (RFC 9110 §15.3.5, §15.3.6, §15.4.5);
// the Response constructor throws when given a stream for one of them. 1xx
// never reaches here: the Mac's head is refused below 200.
export const BODYLESS_STATUS = new Set([204, 205, 304]);

// Hop-by-hop headers, the ones the Mac rewrites, and the ones Cloudflare adds
// about the agent's connection. Repeated on the Mac in case a Worker is ever
// replaced by something less careful.
const STRIP_REQUEST = new Set([
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
  "trailers", "transfer-encoding", "upgrade", "host", "content-length",
  "x-ksf-via", "x-real-ip", "cdn-loop", "true-client-ip",
]);

export const STRIP_RESPONSE = new Set([
  "connection", "keep-alive", "transfer-encoding", "content-length", "upgrade", "trailers", "te",
]);

export function stripRequestHeader(name) {
  const n = name.toLowerCase();
  return STRIP_REQUEST.has(n) || n.startsWith("cf-") || n.startsWith("x-forwarded-");
}

const utf8 = new TextEncoder();

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
