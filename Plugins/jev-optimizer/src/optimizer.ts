import { noulAnswer } from './request.js';
import type { JevAsker, JevQuestions, JevResponse } from './types.js';

export type OptimizerCommand = 'retrieve' | 'select_tools' | 'route_model' | 'assess_memory';
export type OptimizerMode = 'off' | 'observe' | 'suggest' | 'auto';

export interface OptimizerUsage {
  requests: number;
  cache_hits: number;
  estimated_input_tokens?: number;
  actual_input_tokens?: number;
  actual_output_tokens?: number;
  optimizer_cost_usd?: number;
}

export interface OptimizerResult {
  ok: true;
  command: OptimizerCommand;
  status: 'selected' | 'suggested' | 'observed' | 'abstained';
  applied: false;
  reason: string;
  usage: OptimizerUsage;
  [key: string]: unknown;
}

export class OptimizerValidationError extends Error {
  readonly reason: string;

  constructor(reason = 'invalid_request') {
    super(reason);
    this.name = 'OptimizerValidationError';
    this.reason = reason;
  }
}

type JsonRecord = Record<string, unknown>;

interface Policy {
  expiresAt?: number;
  maxRequests: number;
  maxInputTokens: number;
  maxCostUsd?: number;
  optimizerCostUsd?: number;
  candidateLimit: number;
  threshold: number;
  questionVersion: string;
  evaluationTrusted: boolean;
  evaluationPassed: boolean;
}

interface ParsedRequest {
  command: OptimizerCommand;
  projectId: string;
  taskId: string;
  projectEnabled: boolean;
  providerEnabled: boolean;
  mode: OptimizerMode;
  requestText: string;
  candidates: JsonRecord[];
  currentConstraints: string[];
  dependencyHashes: Record<string, string>;
  availableTools: string[];
  policy: Policy;
  raw: JsonRecord;
}

interface Evaluation {
  response: JevResponse;
  usage: OptimizerUsage;
}

interface EvaluationAttempt {
  evaluation?: Evaluation;
  failureReason?: 'provider_unavailable' | 'circuit_open' | 'budget_exhausted' | 'evaluation_failed';
  usage?: OptimizerUsage;
}

interface CacheEntry {
  response: JevResponse;
  expiresAt: number;
}

interface Reservation {
  requests: number;
  inputTokens: number;
  costUsd: number;
}

interface BudgetState extends Reservation {}

export interface OptimizerEngineOptions {
  asker?: JevAsker;
  modelId?: string;
  timeoutMs?: number;
  cacheTtlMs?: number;
  maxCacheEntries?: number;
  now?: () => number;
  circuitFailureThreshold?: number;
  circuitCooldownMs?: number;
}

export interface AbortableJevAsker extends JevAsker {
  askWithSignal?: (
    state: Parameters<JevAsker['ask']>[0],
    questions: JevQuestions,
    signal: AbortSignal,
  ) => Promise<JevResponse>;
}

const COMMANDS = new Set<OptimizerCommand>(['retrieve', 'select_tools', 'route_model', 'assess_memory']);
const MODES = new Set<OptimizerMode>(['off', 'observe', 'suggest', 'auto']);
const DEFAULT_THRESHOLD = 0.75;
const DEFAULT_MAX_REQUESTS = 4;
const DEFAULT_MAX_INPUT_TOKENS = 12_000;
const DEFAULT_CANDIDATE_LIMIT = 8;
const MAX_CANDIDATE_LIMIT = 24;
const MAX_REQUEST_CHARS = 1_000_000;
const MAX_TEXT_CHARS = 100_000;
const MAX_CANDIDATES = 1_000;
const WORDS = /[\p{L}\p{N}_-]+/gu;

function isRecord(value: unknown): value is JsonRecord {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function finiteNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function tokenCount(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) && Number.isInteger(value) && value >= 0
    ? value
    : undefined;
}

function providerReportedCost(response: JevResponse): number | undefined {
  const direct = finiteNumber(response.cost_usd);
  if (direct !== undefined && direct >= 0) return direct;
  const metadata = isRecord(response.providerMetadata) ? response.providerMetadata : undefined;
  const gateway = metadata && isRecord(metadata.gateway) ? metadata.gateway : undefined;
  const raw = gateway?.cost;
  const parsed = typeof raw === 'string' && raw.trim() ? Number(raw) : finiteNumber(raw);
  return typeof parsed === 'number' && Number.isFinite(parsed) && parsed >= 0 ? parsed : undefined;
}

function boundedInteger(value: unknown, fallback: number, min: number, max: number): number {
  const numeric = finiteNumber(value);
  return numeric === undefined ? fallback : Math.max(min, Math.min(max, Math.floor(numeric)));
}

function boundedNumber(value: unknown, fallback: number, min: number, max: number): number {
  const numeric = finiteNumber(value);
  return numeric === undefined ? fallback : Math.max(min, Math.min(max, numeric));
}

function stringValue(value: unknown, max = MAX_TEXT_CHARS): string {
  return typeof value === 'string' ? value.slice(0, max) : '';
}

