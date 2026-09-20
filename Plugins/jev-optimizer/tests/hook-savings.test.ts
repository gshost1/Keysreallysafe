import { describe, expect, it, vi } from 'vitest';
import { register, getScopedConnection } from '../hooks/vercel-compaction.ts';
import type { Message } from '../src/types.js';

const transcript: Message[] = [
  { role: 'user', text: 'Find the bug.', toolUses: [] },
  { role: 'assistant', text: '', toolUses: [{ tool_use_id: 'r1', tool: 'Read', input: { file_path: 'src/old.ts' }, text: 'x'.repeat(10_000) }] },
  { role: 'user', text: '', toolUses: [], toolResults: [{ tool_use_id: 'r1', text: 'x'.repeat(10_000) }] },
  { role: 'user', text: 'Continue.', toolUses: [] },
];

type Handler = ($: any, event: any, next: any) => Promise<any>;
function harness(options: Record<string, unknown> = {}, env: Record<string, string | undefined> = {}) {
  const handlers = new Map<string, Handler>();
  register(((name: string, handler: Handler) => handlers.set(name, handler)) as any, { preserveRecentMessages: 1, ...options });
  const state = { tokens: 70_000, percent: 70 };
  const fallback = vi.fn(async () => ({ messages: [{ role: 'assistant', text: 'built-in summary', toolUses: [] }] }));
  const fetch = vi.fn(async (_url: string, init: { body: string }) => {
    const { questions } = JSON.parse(init.body);
    return { status: 200, ok: true, text: JSON.stringify({ answers: Object.fromEntries(Object.keys(questions).map((key) => [key, { type: 'boolean', probability: 0.1 }])), usage: { inputTokens: 250, outputTokens: 0 } }) };
  });
  const $ = {
    env: { get: async (name: string) => env[name] },
    settings: { read: async () => ({}) },
    http: { fetch },
    ui: { log: vi.fn(), toast: vi.fn() },
    session: {
      usage: vi.fn(async () => ({ context: { ...state, window: 100_000 } })),
      compact: vi.fn(async () => handlers.get('session.compact')!($, { trigger: 'plugin', messages: transcript }, fallback)),
    },
  };
  return {
    $, state, fetch, fallback,
    compact: (event: Record<string, unknown> = {}) => handlers.get('session.compact')!($, { trigger: 'manual', messages: transcript, ...event }, fallback),
    turn: (event: Record<string, unknown> = {}) => handlers.get('turn.complete')!($, { reason: 'answer', ...event }, vi.fn(async () => ({ text: 'done' }))),
  };
}

describe('automatic growth gate and observe mode', () => {
  it('waits for 8k new context tokens after each attempt, including after context shrinks', async () => {
    const host = harness({ apiKey: 'key', mode: 'observe' });
    await host.turn();
    await host.turn();
    host.state.tokens = 77_999;
    await host.turn();
    expect(host.$.session.compact).toHaveBeenCalledTimes(1);
    host.state.tokens = 78_000;
    await host.turn();
    expect(host.$.session.compact).toHaveBeenCalledTimes(2);
    host.state.tokens = 10_000;
    await host.turn();
    host.state.tokens = 17_999;
    await host.turn();
    expect(host.$.session.compact).toHaveBeenCalledTimes(2);
    host.state.tokens = 18_000;
    await host.turn();
    expect(host.$.session.compact).toHaveBeenCalledTimes(3);
  });

  it('observes early attempts without replacing messages, but manual compaction still works', async () => {
    const host = harness({ apiKey: 'key', mode: 'observe' });
    await host.turn();
    expect(host.fallback).not.toHaveBeenCalled();
    expect(await host.$.session.compact.mock.results[0]!.value).toEqual({ skip: 'Jev observe mode leaves the transcript unchanged' });
    expect(host.$.ui.log.mock.calls.flat().join(' ')).toContain('observe only');
    await host.compact();
    expect(host.fallback).toHaveBeenCalledTimes(1);
    expect(host.fetch).toHaveBeenCalledTimes(1); // manual repeat used the exact session-local cache
  });

  it('does not observe/prune by triggering the main session from subagent or interrupted turns', async () => {
    const host = harness({ apiKey: 'key' });
    await host.turn({ agentId: 'worker' });
    await host.turn({ reason: 'aborted' });
    expect(host.$.session.compact).not.toHaveBeenCalled();
  });

  it('skips tiny early attempts without paying for Jev or a built-in summary', async () => {
    const host = harness({ apiKey: 'key', minRemovableChars: 50_000 });
    await host.turn();
    expect(host.fetch).not.toHaveBeenCalled();
    expect(host.fallback).not.toHaveBeenCalled();
    expect(await host.$.session.compact.mock.results[0]!.value).toEqual({ skip: 'Jev preflight: below_minimum' });
  });

  it('preserves manual instructions by delegating to the built-in summarizer immediately', async () => {
    const host = harness({ apiKey: 'key' });
    await host.compact({ instructions: 'Focus on the failing tests.' });
    expect(host.fetch).not.toHaveBeenCalled();
    expect(host.fallback).toHaveBeenCalledTimes(1);
  });

  it('falls back on invalid answers without installing a partial result', async () => {
    const host = harness({ apiKey: 'key' });
    host.fetch.mockResolvedValueOnce({ status: 200, ok: true, text: '{"answers":{}}' });
    const output = await host.compact();
    expect(output.messages[0].text).toBe('built-in summary');
    expect(host.fallback).toHaveBeenCalledTimes(1);
  });

  it('keeps an observation unchanged when evaluation fails', async () => {
    const host = harness({ apiKey: 'key', mode: 'observe' });
    host.fetch.mockResolvedValueOnce({ status: 500, ok: false, text: 'sensitive request echo' });
    await host.turn();
    expect(host.fallback).not.toHaveBeenCalled();
    expect(host.$.ui.log.mock.calls.flat().join(' ')).not.toContain('sensitive request echo');
  });
});

