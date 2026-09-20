import { describe, expect, it, vi } from 'vitest';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { OptimizerEngine, OptimizerSessionAdapter, type AdapterHost, type JevAsker, type ToolCatalogItem, type ModelCatalogItem } from '../src/index.js';

const task = { projectId: 'project-a', taskId: 'task-a', requestText: 'repair parser test', permissionFingerprint: 'scope-a', currentConstraints: ['test'], dependencyHashes: { 'src/parser.ts': 'v1' } };
const answer = (name: string) => name === 'none_fit' ? 0.01 : name.startsWith('conflict_') ? 0.01 : 0.99;
const asker: JevAsker = { ask: async (_state, questions) => ({ answers: Object.fromEntries(Object.keys(questions).map((name) => [name, { noul: answer(name) }])) }) };

function host(overrides: Partial<AdapterHost> = {}): AdapterHost {
  return {
    loadPolicy: async () => ({ projectEnabled: true, providerEnabled: true, policy: { max_requests: 8, max_input_tokens: 50_000, threshold: 0.75 } }),
    loadPlans: async () => [{ id: 'plan-a', project_id: 'project-a', title: 'repair parser test', content: 'Read parser and run test', constraints: ['test'], dependencies: { 'src/parser.ts': 'v1' } }],
    loadTools: async () => [
      { id: 'read', name: 'read_file', version: '1', description: 'read parser', readOnly: true },
      { id: 'coord', name: 'ask_user', version: '1', description: 'coordinate', mandatory: true, permissionOrCoordination: true },
    ],
    ...overrides,
  };
}

