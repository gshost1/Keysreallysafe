import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { JevClient } from '../src/client.js';
import { buildJevRequest, parseJevResponse, validScopedEndpoint } from '../src/request.js';

const grant = `ksf_1234abcd_${'A'.repeat(43)}`;
const directURL = 'http://127.0.0.1:12767/direct-key/v1/systemone';

describe('reviewed TypeSafe protocol', () => {
  it('sends the model in the body and preserves noul questions without Vercel headers', () => {
    const questions = { keep: { type: 'noul' as const, instructions: 'Keep this context' } };
    const request = buildJevRequest({ apiKey: 'synthetic', provider: 'typesafe' }, 'fixture', questions);
    expect(request.url).toBe('https://api.typesafe.ai/v1/systemone');
    expect(request.headers).toEqual({ authorization: 'Bearer synthetic', 'content-type': 'application/json' });
    expect(JSON.parse(request.body)).toEqual({ model: 'jev-latest', state: 'fixture', questions });
  });

  it('preserves direct confidence and snake_case usage, leaving billed cost unknown', () => {
    const answers = { q: { type: 'choice', choice: 'a', probabilities: { a: 0.8, b: 0.2 }, confidence: 0.63 } };
    const result = parseJevResponse(200, true, JSON.stringify({ model: 'jev-1.13.0', answers,
      usage: { input_tokens: 50, output_tokens: 0, inputTokens: 999 }, providerMetadata: { gateway: { cost: 1 } } }), 'typesafe');
    expect(result).toEqual({ answers, model: 'jev-1.13.0', usage: { input_tokens: 50, output_tokens: 0 } });
    for (const count of [-1, 1.5, true, '3', 1e100, null]) {
      expect(parseJevResponse(200, true, JSON.stringify({ answers: {}, usage: { input_tokens: count, output_tokens: count } }), 'typesafe').usage)
        .toEqual({ input_tokens: undefined, output_tokens: undefined });
    }
  });

  it('uses the selected protocol with an injected client transport and rejects redirects', async () => {
    const client = new JevClient({ provider: 'typesafe', apiKey: 'fixture', fetch: (async (url, init) => {
      expect(url).toBe('https://api.typesafe.ai/v1/systemone');
      expect(init?.redirect).toBe('error');
      expect(init?.credentials).toBe('omit');
      expect(JSON.parse(init?.body as string).model).toBe('jev-latest');
      return new Response('{"answers":{"q":{"type":"noul","noul":0.9}},"usage":{"input_tokens":10,"output_tokens":0}}');
    }) as typeof fetch });
    expect((await client.ask('fixture', { q: { type: 'noul', instructions: 'keep?' } })).usage?.input_tokens).toBe(10);
  });


});

async function runCLI(provider: string): Promise<{ stdout: string; stderr: string }> {
  // This preload replaces fetch before the CLI starts. No socket is opened.
  const preload = `globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    if (url !== ${JSON.stringify(directURL)} || body.model !== 'jev-latest' || init.redirect !== 'error' || init.credentials !== 'omit' ||
        Object.values(body.questions).some(q => q.type !== 'noul') || init.headers['ai-model-id']) throw new Error('wire mismatch');
    return new Response(JSON.stringify({answers:Object.fromEntries(Object.keys(body.questions).map(k => [k,{type:'noul',noul:k === 'none_fit' || k.startsWith('conflict_') ? 0.01 : 0.99}])),
      usage:{input_tokens:41,output_tokens:0},providerMetadata:{gateway:{cost:999}}}));
  };`;
  const input = { command: 'retrieve', project_id: 'p', task_id: 't', project_enabled: true, provider_enabled: true, mode: 'suggest',
    request_text: 'run fixture tests', candidates: [{ id: 'plan', project_id: 'p', title: 'fixture tests', content: 'Run fixture tests',
      source: 'verified fixture', verification: ['tests pass'] }] };
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', '--import', `data:text/javascript,${encodeURIComponent(preload)}`,
      fileURLToPath(new URL('../src/optimizer-cli.ts', import.meta.url))], {
      cwd: fileURLToPath(new URL('..', import.meta.url)),
      env: { ...process.env, KEYS_JEV_SCOPED_GRANT: '1', KEYS_JEV_PROVIDER: provider,
        AI_GATEWAY_API_KEY: grant, AI_GATEWAY_BASE_URL: directURL },
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve({ stdout, stderr }) : reject(new Error(`exit ${code}`)));
    child.stdin.end(JSON.stringify(input));
  });
}

describe('scoped direct CLI', () => {
  it('dispatches the direct wire format, records actual tokens, and does not invent cost', async () => {
    const { stdout, stderr } = await runCLI('typesafe');
    const result = JSON.parse(stdout);
    expect(result.status).toBe('suggested');
    expect(result.usage).toMatchObject({ requests: 1, actual_input_tokens: 41, actual_output_tokens: 0 });
    expect(result.usage.optimizer_cost_usd).toBeUndefined();
    expect(stderr).toBe('');
    expect(stdout).not.toContain(grant);
  });
  it('refuses a provider/path mismatch before dispatch', async () => {
    const { stdout, stderr } = await runCLI('vercel-ai-gateway');
    const result = JSON.parse(stdout);
    expect(result.status).toBe('abstained');
    expect(result.usage.requests).toBe(0);
    expect(stderr).toBe('');
  });
});
