type JsonRecord = Record<string, unknown>;

export interface ReadOnlyToolCacheKey {
  project_id: string;
  tool: string;
  tool_version: string;
  arguments: JsonRecord;
  dependencies: Record<string, string>;
  permission_fingerprint: string;
}

export interface ReadOnlyToolCacheLookup extends ReadOnlyToolCacheKey {
  current_dependencies: Record<string, string>;
  current_permission_fingerprint: string;
}

export interface ReadOnlyToolResultCacheOptions {
  allowedTools?: readonly string[];
  ttlMs?: number;
  maxEntries?: number;
  maxKeyBytes?: number;
  maxValueBytes?: number;
  now?: () => number;
}

interface Entry {
  value: unknown;
  dependencies: Record<string, string>;
  permissionFingerprint: string;
  expiresAt: number;
}

const DEFAULT_ALLOWED = ['read_file', 'stat_file'];
const FORBIDDEN_TOOL = /(write|edit|delete|remove|move|copy|deploy|publish|send|message|email|purchase|pay|credential|secret|shell|bash|exec|command)/i;
const SENSITIVE_KEY = /(^|_)(authorization|credential|password|secret|token|api_?key)($|_)/i;
const SENSITIVE_VALUE = /(?:^|\s)(?:Bearer\s+\S+|ksf_[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{16,}|(?:api[_-]?key|password|secret|token)\s*[:=]\s*\S+)/i;
const SENSITIVE_PATH = /(?:^|\/)(?:\.env(?:\.[^/]*)?|\.ssh(?:\/.*)?|id_(?:rsa|ed25519)(?:\.[^/]*)?|credentials?(?:\.[^/]*)?|keychain(?:\.[^/]*)?|[^/]+\.(?:pem|key))$/i;
const PATH_KEY = /(?:^|_)(?:file_?)?path$/i;

function normalizedTool(value: string): string {
  return value.trim().toLocaleLowerCase('en-US');
}

function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    return `{${Object.entries(value as JsonRecord).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${stable(item)}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function containsCredentials(value: unknown, seen = new Set<object>()): boolean {
  if (typeof value === 'string') return SENSITIVE_VALUE.test(value);
  if (value === null || typeof value !== 'object') return false;
  if (seen.has(value)) return true;
  seen.add(value);
  if (Array.isArray(value)) return value.some((item) => containsCredentials(item, seen));
  return Object.entries(value as JsonRecord).some(([key, item]) => SENSITIVE_KEY.test(key) || containsCredentials(item, seen));
}

function cloneJson<T>(value: T): T | undefined {
  try {
    return JSON.parse(JSON.stringify(value)) as T;
  } catch {
    return undefined;
  }
}

function argumentPaths(value: unknown): string[] {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return [];
  const paths: string[] = [];
  for (const [key, item] of Object.entries(value as JsonRecord)) {
    if (PATH_KEY.test(key) && typeof item === 'string') paths.push(item);
    else if (item !== null && typeof item === 'object') paths.push(...argumentPaths(item));
  }
  return paths;
}

/**
 * Memory-only cache for deterministic, allowlisted local reads. It never runs
 * tools, persists data, or treats a cached result as permission to read.
 */
export class ReadOnlyToolResultCache {
  private readonly allowed: Set<string>;
  private readonly ttlMs: number;
  private readonly maxEntries: number;
  private readonly maxKeyBytes: number;
  private readonly maxValueBytes: number;
  private readonly now: () => number;
  private readonly entries = new Map<string, Entry>();

  constructor(options: ReadOnlyToolResultCacheOptions = {}) {
    this.allowed = new Set((options.allowedTools ?? DEFAULT_ALLOWED).map(normalizedTool));
    this.ttlMs = Math.max(1, Math.min(options.ttlMs ?? 60_000, 5 * 60_000));
    this.maxEntries = Math.max(1, Math.min(options.maxEntries ?? 64, 1_000));
    this.maxKeyBytes = Math.max(1, Math.min(options.maxKeyBytes ?? 64_000, 256_000));
    this.maxValueBytes = Math.max(1, Math.min(options.maxValueBytes ?? 256_000, 1_000_000));
    this.now = options.now ?? Date.now;
  }

  isEligible(tool: string): boolean {
    const name = normalizedTool(tool);
    return this.allowed.has(name) && !FORBIDDEN_TOOL.test(name);
  }

  put(key: ReadOnlyToolCacheKey, value: unknown): boolean {
    if (!this.validKey(key) || Object.keys(key.dependencies).length === 0 || containsCredentials(key.arguments) || containsCredentials(value)) return false;
    let encodedValue: string | undefined;
    try {
      encodedValue = JSON.stringify(value);
    } catch {
      return false;
    }
    if (encodedValue === undefined || Buffer.byteLength(encodedValue, 'utf8') > this.maxValueBytes) return false;
    const valueClone = cloneJson(value);
    if (valueClone === undefined) return false;
    const encoded = this.key(key);
    if (Buffer.byteLength(encoded, 'utf8') > this.maxKeyBytes) return false;
    this.entries.delete(encoded);
    this.entries.set(encoded, {
      value: valueClone,
      dependencies: { ...key.dependencies },
      permissionFingerprint: key.permission_fingerprint,
      expiresAt: this.now() + this.ttlMs,
    });
    while (this.entries.size > this.maxEntries) this.entries.delete(this.entries.keys().next().value as string);
    return true;
  }

  get(lookup: ReadOnlyToolCacheLookup): unknown | undefined {
    if (!this.validKey(lookup)) return undefined;
    this.removeExpired();
    if (lookup.permission_fingerprint !== lookup.current_permission_fingerprint) return undefined;
    const encoded = this.key(lookup);
    if (Buffer.byteLength(encoded, 'utf8') > this.maxKeyBytes) return undefined;
    const entry = this.entries.get(encoded);
    if (!entry || entry.permissionFingerprint !== lookup.current_permission_fingerprint) return undefined;
    for (const [path, hash] of Object.entries(entry.dependencies)) {
      if (!hash || lookup.current_dependencies[path] !== hash) return undefined;
    }
    this.entries.delete(encoded);
    this.entries.set(encoded, entry);
    return cloneJson(entry.value);
  }

  clearProject(projectId: string): void {
    for (const key of this.entries.keys()) {
      if (key.startsWith(`${JSON.stringify(projectId)}\u0000`)) this.entries.delete(key);
    }
  }

  get size(): number {
    this.removeExpired();
    return this.entries.size;
  }

  private validKey(key: ReadOnlyToolCacheKey): boolean {
    if (!(
      key.project_id && key.tool_version && key.permission_fingerprint &&
      this.isEligible(key.tool) && key.arguments && typeof key.arguments === 'object' && !Array.isArray(key.arguments)
    )) return false;
    if (!key.dependencies || typeof key.dependencies !== 'object' || Array.isArray(key.dependencies)) return false;
    const dependencies = Object.entries(key.dependencies);
    if (dependencies.length === 0 || dependencies.some(([path, hash]) => !path || !hash)) return false;
    if (containsCredentials(key.arguments)) return false;
    const paths = argumentPaths(key.arguments);
    if (paths.length === 0 || paths.some((path) => SENSITIVE_PATH.test(path) || key.dependencies[path] === undefined)) return false;
    return true;
  }

  private key(key: ReadOnlyToolCacheKey): string {
    return `${JSON.stringify(key.project_id)}\u0000${stable({
      tool: normalizedTool(key.tool),
      tool_version: key.tool_version,
      arguments: key.arguments,
      dependencies: key.dependencies,
      permission_fingerprint: key.permission_fingerprint,
    })}`;
  }

  private removeExpired(): void {
    for (const [key, entry] of this.entries) if (entry.expiresAt <= this.now()) this.entries.delete(key);
  }
}
