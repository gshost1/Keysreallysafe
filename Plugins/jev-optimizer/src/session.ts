import { OptimizerEngine, type OptimizerResult } from './optimizer.js';
import { ReadOnlyToolResultCache } from './optimizer-tools.js';

type JsonRecord = Record<string, unknown>;
type Mode = 'observe' | 'suggest';

export interface AdapterPolicy {
  projectEnabled: boolean;
  providerEnabled: boolean;
  mode?: Mode;
  policy: JsonRecord;
  captureEnabled?: boolean;
  storageEnabled?: boolean;
  allowPlanApplication?: boolean;
  allowModelApplication?: boolean;
}

export interface SessionTask {
  projectId: string;
  taskId: string;
  requestText: string;
  currentConstraints?: string[];
  dependencyHashes?: Record<string, string>;
  permissionFingerprint: string;
  taskRequirements?: JsonRecord;
}

export interface ToolCatalogItem {
  id: string;
  name: string;
  version: string;
  description?: string;
  mandatory?: boolean;
  permissionOrCoordination?: boolean;
  readOnly?: boolean;
  /** Loaded only when a host explicitly requests this selected tool's detail. */
  load?: () => Promise<JsonRecord | undefined>;
}

export interface ModelCatalogItem extends JsonRecord { id: string; is_current?: boolean; explicitly_selected?: boolean; }

export interface AdapterHost {
  loadPolicy(task: Pick<SessionTask, 'projectId' | 'taskId'>): Promise<AdapterPolicy>;
  loadPlans(task: SessionTask): Promise<JsonRecord[]>;
  loadTools(task: SessionTask): Promise<ToolCatalogItem[]>;
  loadModels?(task: SessionTask): Promise<ModelCatalogItem[]>;
  /** Transport injects this exact candidate_capture payload into the local API. */
  saveCandidate?(candidate: CandidateCapturePayload): Promise<void>;
  applyPlan?(input: { projectId: string; taskId: string; planId: string }): Promise<void>;
  applyModel?(input: { projectId: string; taskId: string; modelId: string }): Promise<void>;
}

export interface ToolHost {
  permissionFingerprint(): Promise<string>;
  dependencyFingerprints(arguments_: JsonRecord): Promise<Record<string, string>>;
  execute(tool: ToolCatalogItem, arguments_: JsonRecord): Promise<unknown>;
}

export interface Advice {
  mode: Mode;
  plans: OptimizerResult;
  tools: OptimizerResult;
  model?: OptimizerResult;
  toolIds: string[];
  fullCatalogFallback: boolean;
  usage: { requests: number; cacheHits: number; unknown: boolean };
}

export interface VerifiedTaskCandidate {
  projectId: string;
  taskId: string;
  kind: 'plan' | 'memory';
  title: string;
  /** Curated candidate content, never a raw transcript. */
  content: string;
  source: string;
  tags: string[];
  dependencies: Record<string, string>;
  verification: string[];
  requiredTools?: string[];
  constraints?: string[];
  outcome: 'success';
  verified: true;
}
export interface CandidateCapturePayload {
  project_id: string;
  task_id: string;
  kind: 'plan' | 'memory';
  title: string;
  content: string;
  source: string;
  verification: string[];
  required_tools: string[];
  constraints: string[];
  dependencies: Record<string, string>;
}

