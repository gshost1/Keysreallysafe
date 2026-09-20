import type {
  On,
  PluginOptions,
  Register,
  SessionMessage,
  ToolResultSummary,
  ToolUseSummary,
  TurnCompleteInput,
} from 'claude-code';

import { compact, reductionRatio, resolveOptions } from '../src/compact.js';
import { buildJevRequest, DEFAULT_MODEL, parseJevResponse, providerModel, validScopedEndpoint, type JevProvider } from '../src/request.js';
import type {
  CompactOptions,
  CompactResult,
  JevAsker,
  Message,
  ToolResult,
  ToolUse,
} from '../src/types.js';

const HOOK_DEFAULTS = {
  compactAtPercent: 60,
  minReductionRatio: 0.25,
  model: DEFAULT_MODEL,
  minContextGrowthTokens: 8_000,
  mode: 'apply' as const,
};

export type HookFetchInit = {
  method?: string;
  headers?: Record<string, string>;
  body?: string;
};

export type HookFetchResponse = {
  status: number;
  ok: boolean;
  text: string;
};

/** The shape of `$.http.fetch`, so the hook can be driven without an engine. */
export type HookFetch = (url: string, init?: HookFetchInit) => Promise<HookFetchResponse>;

export type HookConfig = CompactOptions & {
  apiKey?: string;
  compactAtPercent: number;
  minReductionRatio: number;
  model: string;
  minContextGrowthTokens: number;
  mode: 'apply' | 'observe';
  /** Overrides the Vercel AI Gateway evaluation endpoint, e.g. a self-hosted gateway. */
  baseUrl?: string;
  provider?: JevProvider;
};

/**
 * The key and the conversation state go to this URL, so only https is
 * accepted; plain http is allowed for a loopback proxy alone. A bad value
 * throws at load, which is louder than silently using the default endpoint.
 */
export function validateBaseUrl(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error('baseUrl is not a valid URL');
  }
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) {
    throw new Error('baseUrl must be https (http is allowed only for localhost)');
  }
  if (url.username || url.password) throw new Error('baseUrl must not embed credentials');
  return url.toString();
}

