import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  OptimizerEngine,
  parseOptimizerRequest,
  ReadOnlyToolResultCache,
  type JevAsker,
  type JevQuestions,
} from '../src/index.js';
import { OPTIMIZER_FIXTURES, runLiveModelJudgeFixtures, runOfflineStructuralFixtures } from './optimizer-fixtures.js';

async function runCli(args: string[], input: string, env: NodeJS.ProcessEnv): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, args, { cwd: fileURLToPath(new URL('..', import.meta.url)), env });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8').on('data', (chunk: string) => { stdout += chunk; });
    child.stderr.setEncoding('utf8').on('data', (chunk: string) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (code) => code === 0 ? resolve({ stdout, stderr }) : reject(new Error(`CLI exited ${code}`)));
    child.stdin.end(input);
  });
}

function base(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    command: 'retrieve',
    project_id: 'project-a',
    task_id: 'task-a',
    project_enabled: true,
    provider_enabled: true,
    mode: 'suggest',
    request_text: 'fix the parser test',
    current_constraints: { requirements: ['Use npm test', 'Do not edit generated files'] },
    required_tools: ['Read', 'Edit', 'Bash'],
    dependency_hashes: { 'src/parser.ts': 'hash-a' },
    policy: { max_requests: 4, max_input_tokens: 50_000, threshold: 0.75 },
    candidates: [{
      id: 'plan-a',
      project_id: 'project-a',
      title: 'Fix parser test',
      content: 'Inspect and repair the parser, then run npm test.',
      tags: ['parser', 'test'],
      constraints: ['Use npm test'],
      required_tools: ['Read', 'Edit'],
      dependencies: { 'src/parser.ts': 'hash-a' },
      source: 'verified-task-1',
      verification: ['npm test'],
    }],
    ...overrides,
  };
}

function jev(answer: (name: string) => number, calls: { state: unknown; questions: JevQuestions }[] = []): JevAsker {
  return {
    async ask(state, questions) {
      calls.push({ state, questions });
      return {
        answers: Object.fromEntries(Object.keys(questions).map((name) => [name, { noul: answer(name) }])),
        usage: { input_tokens: 101, output_tokens: 7 },
      };
    },
  };
}

function positive(name: string): number {
  if (name === 'none_fit') return 0.02;
  if (name.startsWith('suitable_')) return 0.95;
  if (name.startsWith('conflict_')) return 0.02;
  return 0.5;
}

describe('optimizer request validation', () => {
  it('accepts store-native aliases and normalizes bounded policy values', () => {
    const parsed = parseOptimizerRequest(base({
      dependency_hashes: undefined,
      dependencies: { 'src/other.ts': 'b' },
      policy: { threshold: 10, candidate_limit: 999, max_requests: -5 },
    }));
    expect(parsed.dependencyHashes).toEqual({ 'src/other.ts': 'b' });
    expect(parsed.policy).toMatchObject({ threshold: 0.99, candidateLimit: 24, maxRequests: 0 });
  });

  it('rejects malformed commands and oversized inputs with fixed reason codes', () => {
    expect(() => parseOptimizerRequest(base({ command: 'execute' }))).toThrow(/invalid_command/);
    expect(() => parseOptimizerRequest(base({ request_text: 'x'.repeat(1_100_000) }))).toThrow(/request_too_large/);
  });
});