function stringList(value: unknown, max = 500): string[] {
  if (!Array.isArray(value)) return [];
  return value.slice(0, max).filter((item): item is string => typeof item === 'string').map((item) => item.slice(0, 2_000));
}

function normalized(value: string): string {
  return value.trim().replace(/\s+/g, ' ').toLocaleLowerCase('en-US');
}

function normalizedSet(values: readonly string[]): Set<string> {
  return new Set(values.map(normalized).filter(Boolean));
}

function recordOfStrings(value: unknown): Record<string, string> {
  if (!isRecord(value)) return {};
  return Object.fromEntries(
    Object.entries(value)
      .filter((entry): entry is [string, string] => typeof entry[1] === 'string')
      .slice(0, 2_000),
  );
}

function parseExpiry(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value !== 'string') return undefined;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function constraintList(value: unknown): string[] {
  if (Array.isArray(value)) return stringList(value);
  if (isRecord(value)) return stringList(value.requirements);
  return [];
}

function parsePolicy(value: unknown): Policy {
  const policy = isRecord(value) ? value : {};
  const profile = isRecord(policy.evaluation_profile) ? policy.evaluation_profile : {};
  const maxCost = finiteNumber(policy.max_cost_usd);
  const optimizerCost = finiteNumber(policy.optimizer_cost_usd);
  return {
    expiresAt: parseExpiry(policy.expires_at),
    maxRequests: boundedInteger(policy.max_requests, DEFAULT_MAX_REQUESTS, 0, 100),
    maxInputTokens: boundedInteger(policy.max_input_tokens, DEFAULT_MAX_INPUT_TOKENS, 0, 1_000_000),
    maxCostUsd: maxCost === undefined ? undefined : Math.max(0, maxCost),
    optimizerCostUsd: optimizerCost === undefined ? undefined : Math.max(0, optimizerCost),
    candidateLimit: boundedInteger(policy.candidate_limit, DEFAULT_CANDIDATE_LIMIT, 1, MAX_CANDIDATE_LIMIT),
    threshold: boundedNumber(policy.threshold, DEFAULT_THRESHOLD, 0.5, 0.99),
    questionVersion: stringValue(policy.question_version, 100) || 'optimizer-v1',
    evaluationTrusted: profile.trusted === true,
    evaluationPassed: profile.feature_passed === true,
  };
}

export function parseOptimizerRequest(input: unknown): ParsedRequest {
  if (!isRecord(input)) throw new OptimizerValidationError();
  let serialized: string;
  try {
    serialized = JSON.stringify(input);
  } catch {
    throw new OptimizerValidationError();
  }
  if (serialized.length > MAX_REQUEST_CHARS) throw new OptimizerValidationError('request_too_large');
  if (typeof input.command !== 'string' || !COMMANDS.has(input.command as OptimizerCommand)) {
    throw new OptimizerValidationError('invalid_command');
  }
  const projectId = stringValue(input.project_id, 256).trim();
  if (!projectId) throw new OptimizerValidationError('invalid_project');
  const mode = typeof input.mode === 'string' && MODES.has(input.mode as OptimizerMode)
    ? input.mode as OptimizerMode
    : 'off';
  const candidates = Array.isArray(input.candidates)
    ? input.candidates.slice(0, MAX_CANDIDATES).filter(isRecord)
    : [];
  const dependencyHashes = recordOfStrings(input.dependency_hashes ?? input.dependencies);
  const availableTools = stringList(input.available_tools ?? input.required_tools);
  return {
    command: input.command as OptimizerCommand,
    projectId,
    taskId: stringValue(input.task_id, 256) || 'default',
    projectEnabled: input.project_enabled === true,
    providerEnabled: input.provider_enabled === true,
    mode,
    requestText: stringValue(input.request_text ?? input.task_text),
    candidates,
    currentConstraints: constraintList(input.current_constraints),
    dependencyHashes,
    availableTools,
    policy: parsePolicy(input.policy),
    raw: input,
  };
}

function usage(requests = 0, cacheHits = 0): OptimizerUsage {
  return { requests, cache_hits: cacheHits };
}

function abstain(request: ParsedRequest, reason: string, extra: JsonRecord = {}): OptimizerResult {
  return { ok: true, command: request.command, status: 'abstained', applied: false, reason, usage: usage(), ...extra };
}

function candidateId(candidate: JsonRecord, fallback: string): string {
  return stringValue(candidate.id ?? candidate.name, 256) || fallback;
}

function candidateText(candidate: JsonRecord): string {
  return [candidate.title, candidate.content, candidate.summary, candidate.name, candidate.description, ...(Array.isArray(candidate.tags) ? candidate.tags : [])]
    .filter((item): item is string => typeof item === 'string')
    .join(' ')
    .slice(0, MAX_TEXT_CHARS);
}

function lexicalScore(query: string, candidate: JsonRecord): number {
  const queryWords = normalizedSet(query.match(WORDS) ?? []);
  if (queryWords.size === 0) return 0;
  const candidateWords = normalizedSet(candidateText(candidate).match(WORDS) ?? []);
  let overlap = 0;
  for (const word of queryWords) if (candidateWords.has(word)) overlap += 1;
  return overlap / Math.sqrt(queryWords.size * Math.max(1, candidateWords.size));
}

