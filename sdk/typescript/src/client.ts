import createFetchClient, { type Client, type Middleware } from 'openapi-fetch';
import type { paths as CorePaths } from './generated/opsapi';
import { OpsApiError, messageOf } from './errors';

/** A token, or a function that returns the current one (e.g. from your session store). */
export type TokenSource = string | (() => string | null | undefined | Promise<string | null | undefined>);

export interface ClientOptions {
  /** Where OpsAPI runs, e.g. "https://api.example.com". */
  baseUrl: string;
  /** A JWT (from auth.login) or an API key. Both are sent as `Authorization: Bearer …`. */
  token?: TokenSource;
  /** The workspace to act in: its UUID (sent as X-Namespace-Id) or its slug (X-Namespace-Slug). */
  namespace?: string;
  /** Extra attempts for GET/PUT/DELETE on 429, 502, 503, 504 and network errors. Default 2. */
  retries?: number;
  /** Abort a request after this many milliseconds (each attempt). Default 30000. */
  timeoutMs?: number;
  /**
   * Throw an `OpsApiError` for non-2xx responses (default). With `false`
   * calls resolve to openapi-fetch's `{ data, error, response }` instead.
   */
  throwOnError?: boolean;
  /**
   * Called once when a request is rejected with 401: return a fresh token
   * (e.g. from `client.auth.refresh()`) to retry it, or nothing to give up.
   */
  onUnauthorized?: () => Promise<string | null | undefined> | string | null | undefined;
  /** Sent with every request. */
  headers?: Record<string, string>;
  /** A fetch implementation (default: the global one). */
  fetch?: typeof globalThis.fetch;
}

export interface LoginUser {
  id: number;
  uuid: string;
  email: string;
  username?: string;
  first_name?: string;
  last_name?: string;
  roles?: string[];
  [key: string]: unknown;
}

export interface LoginNamespace {
  id: number;
  uuid: string;
  name: string;
  slug: string;
  is_owner?: boolean;
  [key: string]: unknown;
}

/** Signed in: the client now uses `token` (and `currentNamespace`, if you didn't pick one). */
export interface LoginSuccess {
  status: 'signed_in';
  token: string;
  refreshToken?: string;
  user: LoginUser;
  namespaces: LoginNamespace[];
  currentNamespace?: LoginNamespace;
}

/** The account uses 2FA: a code was sent; finish with `auth.verify2fa({ sessionToken, code })`. */
export interface LoginChallenge {
  status: 'needs_2fa';
  sessionToken: string;
  [key: string]: unknown;
}

export interface AuthApi {
  /** Sign in with a username/email and password. */
  login(credentials: { username: string; password: string }): Promise<LoginSuccess | LoginChallenge>;
  /** Finish a 2FA sign-in with the emailed code. */
  verify2fa(input: { sessionToken: string; code: string }): Promise<LoginSuccess>;
  /** Swap a refresh token for a new access token; the client starts using it. */
  refresh(refreshToken: string): Promise<{ token: string; refreshToken?: string }>;
  /** Revoke the refresh token (if given) and forget the access token. */
  logout(refreshToken?: string): Promise<void>;
}

