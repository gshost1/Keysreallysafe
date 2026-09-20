import { afterEach, describe, expect, it, vi } from 'vitest';
import { applyDecisions, collectToolCalls, compact, fitState, resolveOptions, type JevAsker, type JevResponse, type Message } from '../src/index.js';

function transcript(sizes = [10_000, 8_000, 6_000]): Message[] {
  const messages: Message[] = [{ role: 'user', text: 'Fix the test; preserve requirements.', toolUses: [] }];
  sizes.forEach((size, index) => {
    const id = `c${index + 1}`;
    messages.push({ role: 'assistant', text: '', toolUses: [{ tool_use_id: id, tool: 'Read', input: { file_path: `src/${id}.ts` }, text: 'x'.repeat(size) }] });
    messages.push({ role: 'user', text: '', toolUses: [], toolResults: [{ tool_use_id: id, text: 'x'.repeat(size) }] });
  });
  messages.push({ role: 'user', text: 'Continue with the fix.', toolUses: [] });
  return messages;
}

function evaluator(probability = 0.1, usage?: JevResponse['usage']) {
  const ask = vi.fn<JevAsker['ask']>(async (_state, questions) => ({
    answers: Object.fromEntries(Object.keys(questions).map((key) => [key, { noul: probability }])), usage,
  }));
  return { ask };
}

const options = { preserveRecentMessages: 1 };
function splitOptions(messages: Message[]) {
  const tokens = fitState(messages, collectToolCalls(messages, 1), resolveOptions(options)).tokens;
  return { ...options, maxRequestTokens: tokens + 180, maxRequests: 10, maxDecisionInputTokens: 100_000 };
}

afterEach(() => vi.useRealTimers());

describe('preflight and preservation', () => {
  it.each(['SendMessage', 'TaskCreate', 'TaskUpdate', 'TaskList', 'TaskGet', 'TaskStop', 'ListAgents', 'Task', 'Agent', 'TaskOutput', 'ToolSearch', 'Skill', 'AskUserQuestion'])('preserves native %s coordination/instruction output', async (tool) => {
    const messages = transcript([10_000]);
    messages[1]!.toolUses[0]!.tool = tool;
    const asker = evaluator(0);
    const result = await compact(messages, asker, options);
    expect(asker.ask).not.toHaveBeenCalled();
    expect(result.stats).toMatchObject({ protected: 1, candidates: 0 });
    expect(result.messages).toEqual(messages);
  });

  it('leaves duplicate and reversed tool pairs untouched', async () => {
    for (const duplicate of ['call', 'result', 'reversed']) {
      const messages = transcript([10_000]);
      if (duplicate === 'call') messages.splice(2, 0, messages[1]!);
      if (duplicate === 'result') messages.splice(3, 0, messages[2]!);
      if (duplicate === 'reversed') [messages[1], messages[2]] = [messages[2]!, messages[1]!];
      const asker = evaluator(0);
      const result = await compact(messages, asker, options);
      expect(asker.ask).not.toHaveBeenCalled();
      expect(result.messages).toEqual(messages);
      expect(result.stats.calls).toBe(0);
    }
  });

  it('does not send small histories to Jev', async () => {
    const messages = transcript([1_000]);
    const asker = evaluator();
    const result = await compact(messages, asker, options);
    expect(asker.ask).not.toHaveBeenCalled();
    expect(result.messages).toEqual(messages);
    expect(result.stats).toMatchObject({ skippedReason: 'below_minimum', requests: 0, jevUsage: { inputTokens: 0, outputTokens: 0, complete: true } });
  });

  it('scores the largest outputs only and leaves the rest verbatim', async () => {
    const messages = transcript([5_000, 20_000, 10_000]);
    const asker = evaluator();
    const result = await compact(messages, asker, { ...options, maxCandidates: 2 });
    expect(Object.keys(asker.ask.mock.calls[0]![1]).sort()).toEqual(['call_t2', 'call_t3', 'result_t2', 'result_t3']);
    expect(result.messages).toContain(messages[1]);
    expect(result.messages).toContain(messages[2]);
    expect(result.stats.callsDropped).toBe(2);
  });

  it('preserves failed, instruction-loading, coordination and recent output without asking', async () => {
    const messages = transcript([10_000, 10_000, 10_000, 10_000, 10_000]);
    messages[2]!.toolResults![0]!.isError = true;
    messages[3]!.toolUses[0]!.input = { file_path: '/repo/AGENTS.md' };
    messages[5]!.toolUses[0]!.tool = 'mcp__tools__send_message';
    messages[7]!.toolUses[0]!.input = { command: 'cat /skills/review/SKILL.md' };
    const asker = evaluator(0);
    const result = await compact(messages, asker, { preserveRecentMessages: 3 });
    expect(asker.ask).not.toHaveBeenCalled();
    expect(result.messages).toEqual(messages);
    expect(result.stats).toMatchObject({ errorsKept: 1, protected: 3, pinned: 1 });
    const calls = collectToolCalls(messages, 3);
    const malicious = calls.map((call) => ({ id: call.id, tool: call.tool, action: 'drop_call' as const, reason: 'call_dropped' as const, keepCall: 0, keepResult: 0 }));
    expect(applyDecisions(messages, malicious, calls, 0)).toEqual(messages);
  });

  it('uses an error on either side of a tool pair as protection', async () => {
    const messages = transcript([10_000]);
    messages[1]!.toolUses[0]!.isError = true;
    expect((await compact(messages, evaluator(0), options)).stats.errorsKept).toBe(1);
  });

  it('keeps uncertain probabilities by default', async () => {
    const messages = transcript();
    const result = await compact(messages, evaluator(0.3), options);
    expect(result.messages).toEqual(messages);
    expect(result.stats.callsDropped).toBe(0);
  });

  it.each([-0.1, 1.1, Number.NaN, Infinity])('rejects invalid probability %s and never caches it', async (probability) => {
    const asker = evaluator(probability);
    await expect(compact(transcript(), asker, options)).rejects.toThrow(/Invalid evaluation answer/);
    await expect(compact(transcript(), asker, options)).rejects.toThrow(/Invalid evaluation answer/);
    expect(asker.ask).toHaveBeenCalledTimes(2);
  });
});