describe('Keys scoped grants', () => {
  const baseUrl = 'http://127.0.0.1:12767/my.vercel-key/v4/ai/evaluation-model';
  const grant = `ksf_1234abcd_${'A'.repeat(43)}`;
  const rotatedGrant = `ksf_4321dcba_${'B'.repeat(43)}`;
  it('uses the paired scoped environment over conflicting saved upstream credentials and endpoint', async () => {
    const env = { KEYS_JEV_SCOPED_GRANT: '1', AI_GATEWAY_API_KEY: grant, AI_GATEWAY_BASE_URL: baseUrl };
    const host = harness({ apiKey: 'saved-upstream-secret', baseUrl: 'https://elsewhere.example/v4/ai/evaluation-model' }, env);
    await host.compact();
    expect(host.fetch).toHaveBeenCalledTimes(1);
    expect(host.fetch.mock.calls[0]![0]).toBe(baseUrl);
    expect((host.fetch.mock.calls[0]![1] as any).headers.authorization).toBe(`Bearer ${grant}`);
    env.AI_GATEWAY_API_KEY = rotatedGrant;
    await host.compact();
    expect(host.fetch).toHaveBeenCalledTimes(2); // rotation invalidates the old grant's decision cache
    expect((host.fetch.mock.calls[1]![1] as any).headers.authorization).toBe(`Bearer ${rotatedGrant}`);
  });

  it.each([
    { AI_GATEWAY_API_KEY: grant },
    { AI_GATEWAY_BASE_URL: baseUrl },
    { AI_GATEWAY_API_KEY: grant, AI_GATEWAY_BASE_URL: 'https://external.example/key/v4/ai/evaluation-model' },
    { AI_GATEWAY_API_KEY: grant, AI_GATEWAY_BASE_URL: 'http://localhost:12767/key/v4/ai/evaluation-model' },
    { AI_GATEWAY_API_KEY: grant, AI_GATEWAY_BASE_URL: `${baseUrl}?proxy=elsewhere` },
  ])('fails closed rather than mixing a scoped grant with saved settings: %j', async (values) => {
    const host = harness({ apiKey: 'saved', baseUrl: 'https://external.example' }, { KEYS_JEV_SCOPED_GRANT: '1', ...values });
    await host.compact();
    expect(host.fetch).not.toHaveBeenCalled();
    expect(host.fallback).toHaveBeenCalledTimes(1);
  });

  it('preserves standalone config precedence without the Keys marker', async () => {
    const host = harness({ apiKey: 'configured', baseUrl: 'https://configured.example/evaluate' }, { AI_GATEWAY_API_KEY: 'env-key', AI_GATEWAY_BASE_URL: baseUrl });
    await host.compact();
    expect(host.fetch.mock.calls[0]![0]).toBe('https://configured.example/evaluate');
    expect((host.fetch.mock.calls[0]![1] as any).headers.authorization).toBe('Bearer configured');
    expect(await getScopedConnection(host.$)).toBeUndefined();
  });

  it('uses the direct scoped model and protocol even with conflicting saved Vercel settings', async () => {
    const directURL = 'http://127.0.0.1:12767/direct/v1/systemone';
    const host = harness({ apiKey: 'saved', model: 'saved-vercel-model', baseUrl: 'https://external.example' }, {
      KEYS_JEV_SCOPED_GRANT: '1', KEYS_JEV_PROVIDER: 'typesafe', AI_GATEWAY_API_KEY: grant, AI_GATEWAY_BASE_URL: directURL,
    });
    host.fetch.mockImplementation(async (_url, init) => {
      const body = JSON.parse(init.body);
      return { status: 200, ok: true, text: JSON.stringify({
        answers: Object.fromEntries(Object.keys(body.questions).map(key => [key, { type: 'noul', noul: 0.1 }])),
        usage: { input_tokens: 250, output_tokens: 0 },
      }) };
    });
    await host.compact();
    expect(host.fallback).not.toHaveBeenCalled();
    expect(host.fetch).toHaveBeenCalledTimes(1);
    const [url, init] = host.fetch.mock.calls[0]!;
    expect(url).toBe(directURL);
    expect(JSON.parse(init.body).model).toBe('jev-latest');
    expect(JSON.stringify(init)).not.toContain('saved');
    expect((init as any).headers['ai-model-id']).toBeUndefined();
    expect(host.$.ui.log.mock.calls.flat().join(' ')).toContain('input=250, output=0');
  });
});
