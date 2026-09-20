import type { CallAnswer, JevAsker, JevQuestions, JevState } from './types.js';

const MAX_ENTRIES = 32;
const MAX_KEY_CHARS = 1_000_000;
const MAX_ENTRY_CHARS = 250_000;
const TTL_MS = 5 * 60_000;
type Entry = { answers: Map<string, CallAnswer>; expires: number };
// Instance identity scopes this cache to one immutable model/endpoint/credential transport.
// No transcript or decision is persisted, hashed into telemetry, or shared across sessions.
const caches = new WeakMap<JevAsker, Map<string, Entry>>();

export function decisionCacheKey(state: JevState, questions: JevQuestions): string {
  return JSON.stringify({ state, questions });
}

export function readDecisionCache(asker: JevAsker, key: string): Map<string, CallAnswer> | undefined {
  const cache = caches.get(asker);
  if (!cache) return undefined;
  for (const [oldKey, entry] of cache) if (entry.expires <= Date.now()) cache.delete(oldKey);
  const entry = cache.get(key);
  if (!entry) return undefined;
  cache.delete(key);
  cache.set(key, entry);
  return entry.answers;
}

export function writeDecisionCache(asker: JevAsker, key: string, answers: Map<string, CallAnswer>): void {
  if (key.length > MAX_ENTRY_CHARS) return;
  const cache = caches.get(asker) ?? new Map<string, Entry>();
  cache.delete(key);
  cache.set(key, { answers, expires: Date.now() + TTL_MS });
  let size = Array.from(cache.keys()).reduce((sum, item) => sum + item.length, 0);
  while (cache.size > MAX_ENTRIES || size > MAX_KEY_CHARS) {
    const oldest = cache.keys().next().value as string;
    size -= oldest.length;
    cache.delete(oldest);
  }
  caches.set(asker, cache);
}