interface CheckedCandidate {
  candidate: JsonRecord;
  id: string;
  index: number;
  localScore: number;
}

function checkCandidate(request: ParsedRequest, candidate: JsonRecord, index: number): { ok: true } | { ok: false; reason: string } {
  const project = stringValue(candidate.project_id);
  if (project && project !== request.projectId) return { ok: false, reason: 'project_mismatch' };
  const expiresAt = parseExpiry(candidate.expires_at);
  if (expiresAt !== undefined && expiresAt <= Date.now()) return { ok: false, reason: 'expired' };
  const constraints = stringList(candidate.constraints);
  const currentConstraints = normalizedSet(request.currentConstraints);
  if (constraints.some((constraint) => !currentConstraints.has(normalized(constraint)))) {
    return { ok: false, reason: 'constraint_mismatch' };
  }
  const dependencies = recordOfStrings(candidate.dependencies ?? candidate.dependency_hashes);
  for (const [path, hash] of Object.entries(dependencies)) {
    if (!hash || request.dependencyHashes[path] !== hash) return { ok: false, reason: 'dependency_mismatch' };
  }
  const availableTools = normalizedSet(request.availableTools);
  if (stringList(candidate.required_tools).some((tool) => !availableTools.has(normalized(tool)))) {
    return { ok: false, reason: 'required_tool_unavailable' };
  }
  if (!candidateId(candidate, `candidate_${index + 1}`)) return { ok: false, reason: 'invalid_candidate' };
  return { ok: true };
}

function shortlist(request: ParsedRequest, candidates = request.candidates): { candidates: CheckedCandidate[]; rejected: JsonRecord[] } {
  const checked: CheckedCandidate[] = [];
  const rejected: JsonRecord[] = [];
  candidates.forEach((candidate, index) => {
    const result = checkCandidate(request, candidate, index);
    const id = candidateId(candidate, `candidate_${index + 1}`);
    if (!result.ok) {
      rejected.push({ id, reason: result.reason });
      return;
    }
    const localScore = lexicalScore(request.requestText, candidate);
    if (localScore <= 0) {
      rejected.push({ id, reason: 'local_irrelevance' });
      return;
    }
    checked.push({ candidate, id, index, localScore });
  });
  checked.sort((a, b) => b.localScore - a.localScore || a.index - b.index);
  return { candidates: checked.slice(0, request.policy.candidateLimit), rejected };
}

function sanitizedCandidate(candidate: JsonRecord): JsonRecord {
  const dependencies = recordOfStrings(candidate.dependencies ?? candidate.dependency_hashes);
  const sanitized: JsonRecord = {
    id: candidateId(candidate, 'candidate'),
    name: stringValue(candidate.name, 10_000),
    description: stringValue(candidate.description, MAX_TEXT_CHARS),
    title: stringValue(candidate.title, 10_000),
    content: stringValue(candidate.content ?? candidate.summary, MAX_TEXT_CHARS),
    tags: stringList(candidate.tags),
    constraints: stringList(candidate.constraints),
    required_tools: stringList(candidate.required_tools),
    dependencies,
    source: stringValue(candidate.source ?? candidate.provenance, 10_000),
    verification: stringList(candidate.verification),
    provider: stringValue(candidate.provider, 256),
    route_type: stringValue(candidate.route_type, 256),
    privacy_route: stringValue(candidate.privacy_route, 256),
    billing_mode: stringValue(candidate.billing_mode, 256),
    permission_fingerprint: stringValue(candidate.permission_fingerprint, 1_000),
    capabilities: stringList(candidate.capabilities),
    essential: candidate.essential === true,
    permission_or_coordination: candidate.permission_or_coordination === true,
  };
  for (const field of [
    'context_limit',
    'input_cost_per_million',
    'output_cost_per_million',
    'observed_success_rate',
  ] as const) {
    const value = finiteNumber(candidate[field]);
    if (value !== undefined) sanitized[field] = value;
  }
  const version = candidate.version;
  if (typeof version === 'string' || (typeof version === 'number' && Number.isFinite(version))) {
    sanitized.version = version;
  }
  return sanitized;
}

function sanitizedTaskRequirements(value: unknown): JsonRecord {
  const requirements = isRecord(value) ? value : {};
  const sanitized: JsonRecord = {
    required_capabilities: stringList(requirements.required_capabilities),
    allowed_providers: stringList(requirements.allowed_providers),
    allowed_model_ids: stringList(requirements.allowed_model_ids),
    privacy_route: stringValue(requirements.privacy_route, 256),
    billing_mode: stringValue(requirements.billing_mode, 256),
    route_type: stringValue(requirements.route_type, 256),
    at_task_boundary: requirements.at_task_boundary === true,
  };
  for (const field of [
    'estimated_input_tokens',
    'estimated_output_tokens',
    'cache_rebuild_cost_usd',
    'fallback_cost_usd',
  ] as const) {
    const value = finiteNumber(requirements[field]);
    if (value !== undefined) sanitized[field] = value;
  }
  return sanitized;
}

