#!/usr/bin/env node
import { createInterface } from 'node:readline';
import { stdin, stdout } from 'node:process';
import { buildJevRequest, parseJevResponse, providerModel, validScopedEndpoint, type JevProvider } from './request.js';
import { OptimizerEngine, type AbortableJevAsker, type OptimizerCommand, type OptimizerResult } from './optimizer.js';
import type { JevQuestions, JevState } from './types.js';

const COMMANDS = new Set<OptimizerCommand>(['retrieve', 'select_tools', 'route_model', 'assess_memory']);

class ScopedOptimizerAsker implements AbortableJevAsker {
  constructor(private readonly apiKey: string, private readonly baseUrl: string, private readonly provider: JevProvider) {}

  ask(state: JevState, questions: JevQuestions) {
    return this.askWithSignal(state, questions, new AbortController().signal);
  }

  async askWithSignal(state: JevState, questions: JevQuestions, signal: AbortSignal) {
    const request = buildJevRequest({ apiKey: this.apiKey, baseUrl: this.baseUrl, provider: this.provider }, state, questions);
    const response = await fetch(request.url, {
      method: request.method,
      headers: request.headers,
      body: request.body,
      signal,
      redirect: 'error',
      credentials: 'omit',
    });
    const text = await response.text();
    const parsed = parseJevResponse(response.status, response.ok, text, this.provider);
    // Direct TypeSafe responses have no documented billed-cost receipt.
    if (this.provider === 'typesafe') return parsed;
    try {
      const raw = JSON.parse(text) as { providerMetadata?: { gateway?: { cost?: unknown } } };
      const cost = raw.providerMetadata?.gateway?.cost;
      const numeric = typeof cost === 'string' && cost.trim() ? Number(cost) : cost;
      if (typeof numeric === 'number' && Number.isFinite(numeric) && numeric >= 0) parsed.cost_usd = numeric;
    } catch {
      // parseJevResponse already validated JSON; cost metadata is optional.
    }
    return parsed;
  }
}

function scopedClient(): { asker: AbortableJevAsker; modelId: string } | undefined {
  const scoped = process.env.KEYS_JEV_SCOPED_GRANT;
  const apiKey = process.env.AI_GATEWAY_API_KEY;
  const baseUrl = process.env.AI_GATEWAY_BASE_URL;
  const provider = process.env.KEYS_JEV_PROVIDER ?? 'vercel-ai-gateway';
  if (provider !== 'vercel-ai-gateway' && provider !== 'typesafe') return undefined;
  if (scoped !== '1' || !apiKey || !/^ksf_[0-9a-f]{8}_[A-Za-z0-9_-]{43}$/.test(apiKey) ||
      !baseUrl || !validScopedEndpoint(provider, baseUrl)) return undefined;
  return { asker: new ScopedOptimizerAsker(apiKey, baseUrl, provider), modelId: providerModel(provider) };
}

const engine = new OptimizerEngine(scopedClient() ?? {});

function safeCommand(input: unknown): OptimizerCommand {
  if (input !== null && typeof input === 'object' && !Array.isArray(input)) {
    const value = (input as Record<string, unknown>).command;
    if (typeof value === 'string' && COMMANDS.has(value as OptimizerCommand)) return value as OptimizerCommand;
  }
  return 'retrieve';
}

function safeAbstention(input: unknown, reason: string): OptimizerResult {
  return {
    ok: true,
    command: safeCommand(input),
    status: 'abstained',
    applied: false,
    reason,
    usage: { requests: 0, cache_hits: 0 },
  };
}

async function processLine(line: string): Promise<void> {
  let input: unknown;
  try {
    input = JSON.parse(line);
  } catch {
    stdout.write(`${JSON.stringify(safeAbstention(undefined, 'invalid_json'))}\n`);
    return;
  }
  let result: OptimizerResult;
  try {
    result = await engine.handle(input);
  } catch {
    result = safeAbstention(input, 'invalid_request');
  }
  stdout.write(`${JSON.stringify(result)}\n`);
}

async function main(): Promise<void> {
  if (process.argv.includes('--stream')) {
    const lines = createInterface({ input: stdin, crlfDelay: Infinity });
    for await (const line of lines) if (line.trim()) await processLine(line);
    return;
  }
  let body = '';
  stdin.setEncoding('utf8');
  for await (const chunk of stdin) body += chunk;
  await processLine(body);
}

await main();
