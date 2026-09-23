#!/usr/bin/env node
// Issue a Keysrs license by hand (support cases, refunds re-issued, tests).
// The Ed25519 seed comes from the login Keychain item `keysrs.license-signing`
// unless --seed <base64> is given; the key format matches worker/index.js and
// Sources/KeysCore/License.swift.
//   node scripts/license-sign.mjs --email buyer@example.com [--id cs_...] [--iat 1700000000]
import { createPrivateKey, sign as edSign } from "node:crypto";
import { execFileSync } from "node:child_process";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) {
  const flag = process.argv[i], value = process.argv[i + 1];
  if (!/^--(email|id|iat|seed)$/.test(flag) || value === undefined || value.startsWith("--")) {
    console.error(`bad or valueless flag: ${flag}`); process.exit(2);
  }
  args[flag.slice(2)] = value;
}
if (args.iat !== undefined && !/^\d+$/.test(args.iat)) { console.error("--iat must be unix seconds"); process.exit(2); }
if (!args.email || !args.email.includes("@")) { console.error("usage: --email <address> [--id <id>] [--iat <unix seconds>] [--seed <base64>]"); process.exit(2); }
const seedB64 = args.seed || execFileSync("security", ["find-generic-password", "-s", "keysrs.license-signing", "-a", "ed25519", "-w"]).toString().trim();
const seed = Buffer.from(seedB64, "base64");
if (seed.length !== 32) { console.error("seed must be 32 bytes"); process.exit(2); }
const key = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]), format: "der", type: "pkcs8" });
const payload = { email: args.email, iat: Number(args.iat || Math.floor(Date.now() / 1000)), id: args.id || `manual_${Date.now().toString(36)}`, major: 1, v: 1 };
const b64url = (b) => Buffer.from(b).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const payloadPart = b64url(JSON.stringify(payload));
const sig = edSign(null, Buffer.from(`keysrs1.${payloadPart}`), key);
process.stdout.write(`keysrs1.${payloadPart}.${b64url(sig)}\n`);
