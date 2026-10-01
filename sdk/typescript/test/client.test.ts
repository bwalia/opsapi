import { createHmac } from 'node:crypto';
import { describe, expect, it, vi } from 'vitest';
import {
  collect,
  createClient,
  OpsApiError,
  paginate,
  paginateCursor,
  signWebhook,
  verifyWebhook,
  WebhookVerificationError,
} from '../src/index';

type Handler = (req: Request, n: number) => Response | Promise<Response>;

/** A fetch that records requests and answers from `handler`. */
function fakeFetch(handler: Handler) {
  const calls: Request[] = [];
  const fetch = vi.fn(async (req: Request) => {
    calls.push(req.clone());
    return handler(req, calls.length);
  });
  return { fetch: fetch as unknown as typeof globalThis.fetch, calls };
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });

const BASE = 'https://api.example.test';
const NS_UUID = '8140ae50-6606-4b53-9eed-9a51e1c16151';

describe('requests', () => {
  it('needs a baseUrl', () => {
    expect(() => createClient({} as never)).toThrow('baseUrl is required');
  });

  it('sends the token and the workspace (uuid -> X-Namespace-Id, slug -> X-Namespace-Slug)', async () => {
    const { fetch, calls } = fakeFetch(() => json({ success: true, data: [] }));
    const opsapi = createClient({ baseUrl: `${BASE}/`, token: 'key_123', namespace: NS_UUID, fetch });
    await opsapi.GET('/api/v2/customers');
    expect(calls[0]!.url).toBe(`${BASE}/api/v2/customers`);
    expect(calls[0]!.headers.get('authorization')).toBe('Bearer key_123');
    expect(calls[0]!.headers.get('x-namespace-id')).toBe(NS_UUID);

    opsapi.setNamespace('acme');
    opsapi.setToken(async () => 'jwt_from_store');
    await opsapi.GET('/api/v2/customers');
    expect(calls[1]!.headers.get('x-namespace-slug')).toBe('acme');
    expect(calls[1]!.headers.get('x-namespace-id')).toBeNull();
    expect(calls[1]!.headers.get('authorization')).toBe('Bearer jwt_from_store');
  });

  it('types query parameters and JSON bodies through to the wire', async () => {
    const { fetch, calls } = fakeFetch(() => json({ success: true, data: {} }, 201));
    const opsapi = createClient({ baseUrl: BASE, token: 't', fetch });
    await opsapi.GET('/api/v2/customers', { params: { query: { page: 2, perPage: 5 } as never } });
    expect(new URL(calls[0]!.url).searchParams.get('page')).toBe('2');
    await opsapi.POST('/api/v2/customers', { body: { email: 'a@b.test' } as never });
    expect(calls[1]!.method).toBe('POST');
    expect(await calls[1]!.json()).toEqual({ email: 'a@b.test' });
  });

  it('throws OpsApiError with status, message and validation details', async () => {
    const { fetch } = fakeFetch(() =>
      json({ success: false, error: 'Validation failed', details: { title: 'is required' } }, 422));
    const opsapi = createClient({ baseUrl: BASE, fetch });
    const err = await opsapi.POST('/api/v2/customers', { body: {} as never }).catch((e) => e);
    expect(err).toBeInstanceOf(OpsApiError);
    expect(err.status).toBe(422);
    expect(err.isValidation).toBe(true);
    expect(err.message).toBe('Validation failed');
    expect(err.details).toEqual({ title: 'is required' });
  });

  it('reads catalog-style errors ({ error: { message } })', async () => {
    const { fetch } = fakeFetch(() => json({ error: { code: 'NOT_FOUND_404', message: 'Not here' } }, 404));
    const err = await createClient({ baseUrl: BASE, fetch }).GET('/api/v2/customers').catch((e) => e);
    expect(err.isNotFound).toBe(true);
    expect(err.message).toBe('Not here');
  });

  it('throwOnError: false returns { error } instead', async () => {
    const { fetch } = fakeFetch(() => json({ success: false, error: 'nope' }, 403));
    const res = await createClient({ baseUrl: BASE, fetch, throwOnError: false }).GET('/api/v2/customers');
    expect(res.response.status).toBe(403);
    expect(res.error).toEqual({ success: false, error: 'nope' });
  });
});

