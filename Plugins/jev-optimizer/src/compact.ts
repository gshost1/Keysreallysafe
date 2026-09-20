import { noulAnswer } from './request.js';
import { readDecisionCache, writeDecisionCache, decisionCacheKey } from './cache.js';
import { collectToolCalls, estimateTokens, fitState } from './state.js';
import type {
  CallAnswer,
  CallDecision,
  CompactOptions,
  CompactResult,
  CompactionState,
  JevAsker,
  JevQuestions,
  JevResponse,
  Message,
  ResolvedCompactOptions,
  ToolCall,
  ToolUse,
} from './types.js';

export const DEFAULT_OPTIONS: ResolvedCompactOptions = {
  goal: '',
  keepThreshold: 0.2,
  preserveRecentMessages: 6,
  maxStateTokens: 25_000,
  maxRequestTokens: 30_000,
  truncateHeadChars: 300,
  minRemovableChars: 4_000,
  maxCandidates: 16,
  maxDecisionInputTokens: 60_000,
  maxRequests: 3,
  maxConcurrency: 2,
};

/** Tokens the request envelope (`model`, key names) adds around state and questions. */
const REQUEST_OVERHEAD_TOKENS = 20;

function finite(value: number | undefined, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

export function resolveOptions(options: CompactOptions = {}): ResolvedCompactOptions {
  return {
    goal: options.goal ?? DEFAULT_OPTIONS.goal,
    keepThreshold: Math.max(0, Math.min(1, finite(options.keepThreshold, DEFAULT_OPTIONS.keepThreshold))),
    preserveRecentMessages: Math.max(
      0,
      Math.floor(
        finite(options.preserveRecentMessages, DEFAULT_OPTIONS.preserveRecentMessages),
      ),
    ),
    maxStateTokens: Math.max(1, finite(options.maxStateTokens, DEFAULT_OPTIONS.maxStateTokens)),
    maxRequestTokens: Math.max(
      1,
      finite(options.maxRequestTokens, DEFAULT_OPTIONS.maxRequestTokens),
    ),
    minRemovableChars: Math.max(0, finite(options.minRemovableChars, DEFAULT_OPTIONS.minRemovableChars)),
    maxCandidates: Math.max(1, Math.floor(finite(options.maxCandidates, DEFAULT_OPTIONS.maxCandidates))),
    maxDecisionInputTokens: Math.max(0, finite(options.maxDecisionInputTokens, DEFAULT_OPTIONS.maxDecisionInputTokens)),
    maxRequests: Math.max(0, Math.floor(finite(options.maxRequests, DEFAULT_OPTIONS.maxRequests))),
    maxConcurrency: Math.max(1, Math.min(8, Math.floor(finite(options.maxConcurrency, DEFAULT_OPTIONS.maxConcurrency)))),
    truncateHeadChars: Math.max(
      0,
      Math.floor(finite(options.truncateHeadChars, DEFAULT_OPTIONS.truncateHeadChars)),
    ),
  };
}

/** The two `noul` questions asked about one call: keep the call, keep its result. */
export function questionsFor(call: ToolCall): JevQuestions {
  return {
    [`call_${call.id}`]: {
      type: 'noul',
      instructions: `Tool call ${call.id} (${call.tool}) should stay in the history: knowing this call was made, with its input, still matters for what the assistant does next`,
    },
    [`result_${call.id}`]: {
      type: 'noul',
      instructions: `The full output of tool call ${call.id} (${call.tool}, ${call.resultChars} chars) should stay in the history verbatim: the assistant still needs its contents, or it is uncertain whether the evidence can be recovered safely`,
    },
  };
}

/**
 * Splits the candidate calls into batches whose questions, together with the
 * (always complete) state, fit one request.
 */
export function batchCalls(
  calls: readonly ToolCall[],
  stateTokens: number,
  options: Pick<ResolvedCompactOptions, 'maxRequestTokens'>,
): ToolCall[][] {
  const budget = options.maxRequestTokens - stateTokens - REQUEST_OVERHEAD_TOKENS;
  const batches: ToolCall[][] = [];
  let current: ToolCall[] = [];
  let currentTokens = 0;
  for (const call of calls) {
    const tokens = estimateTokens(JSON.stringify(questionsFor(call)));
    if (current.length > 0 && currentTokens + tokens > budget) {
      batches.push(current);
      current = [];
      currentTokens = 0;
    }
    if (current.length === 0 && tokens > budget) {
      throw new Error(
        `state leaves no room for questions (~${stateTokens} of ${options.maxRequestTokens} tokens)`,
      );
    }
    current.push(call);
    currentTokens += tokens;
  }
  if (current.length > 0) batches.push(current);
  return batches;
}

export function decideCall(
  call: Pick<ToolCall, 'id' | 'tool' | 'pinned'> & Partial<Pick<ToolCall, 'isError' | 'protected'>>,
  answer: CallAnswer,
  options: Pick<ResolvedCompactOptions, 'keepThreshold'>,
): CallDecision {
  const base = { id: call.id, tool: call.tool, ...answer };
  if (call.pinned) return { ...base, action: 'keep', reason: 'pinned' };
  if (call.isError) return { ...base, action: 'keep', reason: 'error' };
  if (call.protected) return { ...base, action: 'keep', reason: 'protected' };
  if (![answer.keepCall, answer.keepResult].every((p) => Number.isFinite(p) && p >= 0 && p <= 1)) {
    throw new Error(`Invalid evaluation answer for ${call.id}`);
  }
  if (answer.keepResult >= options.keepThreshold) {
    return { ...base, action: 'keep', reason: 'kept' };
  }
  if (answer.keepCall >= options.keepThreshold) {
    return { ...base, action: 'drop_result', reason: 'result_dropped' };
  }
  return { ...base, action: 'drop_call', reason: 'call_dropped' };
}

type BatchAnswer = { answers: Map<string, CallAnswer>; usage?: JevResponse['usage']; cached: boolean };

async function askBatch(
  asker: JevAsker,
  state: CompactionState,
  batch: readonly ToolCall[],
  questions: JevQuestions,
  key: string,
  cached?: Map<string, CallAnswer>,
): Promise<BatchAnswer> {
  if (cached) return { answers: cached, cached: true };
  const response = await asker.ask(state, questions);
  const answers = new Map(batch.map((call) => [call.id, {
    keepCall: noulAnswer(response.answers, `call_${call.id}`),
    keepResult: noulAnswer(response.answers, `result_${call.id}`),
  }]));
  // Cache only complete, validated decisions. Paid usage belongs only to this request.
  writeDecisionCache(asker, key, answers);
  return { answers, usage: response.usage, cached: false };
}

/** Wait for already-started requests on failure and stop scheduling new work. */
async function boundedMap<T, R>(items: readonly T[], concurrency: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  let failed = false;
  let failure: unknown;
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (!failed && next < items.length) {
      const index = next++;
      try { results[index] = await fn(items[index]!); }
      catch (error) { failed = true; failure ??= error; }
    }
  }));
  if (failed) throw failure;
  return results;
}