function optionNumber(options: PluginOptions, key: string, fallback: number): number {
  const value = options[key];
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

function optionString(options: PluginOptions, key: string): string | undefined {
  const value = options[key];
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

/** Reads the plugin's `userConfig` values; anything missing takes the defaults. */
export function resolveHookConfig(options: PluginOptions): HookConfig {
  const numbers: Partial<Omit<CompactOptions, 'goal'>> = {};
  for (const key of [
    'keepThreshold',
    'preserveRecentMessages',
    'maxStateTokens',
    'maxRequestTokens',
    'truncateHeadChars',
    'minRemovableChars',
    'maxCandidates',
    'maxDecisionInputTokens',
    'maxRequests',
    'maxConcurrency',
  ] as const) {
    const value = options[key];
    if (typeof value === 'number' && Number.isFinite(value)) numbers[key] = value;
  }
  const config: HookConfig = {
    ...numbers,
    compactAtPercent: Math.max(0, Math.min(100, optionNumber(options, 'compactAtPercent', HOOK_DEFAULTS.compactAtPercent))),
    minReductionRatio: Math.max(0, Math.min(1, optionNumber(options, 'minReductionRatio', HOOK_DEFAULTS.minReductionRatio))),
    minContextGrowthTokens: Math.max(1, optionNumber(options, 'minContextGrowthTokens', HOOK_DEFAULTS.minContextGrowthTokens)),
    mode: options.mode === 'observe' ? 'observe' : 'apply',
    model: optionString(options, 'model') ?? HOOK_DEFAULTS.model,
  };
  const apiKey = optionString(options, 'apiKey');
  if (apiKey) config.apiKey = apiKey;
  const baseUrl = optionString(options, 'baseUrl');
  if (baseUrl) config.baseUrl = validateBaseUrl(baseUrl);
  const goal = optionString(options, 'goal');
  if (goal) config.goal = goal;
  return config;
}

/** A `JevAsker` over the engine's `$.http.fetch`. */
export function jevAsker(
  fetchFn: HookFetch,
  apiKey: string,
  model: string,
  baseUrl?: string,
  provider: JevProvider = 'vercel-ai-gateway',
): JevAsker {
  return {
    async ask(state, questions) {
      const request = buildJevRequest({ apiKey, model, baseUrl, provider }, state, questions);
      const response = await fetchFn(request.url, {
        method: request.method,
        headers: request.headers,
        body: request.body,
      });
      return parseJevResponse(response.status, response.ok, response.text, provider);
    },
  };
}

function toolUseSummary(tool: ToolUse): ToolUseSummary {
  const summary: ToolUseSummary = {
    tool_use_id: tool.tool_use_id,
    tool: tool.tool,
    input: tool.input,
  };
  if (tool.text !== undefined) summary.text = tool.text;
  if (tool.isError) summary.isError = true;
  return summary;
}

function toolResultSummary(result: ToolResult): ToolResultSummary {
  return {
    tool_use_id: result.tool_use_id,
    text: result.text,
    isError: result.isError ?? false,
  };
}

/**
 * Maps the library's output back onto session messages. Whatever came back
 * unchanged (a message, a tool use, a tool result) is the engine's own object,
 * handle included; anything rebuilt is a fresh message without a handle, so the
 * engine takes the edited content instead of its original.
 */
export function toSessionMessages(
  input: readonly SessionMessage[],
  output: readonly Message[],
): SessionMessage[] {
  const messages = new Map<Message, SessionMessage>();
  const uses = new Map<ToolUse, ToolUseSummary>();
  const results = new Map<ToolResult, ToolResultSummary>();
  for (const message of input) {
    messages.set(message, message);
    for (const tool of message.toolUses) uses.set(tool, tool);
    for (const result of message.toolResults ?? []) results.set(result, result);
  }
  return output.map((message) => {
    const own = messages.get(message);
    if (own) return own;
    const rebuilt: SessionMessage = {
      role: message.role,
      text: message.text,
      toolUses: message.toolUses.map((tool) => uses.get(tool) ?? toolUseSummary(tool)),
    };
    if (message.toolResults && message.toolResults.length > 0) {
      rebuilt.toolResults = message.toolResults.map(
        (result) => results.get(result) ?? toolResultSummary(result),
      );
    }
    return rebuilt;
  });
}

export type SessionCompaction = {
  result: CompactResult;
  messages: SessionMessage[];
};

/** Runs the library over a session transcript; throws when the key is missing or Jev fails. */
export async function compactSession(
  messages: readonly SessionMessage[],
  config: HookConfig,
  fetchFn: HookFetch,
  asker?: JevAsker,
): Promise<SessionCompaction> {
  if (!config.apiKey) throw new Error('AI_GATEWAY_API_KEY is not configured');
  const result = await compact(messages, asker ?? jevAsker(fetchFn, config.apiKey, config.model, config.baseUrl, config.provider), config);
  return { result, messages: toSessionMessages(messages, result.messages) };
}

function percent(ratio: number): string {
  return `${Math.round(ratio * 100)}%`;
}

export function summarize(result: CompactResult): string {
  const { stats } = result;
  const parts = [
    stats.kept > 0 ? `${stats.kept} kept` : '',
    stats.resultsDropped > 0 ? `${stats.resultsDropped} results truncated` : '',
    stats.callsDropped > 0 ? `${stats.callsDropped} call_dropped` : '',
    stats.pinned > 0 ? `${stats.pinned} pinned` : '',
    stats.errorsKept > 0 ? `${stats.errorsKept} errors preserved` : '',
    stats.protected > 0 ? `${stats.protected} instruction/coordination outputs preserved` : '',
  ].filter(Boolean);
  const usage = stats.jevUsage;
  return `${percent(reductionRatio(result))} character reduction; ${parts.join(', ') || 'no tool calls'}; ` +
    `${stats.requests} request(s), ${stats.cacheHits} exact decision cache hit(s); ` +
    `Jev reported input=${usage.inputTokens ?? 'unknown'}, output=${usage.outputTokens ?? 'unknown'} tokens ` +
    `(${usage.complete ? 'complete' : 'incomplete'}); estimated request input ~${stats.estimatedDecisionInputTokens} tokens` +
    (stats.skippedReason ? `; skipped: ${stats.skippedReason}` : '');
}

const UI_LOG_MAX_CHARS = 4096;

export function decisionLog(result: CompactResult): string {
  return result.decisions
    .filter((d) => d.reason !== 'pinned')
    .map(
      (d) =>
        `${d.id}:${d.tool}:${d.action}/call=${d.keepCall.toFixed(2)}/result=${d.keepResult.toFixed(2)}`,
    )
    .join(' ');
}

export function decisionLogLines(
  result: CompactResult,
  maxChars: number = UI_LOG_MAX_CHARS,
): string[] {
  const entries = decisionLog(result).split(' ').filter(Boolean);
  if (entries.length === 0) return ['decisions: (none)'];
  const chunks: string[] = [];
  let current = '';
  for (const entry of entries) {
    const next = current ? `${current} ${entry}` : entry;
    if (current && next.length > maxChars - 24) {
      chunks.push(current);
      current = entry;
    } else current = next;
  }
  chunks.push(current);
  return chunks.map((chunk, index) =>
    chunks.length === 1
      ? `decisions: ${chunk}`
      : `decisions (${index + 1}/${chunks.length}): ${chunk}`,
  );
}

async function getApiKey(
  $: {
    env: { get: (name: string) => Promise<string | undefined> };
    settings: { read: () => Promise<Readonly<Record<string, unknown>>> };
  },
  config: HookConfig,
): Promise<string | undefined> {
  if (config.apiKey) return config.apiKey;
  const fromEnv = await $.env.get('AI_GATEWAY_API_KEY');
  if (fromEnv) return fromEnv;
  const settings = await $.settings.read();
  const env = settings['env'];
  if (env && typeof env === 'object') {
    const value = (env as Record<string, unknown>)['AI_GATEWAY_API_KEY'];
    if (typeof value === 'string' && value) return value;
  }
  return undefined;
}

/**
 * The endpoint: the `baseUrl` option, else `AI_GATEWAY_BASE_URL` from the
 * environment, else the library default. The environment route lets a
 * launcher point one session at a local key-broker gateway without touching
 * stored settings. Either way the value passes `validateBaseUrl`.
 */
export async function getBaseUrl(
  $: { env: { get: (name: string) => Promise<string | undefined> } },
  config: HookConfig,
): Promise<string | undefined> {
  if (config.baseUrl) return config.baseUrl;
  const fromEnv = await $.env.get('AI_GATEWAY_BASE_URL');
  return fromEnv ? validateBaseUrl(fromEnv) : undefined;
}

/** A Keys launcher grant must never be combined with a saved endpoint or upstream key. */
export async function getScopedConnection(
  $: { env: { get: (name: string) => Promise<string | undefined> } },
): Promise<{ apiKey: string; baseUrl: string; provider: JevProvider } | undefined> {
  if (await $.env.get('KEYS_JEV_SCOPED_GRANT') !== '1') return undefined;
  const [apiKey, baseUrl, selectedProvider] = await Promise.all([
    $.env.get('AI_GATEWAY_API_KEY'), $.env.get('AI_GATEWAY_BASE_URL'), $.env.get('KEYS_JEV_PROVIDER'),
  ]);
  const provider = selectedProvider ?? 'vercel-ai-gateway';
  if (provider !== 'vercel-ai-gateway' && provider !== 'typesafe') throw new Error('Unsupported Keys Jev provider');
  if (!apiKey || !baseUrl) throw new Error('Keys Jev scoped grant requires both gateway environment values');
  if (!/^ksf_[0-9a-f]{8}_[A-Za-z0-9_-]{43}$/.test(apiKey)) {
    throw new Error('Invalid Keys Jev scoped grant token');
  }
  // Match the literal launcher URL, not URL-normalized alternative hosts or paths.
  if (!validScopedEndpoint(provider, baseUrl)) {
    throw new Error('Keys Jev scoped grant requires the local Keys evaluation endpoint');
  }
  return { apiKey, baseUrl, provider };
}

function notify(
  $: {
    ui: {
      log: (text: string) => void;
      toast: (text: string, options?: { timeoutMs?: number }) => void;
    };
  },
  text: string,
): void {
  $.ui.log(text);
  $.ui.toast(text, { timeoutMs: 15_000 });
}

export const register: Register = (on: On, options: PluginOptions) => {
  const configured = resolveHookConfig(options);
  let compacting = false;
  let lastAttemptTokens: number | undefined;
  // The transport instance (and its exact decision cache) is session-local.
  let active: { apiKey: string; model: string; baseUrl?: string; provider?: JevProvider; asker: JevAsker; fetch: HookFetch } | undefined;

  on('session.compact', async ($, event, next) => {
    // Explicit summarization instructions belong to the built-in summarizer.
    if (event.instructions?.trim()) return next(event);
    const ownAutomatic = event.trigger === 'plugin' && compacting && !event.agentId;
    try {
      const scoped = await getScopedConnection($);
      const config: HookConfig = { ...configured, apiKey: scoped?.apiKey ?? await getApiKey($, configured) };
      if (scoped) {
        config.provider = scoped.provider;
        // A scoped connection's model and wire protocol cannot be overridden by saved plugin settings.
        config.model = providerModel(scoped.provider);
      }
      const baseUrl = scoped?.baseUrl ?? await getBaseUrl($, configured);
      if (baseUrl) config.baseUrl = baseUrl;
      if (!config.apiKey) throw new Error('AI_GATEWAY_API_KEY is not configured');
      const fetchFn: HookFetch = async (url, init) => {
        const response = await $.http.fetch(url, init);
        return { status: response.status, ok: response.ok, text: response.text };
      };
      if (!active || active.apiKey !== config.apiKey || active.model !== config.model || active.baseUrl !== config.baseUrl || active.provider !== config.provider) {
        const entry = { apiKey: config.apiKey, model: config.model, baseUrl: config.baseUrl, provider: config.provider, fetch: fetchFn, asker: undefined as unknown as JevAsker };
        entry.asker = jevAsker((url, init) => entry.fetch(url, init), config.apiKey, config.model, config.baseUrl, config.provider);
        active = entry;
      }
      active.fetch = fetchFn;
      const { result, messages } = await compactSession(event.messages, config, fetchFn, active.asker);
      for (const line of decisionLogLines(result)) $.ui.log(line);
      if (config.mode === 'observe') {
        notify($, `observe only: proposed ${summarize(result)}`);
        // Our early observation must not compact. A user/host-requested compaction still works normally.
        return ownAutomatic ? { skip: 'Jev observe mode leaves the transcript unchanged' } : next(event);
      }
      if (result.stats.skippedReason && ownAutomatic) {
        $.ui.log(`auto-compact skipped (${summarize(result)})`);
        return { skip: `Jev preflight: ${result.stats.skippedReason}` };
      }
      if (reductionRatio(result) < config.minReductionRatio) {
        notify($, `fallback to built-in summary (below ${percent(config.minReductionRatio)} minimum: ${summarize(result)})`);
        return next(event);
      }
      notify($, `kept ${messages.length}/${event.messages.length} messages, no summary (${summarize(result)})`);
      return { messages };
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      if (configured.mode === 'observe' && ownAutomatic) {
        $.ui.log(`observation skipped (${reason})`);
        return { skip: 'Jev observation unavailable; transcript unchanged' };
      }
      notify($, `fallback to built-in summary (${reason})`);
      return next(event);
    }
  });

  on('turn.complete', async ($, event: TurnCompleteInput, next) => {
    // $.session is the main conversation even when this event belongs to a subagent.
    if (compacting || event.agentId || event.reason !== 'answer') return next(event);
    try {
      const { context } = await $.session.usage();
      const tokens = context.tokens;
      if (typeof tokens !== 'number' || !Number.isFinite(tokens) || tokens < 0) return next(event);
      // The first response after any compaction or /clear establishes the smaller baseline.
      if (lastAttemptTokens !== undefined && tokens < lastAttemptTokens) lastAttemptTokens = tokens;
      if ((context.percent ?? 0) < configured.compactAtPercent) return next(event);
      if (lastAttemptTokens !== undefined && tokens - lastAttemptTokens < configured.minContextGrowthTokens) return next(event);
      lastAttemptTokens = tokens;
      compacting = true;
      await $.session.compact();
    } catch (error) {
      $.ui.log(`auto-compact skipped (${error instanceof Error ? error.message : String(error)})`);
    } finally {
      compacting = false;
    }
    return next(event);
  });
};

export { resolveOptions };