describe('resilience', () => {
  it('retries idempotent requests on 503, honouring Retry-After', async () => {
    const { fetch, calls } = fakeFetch((_r, n) =>
      n < 3 ? json({ error: 'busy' }, 503, { 'Retry-After': '0' }) : json({ success: true, data: [] }));
    const res = await createClient({ baseUrl: BASE, fetch }).GET('/api/v2/customers');
    expect(calls).toHaveLength(3);
    expect(res.response.status).toBe(200);
  });

  it('never retries a POST (it may have been applied)', async () => {
    const { fetch, calls } = fakeFetch(() => json({ error: 'busy' }, 503, { 'Retry-After': '0' }));
    await createClient({ baseUrl: BASE, fetch }).POST('/api/v2/customers', { body: {} as never }).catch(() => {});
    expect(calls).toHaveLength(1);
  });

  it('retries a PUT with the same body', async () => {
    const { fetch, calls } = fakeFetch((_r, n) => (n === 1 ? json({}, 502, { 'Retry-After': '0' }) : json({ success: true })));
    await createClient({ baseUrl: BASE, fetch }).PUT('/api/v2/customers/{id}', {
      params: { path: { id: 'x' } } as never,
      body: { first_name: 'Ada' } as never,
    });
    expect(calls).toHaveLength(2);
    expect(await calls[1]!.json()).toEqual({ first_name: 'Ada' });
  });

  it('times out slow requests with status 0', async () => {
    const fetch = ((req: Request) =>
      new Promise((_resolve, reject) => req.signal.addEventListener('abort', () => reject(req.signal.reason)))) as typeof globalThis.fetch;
    const err = await createClient({ baseUrl: BASE, fetch, timeoutMs: 20, retries: 0 })
      .GET('/api/v2/customers')
      .catch((e) => e);
    expect(err).toBeInstanceOf(OpsApiError);
    expect(err.status).toBe(0);
    expect(err.message).toMatch(/timed out/);
  });

  it('refreshes once on 401 and retries with the new token', async () => {
    const { fetch, calls } = fakeFetch((req) =>
      req.headers.get('authorization') === 'Bearer fresh' ? json({ success: true }) : json({ error: 'expired' }, 401));
    const onUnauthorized = vi.fn(async () => 'fresh');
    const opsapi = createClient({ baseUrl: BASE, token: 'stale', fetch, onUnauthorized });
    const res = await opsapi.GET('/api/v2/customers');
    expect(res.response.status).toBe(200);
    expect(onUnauthorized).toHaveBeenCalledTimes(1);
    expect(calls.map((c) => c.headers.get('authorization'))).toEqual(['Bearer stale', 'Bearer fresh']);
    await opsapi.GET('/api/v2/customers'); // later calls use it
    expect(calls[2]!.headers.get('authorization')).toBe('Bearer fresh');
  });
});

describe('auth', () => {
  const user = { id: 1, uuid: 'u-1', email: 'a@b.test' };
  const ns = { id: 3, uuid: NS_UUID, name: 'Acme', slug: 'acme' };

  it('login signs the client in and picks the default workspace', async () => {
    const { fetch, calls } = fakeFetch((req) =>
      new URL(req.url).pathname === '/auth/login'
        ? json({ token: 'jwt1', refresh_token: 'r1', user, namespaces: [ns], current_namespace: ns })
        : json({ success: true, data: [] }));
    const opsapi = createClient({ baseUrl: BASE, fetch });
    const res = await opsapi.auth.login({ username: 'a@b.test', password: 'pw' });
    expect(res).toMatchObject({ status: 'signed_in', token: 'jwt1', refreshToken: 'r1', currentNamespace: ns });
    expect(await calls[0]!.json()).toEqual({ username: 'a@b.test', password: 'pw' });
    await opsapi.GET('/api/v2/customers');
    expect(calls[1]!.headers.get('authorization')).toBe('Bearer jwt1');
    expect(calls[1]!.headers.get('x-namespace-id')).toBe(NS_UUID);
  });

  it('login with 2FA returns a challenge; verify2fa finishes it', async () => {
    const { fetch, calls } = fakeFetch((req) =>
      new URL(req.url).pathname === '/auth/login'
        ? json({ requires_2fa: true, session_token: 's1', message: 'Code sent' })
        : json({ token: 'jwt2', user, namespaces: [] }));
    const opsapi = createClient({ baseUrl: BASE, fetch });
    const challenge = await opsapi.auth.login({ username: 'a', password: 'b' });
    expect(challenge).toMatchObject({ status: 'needs_2fa', sessionToken: 's1' });
    const done = await opsapi.auth.verify2fa({ sessionToken: 's1', code: '123456' });
    expect(done.token).toBe('jwt2');
    expect(await calls[1]!.json()).toEqual({ session_token: 's1', code: '123456' });
  });

  it('wrong password -> OpsApiError 401', async () => {
    const { fetch } = fakeFetch(() => json({ error: 'Invalid credentials' }, 401));
    const err = await createClient({ baseUrl: BASE, fetch }).auth.login({ username: 'a', password: 'x' }).catch((e) => e);
    expect(err.isUnauthorized).toBe(true);
    expect(err.message).toBe('Invalid credentials');
  });

  it('refresh swaps the token; logout forgets it', async () => {
    const { fetch, calls } = fakeFetch((req) =>
      new URL(req.url).pathname === '/auth/refresh' ? json({ token: 'jwt3', refresh_token: 'r2' }) : json({}));
    const opsapi = createClient({ baseUrl: BASE, token: 'old', fetch });
    expect(await opsapi.auth.refresh('r1')).toEqual({ token: 'jwt3', refreshToken: 'r2' });
    await opsapi.GET('/api/v2/customers');
    expect(calls[1]!.headers.get('authorization')).toBe('Bearer jwt3');
    await opsapi.auth.logout('r2');
    await opsapi.GET('/api/v2/customers');
    expect(calls[3]!.headers.get('authorization')).toBeNull();
  });
});