export type OpsApiClient<Paths extends {} = CorePaths> = Client<Paths> & {
  auth: AuthApi;
  /** Switch user/credentials. */
  setToken(token: TokenSource | undefined): void;
  /** Switch workspace (UUID or slug). */
  setNamespace(namespace: string | undefined): void;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const RETRY_STATUS = new Set([429, 502, 503, 504]);
const IDEMPOTENT = new Set(['GET', 'HEAD', 'OPTIONS', 'PUT', 'DELETE']);

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Wait before retry `attempt` (0-based): Retry-After if the server sent one, else 300ms·2^n with jitter. */
function retryDelay(attempt: number, res?: Response): number {
  const after = res?.headers.get('retry-after');
  if (after) {
    const seconds = Number(after);
    if (Number.isFinite(seconds)) return Math.min(30_000, Math.max(0, seconds * 1000));
    const at = Date.parse(after);
    if (!Number.isNaN(at)) return Math.min(30_000, Math.max(0, at - Date.now()));
  }
  return Math.min(10_000, 300 * 2 ** attempt) * (0.75 + Math.random() * 0.5);
}

async function resolveToken(source: TokenSource | undefined): Promise<string | undefined> {
  const value = typeof source === 'function' ? await source() : source;
  return value || undefined;
}

async function readBody(res: Response): Promise<unknown> {
  const text = await res.text();
  if (!text) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

/**
 * Create a client. Every OpsAPI endpoint is typed (paths, parameters, bodies,
 * responses); pass your own generated `paths` type to include your plugins:
 *
 *   const opsapi = createClient({ baseUrl, token: process.env.OPSAPI_KEY, namespace: 'acme' });
 *   const { data } = await opsapi.GET('/api/v2/customers', { params: { query: { page: 1 } } });
 */
export function createClient<Paths extends {} = CorePaths>(options: ClientOptions): OpsApiClient<Paths> {
  if (!options?.baseUrl) throw new TypeError('createClient: baseUrl is required, e.g. "https://api.example.com"');
  const baseUrl = options.baseUrl.replace(/\/+$/, '');
  const retries = Math.max(0, options.retries ?? 2);
  const timeoutMs = options.timeoutMs ?? 30_000;
  const throwOnError = options.throwOnError !== false;
  const baseFetch = options.fetch ?? globalThis.fetch.bind(globalThis);
  let token = options.token;
  let namespace = options.namespace;

  // Timeouts, retries and the one-shot 401 refresh live in the transport, so
  // they apply to every call (typed or auth) the same way.
  async function transport(input: Request): Promise<Response> {
    const retryable = IDEMPOTENT.has(input.method.toUpperCase());
    let request = input;
    let refreshed = false;
    for (let attempt = 0; ; attempt++) {
      const spare = request.clone(); // bodies are single-use
      let res: Response;
      try {
        const signal = AbortSignal.any([request.signal, AbortSignal.timeout(timeoutMs)]);
        res = await baseFetch(new Request(request, { signal }));
      } catch (err) {
        if (request.signal.aborted) throw err; // the caller cancelled
        const timedOut = (err as Error)?.name === 'TimeoutError';
        if (retryable && attempt < retries) {
          await sleep(retryDelay(attempt));
          request = spare;
          continue;
        }
        throw new OpsApiError(timedOut ? `Request timed out after ${timeoutMs}ms` : 'Network error', {
          status: 0, method: request.method, url: request.url, cause: err,
        });
      }
      if (res.status === 401 && options.onUnauthorized && !refreshed) {
        refreshed = true;
        const fresh = await options.onUnauthorized();
        if (fresh) {
          token = fresh;
          const headers = new Headers(spare.headers);
          headers.set('Authorization', `Bearer ${fresh}`);
          request = new Request(spare, { headers });
          attempt--; // a refresh isn't a retry
          continue;
        }
      }
      if (retryable && RETRY_STATUS.has(res.status) && attempt < retries) {
        await sleep(retryDelay(attempt, res));
        request = spare;
        continue;
      }
      return res;
    }
  }

  const headersMiddleware: Middleware = {
    async onRequest({ request }) {
      for (const [k, v] of Object.entries(options.headers ?? {})) request.headers.set(k, v);
      const current = await resolveToken(token);
      if (current && !request.headers.has('Authorization')) request.headers.set('Authorization', `Bearer ${current}`);
      if (namespace && !request.headers.has('X-Namespace-Id') && !request.headers.has('X-Namespace-Slug')) {
        request.headers.set(UUID.test(namespace) ? 'X-Namespace-Id' : 'X-Namespace-Slug', namespace);
      }
      return request;
    },
  };

  const errorMiddleware: Middleware = {
    async onResponse({ request, response }) {
      if (response.ok || !throwOnError) return undefined;
      const body = await readBody(response.clone());
      throw new OpsApiError(messageOf(body) ?? `${request.method} ${new URL(request.url).pathname} failed (${response.status})`, {
        status: response.status, body, method: request.method, url: request.url,
      });
    },
  };

  const client = createFetchClient<Paths>({ baseUrl, fetch: transport });
  client.use(headersMiddleware, errorMiddleware);

  // The auth endpoints, through the same transport and headers.
  // The /auth/* endpoints read FORM fields (not JSON), on every OpsAPI version.
  async function call<T>(method: string, path: string, body?: Record<string, string>): Promise<T> {
    const request = new Request(baseUrl + path, {
      method,
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
      body: body === undefined ? undefined : new URLSearchParams(body).toString(),
    });
    for (const [k, v] of Object.entries(options.headers ?? {})) request.headers.set(k, v);
    const res = await transport(request);
    const parsed = await readBody(res);
    if (!res.ok) {
      throw new OpsApiError(messageOf(parsed) ?? `${method} ${path} failed (${res.status})`, {
        status: res.status, body: parsed, method, url: request.url,
      });
    }
    return parsed as T;
  }

  type RawLogin = {
    token: string;
    refresh_token?: string;
    user: LoginUser;
    namespaces?: LoginNamespace[];
    current_namespace?: LoginNamespace;
  };
  const signedIn = (raw: RawLogin): LoginSuccess => {
    token = raw.token;
    if (!namespace && raw.current_namespace?.uuid) namespace = raw.current_namespace.uuid;
    return {
      status: 'signed_in',
      token: raw.token,
      refreshToken: raw.refresh_token,
      user: raw.user,
      namespaces: raw.namespaces ?? [],
      currentNamespace: raw.current_namespace,
    };
  };

  const auth: AuthApi = {
    async login({ username, password }) {
      const raw = await call<RawLogin & { requires_2fa?: boolean; session_token?: string }>('POST', '/auth/login', {
        username, password,
      });
      if (raw.requires_2fa && raw.session_token) {
        const { requires_2fa: _r, session_token, ...rest } = raw;
        return { ...rest, status: 'needs_2fa', sessionToken: session_token };
      }
      return signedIn(raw);
    },
    async verify2fa({ sessionToken, code }) {
      return signedIn(await call<RawLogin>('POST', '/auth/2fa/verify', { session_token: sessionToken, code }));
    },
    async refresh(refreshToken) {
      const raw = await call<{ token: string; refresh_token?: string }>('POST', '/auth/refresh', {
        refresh_token: refreshToken,
      });
      token = raw.token;
      return { token: raw.token, refreshToken: raw.refresh_token };
    },
    async logout(refreshToken) {
      try {
        await call('POST', '/auth/logout', refreshToken ? { refresh_token: refreshToken } : {});
      } finally {
        token = undefined;
      }
    },
  };

  return Object.assign(client, {
    auth,
    setToken(next: TokenSource | undefined) {
      token = next;
    },
    setNamespace(next: string | undefined) {
      namespace = next;
    },
  });
}