function validUsage(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

function truncatedResultText(text: string, isError: boolean, headChars: number): string {
  if (text.length <= headChars + 120) return text;
  const head = headChars > 0 ? `${text.slice(0, headChars)}\n` : '';
  return `${head}[keys-jev-optimizer truncated ${text.length - headChars} chars of this tool result${
    isError ? ' (error)' : ''
  }; consult the original transcript or re-read only if safe]`;
}

/**
 * Rebuilds the conversation from the decisions. A dropped call disappears
 * together with its result; a dropped result keeps a bounded head and note.
 * Messages that lose all their content are removed; untouched messages are
 * returned as the same objects they came in as.
 */
export function applyDecisions(
  messages: readonly Message[],
  decisions: readonly CallDecision[],
  calls: readonly ToolCall[],
  headChars: number,
): Message[] {
  const byId = new Map(calls.map((call) => [call.id, call]));
  const actions = new Map<string, CallDecision['action']>();
  for (const decision of decisions) {
    const call = byId.get(decision.id);
    if (call && !call.pinned && !call.isError && !call.protected && decision.action !== 'keep') {
      actions.set(call.tool_use_id, decision.action);
    }
  }
  const kept: Message[] = [];
  for (const message of messages) {
    const touched =
      message.toolUses.some((tool) => actions.has(tool.tool_use_id)) ||
      (message.toolResults ?? []).some((result) => actions.has(result.tool_use_id));
    if (!touched) {
      kept.push(message);
      continue;
    }
    const toolUses = message.toolUses
      .filter((tool) => actions.get(tool.tool_use_id) !== 'drop_call')
      .map((tool) => {
        if (actions.get(tool.tool_use_id) !== 'drop_result') return tool;
        const text = truncatedResultText(
          tool.text ?? '',
          tool.isError ?? false,
          headChars,
        );
        if ((tool.text ?? '') === text) return tool;
        const copy: ToolUse = {
          tool_use_id: tool.tool_use_id,
          tool: tool.tool,
          input: tool.input,
          text,
        };
        if (tool.isError) copy.isError = true;
        return copy;
      });
    const toolResults = (message.toolResults ?? [])
      .filter((result) => actions.get(result.tool_use_id) !== 'drop_call')
      .map((result) => {
        if (actions.get(result.tool_use_id) !== 'drop_result') return result;
        const text = truncatedResultText(result.text, result.isError ?? false, headChars);
        return text === result.text
          ? result
          : {
              tool_use_id: result.tool_use_id,
              text,
              isError: result.isError,
            };
      });
    if (
      !message.toolUses.some(
        (tool) => actions.get(tool.tool_use_id) === 'drop_call',
      ) &&
      !(message.toolResults ?? []).some(
        (result) => actions.get(result.tool_use_id) === 'drop_call',
      ) &&
      toolUses.every((tool, index) => tool === message.toolUses[index]) &&
      toolResults.every(
        (result, index) => result === message.toolResults?.[index],
      )
    ) {
      kept.push(message);
      continue;
    }
    if (message.text.trim().length === 0 && toolUses.length === 0 && toolResults.length === 0) {
      continue;
    }
    const rebuilt: Message = { role: message.role, text: message.text, toolUses };
    if (toolResults.length > 0) rebuilt.toolResults = toolResults;
    kept.push(rebuilt);
  }
  return kept;
}

/** Characters of text, tool input and tool output a message holds. */
export function messageChars(message: Message): number {
  let total = message.text.length;
  for (const tool of message.toolUses) {
    try {
      total += JSON.stringify(tool.input).length;
    } catch {
      total += 20;
    }
  }
  for (const result of message.toolResults ?? []) total += result.text.length;
  return total;
}

export function reductionRatio(result: Pick<CompactResult, 'stats'>): number {
  const { charsBefore, charsAfter } = result.stats;
  return charsBefore === 0 ? 0 : (charsBefore - charsAfter) / charsBefore;
}

function count(decisions: readonly CallDecision[], reason: CallDecision['reason']): number {
  return decisions.filter((decision) => decision.reason === reason).length;
}

/**
 * Compacts a transcript by asking Jev, for every tool call outside the pinned
 * first and newest messages, whether the call and whether its result must
 * stay. The whole history (results omitted, fitted into `maxStateTokens`) is
 * sent as state with every batch of questions. Throws when Jev fails or the
 * history cannot be fitted; the caller decides whether to fall back.
 */
export async function compact(
  messages: readonly Message[],
  asker: JevAsker,
  options: CompactOptions = {},
): Promise<CompactResult> {
  const started = Date.now();
  const resolved = resolveOptions(options);
  const calls = collectToolCalls(messages, resolved.preserveRecentMessages);
  const candidates = calls.filter((call) => !call.pinned && !call.isError && !call.protected)
    .sort((a, b) => b.resultChars - a.resultChars)
    .slice(0, resolved.maxCandidates);
  const removableChars = candidates.reduce((sum, call) => sum + Math.max(0, call.resultChars - resolved.truncateHeadChars - 160), 0);
  const charsBefore = messages.reduce((sum, message) => sum + messageChars(message), 0);
  const skippedReason = candidates.length === 0 ? 'no_candidates' as const
    : removableChars < resolved.minRemovableChars ? 'below_minimum' as const : undefined;

  let fitted: { tokens: number; stage: string } = { tokens: 0, stage: '' };
  let requests = 0;
  let cacheHits = 0;
  let estimatedDecisionInputTokens = 0;
  let inputTokens: number | null = 0;
  let outputTokens: number | null = 0;
  const answers = new Map<string, CallAnswer>();
  if (!skippedReason) {
    const state = fitState(messages, calls, resolved);
    fitted = state;
    const jobs = batchCalls(candidates, state.tokens, resolved).map((batch) => {
      const questions: JevQuestions = Object.assign({}, ...batch.map(questionsFor));
      const key = decisionCacheKey(state.state, questions);
      const cached = readDecisionCache(asker, key);
      return { batch, questions, key, cached,
        tokens: state.tokens + estimateTokens(JSON.stringify(questions)) + REQUEST_OVERHEAD_TOKENS };
    });
    const misses = jobs.filter((job) => !job.cached);
    estimatedDecisionInputTokens = misses.reduce((sum, job) => sum + job.tokens, 0);
    // All budget checks happen before sending any request.
    if (misses.length > resolved.maxRequests) throw new Error(`Jev request budget exceeded (${misses.length} > ${resolved.maxRequests})`);
    if (estimatedDecisionInputTokens > resolved.maxDecisionInputTokens) {
      throw new Error(`Jev estimated input budget exceeded (${estimatedDecisionInputTokens} > ${resolved.maxDecisionInputTokens})`);
    }
    const answered = await boundedMap(jobs, resolved.maxConcurrency, (job) =>
      askBatch(asker, state.state, job.batch, job.questions, job.key, job.cached));
    for (const result of answered) {
      for (const [id, answer] of result.answers) answers.set(id, answer);
      if (result.cached) { cacheHits++; continue; }
      requests++;
      const input = result.usage?.input_tokens;
      const output = result.usage?.output_tokens;
      inputTokens = inputTokens !== null && validUsage(input) && validUsage(inputTokens + input) ? inputTokens + input : null;
      outputTokens = outputTokens !== null && validUsage(output) && validUsage(outputTokens + output) ? outputTokens + output : null;
    }
  }

  const decisions = calls.map((call) =>
    decideCall(call, answers.get(call.id) ?? { keepCall: 1, keepResult: 1 }, resolved),
  );
  const kept = applyDecisions(messages, decisions, calls, resolved.truncateHeadChars);
  return {
    messages: kept,
    decisions,
    stats: {
      messagesBefore: messages.length,
      messagesAfter: kept.length,
      charsBefore,
      charsAfter: kept.reduce((sum, message) => sum + messageChars(message), 0),
      calls: calls.length,
      kept: count(decisions, 'kept'),
      resultsDropped: count(decisions, 'result_dropped'),
      callsDropped: count(decisions, 'call_dropped'),
      pinned: count(decisions, 'pinned'),
      errorsKept: count(decisions, 'error'),
      protected: count(decisions, 'protected'),
      candidates: candidates.length,
      removableChars,
      skippedReason,
      stateTokens: fitted.tokens,
      stateStage: fitted.stage,
      requests,
      cacheHits,
      estimatedDecisionInputTokens,
      jevUsage: { inputTokens, outputTokens, complete: inputTokens !== null && outputTokens !== null },
      ms: Date.now() - started,
    },
  };
}