describe('plan retrieval', () => {
  it('locally validates project, exact constraints, dependencies, and available tools before Jev', async () => {
    const calls: { state: unknown; questions: JevQuestions }[] = [];
    const engine = new OptimizerEngine({ asker: jev(positive, calls) });
    const candidates = [
      ...(base().candidates as Record<string, unknown>[]),
      { id: 'wrong-project', project_id: 'project-b', title: 'fix parser test' },
      { id: 'stale', project_id: 'project-a', title: 'fix parser test', dependencies: { 'src/parser.ts': 'old' } },
      { id: 'different-rule', project_id: 'project-a', title: 'fix parser test', constraints: ['Use pnpm test'] },
      { id: 'missing-tool', project_id: 'project-a', title: 'fix parser test', required_tools: ['Deploy'] },
    ];
    const result = await engine.handle(base({ candidates }));
    expect(result).toMatchObject({
      status: 'suggested',
      applied: false,
      selected_ids: ['plan-a'],
      verification_required: true,
      usage: { requests: 1, cache_hits: 0, actual_input_tokens: 101, actual_output_tokens: 7 },
    });
    expect(result.rejected).toEqual(expect.arrayContaining([
      { id: 'wrong-project', reason: 'project_mismatch' },
      { id: 'stale', reason: 'dependency_mismatch' },
      { id: 'different-rule', reason: 'constraint_mismatch' },
      { id: 'missing-tool', reason: 'required_tool_unavailable' },
    ]));
    expect(calls).toHaveLength(1);
    expect(Object.keys(calls[0]!.questions)).toEqual(['suitable_0', 'conflict_0', 'none_fit']);
  });

  it('uses exact process cache by asker, project, state, questions, policy, and model', async () => {
    const calls: { state: unknown; questions: JevQuestions }[] = [];
    const engine = new OptimizerEngine({ asker: jev(positive, calls), modelId: 'jev-a' });
    const first = await engine.handle(base());
    const second = await engine.handle(base());
    const changed = await engine.handle(base({ policy: { max_requests: 4, max_input_tokens: 50_000, threshold: 0.8 } }));
    expect(first.usage).toMatchObject({ requests: 1, cache_hits: 0 });
    expect(second.usage).toEqual({ requests: 0, cache_hits: 1 });
    expect(changed.usage).toMatchObject({ requests: 1, cache_hits: 0 });
    expect(calls).toHaveLength(2);
  });

  it('invalidates rank cache on candidate version and permission scope changes', async () => {
    const calls: { state: unknown; questions: JevQuestions }[] = [];
    const engine = new OptimizerEngine({ asker: jev(positive, calls) });
    const candidate = { ...(base().candidates as Record<string, unknown>[])[0], version: 1 };
    await engine.handle(base({ permission_fingerprint: 'scope-a', candidates: [candidate] }));
    await engine.handle(base({ permission_fingerprint: 'scope-a', candidates: [{ ...candidate, version: 2 }] }));
    await engine.handle(base({ permission_fingerprint: 'scope-b', candidates: [{ ...candidate, version: 2 }] }));
    expect(calls).toHaveLength(3);
  });

  it('pre-reserves concurrent task budget and never over-issues calls', async () => {
    let release: (() => void) | undefined;
    const waiting = new Promise<void>((resolve) => { release = resolve; });
    let calls = 0;
    const asker: JevAsker = {
      async ask(_state, questions) {
        calls += 1;
        await waiting;
        return { answers: Object.fromEntries(Object.keys(questions).map((name) => [name, { noul: positive(name) }])) };
      },
    };
    const engine = new OptimizerEngine({ asker });
    const request = base({ policy: { max_requests: 1, max_input_tokens: 50_000 } });
    const first = engine.handle(request);
    const second = engine.handle({ ...request, request_text: 'fix the parser test again' });
    await Promise.resolve();
    expect(calls).toBe(1);
    release!();
    const [, secondResult] = await Promise.all([first, second]);
    expect(secondResult).toMatchObject({ status: 'abstained', reason: 'budget_exhausted' });
  });

  it('does not call Jev when off, provider-disabled, locally empty, or over budget', async () => {
    const calls: { state: unknown; questions: JevQuestions }[] = [];
    const engine = new OptimizerEngine({ asker: jev(positive, calls) });
    expect((await engine.handle(base({ project_enabled: false }))).reason).toBe('project_off');
    expect((await engine.handle(base({ provider_enabled: false }))).reason).toBe('provider_disabled');
    expect((await engine.handle(base({ request_text: 'unrelated quasar' }))).reason).toBe('no_candidates');
    expect((await engine.handle(base({ policy: { max_requests: 0, max_input_tokens: 0 } }))).reason).toBe('budget_exhausted');
    expect(calls).toHaveLength(0);
  });

  it('abstains when the explicit none option wins or evaluator answers are malformed', async () => {
    const none = new OptimizerEngine({ asker: jev((name) => name === 'none_fit' ? 0.95 : 0.9) });
    expect((await none.handle(base())).reason).toBe('no_safe_match');
    const malformed = new OptimizerEngine({ asker: { ask: async () => ({ answers: {}, usage: { input_tokens: 0, output_tokens: 0 } }) } });
    const result = await malformed.handle(base());
    expect(result.reason).toBe('evaluation_failed');
    expect(result.usage).toMatchObject({ requests: 1, cache_hits: 0, actual_input_tokens: 0, actual_output_tokens: 0 });
    const again = await malformed.handle(base());
    expect(again.usage).toMatchObject({ requests: 1, cache_hits: 0 });
  });

  it('omits unknown actual usage and opens a circuit after bounded failures', async () => {
    let calls = 0;
    const failing: JevAsker = { ask: async () => { calls += 1; throw new Error('sensitive upstream text'); } };
    const engine = new OptimizerEngine({ asker: failing, circuitFailureThreshold: 2, circuitCooldownMs: 60_000 });
    expect((await engine.handle(base())).reason).toBe('evaluation_failed');
    expect((await engine.handle(base({ request_text: 'fix parser test second' }))).reason).toBe('evaluation_failed');
    const third = await engine.handle(base({ request_text: 'fix parser test third' }));
    expect(third).toMatchObject({ reason: 'circuit_open', usage: { requests: 0, cache_hits: 0 } });
    expect(JSON.stringify(third)).not.toContain('sensitive');
    expect(calls).toBe(2);

    const withoutUsage: JevAsker = {
      ask: async (_state, questions) => ({
        answers: Object.fromEntries(Object.keys(questions).map((name) => [name, { noul: positive(name) }])),
      }),
    };
    const noUsage = await new OptimizerEngine({ asker: withoutUsage }).handle(base());
    expect(noUsage.usage).not.toHaveProperty('actual_input_tokens');
    expect(noUsage.usage).not.toHaveProperty('actual_output_tokens');
  });

  it('reports optimizer cost only from explicit provider metadata, including an actual zero', async () => {
    const reported: JevAsker = {
      ask: async (_state, questions) => ({
        answers: Object.fromEntries(Object.keys(questions).map((name) => [name, { noul: positive(name) }])),
        providerMetadata: { gateway: { cost: '0' } },
      }),
    };
    const actual = await new OptimizerEngine({ asker: reported }).handle(base({
      policy: { max_requests: 2, max_input_tokens: 50_000, optimizer_cost_usd: 9 },
    }));
    expect(actual.usage.optimizer_cost_usd).toBe(0);
    const estimatedOnly = await new OptimizerEngine({ asker: jev(positive) }).handle(base({
      policy: { max_requests: 2, max_input_tokens: 50_000, optimizer_cost_usd: 9 },
    }));
    expect(estimatedOnly.usage).not.toHaveProperty('optimizer_cost_usd');
  });

  it('reconciles a reservation to provider-reported cost and rejects invalid token counts', async () => {
    let calls = 0;
    const reported: JevAsker = {
      ask: async (_state, questions) => {
        calls += 1;
        return {
          answers: Object.fromEntries(Object.keys(questions).map((name) => [name, { noul: positive(name) }])),
          usage: { input_tokens: -10, output_tokens: 1.5 },
          providerMetadata: { gateway: { cost: 2 } },
        };
      },
    };
    const engine = new OptimizerEngine({ asker: reported });
    const policy = { max_requests: 4, max_input_tokens: 50_000, max_cost_usd: 0.1, optimizer_cost_usd: 0.01 };
    const first = await engine.handle(base({ policy, permission_fingerprint: 'scope-1' }));
    expect(first.usage).toMatchObject({ requests: 1, optimizer_cost_usd: 2 });
    expect(first.usage).not.toHaveProperty('actual_input_tokens');
    expect(first.usage).not.toHaveProperty('actual_output_tokens');
    const second = await engine.handle(base({ policy, permission_fingerprint: 'scope-2' }));
    expect(second.reason).toBe('budget_exhausted');
    expect(calls).toBe(1);
  });

  it('charges reported spend before rejecting malformed evaluation answers', async () => {
    let calls = 0;
    const malformed: JevAsker = {
      ask: async () => {
        calls += 1;
        return {
          answers: {},
          usage: { input_tokens: 0, output_tokens: 0 },
          providerMetadata: { gateway: { cost: 2 } },
        };
      },
    };
    const engine = new OptimizerEngine({ asker: malformed });
    const policy = { max_requests: 4, max_input_tokens: 50_000, max_cost_usd: 0.1, optimizer_cost_usd: 0.01 };
    const first = await engine.handle(base({ policy, permission_fingerprint: 'scope-a' }));
    expect(first).toMatchObject({
      reason: 'evaluation_failed',
      usage: { requests: 1, actual_input_tokens: 0, actual_output_tokens: 0, optimizer_cost_usd: 2 },
    });
    const second = await engine.handle(base({ policy, permission_fingerprint: 'scope-b' }));
    expect(second.reason).toBe('budget_exhausted');
    expect(calls).toBe(1);
  });

  it('aborts abort-aware evaluator transport on timeout and records the attempted request', async () => {
    let aborted = false;
    const asker: JevAsker & { askWithSignal: (_state: unknown, _questions: JevQuestions, signal: AbortSignal) => Promise<never> } = {
      ask: async () => new Promise<never>(() => undefined),
      askWithSignal: async (_state, _questions, signal) => new Promise<never>((_resolve, reject) => {
        signal.addEventListener('abort', () => {
          aborted = true;
          reject(new Error('aborted transport'));
        }, { once: true });
      }),
    };
    const result = await new OptimizerEngine({ asker, timeoutMs: 5 }).handle(base());
    expect(result).toMatchObject({ reason: 'evaluation_failed', usage: { requests: 1, cache_hits: 0 } });
    expect(aborted).toBe(true);
  });
});

