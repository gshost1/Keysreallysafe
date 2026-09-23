#!/usr/bin/env node
// Issue a Keysrs license by hand (support cases, refunds re-issued, tests).
// The Ed25519 seed comes from the login Keychain item `keysrs.license-signing`
// unless --seed <base64> is given; the key format matches worker/index.js and
// Sources/KeysCore/License.swift.
//   node scripts/license-sign.mjs --email buyer@example.com [--id cs_...] [--iat 1700000000]
import { createPrivateKey, sign as edSign } from "node:crypto";
import { execFileSync } from "node:child_process";

const args = Object.fromEntries(process.argv.slice(2).map((a, i, all) => a.startsWith("--") ? [a.slice(2), all[i + 1]] : []).filter(Boolean));
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