describe('bounded evaluation cost and concurrency', () => {
  it('rejects request and total input budgets before any request', async () => {
    const asker = evaluator();
    await expect(compact(transcript(), asker, { ...options, maxRequests: 0 })).rejects.toThrow(/request budget/);
    await expect(compact(transcript(), asker, { ...options, maxDecisionInputTokens: 1 })).rejects.toThrow(/input budget/);
    expect(asker.ask).not.toHaveBeenCalled();
  });

  it('bounds simultaneous requests while retaining every answer', async () => {
    const messages = transcript([10_000, 10_000, 10_000, 10_000, 10_000]);
    let inFlight = 0;
    let peak = 0;
    const asker: JevAsker = { ask: async (_state, questions) => {
      peak = Math.max(peak, ++inFlight);
      await new Promise((resolve) => setTimeout(resolve, 3));
      inFlight--;
      return { answers: Object.fromEntries(Object.keys(questions).map((key) => [key, { noul: 0 }])) };
    } };
    const result = await compact(messages, asker, { ...splitOptions(messages), maxConcurrency: 2 });
    expect(result.stats.requests).toBeGreaterThan(2);
    expect(peak).toBe(2);
    expect(result.stats.callsDropped).toBe(5);
  });

  it('stops dispatching after failure and waits for in-flight requests', async () => {
    const messages = transcript([10_000, 10_000, 10_000, 10_000, 10_000]);
    let finished = 0;
    const ask = vi.fn<JevAsker['ask']>(async (_state, questions) => {
      const first = Object.keys(questions).includes('call_t1');
      await new Promise((resolve) => setTimeout(resolve, first ? 1 : 10));
      finished++;
      if (first) throw new Error('Unavailable');
      return { answers: Object.fromEntries(Object.keys(questions).map((key) => [key, { noul: 0 }])) };
    });
    await expect(compact(messages, { ask }, { ...splitOptions(messages), maxConcurrency: 2 })).rejects.toThrow('Unavailable');
    expect(ask).toHaveBeenCalledTimes(2);
    expect(finished).toBe(2);
  });
});

describe('exact decision reuse and usage accounting', () => {
  it('reuses only exact requests on the same transport and does not charge usage twice', async () => {
    const messages = transcript();
    const asker = evaluator(0.1, { input_tokens: 125, output_tokens: 0 });
    const first = await compact(messages, asker, options);
    const second = await compact(messages, asker, { ...options, maxRequests: 0, maxDecisionInputTokens: 0 });
    expect(asker.ask).toHaveBeenCalledTimes(1);
    expect(first.stats.jevUsage).toEqual({ inputTokens: 125, outputTokens: 0, complete: true });
    expect(second.stats).toMatchObject({ requests: 0, cacheHits: 1, estimatedDecisionInputTokens: 0, jevUsage: { inputTokens: 0, outputTokens: 0, complete: true } });
    await compact(messages, asker, { ...options, goal: 'A different task' });
    expect(asker.ask).toHaveBeenCalledTimes(2);
    await compact(messages, { ask: asker.ask }, options);
    expect(asker.ask).toHaveBeenCalledTimes(3);
  });

  it('expires decisions and evicts the oldest entry from the bounded cache', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    const asker = evaluator();
    const messages = transcript();
    await compact(messages, asker, options);
    vi.setSystemTime(Date.now() + 300_001);
    await compact(messages, asker, options);
    expect(asker.ask).toHaveBeenCalledTimes(2);
    for (let i = 0; i < 32; i++) await compact(messages, asker, { ...options, goal: `task ${i}` });
    await compact(messages, asker, options);
    expect(asker.ask).toHaveBeenCalledTimes(35);
  });

  it('sums reported usage and marks missing counts unknown rather than zero', async () => {
    const messages = transcript([10_000, 10_000]);
    let request = 0;
    const asker: JevAsker = { ask: async (_state, questions) => ({
      answers: Object.fromEntries(Object.keys(questions).map((key) => [key, { noul: 0.1 }])),
      usage: ++request === 1 ? { input_tokens: 100, output_tokens: 0 } : { input_tokens: 200 },
    }) };
    const result = await compact(messages, asker, splitOptions(messages));
    expect(result.stats.requests).toBe(2);
    expect(result.stats.jevUsage).toEqual({ inputTokens: 300, outputTokens: null, complete: false });
    expect(result.stats.estimatedDecisionInputTokens).toBeGreaterThan(result.stats.stateTokens * 2);
  });

  it('does not report invalid usage as a measured saving or a valid token count', async () => {
    const result = await compact(transcript(), evaluator(0.1, { input_tokens: -1, output_tokens: 0.5 }), options);
    expect(result.stats.jevUsage).toEqual({ inputTokens: null, outputTokens: null, complete: false });
  });
});
