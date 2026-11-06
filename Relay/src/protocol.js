// The wire protocol and limits shared by the Worker and its tests
// (docs/relay.md, and Sources/KeysCore/Relay.swift on the Mac). Kept out of
// worker.js because the Workers runtime accepts only handlers and Durable
// Object classes as named exports of the entry module.

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
  // How long a request that arrives while no Mac is connected waits for one,
  // counted from its arrival: long enough for the Mac to redial after a dropped
  // socket (1, 2, 4 … s) or a short sleep. RELAY_OFFLINE_GRACE_MS changes it
  // and 0 turns it off.
  offlineGraceMs: 60_000,
  // A longer wait would only hold requests nobody is waiting for: the Anthropic
  // and OpenAI SDKs give up on a request after ten minutes by default.
  maxOfflineGraceMs: 600_000,
  // The bodies of waiting requests sit in the Durable Object's memory, so they
  // are bounded together as well as one by one, like the Mac bounds its own
  // unfinished uploads.
  heldBytes: 32 * 1024 * 1024,
  // The Mac pings every 30 s. A socket it abandoned without closing (sleep, a
  // dropped network) stays open here until TCP gives up, so a socket that has
  // missed a ping is given no new request.
  macSilenceMs: 45_000,
  // Besides being woken by a connecting Mac, a waiting request looks again this
  // often, which is how it notices a silent socket that has resumed pinging.
  holdRecheckMs: 1_000,
});

// The doorbell (docs/relay.md, The doorbell): a second, low-privilege socket the
// Mac may keep open while its relay is off, which carries nothing but "an agent
// asks for the relay" and the Mac's answer. Both paths start with a dot, which
// no Keysrs key name can, so neither can shadow a key.
export const DOORBELL = Object.freeze({
  listenPath: "/.keysrs/doorbell/listen",
  ringPath: "/.keysrs/doorbell",
  keyPrefix: "ksfd_",
  // HMAC context for the doorbell key; DoorbellKey in
  // Sources/KeysCore/RelayDoorbell.swift uses the same bytes.
  keyContext: "keysrs relay doorbell v1",
  // How long a ringer waits for the Mac's answer by default, and at most
  // (`?wait=<seconds>`): long enough to walk to the Mac and touch the sensor.
  ringWaitMs: 60_000,
  maxRingWaitMs: 120_000,
  // One ring per caller address this often. The Worker checks no credential,
  // so a single spacing for everyone would let a stranger with a made-up token
  // hold it and keep every real agent out; per address, they hold only their
  // own. The Mac bounds what reaches it on top (4 at once, 30 a minute).
  ringIntervalMs: 10_000,
  // Addresses remembered for that spacing, at most; memory only, never stored.
  maxRingCallers: 1024,
});

// The two credentials a ring may carry, in the shape the Mac mints them
// (24 random bytes, lower-case hex). Anything else never reaches the Mac.
const CLIENT_TOKEN = /^ksfc_[0-9a-f]{48}$/;
const PAIRING = /^ksfp_[0-9a-f]{48}$/;

/// The client token and pairing a ring presents, read from the same headers the
/// gateway reads them from, and only as SHA-256 hex: the Mac stores both as
/// those hashes, so it can look them up, and the doorbell socket never carries
/// a credential someone who took over that socket could spend.
export async function ringCredentials(headers) {
  let client = null;
  const auth = (headers.get("authorization") || "").trim().split(/\s+/, 2);
  if (auth.length === 2 && auth[0].toLowerCase() === "bearer" && CLIENT_TOKEN.test(auth[1])) client = auth[1];
  if (!client) {
    for (const name of ["x-ksf-client", "x-api-key", "x-goog-api-key", "api-key"]) {
      const value = (headers.get(name) || "").trim();
      if (CLIENT_TOKEN.test(value)) {
        client = value;
        break;
      }
    }
  }
  const pairValue = (headers.get("x-ksf-pair") || "").trim();
  const pair = PAIRING.test(pairValue) ? pairValue : null;
  return {
    client: client ? await sha256Hex(client) : null,
    pair: pair ? await sha256Hex(pair) : null,
  };
}

export async function sha256Hex(text) {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8.encode(text))));
}

/// The doorbell key for a relay secret: `ksfd_` + HMAC-SHA256(secret, context)
/// in hex. The Worker derives it from RELAY_SECRET, so turning the doorbell on
/// needs no second Worker secret; the Mac derives it once, under Touch ID, and
/// keeps only it. It cannot be turned back into the relay secret.
export async function doorbellKey(secret) {
  if (typeof secret !== "string" || !secret) return "";
  const key = await crypto.subtle.importKey("raw", utf8.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, utf8.encode(DOORBELL.keyContext));
  return DOORBELL.keyPrefix + hex(new Uint8Array(mac));
}

function hex(bytes) {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

/// The limits a deployment runs with. The timeout knobs exist for the offline
/// test suite only; RELAY_OFFLINE_GRACE_MS is a real setting, where 0 means
/// "answer mac_offline at once" and anything above the cap is held to it.
export function limitsFrom(env) {
  const positive = (raw, fallback) => {
    const n = Number(raw);
    return Number.isInteger(n) && n > 0 ? n : fallback;
  };
  const grace = () => {
    const raw = env.RELAY_OFFLINE_GRACE_MS;
    if (raw === undefined || raw === null || String(raw).trim() === "") return LIMITS.offlineGraceMs;
    const n = Number(raw);
    if (!Number.isInteger(n) || n < 0) return LIMITS.offlineGraceMs;
    return Math.min(n, LIMITS.maxOfflineGraceMs);
  };
  return {
    ...LIMITS,
    uploadTimeoutMs: positive(env.RELAY_UPLOAD_TIMEOUT_MS, LIMITS.uploadTimeoutMs),
    headTimeoutMs: positive(env.RELAY_HEAD_TIMEOUT_MS, LIMITS.headTimeoutMs),
    idleTimeoutMs: positive(env.RELAY_IDLE_TIMEOUT_MS, LIMITS.idleTimeoutMs),
    offlineGraceMs: grace(),
  };
}

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