describe('tool selection', () => {
  it('preserves permission and coordination tools and retains full-catalog fallback', async () => {
    const calls: { state: unknown; questions: JevQuestions }[] = [];
    const request = base({
      command: 'select_tools',
      candidates: [
        { name: 'AskPermission', description: 'coordinate approval', permission_or_coordination: true },
        { name: 'Read', description: 'read parser source and test' },
        { name: 'Deploy', description: 'deploy production' },
      ],
    });
    const result = await new OptimizerEngine({ asker: jev(positive, calls) }).handle(request);
    expect(result).toMatchObject({
      selected_ids: ['AskPermission', 'Read'],
      preserved_essential_ids: ['AskPermission'],
      full_catalog_fallback: true,
      applied: false,
    });
    const state = calls[0]!.state as { candidates: { candidate: Record<string, unknown> }[] };
    expect(state.candidates[0]!.candidate).toMatchObject({ name: 'Read', description: 'read parser source and test' });
  });

  it('preserves essential tools even when the project is off', async () => {
    const result = await new OptimizerEngine().handle(base({
      command: 'select_tools', project_enabled: false,
      candidates: [{ name: 'Coordinate', essential: true }],
    }));
    expect(result).toMatchObject({ reason: 'project_off', selected_ids: ['Coordinate'], full_catalog_fallback: true });
  });
});