describe('pagination', () => {
  it('walks page-numbered lists until total_pages', async () => {
    const pages = [[1, 2], [3, 4], [5]];
    const fetchPage = vi.fn(async (page: number) => ({ data: pages[page - 1], meta: { page, total_pages: 3 } }));
    expect(await collect(paginate(fetchPage))).toEqual([1, 2, 3, 4, 5]);
    expect(fetchPage).toHaveBeenCalledTimes(3);
  });

  it('stops on an empty page and respects limits', async () => {
    const fetchPage = vi.fn(async (page: number) => ({ data: page < 3 ? [page] : [] }));
    expect(await collect(paginate(fetchPage))).toEqual([1, 2]);
    expect(await collect(paginate(fetchPage), 1)).toEqual([1]);
  });

  it('follows next_cursor', async () => {
    const fetchPage = vi.fn(async (cursor?: string) =>
      !cursor ? { data: ['a'], meta: { next_cursor: 'c1' } } : { data: ['b'], meta: { next_cursor: null } });
    expect(await collect(paginateCursor(fetchPage))).toEqual(['a', 'b']);
    expect(fetchPage.mock.calls.map((c) => c[0])).toEqual([undefined, 'c1']);
  });
});

describe('webhooks', () => {
  const secret = 'whsec_test';
  const body = JSON.stringify({
    id: 'e1', type: 'invoice.paid', created_at: '2026-10-01T00:00:00Z',
    namespace: { id: NS_UUID, slug: 'acme' }, data: { object: { status: 'paid' } },
  });
  const ts = '1790843000';
  // Exactly what OpsAPI computes (WEBHOOKS.md), with node:crypto as the reference.
  const sig = 'sha256=' + createHmac('sha256', secret).update(`${ts}.${body}`).digest('hex');
  const now = () => Number(ts) + 10;

  it('signs exactly like OpsAPI', async () => {
    expect(await signWebhook(secret, ts, body)).toBe(sig);
  });

  it('accepts a genuine delivery (Headers or a plain object, string or bytes)', async () => {
    const event = await verifyWebhook(body, new Headers({ 'X-Opsapi-Timestamp': ts, 'X-Opsapi-Signature-256': sig }), { secret, now });
    expect(event.type).toBe('invoice.paid');
    const again = await verifyWebhook(new TextEncoder().encode(body),
      { 'x-opsapi-timestamp': ts, 'x-opsapi-signature-256': [sig] }, { secret, now });
    expect(again.id).toBe('e1');
  });

  it('rejects a tampered body, a wrong secret, a stale delivery and missing headers', async () => {
    const headers = { 'x-opsapi-timestamp': ts, 'x-opsapi-signature-256': sig };
    await expect(verifyWebhook(body.replace('paid', 'void'), headers, { secret, now })).rejects.toBeInstanceOf(WebhookVerificationError);
    await expect(verifyWebhook(body, headers, { secret: 'other', now })).rejects.toThrow('Signature does not match');
    await expect(verifyWebhook(body, headers, { secret, now: () => Number(ts) + 301 })).rejects.toThrow('too old');
    await expect(verifyWebhook(body, {}, { secret, now })).rejects.toThrow('Missing');
  });
});
