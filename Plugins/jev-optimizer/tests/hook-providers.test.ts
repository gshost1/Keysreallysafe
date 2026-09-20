import { describe, expect, it } from 'vitest';
import { validScopedEndpoint } from '../src/request.js';
import { getScopedConnection, jevAsker } from '../hooks/vercel-compaction.js';

const grant = `ksf_1234abcd_${'A'.repeat(43)}`;
const directURL = 'http://127.0.0.1:12767/direct-key/v1/systemone';

describe('reviewed TypeSafe hook protocol', () => {
  it('pairs scoped protocol and exact local endpoint; mismatches never fall back to saved settings', async () => {
    expect(validScopedEndpoint('typesafe', directURL)).toBe(true);
    for (const endpoint of [directURL + '?x=1', directURL + '/extra', directURL.replace('127.0.0.1', 'localhost'),
      directURL.replace('12767', '443'), directURL.replace('/v1/systemone', '/v4/ai/evaluation-model')]) {
      expect(validScopedEndpoint('typesafe', endpoint)).toBe(false);
    }
    const env: Record<string, string> = { KEYS_JEV_SCOPED_GRANT: '1', KEYS_JEV_PROVIDER: 'typesafe',
      AI_GATEWAY_API_KEY: grant, AI_GATEWAY_BASE_URL: directURL };
    const host = { env: { get: async (name: string) => env[name] } };
    expect(await getScopedConnection(host)).toEqual({ apiKey: grant, baseUrl: directURL, provider: 'typesafe' });
    env.KEYS_JEV_PROVIDER = 'vercel-ai-gateway';
    await expect(getScopedConnection(host)).rejects.toThrow(/local Keys/);
    env.KEYS_JEV_PROVIDER = 'unreviewed';
    await expect(getScopedConnection(host)).rejects.toThrow(/Unsupported/);
  });

  it('adapts the Claude hook transport and parses direct usage', async () => {
    const asker = jevAsker(async (url, init) => {
      expect(url).toBe(directURL);
      expect(JSON.parse(init!.body!).questions.q.type).toBe('noul');
      expect(init!.headers!['ai-model-id']).toBeUndefined();
      return { status: 200, ok: true, text: '{"answers":{"q":{"type":"noul","noul":0.8}},"usage":{"input_tokens":100,"output_tokens":0}}' };
    }, grant, 'jev-latest', directURL, 'typesafe');
    expect(await asker.ask('fixture', { q: { type: 'noul', instructions: 'keep?' } }))
      .toEqual({ answers: { q: { type: 'noul', noul: 0.8 } }, usage: { input_tokens: 100, output_tokens: 0 } });
  });
});