describe('model routing', () => {
  const models = [
    { id: 'large', provider: 'allowed', name: 'parser large', description: 'fix parser test', capabilities: ['tools'], context_limit: 200_000, route_type: 'gateway', privacy_route: 'scoped', billing_mode: 'api', input_cost_per_million: 10, output_cost_per_million: 20, observed_success_rate: 0.95, is_current: true },
    { id: 'small', provider: 'allowed', name: 'parser small', description: 'fix parser test', capabilities: ['tools'], context_limit: 200_000, route_type: 'gateway', privacy_route: 'scoped', billing_mode: 'api', input_cost_per_million: 1, output_cost_per_million: 2, observed_success_rate: 0.95 },
  ];

  it('preserves an explicit selection without an evaluator call', async () => {
    const calls: { state: unknown; questions: JevQuestions }[] = [];
    const result = await new OptimizerEngine({ asker: jev(positive, calls) }).handle(base({
      command: 'route_model', explicit_model_id: 'small', candidates: models,
    }));
    expect(result).toMatchObject({ selected_id: 'small', reason: 'explicit_model_preserved' });
    expect(calls).toHaveLength(0);
  });

  it('preserves an explicit ID even when it is absent from the catalog or the project is off', async () => {
    const engine = new OptimizerEngine();
    expect(await engine.handle(base({ command: 'route_model', explicit_model_id: 'external-model', candidates: models }))).toMatchObject({
      selected_id: 'external-model', reason: 'explicit_model_preserved',
    });
    expect(await engine.handle(base({ command: 'route_model', project_enabled: false, explicit_model_id: 'external-model', candidates: models }))).toMatchObject({
      selected_id: 'external-model', reason: 'project_off',
    });
    expect(await engine.handle(base({
      command: 'route_model', project_enabled: false,
      candidates: [models[0], { ...models[1], explicitly_selected: true }],
    }))).toMatchObject({ selected_id: 'small', reason: 'project_off' });
  });

  it('suggests only an allowed, capable, quality-gated model with fully known total cost', async () => {
    const result = await new OptimizerEngine({ asker: jev(positive) }).handle(base({
      command: 'route_model', candidates: models,
      request_text: 'fix parser test with tools',
      task_requirements: {
        required_capabilities: ['tools'], allowed_providers: ['allowed'],
        estimated_input_tokens: 100_000, estimated_output_tokens: 10_000,
        cache_rebuild_cost_usd: 0.01, fallback_cost_usd: 0,
        privacy_route: 'scoped', billing_mode: 'api', route_type: 'gateway', at_task_boundary: true,
      },
      policy: { max_requests: 2, max_input_tokens: 50_000, optimizer_cost_usd: 0.001 },
    }));
    expect(result).toMatchObject({ selected_id: 'small', reason: 'lower_estimated_cost_with_quality_gate', applied: false });
    expect(result.proposed_estimated_total_cost_usd).toBeLessThan(result.current_estimated_total_cost_usd as number);
  });

  it('retains the current model when any comparison cost is unknown', async () => {
    const calls: { state: unknown; questions: JevQuestions }[] = [];
    const result = await new OptimizerEngine({ asker: jev(positive, calls) }).handle(base({
      command: 'route_model', candidates: models,
      task_requirements: { required_capabilities: ['tools'], allowed_providers: ['allowed'], at_task_boundary: true },
    }));
    expect(result).toMatchObject({ selected_id: 'large', reason: 'retain_current_unknown_cost_benefit', status: 'abstained' });
    expect(calls).toHaveLength(0);
  });

  it('retains the current model when switching overhead erases the raw model-price saving', async () => {
    const close = [
      { ...models[0], input_cost_per_million: 10, output_cost_per_million: 0 },
      { ...models[1], input_cost_per_million: 9, output_cost_per_million: 0 },
    ];
    const result = await new OptimizerEngine({ asker: jev(positive) }).handle(base({
      command: 'route_model', candidates: close, request_text: 'fix parser test',
      task_requirements: {
        required_capabilities: ['tools'], allowed_providers: ['allowed'],
        estimated_input_tokens: 100_000, estimated_output_tokens: 0,
        cache_rebuild_cost_usd: 0.15, fallback_cost_usd: 0,
        privacy_route: 'scoped', billing_mode: 'api', route_type: 'gateway', at_task_boundary: true,
      },
      policy: { max_requests: 2, max_input_tokens: 50_000, optimizer_cost_usd: 0.01 },
    }));
    expect(result).toMatchObject({ selected_id: 'large', reason: 'retain_current_no_proven_benefit' });
  });

  it('sends model metadata and requirements to Jev and rejects route, billing, context, or mid-task changes locally', async () => {
    const calls: { state: unknown; questions: JevQuestions }[] = [];
    const request = base({
      command: 'route_model', candidates: models, request_text: 'fix parser test',
      task_requirements: {
        required_capabilities: ['tools'], allowed_providers: ['allowed'], allowed_model_ids: ['large', 'small'],
        estimated_input_tokens: 1_000, estimated_output_tokens: 100,
        cache_rebuild_cost_usd: 0, fallback_cost_usd: 0,
        privacy_route: 'scoped', billing_mode: 'api', route_type: 'gateway', at_task_boundary: true,
      },
      policy: { max_requests: 2, max_input_tokens: 50_000, optimizer_cost_usd: 0 },
    });
    await new OptimizerEngine({ asker: jev(positive, calls) }).handle(request);
    const state = calls[0]!.state as { task_requirements: Record<string, unknown>; candidates: { candidate: Record<string, unknown> }[] };
    expect(state.task_requirements).toMatchObject({ privacy_route: 'scoped', billing_mode: 'api', at_task_boundary: true });
    expect(state.candidates[0]!.candidate).toMatchObject({ provider: 'allowed', route_type: 'gateway', billing_mode: 'api', context_limit: 200_000 });

    const incompatible = models.map((model, index) => index === 1 ? { ...model, billing_mode: 'subscription' } : model);
    const result = await new OptimizerEngine({ asker: jev(positive) }).handle({ ...request, candidates: incompatible });
    expect(result).not.toMatchObject({ selected_id: 'small' });
    const midTask = await new OptimizerEngine({ asker: jev(positive) }).handle({
      ...request,
      task_requirements: { ...(request.task_requirements as Record<string, unknown>), at_task_boundary: false },
    });
    expect(midTask.reason).toBe('retain_current_not_task_boundary');
  });
});