function record(value: unknown): value is JsonRecord { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value: unknown, limit = 8_000): string { return typeof value === 'string' && value.trim().length <= limit ? value.trim() : ''; }
function strings(value: unknown, limit = 32): string[] | undefined {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > limit) return undefined;
  const result = value.map((v) => text(v, 512));
  return result.every(Boolean) ? result : undefined;
}
function hashes(value: unknown): Record<string, string> | undefined {
  if (value === undefined) return {};
  if (!record(value) || Object.keys(value).length > 256) return undefined;
  const entries = Object.entries(value);
  if (entries.some(([k, v]) => !text(k, 1_024) || typeof v !== 'string' || !v || v.length > 16_000)) return undefined;
  return Object.fromEntries(entries) as Record<string, string>;
}
function validTask(task: SessionTask): boolean {
  return Boolean(text(task.projectId, 256) && text(task.taskId, 256) && text(task.requestText) && text(task.permissionFingerprint, 1_024));
}
function ids(result: OptimizerResult): string[] {
  const raw = result.selected_ids;
  return Array.isArray(raw) ? raw.filter((value): value is string => typeof value === 'string').slice(0, 128) : [];
}
function usage(results: OptimizerResult[]): Advice['usage'] {
  let requests = 0; let cacheHits = 0; let unknown = false;
  for (const result of results) {
    requests += typeof result.usage.requests === 'number' ? result.usage.requests : 0;
    cacheHits += typeof result.usage.cache_hits === 'number' ? result.usage.cache_hits : 0;
    if (result.usage.actual_input_tokens === undefined || result.usage.actual_output_tokens === undefined) unknown = true;
  }
  return { requests, cacheHits, unknown };
}
function abstain(command: 'retrieve' | 'select_tools' | 'route_model', reason: string): OptimizerResult {
  return { ok: true, command, status: 'abstained', applied: false, reason, usage: { requests: 0, cache_hits: 0 } };
}
function boundedCandidates(value: JsonRecord[], max = 64): JsonRecord[] | undefined {
  if (value.length > max) return undefined;
  try { return JSON.stringify(value).length <= 200_000 ? value : undefined; } catch { return undefined; }
}
function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`;
  if (record(value)) return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
function expiredAt(value: unknown): boolean {
  if (value === undefined || value === null) return false;
  const at = typeof value === 'string' ? Date.parse(value) : typeof value === 'number' ? value : NaN;
  return !Number.isFinite(at) || at <= Date.now();
}
function expired(policy: AdapterPolicy): boolean { return expiredAt(policy.policy.expires_at); }
function policyMode(policy: AdapterPolicy): Mode { return policy.mode === 'observe' ? 'observe' : 'suggest'; }

/** Host-embedded orchestration. It suggests only; hosts decide when to apply anything. */
export class OptimizerSessionAdapter {
  private readonly cache: ReadOnlyToolResultCache;
  private readonly advice = new Map<string, { plans: Set<string>; models: Set<string>; binding: string }>();
  constructor(private readonly engine: OptimizerEngine, private readonly host: AdapterHost, cache = new ReadOnlyToolResultCache()) { this.cache = cache; }

  async advise(task: SessionTask): Promise<Advice | { reason: 'invalid_task' | 'policy_unavailable' }> {
    if (!validTask(task)) return { reason: 'invalid_task' };
    let policy: AdapterPolicy;
    let plans: JsonRecord[];
    let catalog: ToolCatalogItem[];
    try { [policy, plans, catalog] = await Promise.all([this.host.loadPolicy(task), this.host.loadPlans(task), this.host.loadTools(task)]); } catch { return { reason: 'policy_unavailable' }; }
    const mode = policyMode(policy);
    const constraints = strings(task.currentConstraints, 64); const dependencies = hashes(task.dependencyHashes);
    if (!constraints || !dependencies || !record(policy.policy)) return { reason: 'invalid_task' };
    const completeCatalog = catalog.filter((item) => text(item.id, 256) && text(item.name, 256) && text(item.version, 256));
    if (completeCatalog.length !== catalog.length) return { reason: 'invalid_task' };
    const mandatory = completeCatalog.filter((tool) => tool.mandatory || tool.permissionOrCoordination).map((tool) => tool.id);
    const advisoryCatalog = completeCatalog.filter((tool) => !tool.mandatory && !tool.permissionOrCoordination);
    const toolMetadataValid = advisoryCatalog.every((tool) => tool.description === undefined || Boolean(text(tool.description, 2_000)));
    const boundedTools = toolMetadataValid ? boundedCandidates(advisoryCatalog.slice(0, 64).map((tool) => ({ id: tool.id, name: tool.name, version: tool.version, description: tool.description ?? '', project_id: task.projectId }))) : undefined;
    const boundedPlans = boundedCandidates(plans);
    const base = {
      project_id: task.projectId, task_id: task.taskId, request_text: task.requestText,
      current_constraints: { requirements: constraints }, dependency_hashes: dependencies,
      permission_fingerprint: task.permissionFingerprint, project_enabled: policy.projectEnabled === true,
      provider_enabled: policy.providerEnabled === true, mode, policy: policy.policy, task_requirements: record(task.taskRequirements) ? task.taskRequirements : {},
    };
    let plansResult = abstain('retrieve', 'advisory_bounds'); let toolsResult = abstain('select_tools', 'full_catalog_fallback');
    try { if (boundedPlans) plansResult = await this.engine.handle({ ...base, command: 'retrieve', candidates: boundedPlans, available_tools: completeCatalog.slice(0, 500).map((tool) => tool.name) }); } catch { /* local fallback */ }
    try { if (boundedTools) toolsResult = await this.engine.handle({ ...base, command: 'select_tools', candidates: boundedTools, available_tools: completeCatalog.slice(0, 500).map((tool) => tool.name) }); } catch { /* full catalog fallback */ }
    let modelResult: OptimizerResult | undefined;
    let modelsSnapshot: ModelCatalogItem[] = [];
    if (this.host.loadModels) {
      try {
        modelsSnapshot = await this.host.loadModels(task);
        const bounded = boundedCandidates(modelsSnapshot, 32);
        if (bounded) modelResult = await this.engine.handle({ ...base, command: 'route_model', candidates: bounded, available_tools: completeCatalog.slice(0, 500).map((tool) => tool.name) });
      } catch { /* Model advice is optional and unknown rather than fabricated. */ }
    }
    const known = new Set(completeCatalog.map((tool) => tool.id));
    const suggested = ids(toolsResult).filter((id) => known.has(id));
    const fullCatalogFallback = toolsResult.reason !== 'tool_candidates_ranked';
    const toolIds = fullCatalogFallback ? completeCatalog.map((tool) => tool.id) : [...new Set([...mandatory, ...suggested])];
    const modelIds = modelResult && typeof modelResult.selected_id === 'string' ? [modelResult.selected_id] : [];
    this.advice.set(`${task.projectId}\u0000${task.taskId}`, { plans: new Set(ids(plansResult)), models: new Set(modelIds),
      binding: stable({ task: { requestText: task.requestText, constraints, dependencies, permission: task.permissionFingerprint, requirements: task.taskRequirements ?? {} }, policy, plans, catalog, models: modelsSnapshot }) });
    return { mode, plans: plansResult, tools: toolsResult, model: modelResult, toolIds, fullCatalogFallback, usage: usage([plansResult, toolsResult, ...(modelResult ? [modelResult] : [])]) };
  }

  async loadSelectedTool(task: SessionTask, id: string): Promise<JsonRecord | undefined> {
    if (!validTask(task)) return undefined;
    try {
      const tool = (await this.host.loadTools(task)).find((item) => item.id === id);
      return tool?.load ? await tool.load() : undefined;
    } catch { return undefined; }
  }

  async executeTool(task: SessionTask, tool: ToolCatalogItem, arguments_: JsonRecord, host: ToolHost): Promise<{ value: unknown; cacheHit: boolean } | { reason: string }> {
    if (!validTask(task) || !record(arguments_)) return { reason: 'invalid_tool_request' };
    let policy: AdapterPolicy;
    try { policy = await this.host.loadPolicy(task); } catch { return this.normalExecute(tool, arguments_, host); }
    if (!policy.projectEnabled || !policy.providerEnabled) return this.normalExecute(tool, arguments_, host);
    if (tool.readOnly !== true) return this.normalExecute(tool, arguments_, host);
    let key: { project_id: string; tool: string; tool_version: string; arguments: JsonRecord; dependencies: Record<string, string>; permission_fingerprint: string };
    try {
      const dependencies = hashes(await host.dependencyFingerprints(arguments_));
      // This must be the final authorization observation, after slow dependency I/O.
      const currentPolicy = await this.host.loadPolicy(task);
      if (!currentPolicy.projectEnabled || !currentPolicy.providerEnabled || !dependencies) return this.normalExecute(tool, arguments_, host);
      const permission = await host.permissionFingerprint();
      key = { project_id: task.projectId, tool: tool.name, tool_version: tool.version, arguments: arguments_, dependencies, permission_fingerprint: permission };
      const cached = this.cache.get({ ...key, current_dependencies: key.dependencies, current_permission_fingerprint: permission });
      if (cached !== undefined) return { value: cached, cacheHit: true };
    } catch { return this.normalExecute(tool, arguments_, host); }
    try {
      const value = await host.execute(tool, arguments_);
      this.cache.put(key, value);
      return { value, cacheHit: false };
    } catch { return { reason: 'tool_unavailable' }; }
  }

  private async normalExecute(tool: ToolCatalogItem, arguments_: JsonRecord, host: ToolHost): Promise<{ value: unknown; cacheHit: false } | { reason: string }> {
    try { return { value: await host.execute(tool, arguments_), cacheHit: false }; } catch { return { reason: 'tool_unavailable' }; }
  }

  async applySuggestedPlan(task: SessionTask, planId: string, confirmed: boolean): Promise<boolean> {
    let policy: AdapterPolicy; try { policy = await this.host.loadPolicy(task); } catch { return false; }
    const remembered = this.advice.get(`${task.projectId}\u0000${task.taskId}`);
    if (!confirmed || !policy.projectEnabled || !policy.providerEnabled || expired(policy) || policyMode(policy) !== 'suggest' || !policy.allowPlanApplication || !this.host.applyPlan || !validTask(task) || !text(planId, 256) || !remembered?.plans.has(planId)) return false;
    const policyIdentity = stable(policy);
    try {
      const currentConstraints = strings(task.currentConstraints, 64); const currentDependencies = hashes(task.dependencyHashes);
      if (!currentConstraints || !currentDependencies) return false;
      const [plans, catalog, models] = await Promise.all([this.host.loadPlans(task), this.host.loadTools(task), this.host.loadModels ? this.host.loadModels(task) : Promise.resolve([])]);
      if (remembered.binding !== stable({ task: { requestText: task.requestText, constraints: currentConstraints, dependencies: currentDependencies, permission: task.permissionFingerprint, requirements: task.taskRequirements ?? {} }, policy, plans, catalog, models })) return false;
      const plan = plans.find((item) => item.id === planId && item.project_id === task.projectId);
      if (!plan) return false;
      if (expiredAt(plan.expires_at)) return false;
      const planConstraints = strings(plan.constraints, 64); const planDependencies = hashes(plan.dependencies);
      if (!planConstraints || !planDependencies || planConstraints.some((value) => !currentConstraints.includes(value)) || Object.entries(planDependencies).some(([path, hash]) => currentDependencies[path] !== hash)) return false;
      const finalPolicy = await this.host.loadPolicy(task);
      if (stable(finalPolicy) !== policyIdentity || expired(finalPolicy) || expiredAt(plan.expires_at)) return false;
    } catch { return false; }
    await this.host.applyPlan({ projectId: task.projectId, taskId: task.taskId, planId }); return true;
  }
  async applySuggestedModel(task: SessionTask, modelId: string, confirmed: boolean): Promise<boolean> {
    let policy: AdapterPolicy; try { policy = await this.host.loadPolicy(task); } catch { return false; }
    const remembered = this.advice.get(`${task.projectId}\u0000${task.taskId}`);
    if (!confirmed || !policy.projectEnabled || !policy.providerEnabled || expired(policy) || policyMode(policy) !== 'suggest' || !policy.allowModelApplication || !this.host.applyModel || !this.host.loadModels || !validTask(task) || !text(modelId, 256) || !remembered?.models.has(modelId)) return false;
    const policyIdentity = stable(policy);
    try {
      const [plans, catalog, models] = await Promise.all([this.host.loadPlans(task), this.host.loadTools(task), this.host.loadModels(task)]);
      const constraints = strings(task.currentConstraints, 64); const dependencies = hashes(task.dependencyHashes);
      if (!constraints || !dependencies || remembered.binding !== stable({ task: { requestText: task.requestText, constraints, dependencies, permission: task.permissionFingerprint, requirements: task.taskRequirements ?? {} }, policy, plans, catalog, models })) return false;
      if (!models.some((model) => model.id === modelId) || models.some((model) => model.explicitly_selected === true)) return false;
      const finalPolicy = await this.host.loadPolicy(task);
      if (stable(finalPolicy) !== policyIdentity || expired(finalPolicy)) return false;
    } catch { return false; }
    await this.host.applyModel({ projectId: task.projectId, taskId: task.taskId, modelId }); return true;
  }
  async captureVerifiedTask(candidate: VerifiedTaskCandidate): Promise<boolean> {
    const verification = strings(candidate.verification); const requiredTools = strings(candidate.requiredTools); const constraints = strings(candidate.constraints); const dependencies = hashes(candidate.dependencies);
    if (!this.host.saveCandidate || candidate.outcome !== 'success' || candidate.verified !== true || !text(candidate.projectId, 256) || !text(candidate.taskId, 256) || !text(candidate.title) || !text(candidate.content) || !text(candidate.source) || !['plan', 'memory'].includes(candidate.kind) || !verification || verification.length === 0 || !requiredTools || !constraints || !dependencies) return false;
    let policy: AdapterPolicy; try { policy = await this.host.loadPolicy(candidate); } catch { return false; }
    if (!policy.projectEnabled || !policy.storageEnabled || !policy.captureEnabled) return false;
    await this.host.saveCandidate({
      project_id: candidate.projectId, task_id: candidate.taskId, kind: candidate.kind, title: text(candidate.title),
      content: text(candidate.content), source: text(candidate.source), verification,
      required_tools: requiredTools, constraints, dependencies,
    });
    return true;
  }
}