describe('OptimizerSessionAdapter', () => {
  it('orchestrates local plans and compact catalogs while preserving mandatory tools', async () => {
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host());
    const advice = await adapter.advise(task);
    if ('reason' in advice) throw new Error(advice.reason);
    expect(advice.mode).toBe('suggest');
    expect(advice.plans.applied).toBe(false);
    expect(advice.toolIds).toContain('coord');
    expect(advice.usage.unknown).toBe(true);
  });

  it('uses the full catalog fallback and loads tool detail only on an explicit request', async () => {
    let loads = 0;
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
      loadPolicy: async () => ({ projectEnabled: false, providerEnabled: true, policy: {} }),
      loadTools: async () => [{ id: 'lazy', name: 'read_file', version: '1', readOnly: true, load: async () => { loads += 1; return { full: true }; } }],
    }));
    const advice = await adapter.advise(task);
    if ('reason' in advice) throw new Error(advice.reason);
    expect(advice.fullCatalogFallback).toBe(true);
    expect(advice.toolIds).toEqual(['lazy']);
    expect(loads).toBe(0);
    expect(await adapter.loadSelectedTool(task, 'lazy')).toEqual({ full: true });
    expect(loads).toBe(1);
  });

  it('retains mandatory tools beyond the advisory shortlist and falls back to every host tool', async () => {
    const catalog = Array.from({ length: 130 }, (_, index) => ({ id: `tool-${index}`, name: `read_${index}`, version: '1', mandatory: index === 129 }));
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
      loadPolicy: async () => ({ projectEnabled: false, providerEnabled: true, policy: {} }), loadTools: async () => catalog,
    }));
    const advice = await adapter.advise(task);
    if ('reason' in advice) throw new Error(advice.reason);
    expect(advice.toolIds).toHaveLength(130);
    expect(advice.toolIds).toContain('tool-129');
  });

  it.each([9, 25, 65, 130])('preserves all %i optional tools when the catalog exceeds the evaluated bound', async (count) => {
    const catalog: ToolCatalogItem[] = Array.from({ length: count }, (_, index) => ({ id: `read-${index}`, name: `read_${index}`, description: 'repair parser test', version: '1' }));
    catalog.push({ id: 'required', name: 'coordinate', version: '1', mandatory: true });
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({ loadTools: async () => catalog }));
    const advice = await adapter.advise(task);
    if ('reason' in advice) throw new Error(advice.reason);
    expect(advice.fullCatalogFallback).toBe(true);
    expect(advice.tools.full_catalog_fallback).toBe(true);
    expect(advice.toolIds).toEqual(catalog.map((tool) => tool.id));
    expect(advice.suggestedToolIds.length).toBeLessThanOrEqual(8);
  });

  it('keeps tools omitted by lexical prefilter available and labels ranked tools advisory', async () => {
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({ loadTools: async () => [
      { id: 'read', name: 'read_file', description: 'repair parser test', version: '1' },
      { id: 'other', name: 'calendar', description: 'schedule meeting', version: '1' },
    ] }));
    const advice = await adapter.advise(task);
    if ('reason' in advice) throw new Error(advice.reason);
    expect(advice.suggestedToolIds).toEqual(['read']);
    expect(advice.toolIds).toEqual(['read', 'other']);
    expect(advice.fullCatalogFallback).toBe(true);
  });

  it('keeps the complete catalog in observe mode despite complete advisory ranking', async () => {
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
      loadPolicy: async () => ({ projectEnabled: true, providerEnabled: true, mode: 'observe', policy: {} }),
    }));
    const advice = await adapter.advise(task);
    if ('reason' in advice) throw new Error(advice.reason);
    expect(advice.suggestedToolIds).toEqual(['read']);
    expect(advice.tools).toMatchObject({ status: 'observed', full_catalog_fallback: true });
    expect(advice.fullCatalogFallback).toBe(true);
    expect(advice.toolIds).toEqual(['read', 'coord']);
  });

  it('preserves host-required and selected-plan tools even when the evaluator rejects them', async () => {
    const selective: JevAsker = { ask: async (state, questions) => ({ answers: Object.fromEntries(Object.keys(questions).map((name) =>
      [name, { noul: JSON.stringify(state).includes('tool selection') && /_1$|_2$/.test(name) ? 0.01 : answer(name) }])) }) };
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker: selective }), host({
      loadPlans: async () => [{ id: 'plan-a', project_id: 'project-a', title: 'repair parser test', required_tools: ['run_test'] }],
      loadTools: async () => [
        { id: 'read', name: 'read_file', description: 'repair parser test', version: '1' },
        { id: 'test', name: 'run_test', description: 'repair parser test', version: '1' },
        { id: 'host-required', name: 'inspect_file', description: 'repair parser test', version: '1' },
        { id: 'coord', name: 'ask_user', version: '1', permissionOrCoordination: true },
      ],
    }));
    const advice = await adapter.advise({ ...task, requiredTools: ['inspect_file'] });
    if ('reason' in advice) throw new Error(advice.reason);
    expect(advice.tools).toMatchObject({ full_catalog_fallback: false, evaluated_ids: ['read', 'test', 'host-required'] });
    expect(advice.suggestedToolIds).toEqual(['read']);
    expect(new Set(advice.toolIds)).toEqual(new Set(['read', 'test', 'host-required', 'coord']));
    expect(advice.fullCatalogFallback).toBe(false);
  });

  it('rechecks permission and dependencies before cache hits and never caches writes', async () => {
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host());
    const read: ToolCatalogItem = { id: 'read', name: 'read_file', version: '1', readOnly: true };
    const write: ToolCatalogItem = { id: 'write', name: 'edit_file', version: '1', readOnly: false };
    const directory = await mkdtemp(join(tmpdir(), 'jev-session-'));
    const file = join(directory, 'fixture.txt');
    await writeFile(file, 'first');
    let permission = 'scope-a'; let hash = 'v1'; let calls = 0;
    const executor = {
      permissionFingerprint: async () => permission,
      dependencyFingerprints: async () => ({ [file]: hash }),
      execute: async () => ({ value: await readFile(file, 'utf8'), call: ++calls }),
    };
    try {
      expect(await adapter.executeTool(task, read, { path: file }, executor)).toMatchObject({ cacheHit: false });
      expect(await adapter.executeTool(task, read, { path: file }, executor)).toMatchObject({ cacheHit: true });
      permission = 'scope-b';
      expect(await adapter.executeTool({ ...task, permissionFingerprint: permission }, read, { path: file }, executor)).toMatchObject({ cacheHit: false });
      hash = 'v2'; await writeFile(file, 'changed');
      expect(await adapter.executeTool({ ...task, permissionFingerprint: permission }, read, { path: file }, executor)).toMatchObject({ cacheHit: false });
      expect(await adapter.executeTool(task, write, { path: file, content: 'x' }, executor)).toMatchObject({ cacheHit: false });
      expect(await adapter.executeTool(task, write, { path: file, content: 'x' }, executor)).toMatchObject({ cacheHit: false });
      expect(calls).toBe(5);
    } finally { await rm(directory, { recursive: true, force: true }); }
  });

  it('bypasses the cache but retains the normal host path when optimizer policy is disabled', async () => {
    let executions = 0;
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
      loadPolicy: async () => ({ projectEnabled: false, providerEnabled: false, policy: {} }),
    }));
    const result = await adapter.executeTool(task, { id: 'write', name: 'edit_file', version: '1' }, { path: 'src/parser.ts' }, {
      permissionFingerprint: async () => 'scope', dependencyFingerprints: async () => ({ 'src/parser.ts': 'v1' }),
      execute: async () => ({ value: ++executions }),
    });
    expect(result).toMatchObject({ cacheHit: false });
    expect(executions).toBe(1);
  });

  it('never caches host-classified sensitive read tools', async () => {
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host());
    const execute = vi.fn(async () => 'opaque data');
    const permissionFingerprint = vi.fn(async () => 'scope-a');
    const executor = { execute, permissionFingerprint, dependencyFingerprints: async () => ({ 'src/parser.ts': 'v1' }) };
    const tool = { id: 'read', name: 'read_file', version: '1', readOnly: true, sensitive: true };
    expect(await adapter.executeTool(task, tool, { path: 'src/parser.ts' }, executor)).toMatchObject({ cacheHit: false });
    expect(await adapter.executeTool(task, tool, { path: 'src/parser.ts' }, executor)).toMatchObject({ cacheHit: false });
    expect(execute).toHaveBeenCalledTimes(2);
    expect(permissionFingerprint).not.toHaveBeenCalled();
  });

  it('never asks writes for cache fingerprints and lets read cache failures use host authorization', async () => {
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host());
    let writes = 0; let reads = 0;
    const brokenCacheCallbacks = {
      permissionFingerprint: async () => { throw new Error('not needed'); },
      dependencyFingerprints: async () => { throw new Error('not needed'); },
      execute: async (tool: ToolCatalogItem) => {
        if (tool.readOnly) { reads += 1; throw new Error('authorization denied'); }
        writes += 1; return 'write accepted';
      },
    };
    expect(await adapter.executeTool(task, { id: 'write', name: 'edit_file', version: '1' }, { path: 'src/parser.ts' }, brokenCacheCallbacks)).toMatchObject({ value: 'write accepted', cacheHit: false });
    expect(await adapter.executeTool(task, { id: 'read', name: 'read_file', version: '1', readOnly: true }, { path: 'src/parser.ts' }, brokenCacheCallbacks)).toEqual({ reason: 'tool_unavailable' });
    expect(writes).toBe(1);
    expect(reads).toBe(1);
  });

  it('requires opt-in verified capture and explicit gated application callbacks', async () => {
    const saved: unknown[] = []; const applied: string[] = [];
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
      loadPolicy: async () => ({ projectEnabled: true, providerEnabled: true, mode: 'suggest', storageEnabled: true, captureEnabled: true, allowPlanApplication: true, allowModelApplication: true, policy: {} }),
      loadModels: async () => [{ id: 'model-a', is_current: true }],
      saveCandidate: async (payload) => { saved.push(payload); },
      applyPlan: async ({ planId }) => { applied.push(`plan:${planId}`); },
      applyModel: async ({ modelId }) => { applied.push(`model:${modelId}`); },
    }));
    await adapter.advise(task);
    expect(await adapter.captureVerifiedTask({ ...task, kind: 'plan', title: 'Repair parser', content: 'Curated repair plan', source: 'verified task', tags: [], dependencies: {}, verification: ['test'], outcome: 'success', verified: true })).toBe(true);
    expect(saved[0]).toMatchObject({ project_id: 'project-a', task_id: 'task-a', kind: 'plan', content: 'Curated repair plan' });
    expect(await adapter.applySuggestedPlan(task, 'plan-a', false)).toBe(false);
    expect(await adapter.applySuggestedPlan(task, 'plan-a', true)).toBe(true);
    expect(await adapter.applySuggestedModel(task, 'model-a', true)).toBe(false);
    expect(applied).toEqual(['plan:plan-a']);
  });

  it('applies a different model only after confirmation of current cost and quality gated advice', async () => {
    const applied: string[] = [];
    const models: ModelCatalogItem[] = [
      { id: 'large', provider: 'allowed', name: 'repair parser test', capabilities: ['tools'], context_limit: 200_000, route_type: 'gateway', privacy_route: 'scoped', billing_mode: 'api', input_cost_per_million: 10, output_cost_per_million: 20, observed_success_rate: 0.95, is_current: true },
      { id: 'small', provider: 'allowed', name: 'repair parser test', capabilities: ['tools'], context_limit: 200_000, route_type: 'gateway', privacy_route: 'scoped', billing_mode: 'api', input_cost_per_million: 1, output_cost_per_million: 2, observed_success_rate: 0.95 },
    ];
    const routingTask = { ...task, taskRequirements: { at_task_boundary: true, required_capabilities: ['tools'], allowed_providers: ['allowed'],
      estimated_input_tokens: 100_000, estimated_output_tokens: 10_000, cache_rebuild_cost_usd: 0.01, fallback_cost_usd: 0,
      privacy_route: 'scoped', billing_mode: 'api', route_type: 'gateway' } };
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
      loadPolicy: async () => ({ projectEnabled: true, providerEnabled: true, mode: 'suggest', allowModelApplication: true,
        policy: { max_requests: 8, max_input_tokens: 50_000, optimizer_cost_usd: 0.001 } }),
      loadModels: async () => models, applyModel: async ({ modelId }) => { applied.push(modelId); },
    }));
    const advice = await adapter.advise(routingTask);
    if ('reason' in advice) throw new Error(advice.reason);
    expect(advice.model).toMatchObject({ selected_id: 'small', reason: 'lower_estimated_cost_with_quality_gate', applied: false });
    expect(applied).toEqual([]);
    expect(await adapter.applySuggestedModel(routingTask, 'small', false)).toBe(false);
    expect(await adapter.applySuggestedModel({ ...routingTask, permissionFingerprint: 'changed' }, 'small', true)).toBe(false);
    expect(await adapter.applySuggestedModel(routingTask, 'small', true)).toBe(true);
    models[0]!.explicitly_selected = true;
    expect(await adapter.applySuggestedModel(routingTask, 'small', true)).toBe(false);
    expect(applied).toEqual(['small']);
  });

  it('evicts old task advice and expires retained advice before application', async () => {
    let now = Date.now();
    const clock = vi.spyOn(Date, 'now').mockImplementation(() => now);
    const applied: string[] = [];
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
      loadPolicy: async () => ({ projectEnabled: true, providerEnabled: true, allowPlanApplication: true, policy: {} }),
      applyPlan: async ({ taskId }) => { applied.push(taskId); },
    }));
    try {
      for (let index = 0; index < 65; index += 1) await adapter.advise({ ...task, taskId: `task-${index}` });
      expect(await adapter.applySuggestedPlan({ ...task, taskId: 'task-0' }, 'plan-a', true)).toBe(false);
      expect(await adapter.applySuggestedPlan({ ...task, taskId: 'task-64' }, 'plan-a', true)).toBe(true);
      now += 300_001;
      expect(await adapter.applySuggestedPlan({ ...task, taskId: 'task-64' }, 'plan-a', true)).toBe(false);
      expect(applied).toEqual(['task-64']);
    } finally { clock.mockRestore(); }
  });

  it('binds normalized required tools so padded names still apply and changed ones do not', async () => {
    const applied: string[] = [];
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
      loadPolicy: async () => ({ projectEnabled: true, providerEnabled: true, allowPlanApplication: true, policy: {} }),
      applyPlan: async ({ planId }) => { applied.push(planId); },
    }));
    const padded = { ...task, requiredTools: [' read_file '] };
    const advice = await adapter.advise(padded);
    if ('reason' in advice) throw new Error(advice.reason);
    expect(await adapter.applySuggestedPlan({ ...padded, requiredTools: ['ask_user'] }, 'plan-a', true)).toBe(false);
    expect(await adapter.applySuggestedPlan({ ...padded, requiredTools: [7 as unknown as string] }, 'plan-a', true)).toBe(false);
    expect(await adapter.applySuggestedPlan(padded, 'plan-a', true)).toBe(true);
    expect(applied).toEqual(['plan-a']);
  });

  it('rejects stale advice, inactive application policy, and lossy candidate capture', async () => {
    const saved: unknown[] = [];
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
      loadPolicy: async () => ({ projectEnabled: false, providerEnabled: true, mode: 'suggest', storageEnabled: false, captureEnabled: true, allowPlanApplication: true, policy: {} }),
      saveCandidate: async (payload) => { saved.push(payload); }, applyPlan: async () => {},
    }));
    expect(await adapter.applySuggestedPlan(task, 'plan-a', true)).toBe(false);
    expect(await adapter.captureVerifiedTask({ ...task, kind: 'plan', title: 't', content: 'c', source: 's', tags: [], dependencies: {}, verification: [], outcome: 'success', verified: true })).toBe(false);
    expect(saved).toEqual([]);
  });

  it('binds advice to current policy, plan metadata, and task requirements before applying', async () => {
    let policy = { projectEnabled: true, providerEnabled: true, mode: 'suggest' as const, allowPlanApplication: true, allowModelApplication: true, policy: {} };
    let plans: Record<string, unknown>[] = [{ id: 'plan-a', project_id: 'project-a', title: 'repair parser test', content: 'Read parser and run test', constraints: ['test'], dependencies: { 'src/parser.ts': 'v1' } }];
    const applied: string[] = [];
    const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
      loadPolicy: async () => policy, loadPlans: async () => plans, loadModels: async () => [{ id: 'model-a', is_current: true }],
      applyPlan: async () => { applied.push('plan'); }, applyModel: async () => { applied.push('model'); },
    }));
    await adapter.advise(task);
    plans = [{ ...plans[0]!, expires_at: '2000-01-01T00:00:00Z' }];
    expect(await adapter.applySuggestedPlan(task, 'plan-a', true)).toBe(false);
    plans = [{ ...plans[0]!, expires_at: undefined }];
    await adapter.advise(task);
    policy = { ...policy, policy: { expires_at: '2000-01-01T00:00:00Z' } };
    expect(await adapter.applySuggestedModel(task, 'model-a', true)).toBe(false);
    policy = { ...policy, policy: {} };
    await adapter.advise(task);
    expect(await adapter.applySuggestedPlan({ ...task, taskRequirements: { changed: true } }, 'plan-a', true)).toBe(false);
    expect(applied).toEqual([]);
  });

  it('rechecks numeric expiry and elapsed policy expiry after asynchronous catalog reads', async () => {
    const start = Date.parse('2030-01-01T00:00:00Z');
    let now = start; let slowRead = false;
    const clock = vi.spyOn(Date, 'now').mockImplementation(() => now);
    const applied: string[] = [];
    try {
      const policy = { projectEnabled: true, providerEnabled: true, mode: 'suggest' as const,
        allowPlanApplication: true, allowModelApplication: true, policy: { expires_at: start + 100, optimizer_cost_usd: 0, max_requests: 8 } };
      const routingTask = { ...task, taskRequirements: { at_task_boundary: true, estimated_input_tokens: 1000, estimated_output_tokens: 100,
        cache_rebuild_cost_usd: 0, fallback_cost_usd: 0 } };
      const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
        loadPolicy: async () => policy,
        loadPlans: async () => [{ id: 'plan-a', project_id: 'project-a', title: 'repair parser test', content: 'Read parser and run test',
          constraints: ['test'], dependencies: { 'src/parser.ts': 'v1' }, expires_at: start + 50 }],
        loadModels: async () => { if (slowRead) now = start + 150; return [
          { id: 'model-a', name: 'repair parser test', is_current: true, context_limit: 10000, input_cost_per_million: 10, output_cost_per_million: 10, observed_success_rate: 1 },
          { id: 'model-b', name: 'repair parser test', context_limit: 10000, input_cost_per_million: 1, output_cost_per_million: 1, observed_success_rate: 1 },
        ]; },
        applyPlan: async () => { applied.push('plan'); }, applyModel: async () => { applied.push('model'); },
      }));
      const advice = await adapter.advise(routingTask);
      if ('reason' in advice) throw new Error(advice.reason);
      expect(advice.model).toMatchObject({ selected_id: 'model-b', reason: 'lower_estimated_cost_with_quality_gate' });
      now = start + 60;
      expect(await adapter.applySuggestedPlan(routingTask, 'plan-a', true)).toBe(false);
      now = start; slowRead = true;
      expect(await adapter.applySuggestedModel(routingTask, 'model-b', true)).toBe(false);
      expect(applied).toEqual([]);
    } finally { clock.mockRestore(); }
  });
});