describe('memory assessment', () => {
  it('detects exact duplicates locally without generating text or calling Jev', async () => {
    const calls: { state: unknown; questions: JevQuestions }[] = [];
    const result = await new OptimizerEngine({ asker: jev(positive, calls) }).handle(base({
      command: 'assess_memory', proposed_memory: { content: '  USE NPM TEST ' },
      candidates: [{ id: 'm1', project_id: 'project-a', content: 'use npm test' }],
    }));
    expect(result).toMatchObject({ disposition: 'duplicate', related_id: 'm1', reason: 'exact_duplicate', applied: false });
    expect(calls).toHaveLength(0);
  });

  it('returns advisory conflict assessments only', async () => {
    const answer = (name: string) => name === 'conflict_0' ? 0.95 : name === 'worth_retain' ? 0.9 : 0.05;
    const result = await new OptimizerEngine({ asker: jev(answer) }).handle(base({
      command: 'assess_memory', request_text: 'parser uses npm test',
      proposed_memory: { content: 'parser uses npm test command' },
      candidates: [{ id: 'm1', project_id: 'project-a', title: 'parser npm test', content: 'parser uses a different test command' }],
    }));
    expect(result).toMatchObject({ disposition: 'conflict', related_id: 'm1', applied: false });
    expect(result).not.toHaveProperty('generated_text');
  });

  it('does not treat a foreign-project exact memory as a duplicate', async () => {
    const result = await new OptimizerEngine().handle(base({
      command: 'assess_memory', proposed_memory: { content: 'same durable memory' },
      candidates: [{ id: 'foreign', project_id: 'project-b', title: 'same durable memory', content: 'same durable memory' }],
    }));
    expect(result).toMatchObject({ reason: 'no_related_memory', disposition: 'uncertain' });
    expect(result).not.toHaveProperty('related_id');
  });

  it('misses memory decision cache when permission scope changes', async () => {
    const calls: { state: unknown; questions: JevQuestions }[] = [];
    const engine = new OptimizerEngine({ asker: jev((name) => name === 'worth_retain' ? 0.9 : 0.05, calls) });
    const request = base({
      command: 'assess_memory', proposed_memory: { content: 'parser npm durable detail' },
      candidates: [{ id: 'm1', project_id: 'project-a', title: 'parser npm context', content: 'parser npm neighboring detail' }],
    });
    await engine.handle({ ...request, permission_fingerprint: 'scope-a' });
    await engine.handle({ ...request, permission_fingerprint: 'scope-b' });
    expect(calls).toHaveLength(2);
  });
});