function estimateTokens(value: unknown): number {
  return Math.ceil(JSON.stringify(value).length / 3);
}

function optimizerQuestions(candidates: readonly CheckedCandidate[], purpose: string): JevQuestions {
  const questions: JevQuestions = {};
  candidates.forEach((entry, index) => {
    questions[`suitable_${index}`] = {
      type: 'noul',
      instructions: `Candidate ${index} is directly suitable for the current ${purpose} without inventing missing prerequisites`,
    };
    questions[`conflict_${index}`] = {
      type: 'noul',
      instructions: `Candidate ${index} conflicts with a current requirement, permission, dependency, or task boundary`,
    };
  });
  questions.none_fit = {
    type: 'noul',
    instructions: `None of the candidates safely fit the current ${purpose}; abstention is better than selecting one`,
  };
  return questions;
}

class ExactDecisionCache {
  private readonly caches = new WeakMap<JevAsker, Map<string, CacheEntry>>();

  constructor(private readonly maxEntries: number, private readonly ttlMs: number, private readonly now: () => number) {}

  read(asker: JevAsker, key: string): JevResponse | undefined {
    const cache = this.caches.get(asker);
    if (!cache) return undefined;
    for (const [entryKey, entry] of cache) if (entry.expiresAt <= this.now()) cache.delete(entryKey);
    const found = cache.get(key);
    if (!found) return undefined;
    cache.delete(key);
    cache.set(key, found);
    return found.response;
  }

  write(asker: JevAsker, key: string, response: JevResponse): void {
    if (key.length > MAX_REQUEST_CHARS) return;
    const cache = this.caches.get(asker) ?? new Map<string, CacheEntry>();
    cache.delete(key);
    cache.set(key, { response, expiresAt: this.now() + this.ttlMs });
    while (cache.size > this.maxEntries) cache.delete(cache.keys().next().value as string);
    this.caches.set(asker, cache);
  }
}

class TaskBudgets {
  private readonly states = new Map<string, BudgetState>();

  reserve(key: string, policy: Policy, reservation: Reservation): boolean {
    const state = this.states.get(key) ?? { requests: 0, inputTokens: 0, costUsd: 0 };
    if (state.requests + reservation.requests > policy.maxRequests) return false;
    if (state.inputTokens + reservation.inputTokens > policy.maxInputTokens) return false;
    if (policy.maxCostUsd !== undefined) {
      if (policy.optimizerCostUsd === undefined) return false;
      if (state.costUsd + reservation.costUsd > policy.maxCostUsd) return false;
    }
    this.states.set(key, {
      requests: state.requests + reservation.requests,
      inputTokens: state.inputTokens + reservation.inputTokens,
      costUsd: state.costUsd + reservation.costUsd,
    });
    return true;
  }

  reconcile(
    key: string,
    reserved: Reservation,
    actualInputTokens: number | undefined,
    actualCostUsd: number | undefined,
  ): void {
    if (actualInputTokens === undefined && actualCostUsd === undefined) return;
    const state = this.states.get(key);
    if (!state) return;
    this.states.set(key, {
      ...state,
      inputTokens: actualInputTokens === undefined
        ? state.inputTokens
        : Math.max(0, state.inputTokens - reserved.inputTokens + actualInputTokens),
      costUsd: actualCostUsd === undefined
        ? state.costUsd
        : Math.max(0, state.costUsd - reserved.costUsd + actualCostUsd),
    });
  }
}

export class OptimizerEngine {
  private readonly asker?: JevAsker;
  private readonly modelId: string;
  private readonly timeoutMs: number;
  private readonly now: () => number;
  private readonly cache: ExactDecisionCache;
  private readonly budgets = new TaskBudgets();
  private readonly circuitFailureThreshold: number;
  private readonly circuitCooldownMs: number;
  private consecutiveFailures = 0;
  private circuitOpenUntil = 0;

  constructor(options: OptimizerEngineOptions = {}) {
    this.asker = options.asker;
    this.modelId = options.modelId ?? 'typesafe-ai/jev';
    this.timeoutMs = Math.max(1, options.timeoutMs ?? 4_000);
    this.now = options.now ?? Date.now;
    this.circuitFailureThreshold = Math.max(1, options.circuitFailureThreshold ?? 3);
    this.circuitCooldownMs = Math.max(1, options.circuitCooldownMs ?? 30_000);
    this.cache = new ExactDecisionCache(
      Math.max(1, options.maxCacheEntries ?? 64),
      Math.max(1, options.cacheTtlMs ?? 5 * 60_000),
      this.now,
    );
  }

