import { describe, expect, it, vi } from 'vitest';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { OptimizerEngine, OptimizerSessionAdapter, type AdapterHost, type JevAsker, type ToolCatalogItem } from '../src/index.js';

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
    expect(await adapter.applySuggestedModel(task, 'model-a', true)).toBe(true);
    expect(applied).toEqual(['plan:plan-a', 'model:model-a']);
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
    let plans = [{ id: 'plan-a', project_id: 'project-a', title: 'repair parser test', content: 'Read parser and run test', constraints: ['test'], dependencies: { 'src/parser.ts': 'v1' } }];
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
        allowPlanApplication: true, allowModelApplication: true, policy: { expires_at: start + 100 } };
      const adapter = new OptimizerSessionAdapter(new OptimizerEngine({ asker }), host({
        loadPolicy: async () => policy,
        loadPlans: async () => [{ id: 'plan-a', project_id: 'project-a', title: 'repair parser test', content: 'Read parser and run test',
          constraints: ['test'], dependencies: { 'src/parser.ts': 'v1' }, expires_at: start + 50 }],
        loadModels: async () => { if (slowRead) now = start + 150; return [{ id: 'model-a', is_current: true }]; },
        applyPlan: async () => { applied.push('plan'); }, applyModel: async () => { applied.push('model'); },
      }));
      await adapter.advise(task);
      now = start + 60;
      expect(await adapter.applySuggestedPlan(task, 'plan-a', true)).toBe(false);
      now = start; slowRead = true;
      expect(await adapter.applySuggestedModel(task, 'model-a', true)).toBe(false);
      expect(applied).toEqual([]);
    } finally { clock.mockRestore(); }
  });
});