describe('read-only tool result cache', () => {
  it('requires allowlisted reads, exact dependencies, and current permission', () => {
    let now = 1_000;
    const cache = new ReadOnlyToolResultCache({ now: () => now, ttlMs: 100, maxEntries: 2 });
    const key = {
      project_id: 'p', tool: 'read_file', tool_version: '1', arguments: { path: 'a.ts' },
      dependencies: { 'a.ts': 'h1' }, permission_fingerprint: 'scope-a',
    };
    expect(cache.put(key, { text: 'safe result' })).toBe(true);
    expect(cache.get({ ...key, current_dependencies: { 'a.ts': 'h1' }, current_permission_fingerprint: 'scope-a' })).toEqual({ text: 'safe result' });
    expect(cache.get({ ...key, current_dependencies: { 'a.ts': 'h2' }, current_permission_fingerprint: 'scope-a' })).toBeUndefined();
    expect(cache.get({ ...key, current_dependencies: { 'a.ts': 'h1' }, current_permission_fingerprint: 'scope-b' })).toBeUndefined();
    expect(cache.put({ ...key, tool: 'write_file' }, 'no')).toBe(false);
    now += 101;
    expect(cache.get({ ...key, current_dependencies: { 'a.ts': 'h1' }, current_permission_fingerprint: 'scope-a' })).toBeUndefined();
  });

  it('rejects unproven, broad, credential-bearing, and oversized reads and returns immutable clones', () => {
    const cache = new ReadOnlyToolResultCache({ maxValueBytes: 40 });
    const key = {
      project_id: 'p', tool: 'read_file', tool_version: '1', arguments: { path: 'a.ts' },
      dependencies: { 'a.ts': 'h1' }, permission_fingerprint: 'scope-a',
    };
    expect(cache.put({ ...key, dependencies: {} }, { ok: true })).toBe(false);
    expect(cache.put({ ...key, tool: 'list_directory' }, { ok: true })).toBe(false);
    expect(cache.put({ ...key, arguments: { path: '.env' }, dependencies: { '.env': 'h' } }, { ok: true })).toBe(false);
    expect(cache.put({ ...key, arguments: { path: 'a.ts', api_key: 'hidden' } }, { ok: true })).toBe(false);
    expect(cache.put(key, { text: 'x'.repeat(100) })).toBe(false);
    const original = { nested: { value: 1 } };
    expect(cache.put(key, original)).toBe(true);
    original.nested.value = 2;
    const first = cache.get({ ...key, current_dependencies: { 'a.ts': 'h1' }, current_permission_fingerprint: 'scope-a' }) as typeof original;
    expect(first.nested.value).toBe(1);
    first.nested.value = 3;
    const second = cache.get({ ...key, current_dependencies: { 'a.ts': 'h1' }, current_permission_fingerprint: 'scope-a' }) as typeof original;
    expect(second.nested.value).toBe(1);
  });
});