  async handle(input: unknown): Promise<OptimizerResult> {
    const request = parseOptimizerRequest(input);
    const gate = this.preflight(request);
    if (gate) {
      if (request.command === 'select_tools') {
        const essentials = request.candidates
          .filter((candidate) => candidate.essential === true || candidate.permission_or_coordination === true)
          .map((candidate, index) => candidateId(candidate, `essential_${index + 1}`));
        return { ...gate, selected_ids: essentials, preserved_essential_ids: essentials, full_catalog_fallback: true };
      }
      if (request.command === 'route_model') {
        const explicitId = stringValue(request.raw.explicit_model_id);
        if (explicitId) return { ...gate, selected_id: explicitId };
        const retained = request.candidates.find((candidate) => candidate.explicitly_selected === true) ??
          request.candidates.find((candidate) => candidate.is_current === true);
        return retained ? { ...gate, selected_id: candidateId(retained, explicitId || 'current') } : gate;
      }
      return gate;
    }
    if (request.command === 'retrieve') return this.retrieve(request);
    if (request.command === 'select_tools') return this.selectTools(request);
    if (request.command === 'route_model') return this.routeModel(request);
    return this.assessMemory(request);
  }

  private preflight(request: ParsedRequest): OptimizerResult | undefined {
    if (!request.projectEnabled || request.mode === 'off') return abstain(request, 'project_off');
    if (!request.providerEnabled) return abstain(request, 'provider_disabled');
    if (request.policy.expiresAt !== undefined && request.policy.expiresAt <= this.now()) {
      return abstain(request, 'policy_expired');
    }
    return undefined;
  }

