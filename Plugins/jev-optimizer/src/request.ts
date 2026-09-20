import type { JevAnswer, JevQuestions, JevResponse, JevState } from './types.js';

/** The Vercel AI Gateway's evaluation-model endpoint. */
export const GATEWAY_URL = 'https://ai-gateway.vercel.sh/v4/ai/evaluation-model';
export const DEFAULT_MODEL = 'typesafe-ai/jev';
export const TYPESAFE_URL = 'https://api.typesafe.ai/v1/systemone';
export const TYPESAFE_MODEL = 'jev-latest';
export type JevProvider = 'vercel-ai-gateway' | 'typesafe';

export function providerModel(provider: JevProvider): string {
  return provider === 'typesafe' ? TYPESAFE_MODEL : DEFAULT_MODEL;
}

/** Exact local routes only. Do not infer a protocol from arbitrary URLs. */
export function validScopedEndpoint(provider: JevProvider, endpoint: string): boolean {
  const prefix = /^http:\/\/127\.0\.0\.1:12767\/[a-z0-9][a-z0-9._-]{0,127}/;
  const suffix = provider === 'typesafe' ? '/v1/systemone' : '/v4/ai/evaluation-model';
  const match = endpoint.match(prefix);
  return match !== null && endpoint === match[0] + suffix;
}

const GATEWAY_PROTOCOL_VERSION = '0.0.1';
const EVALUATION_SPECIFICATION_VERSION = '4';

export interface JevRequest {
  url: string;
  method: 'POST';
  headers: Record<string, string>;
  body: string;
}

/**
 * The library asks `noul` questions; the gateway calls the same thing
 * `boolean`. Choice and score questions have the same shape on both sides.
 */
function toGatewayQuestions(questions: JevQuestions): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [name, question] of Object.entries(questions)) {
    out[name] = question.type === 'noul' ? { ...question, type: 'boolean' } : question;
  }
  return out;
}

/** The HTTP request for one evaluation call, for any fetch-like transport. */
export function buildJevRequest(
  params: {
    apiKey: string;
    model?: string;
    baseUrl?: string;
    provider?: JevProvider;
  },
  state: JevState,
  questions: JevQuestions,
): JevRequest {
  if (params.provider === 'typesafe') {
    return {
      url: params.baseUrl ?? TYPESAFE_URL,
      method: 'POST',
      headers: { authorization: `Bearer ${params.apiKey}`, 'content-type': 'application/json' },
      body: JSON.stringify({ model: params.model ?? TYPESAFE_MODEL, state, questions }),
    };
  }
  return {
    url: params.baseUrl ?? GATEWAY_URL,
    method: 'POST',
    headers: {
      authorization: `Bearer ${params.apiKey}`,
      'content-type': 'application/json',
      'ai-gateway-protocol-version': GATEWAY_PROTOCOL_VERSION,
      'ai-gateway-auth-method': 'api-key',
      'ai-evaluation-model-specification-version': EVALUATION_SPECIFICATION_VERSION,
      'ai-model-id': params.model ?? DEFAULT_MODEL,
    },
    body: JSON.stringify({ state, questions: toGatewayQuestions(questions) }),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function confidence(probabilities: Record<string, number>): number {
  const values = Object.values(probabilities).filter((v) => Number.isFinite(v));
  return values.length > 0 ? Math.max(...values) : 1;
}

/** One gateway answer in the library's shape; anything unrecognised is passed through untouched. */
function fromGatewayAnswer(answer: unknown): JevAnswer {
  if (!isRecord(answer)) return answer as JevAnswer;
  if (answer.type === 'boolean' && typeof answer.probability === 'number') {
    return { type: 'noul', noul: answer.probability };
  }
  if (answer.type === 'choice' && typeof answer.choice === 'string') {
    const probabilities = isRecord(answer.probabilities)
      ? (answer.probabilities as Record<string, number>)
      : { [answer.choice]: 1 };
    return { type: 'choice', choice: answer.choice, confidence: confidence(probabilities), probabilities };
  }
  if (answer.type === 'score' && typeof answer.score === 'number') {
    const probabilities = isRecord(answer.probabilities)
      ? (answer.probabilities as Record<string, number>)
      : {};
    return { type: 'score', score: answer.score, confidence: confidence(probabilities), probabilities };
  }
  return answer as unknown as JevAnswer;
}

/** Validates a gateway response body; throws on anything but an `answers` object. */
export function parseJevResponse(
  status: number,
  ok: boolean,
  text: string,
  provider: JevProvider = 'vercel-ai-gateway',
): JevResponse {
  if (!ok) {
    // Upstream error bodies can echo sensitive request content; never surface them in UI logs.
    throw new Error(`Gateway request failed (${status})`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error('Gateway returned malformed JSON');
  }
  if (!isRecord(parsed) || !isRecord(parsed.answers)) {
    throw new Error('Gateway response is missing answers');
  }
  const answers: Record<string, JevAnswer> = {};
  for (const [name, answer] of Object.entries(parsed.answers)) {
    answers[name] = provider === 'typesafe' ? answer as JevAnswer : fromGatewayAnswer(answer);
  }
  const usage = isRecord(parsed.usage) ? parsed.usage : undefined;
  const response: JevResponse = { answers };
  if (typeof parsed.model === 'string') response.model = parsed.model;
  if (usage) {
    response.usage = {
      input_tokens: tokenCount(provider === 'typesafe' ? usage.input_tokens : usage.inputTokens),
      output_tokens: tokenCount(provider === 'typesafe' ? usage.output_tokens : usage.outputTokens),
    };
  }
  return response;
}

function tokenCount(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
}

/**
 * The keep probability of one answer; throws when it is not there, so a gap in
 * the response is never read as "drop this call".
 */
export function noulAnswer(
  answers: Record<string, JevAnswer>,
  name: string,
): number {
  const answer = answers[name];
  if (
    !answer || typeof answer !== 'object' ||
    !('noul' in answer) ||
    typeof answer.noul !== 'number' ||
    !Number.isFinite(answer.noul) || answer.noul < 0 || answer.noul > 1
  ) {
    throw new Error(`Invalid evaluation answer for ${name}`);
  }
  return answer.noul;
}