describe('labeled structural evaluation fixture', () => {
  it('reports 120 structural records across separate development and held-out task families', async () => {
    expect(OPTIMIZER_FIXTURES).toHaveLength(120);
    expect(new Set(OPTIMIZER_FIXTURES.map((fixture) => fixture.kind))).toEqual(new Set([
      'positive', 'dependency_near_miss', 'constraint_near_miss', 'tool_near_miss',
      'project_near_miss', 'prompt_injection', 'semantic_near_miss',
    ]));
    expect(OPTIMIZER_FIXTURES.some((fixture) => fixture.split === 'held_out')).toBe(true);
    expect(OPTIMIZER_FIXTURES.filter((fixture) => fixture.split === 'held_out').every((fixture) => fixture.task_family.startsWith('heldout_ledger_'))).toBe(true);
    const report = await runOfflineStructuralFixtures();
    expect(report).toEqual({ kind: 'synthetic_structural', cases: 120, correct: 120, accuracy: 1, failures: [] });
  });

  it('keeps the live model judge inert without an explicit scoped grant', async () => {
    await expect(runLiveModelJudgeFixtures(new OptimizerEngine(), {})).rejects.toThrow('live_scoped_grant_required');
  });
});

describe('CLI', () => {
  it('returns one safe abstention and no stderr for malformed input', async () => {
    const cli = fileURLToPath(new URL('../src/optimizer-cli.ts', import.meta.url));
    const { stdout, stderr } = await runCli(
      ['--import', 'tsx', cli],
      '{secret malformed',
      { ...process.env, AI_GATEWAY_API_KEY: 'do-not-print' },
    );
    expect(stderr).toBe('');
    expect(JSON.parse(stdout)).toEqual({
      ok: true, command: 'retrieve', status: 'abstained', applied: false,
      reason: 'invalid_json', usage: { requests: 0, cache_hits: 0 },
    });
    expect(stdout).not.toContain('secret');
    expect(stdout).not.toContain('do-not-print');
  });

  it('supports sequential NDJSON requests in stream mode', async () => {
    const cli = fileURLToPath(new URL('../src/optimizer-cli.ts', import.meta.url));
    const first = JSON.stringify(base({ project_enabled: false }));
    const second = JSON.stringify(base({ provider_enabled: false }));
    const { stdout } = await runCli(
      ['--import', 'tsx', cli, '--stream'],
      `${first}\n${second}\n`,
      { ...process.env, KEYS_JEV_SCOPED_GRANT: '0' },
    );
    expect(stdout.trim().split('\n').map((line) => JSON.parse(line).reason)).toEqual(['project_off', 'provider_disabled']);
  });
});