  private async evaluate(request: ParsedRequest, state: JsonRecord, questions: JevQuestions): Promise<EvaluationAttempt> {
    if (!this.asker) return { failureReason: 'provider_unavailable' };
    if (this.now() < this.circuitOpenUntil) return { failureReason: 'circuit_open' };
    const key = JSON.stringify({
      project_id: request.projectId,
      full_state: state,
      questions,
      policy: request.raw.policy ?? {},
      scope: {
        permission_fingerprint: stringValue(request.raw.permission_fingerprint, 1_000),
        current_constraints: request.currentConstraints,
        dependency_hashes: request.dependencyHashes,
        available_tools: request.availableTools,
      },
      model: this.modelId,
      command: request.command,
    });
    const cached = this.cache.read(this.asker, key);
    if (cached) return { evaluation: { response: cached, usage: usage(0, 1) } };
    const estimatedInputTokens = estimateTokens({ state, questions });
    const cost = request.policy.optimizerCostUsd ?? 0;
    const budgetKey = `${request.projectId}\u0000${request.taskId}`;
    const reservation = { requests: 1, inputTokens: estimatedInputTokens, costUsd: cost };
    if (!this.budgets.reserve(budgetKey, request.policy, reservation)) {
      return { failureReason: 'budget_exhausted' };
    }
    const attemptedUsage = usage(1, 0);
    attemptedUsage.estimated_input_tokens = estimatedInputTokens;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new Error('timeout'));
        }, this.timeoutMs);
      });
      const abortable = this.asker as AbortableJevAsker;
      const response = await Promise.race([
        abortable.askWithSignal
          ? abortable.askWithSignal(state, questions, controller.signal)
          : this.asker.ask(state, questions),
        timeout,
      ]);
      const resultUsage = attemptedUsage;
      const actualInputTokens = tokenCount(response.usage?.input_tokens);
      const actualOutputTokens = tokenCount(response.usage?.output_tokens);
      if (actualInputTokens !== undefined) resultUsage.actual_input_tokens = actualInputTokens;
      if (actualOutputTokens !== undefined) resultUsage.actual_output_tokens = actualOutputTokens;
      const actualCost = providerReportedCost(response);
      if (actualCost !== undefined && actualCost >= 0) resultUsage.optimizer_cost_usd = actualCost;
      this.budgets.reconcile(budgetKey, reservation, resultUsage.actual_input_tokens, actualCost);
      for (const name of Object.keys(questions)) noulAnswer(response.answers, name);
      this.consecutiveFailures = 0;
      this.cache.write(this.asker, key, response);
      return { evaluation: { response, usage: resultUsage } };
    } catch {
      this.consecutiveFailures += 1;
      if (this.consecutiveFailures >= this.circuitFailureThreshold) {
        this.circuitOpenUntil = this.now() + this.circuitCooldownMs;
        this.consecutiveFailures = 0;
      }
      return { failureReason: 'evaluation_failed', usage: attemptedUsage };
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  private status(request: ParsedRequest): OptimizerResult['status'] {
    if (request.mode === 'observe') return 'observed';
    return request.mode === 'suggest' || request.mode === 'auto' ? 'suggested' : 'selected';
  }

  private autoGate(request: ParsedRequest): boolean {
    return request.mode === 'auto' && request.policy.evaluationTrusted && request.policy.evaluationPassed;
  }

  private async rank(
    request: ParsedRequest,
    checked: CheckedCandidate[],
    purpose: string,
  ): Promise<{ selected: CheckedCandidate[]; evaluation?: Evaluation; failureReason?: string; failureUsage?: OptimizerUsage }> {
    const state = {
      purpose,
      request: request.requestText,
      current_constraints: request.currentConstraints,
      required_tools: request.availableTools,
      permission_fingerprint: stringValue(request.raw.permission_fingerprint, 1_000),
      task_requirements: sanitizedTaskRequirements(request.raw.task_requirements),
      candidates: checked.map((entry, index) => ({ index, candidate: sanitizedCandidate(entry.candidate) })),
    };
    const questions = optimizerQuestions(checked, purpose);
    const attempt = await this.evaluate(request, state, questions);
    const evaluation = attempt.evaluation;
    if (!evaluation) return { selected: [], failureReason: attempt.failureReason, failureUsage: attempt.usage };
    const noneFit = noulAnswer(evaluation.response.answers, 'none_fit');
    if (noneFit >= request.policy.threshold) return { selected: [], evaluation };
    const selected = checked.filter((_, index) => {
      const suitable = noulAnswer(evaluation.response.answers, `suitable_${index}`);
      const conflict = noulAnswer(evaluation.response.answers, `conflict_${index}`);
      return suitable >= request.policy.threshold && conflict <= 1 - request.policy.threshold;
    });
    return { selected, evaluation };
  }

  private async retrieve(request: ParsedRequest): Promise<OptimizerResult> {
    const listed = shortlist(request);
    if (listed.candidates.length === 0) return abstain(request, 'no_candidates', { rejected: listed.rejected });
    let ranked: { selected: CheckedCandidate[]; evaluation?: Evaluation; failureReason?: string; failureUsage?: OptimizerUsage };
    try {
      ranked = await this.rank(request, listed.candidates, 'reusable plan retrieval');
    } catch {
      return abstain(request, 'invalid_evaluation', { rejected: listed.rejected });
    }
    if (!ranked.evaluation) {
      return {
        ...abstain(request, ranked.failureReason ?? 'evaluation_unavailable', { rejected: listed.rejected }),
        usage: ranked.failureUsage ?? usage(),
      };
    }
    if (ranked.selected.length === 0) {
      return { ...abstain(request, 'no_safe_match', { rejected: listed.rejected }), usage: ranked.evaluation.usage };
    }
    const selected = ranked.selected.map((entry) => sanitizedCandidate(entry.candidate));
    return {
      ok: true,
      command: request.command,
      status: this.status(request),
      applied: false,
      reason: this.autoGate(request) ? 'trusted_profile_suggestion' : 'plan_candidates_ranked',
      selected_ids: ranked.selected.map((entry) => entry.id),
      selected,
      rejected: listed.rejected,
      verification_required: true,
      usage: ranked.evaluation.usage,
    };
  }

  private async selectTools(request: ParsedRequest): Promise<OptimizerResult> {
    const essentials = request.candidates.filter((candidate) => candidate.essential === true || candidate.permission_or_coordination === true);
    const optional = request.candidates.filter((candidate) => !essentials.includes(candidate));
    const optionalRequest = { ...request, candidates: optional };
    const listed = shortlist(optionalRequest);
    const essentialIds = essentials.map((candidate, index) => candidateId(candidate, `essential_${index + 1}`));
    if (listed.candidates.length === 0) {
      return abstain(request, 'full_catalog_fallback', {
        selected_ids: essentialIds,
        preserved_essential_ids: essentialIds,
        full_catalog_fallback: true,
      });
    }
    let ranked: { selected: CheckedCandidate[]; evaluation?: Evaluation; failureReason?: string; failureUsage?: OptimizerUsage };
    try {
      ranked = await this.rank(request, listed.candidates, 'tool selection');
    } catch {
      return abstain(request, 'invalid_evaluation', { selected_ids: essentialIds, preserved_essential_ids: essentialIds, full_catalog_fallback: true });
    }
    if (!ranked.evaluation || ranked.selected.length === 0) {
      return {
        ...abstain(request, ranked.evaluation ? 'full_catalog_fallback' : ranked.failureReason ?? 'evaluation_unavailable', {
          selected_ids: essentialIds,
          preserved_essential_ids: essentialIds,
          full_catalog_fallback: true,
        }),
        usage: ranked.evaluation?.usage ?? ranked.failureUsage ?? usage(),
      };
    }
    return {
      ok: true,
      command: request.command,
      status: this.status(request),
      applied: false,
      reason: 'tool_candidates_ranked',
      selected_ids: [...new Set([...essentialIds, ...ranked.selected.map((entry) => entry.id)])],
      preserved_essential_ids: essentialIds,
      full_catalog_fallback: true,
      usage: ranked.evaluation.usage,
    };
  }

  private async routeModel(request: ParsedRequest): Promise<OptimizerResult> {
    const explicitId = stringValue(request.raw.explicit_model_id);
    if (explicitId) {
      return {
        ok: true, command: request.command, status: this.status(request), applied: false,
        reason: 'explicit_model_preserved', selected_id: explicitId, usage: usage(),
      };
    }
    const explicit = request.candidates.find((candidate) => candidate.explicitly_selected === true);
    if (explicit) {
      return {
        ok: true, command: request.command, status: this.status(request), applied: false,
        reason: 'explicit_model_preserved', selected_id: candidateId(explicit, explicitId), usage: usage(),
      };
    }
    const current = request.candidates.find((candidate) => candidate.is_current === true);
    if (!current) return abstain(request, 'current_model_unknown');
    const requirements = isRecord(request.raw.task_requirements) ? request.raw.task_requirements : {};
    if (requirements.at_task_boundary !== true) {
      return abstain(request, 'retain_current_not_task_boundary', { selected_id: candidateId(current, 'current') });
    }
    const inputTokens = finiteNumber(requirements.estimated_input_tokens);
    const outputTokens = finiteNumber(requirements.estimated_output_tokens);
    const cacheRebuildCost = finiteNumber(requirements.cache_rebuild_cost_usd);
    const fallbackCost = finiteNumber(requirements.fallback_cost_usd);
    const optimizerCost = request.policy.optimizerCostUsd;
    if ([inputTokens, outputTokens, cacheRebuildCost, fallbackCost, optimizerCost].some((value) => value === undefined)) {
      return abstain(request, 'retain_current_unknown_cost_benefit', { selected_id: candidateId(current, 'current') });
    }
    const requiredCapabilities = normalizedSet(stringList(requirements.required_capabilities));
    const allowedProviders = normalizedSet(stringList(requirements.allowed_providers));
    const allowedModelIds = normalizedSet(stringList(requirements.allowed_model_ids));
    const requiredContext = inputTokens! + outputTokens!;
    const requiredPrivacyRoute = normalized(stringValue(requirements.privacy_route));
    const requiredBillingMode = normalized(stringValue(requirements.billing_mode));
    const requiredRouteType = normalized(stringValue(requirements.route_type));
    const currentBillingMode = normalized(stringValue(current.billing_mode));
    const currentRouteType = normalized(stringValue(current.route_type));
    const currentPrivacyRoute = normalized(stringValue(current.privacy_route));
    const currentProvider = normalized(stringValue(current.provider));
    const eligible = request.candidates.filter((candidate) => {
      const id = normalized(candidateId(candidate, ''));
      if (allowedModelIds.size > 0 && !allowedModelIds.has(id)) return false;
      if (allowedProviders.size > 0 && !allowedProviders.has(normalized(stringValue(candidate.provider)))) return false;
      if (allowedProviders.size === 0 && normalized(stringValue(candidate.provider)) !== currentProvider) return false;
      const capabilities = normalizedSet(stringList(candidate.capabilities));
      if ([...requiredCapabilities].some((capability) => !capabilities.has(capability))) return false;
      const contextLimit = finiteNumber(candidate.context_limit);
      if (contextLimit === undefined || contextLimit < requiredContext) return false;
      const privacyRoute = normalized(stringValue(candidate.privacy_route));
      const billingMode = normalized(stringValue(candidate.billing_mode));
      const routeType = normalized(stringValue(candidate.route_type));
      if (requiredPrivacyRoute && privacyRoute !== requiredPrivacyRoute) return false;
      if (!requiredPrivacyRoute && privacyRoute !== currentPrivacyRoute) return false;
      if (requiredBillingMode && billingMode !== requiredBillingMode) return false;
      if (billingMode !== currentBillingMode) return false;
      if (requiredRouteType && routeType !== requiredRouteType) return false;
      if (routeType !== currentRouteType) return false;
      return finiteNumber(candidate.input_cost_per_million) !== undefined &&
        finiteNumber(candidate.output_cost_per_million) !== undefined &&
        finiteNumber(candidate.observed_success_rate) !== undefined;
    });
    if (!eligible.includes(current)) return abstain(request, 'retain_current_unknown_cost_or_quality', { selected_id: candidateId(current, 'current') });
    const routingRequest = { ...request, candidates: eligible };
    const listed = shortlist(routingRequest);
    if (listed.candidates.length === 0) return abstain(request, 'retain_current_no_candidate', { selected_id: candidateId(current, 'current') });
    let ranked: { selected: CheckedCandidate[]; evaluation?: Evaluation; failureReason?: string; failureUsage?: OptimizerUsage };
    try {
      ranked = await this.rank(request, listed.candidates, 'model routing');
    } catch {
      return abstain(request, 'invalid_evaluation', { selected_id: candidateId(current, 'current') });
    }
    if (!ranked.evaluation || ranked.selected.length === 0) {
      return {
        ...abstain(request, ranked.evaluation ? 'retain_current_uncertain' : ranked.failureReason ?? 'evaluation_unavailable', {
          selected_id: candidateId(current, 'current'),
        }),
        usage: ranked.evaluation?.usage ?? ranked.failureUsage ?? usage(),
      };
    }
    const executionCost = (candidate: JsonRecord): number =>
      (inputTokens! * finiteNumber(candidate.input_cost_per_million)! + outputTokens! * finiteNumber(candidate.output_cost_per_million)!) / 1_000_000;
    const proposedTotal = (candidate: JsonRecord): number =>
      executionCost(candidate) + cacheRebuildCost! + fallbackCost! + optimizerCost!;
    const baselineTotal = executionCost(current);
    const currentSuccess = finiteNumber(current.observed_success_rate)!;
    const best = ranked.selected
      .filter((entry) => finiteNumber(entry.candidate.observed_success_rate)! >= currentSuccess)
      .sort((a, b) => proposedTotal(a.candidate) - proposedTotal(b.candidate))[0];
    if (!best || proposedTotal(best.candidate) >= baselineTotal) {
      return { ...abstain(request, 'retain_current_no_proven_benefit', { selected_id: candidateId(current, 'current') }), usage: ranked.evaluation.usage };
    }
    return {
      ok: true, command: request.command, status: this.status(request), applied: false,
      reason: 'lower_estimated_cost_with_quality_gate', selected_id: best.id,
      current_estimated_total_cost_usd: baselineTotal,
      proposed_estimated_total_cost_usd: proposedTotal(best.candidate),
      usage: ranked.evaluation.usage,
    };
  }

  private async assessMemory(request: ParsedRequest): Promise<OptimizerResult> {
    const proposed = isRecord(request.raw.proposed_memory) ? request.raw.proposed_memory : {};
    const proposedText = stringValue(proposed.content);
    if (!proposedText) return abstain(request, 'missing_proposed_memory');
    const exact = request.candidates.find((candidate, index) =>
      checkCandidate(request, candidate, index).ok && normalized(stringValue(candidate.content)) === normalized(proposedText),
    );
    if (exact) {
      return {
        ok: true, command: request.command, status: this.status(request), applied: false,
        reason: 'exact_duplicate', disposition: 'duplicate', related_id: candidateId(exact, 'existing'), usage: usage(),
      };
    }
    const memoryRequest = { ...request, requestText: proposedText };
    const listed = shortlist(memoryRequest);
    if (listed.candidates.length === 0) return abstain(request, 'no_related_memory', { disposition: 'uncertain' });
    const state = {
      purpose: 'memory retention assessment',
      permission_fingerprint: stringValue(request.raw.permission_fingerprint, 1_000),
      proposed_memory: { content: proposedText.slice(0, MAX_TEXT_CHARS), tags: stringList(proposed.tags) },
      existing: listed.candidates.map((entry, index) => ({ index, candidate: sanitizedCandidate(entry.candidate) })),
    };
    const questions: JevQuestions = {
      worth_retain: { type: 'noul', instructions: 'The proposed memory is durable, project-relevant, and worth retaining as advisory knowledge' },
      none_related: { type: 'noul', instructions: 'None of the existing memories overlap or conflict with the proposed memory' },
    };
    listed.candidates.forEach((_, index) => {
      questions[`duplicate_${index}`] = { type: 'noul', instructions: `Existing memory ${index} already contains the same durable information` };
      questions[`conflict_${index}`] = { type: 'noul', instructions: `Existing memory ${index} materially conflicts with the proposed memory` };
    });
    const attempt = await this.evaluate(request, state, questions);
    const evaluation = attempt.evaluation;
    if (!evaluation) {
      return {
        ...abstain(request, attempt.failureReason ?? 'evaluation_unavailable', { disposition: 'uncertain' }),
        usage: attempt.usage ?? usage(),
      };
    }
    try {
      for (let index = 0; index < listed.candidates.length; index += 1) {
        if (noulAnswer(evaluation.response.answers, `conflict_${index}`) >= request.policy.threshold) {
          return {
            ok: true, command: request.command, status: this.status(request), applied: false,
            reason: 'memory_conflict', disposition: 'conflict', related_id: listed.candidates[index]!.id, usage: evaluation.usage,
          };
        }
        if (noulAnswer(evaluation.response.answers, `duplicate_${index}`) >= request.policy.threshold) {
          return {
            ok: true, command: request.command, status: this.status(request), applied: false,
            reason: 'memory_duplicate', disposition: 'duplicate', related_id: listed.candidates[index]!.id, usage: evaluation.usage,
          };
        }
      }
      const retain = noulAnswer(evaluation.response.answers, 'worth_retain') >= request.policy.threshold;
      return {
        ok: true, command: request.command, status: this.status(request), applied: false,
        reason: retain ? 'worth_retaining' : 'retention_uncertain', disposition: retain ? 'retain' : 'uncertain', usage: evaluation.usage,
      };
    } catch {
      return { ...abstain(request, 'invalid_evaluation', { disposition: 'uncertain' }), usage: evaluation.usage };
    }
  }
}

export interface LabeledOptimizerCase {
  id: string;
  expected: string;
  input: unknown;
}

export interface OptimizerEvaluationReport {
  kind: 'synthetic_structural';
  cases: number;
  correct: number;
  accuracy: number;
  failures: string[];
}

/** Structural fixture harness; its result is not model accuracy or a savings measurement. */
export async function evaluateOptimizerLabels(
  cases: readonly LabeledOptimizerCase[],
  predict: (input: unknown) => Promise<string> | string,
): Promise<OptimizerEvaluationReport> {
  const failures: string[] = [];
  for (const testCase of cases) {
    let actual: string;
    try {
      actual = await predict(testCase.input);
    } catch {
      actual = 'error';
    }
    if (actual !== testCase.expected) failures.push(testCase.id);
  }
  const correct = cases.length - failures.length;
  return {
    kind: 'synthetic_structural',
    cases: cases.length,
    correct,
    accuracy: cases.length === 0 ? 0 : correct / cases.length,
    failures,
  };
}
