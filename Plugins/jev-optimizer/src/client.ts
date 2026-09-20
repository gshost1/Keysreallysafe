import { buildJevRequest, parseJevResponse, type JevProvider } from './request.js';
import type { JevAsker, JevQuestions, JevResponse, JevState } from './types.js';

export interface JevClientOptions {
  /** Explicit transport protocol; defaults to Vercel. */
  provider?: JevProvider;
  /** A Vercel AI Gateway key. Defaults to `process.env.AI_GATEWAY_API_KEY`. */
  apiKey?: string;
  /** Defaults to `typesafe-ai/jev`. */
  model?: string;
  /** Defaults to the Vercel AI Gateway evaluation endpoint. */
  baseUrl?: string;
  /** Defaults to the global `fetch`. */
  fetch?: typeof fetch;
}

/** Asks Jev over HTTP with the global `fetch` (or an injected one). */
export class JevClient implements JevAsker {
  private readonly apiKey: string;
  private readonly model: string | undefined;
  private readonly baseUrl: string | undefined;
  private readonly fetcher: typeof fetch;
  private readonly provider: JevProvider;

  constructor(options: JevClientOptions = {}) {
    this.provider = options.provider ?? 'vercel-ai-gateway';
    this.apiKey = options.apiKey ?? (this.provider === 'typesafe' ? process.env.TYPESAFE_API_KEY : process.env.AI_GATEWAY_API_KEY) ?? '';
    this.model = options.model;
    this.baseUrl = options.baseUrl;
    this.fetcher = options.fetch ?? fetch;
  }

  async ask(state: JevState, questions: JevQuestions): Promise<JevResponse> {
    if (!this.apiKey) throw new Error(`${this.provider === 'typesafe' ? 'TYPESAFE_API_KEY' : 'AI_GATEWAY_API_KEY'} is not configured`);
    const request = buildJevRequest(
      { apiKey: this.apiKey, model: this.model, baseUrl: this.baseUrl, provider: this.provider },
      state,
      questions,
    );
    const response = await this.fetcher(request.url, {
      method: request.method,
      headers: request.headers,
      body: request.body,
      redirect: 'error',
      credentials: 'omit',
    });
    return parseJevResponse(response.status, response.ok, await response.text(), this.provider);
  }
}
