import { describe, expect, it, vi } from 'vitest';
import {
  BillingError,
  createBilling,
  createLicensing,
  sha256Hex,
  verifyLicenseFile,
  type Jwks,
} from '../src/billing';

const BASE = 'https://api.example.test';
const APP = '0032e459-e532-4bf1-8bfa-5a35c52cf70b';

// A signing key like the server's BILLING_SIGNING_KEY, and its JWKS.
const pair = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
const pub = await crypto.subtle.exportKey('jwk', pair.publicKey);
const JWKS: Jwks = { keys: [{ ...pub, kid: 'k1', alg: 'ES256', use: 'sig' }] };

const b64url = (bytes: Uint8Array) => Buffer.from(bytes).toString('base64url');
async function sign(typ: string, claims: object, kid = 'k1', key = pair.privateKey) {
  const input = `${b64url(Buffer.from(JSON.stringify({ alg: 'ES256', typ, kid })))}.${b64url(Buffer.from(JSON.stringify(claims)))}`;
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(input));
  return `${input}.${b64url(new Uint8Array(sig))}`;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

let clock = 1_000_000;
const now = () => clock;

const entClaims = (over: object = {}) => ({
  iss: BASE,
  aud: APP,
  sub: 'user_42',
  plan: 'pro',
  status: 'active',
  features: { reports: true, exports: false, projects: 10, seats: null },
  iat: clock,
  exp: clock + 900,
  grace: 3600,
  policy: 'fail_open',
  ...over,
});

/** A fake OpsAPI: JWKS + the runtime entitlement endpoint (`answer` decides each GET). */
function server(answer: (n: number) => Promise<Response> | Response) {
  let gets = 0;
  const calls: string[] = [];
  const fetch = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
    const u = String(url);
    calls.push(`${init?.method ?? 'GET'} ${u.replace(BASE, '')}`);
    if (u.endsWith('/jwks.json')) return json(JWKS);
    gets += 1;
    return answer(gets);
  });
  return { fetch: fetch as unknown as typeof globalThis.fetch, calls };
}

const tokenResponse = async (over: object = {}) => json({ success: true, data: { token: await sign('opsapi-entitlements+jwt', entClaims(over)) } });

describe('entitlements', () => {
  it('verifies the token, caches it until it expires, and checks features', async () => {
    const { fetch, calls } = server(() => tokenResponse());
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_x', app: 'acme', fetch, now });
    const ent = await billing.getEntitlements('user_42');
    expect(ent).toMatchObject({ plan: 'pro', status: 'active', policy: 'fail_open', graceSeconds: 3600 });
    expect(await billing.can('user_42', 'reports')).toBe(true);
    expect(await billing.can('user_42', 'exports')).toBe(false);
    expect(await billing.can('user_42', 'unknown')).toBe(false);
    expect(await billing.limit('user_42', 'projects')).toBe(10);
    expect(await billing.limit('user_42', 'seats')).toBeNull(); // unlimited
    expect(await billing.can('user_42', 'seats')).toBe(true);
    expect(calls.filter((c) => c.includes('/entitlements/'))).toEqual(['GET /api/v2/entitlements/acme/customers/user_42']);
  });

  it('asks again after the token expires (minus the refresh skew)', async () => {
    const { fetch, calls } = server(() => tokenResponse());
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_x', app: 'acme', fetch, now });
    await billing.getEntitlements('user_42');
    clock += 880; // inside the 30 s refresh window
    await billing.getEntitlements('user_42');
    expect(calls.filter((c) => c.includes('/entitlements/'))).toHaveLength(2);
  });

  it('sends the secret key and shares one request between concurrent checks', async () => {
    const seen: (string | null)[] = [];
    const fetch = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      if (String(url).endsWith('/jwks.json')) return json(JWKS);
      seen.push(new Headers(init?.headers).get('Authorization'));
      return tokenResponse();
    }) as unknown as typeof globalThis.fetch;
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_secret', app: APP, fetch, now });
    await Promise.all([billing.can('user_42', 'reports'), billing.can('user_42', 'reports')]);
    expect(seen).toEqual(['Bearer opsk_secret']);
  });

  it('rejects a token that does not verify', async () => {
    const other = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign'])) as CryptoKeyPair;
    const forged = await sign('opsapi-entitlements+jwt', entClaims({ features: { reports: true } }), 'k1', other.privateKey);
    const { fetch } = server(() => json({ success: true, data: { token: forged } }));
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_x', app: 'acme', fetch, now });
    await expect(billing.can('user_42', 'reports')).rejects.toMatchObject({ code: 'invalid_token' });
  });

  it('rejects a token for another customer', async () => {
    const { fetch } = server(() => tokenResponse({ sub: 'user_99' }));
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_x', app: 'acme', fetch, now });
    await expect(billing.getEntitlements('user_42')).rejects.toBeInstanceOf(BillingError);
  });

  it('fail_open: keeps the last answer through an outage, for the grace period only', async () => {
    const { fetch } = server((n) => (n === 1 ? tokenResponse() : Promise.reject(new TypeError('fetch failed'))));
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_x', app: 'acme', fetch, now });
    await billing.getEntitlements('user_42');
    clock += 900 + 60; // expired, OpsAPI down
    const stale = await billing.getEntitlements('user_42');
    expect(stale.stale).toBe(true);
    expect(await billing.can('user_42', 'reports')).toBe(true);
    clock += 3600; // past exp + grace
    expect(await billing.can('user_42', 'reports')).toBe(false);
    await expect(billing.getEntitlements('user_42')).rejects.toMatchObject({ status: 0, code: 'unreachable' });
  });

  it('fail_closed: denies as soon as the token has expired and OpsAPI is down', async () => {
    const { fetch } = server((n) => (n === 1 ? tokenResponse({ policy: 'fail_closed' }) : json({ error: 'down' }, 503)));
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_x', app: 'acme', fetch, now });
    expect(await billing.can('user_42', 'reports')).toBe(true);
    clock += 901;
    expect(await billing.can('user_42', 'reports')).toBe(false);
  });

  it('a 4xx (bad key, unknown app) throws instead of silently denying', async () => {
    const { fetch } = server(() => json({ success: false, error: 'Permission denied' }, 403));
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_x', app: 'acme', fetch, now });
    await expect(billing.can('user_42', 'reports')).rejects.toMatchObject({ status: 403, message: 'Permission denied' });
  });

  it('explains a server without a signing key', async () => {
    const { fetch } = server(() => json({ success: true, data: { token: null } }));
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_x', app: 'acme', fetch, now });
    await expect(billing.getEntitlements('user_42')).rejects.toMatchObject({ code: 'not_configured' });
  });

  it('upsertCustomer sends PUT with the body and drops the cache', async () => {
    const bodies: string[] = [];
    const fetch = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      if (String(url).endsWith('/jwks.json')) return json(JWKS);
      if (init?.method === 'PUT') {
        bodies.push(String(init.body));
        return json({ success: true, data: { uuid: 'c1', external_id: 'user_42', email: 'a@b.co' } });
      }
      return tokenResponse();
    }) as unknown as typeof globalThis.fetch;
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_x', app: 'acme', fetch, now });
    await billing.getEntitlements('user_42');
    const c = await billing.upsertCustomer('user_42', { email: 'a@b.co' });
    expect(c.uuid).toBe('c1');
    expect(bodies).toEqual(['{"email":"a@b.co"}']);
    await billing.getEntitlements('user_42');
    expect(fetch).toHaveBeenCalledTimes(4); // jwks, GET, PUT, GET again
  });
});

describe('middleware', () => {
  const make = () => createBilling({ baseUrl: BASE, apiKey: 'opsk_x', app: 'acme', fetch: server(() => tokenResponse()).fetch, now });

  it('express: next() when allowed, 402 when not, 401 when signed out', async () => {
    const billing = make();
    const res = { code: 0, body: undefined as unknown, status(c: number) { this.code = c; return { json: (b: unknown) => (res.body = b) }; } };
    const next = vi.fn();
    await billing.requireFeature('reports', (req: { user?: string }) => req.user)({ user: 'user_42' }, res, next);
    expect(next).toHaveBeenCalledWith();
    await billing.requireFeature('exports', (req: { user?: string }) => req.user, { upgradeUrl: '/pricing' })({ user: 'user_42' }, res, next);
    expect(res.code).toBe(402);
    expect(res.body).toMatchObject({ code: 'feature_required', feature: 'exports', upgrade_url: '/pricing' });
    await billing.requireFeature('reports', () => null)({}, res, next);
    expect(res.code).toBe(401);
  });

  it('fetch handlers: runs the handler or answers 402', async () => {
    const billing = make();
    const handler = billing.withFeature('reports', () => 'user_42', () => new Response('ok'));
    expect(await (await handler(new Request(`${BASE}/x`))).text()).toBe('ok');
    const blocked = billing.withFeature('exports', () => 'user_42', () => new Response('ok'));
    const r = await blocked(new Request(`${BASE}/x`));
    expect(r.status).toBe(402);
    expect(await r.json()).toMatchObject({ code: 'feature_required' });
  });
});

describe('licences', () => {
  const t = 2_000_000;
  const fp = 'machine-0001';
  const licClaims = async (over: object = {}) => ({
    iss: BASE,
    aud: APP,
    sub: 'user_42',
    lic: 'lic-1',
    fp: await sha256Hex(fp),
    plan: 'pro',
    features: { reports: true },
    iat: t,
    exp: t + 900,
    offline_until: t + 259200,
    policy: 'fail_closed',
    ...over,
  });

  it('verifies a licence file offline with embedded keys', async () => {
    const file = await sign('opsapi-license+jwt', await licClaims());
    const { claims, needsCheckIn } = await verifyLicenseFile(file, { jwks: JWKS, fingerprint: fp, app: APP, now: t + 10 });
    expect(claims.features).toEqual({ reports: true });
    expect(needsCheckIn).toBe(false);
    // After exp it still works offline, but asks to check in.
    expect((await verifyLicenseFile(file, { jwks: JWKS, now: t + 1000 })).needsCheckIn).toBe(true);
  });

  it('refuses another machine, another app, an expired file, or an entitlement token', async () => {
    const file = await sign('opsapi-license+jwt', await licClaims());
    await expect(verifyLicenseFile(file, { jwks: JWKS, fingerprint: 'other-machine', now: t })).rejects.toMatchObject({ code: 'wrong_machine' });
    await expect(verifyLicenseFile(file, { jwks: JWKS, app: 'another', now: t })).rejects.toMatchObject({ code: 'wrong_app' });
    await expect(verifyLicenseFile(file, { jwks: JWKS, now: t + 259200 })).rejects.toMatchObject({ code: 'expired' });
    const token = await sign('opsapi-entitlements+jwt', await licClaims());
    await expect(verifyLicenseFile(token, { jwks: JWKS, now: t })).rejects.toMatchObject({ code: 'invalid_token' });
  });

  it('activate posts the publishable key and maps error codes', async () => {
    const bodies: unknown[] = [];
    const fetch = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      bodies.push(JSON.parse(String(init?.body)));
      return bodies.length === 1
        ? json({ success: true, data: { license_file: 'x.y.z', features: {} } })
        : json({ success: false, code: 'activation_limit', error: 'This licence is already active on 1 device(s), its limit' }, 409);
    }) as unknown as typeof globalThis.fetch;
    const licensing = createLicensing({ baseUrl: BASE, publishableKey: 'pk_test_abc', fetch });
    const r = await licensing.activate({ licenseKey: 'ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2', fingerprint: fp, name: 'Laptop' });
    expect(r.license_file).toBe('x.y.z');
    expect(bodies[0]).toMatchObject({ pk: 'pk_test_abc', license_key: 'ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2', fingerprint: fp, name: 'Laptop' });
    await expect(licensing.activate({ licenseKey: 'k', fingerprint: fp })).rejects.toMatchObject({ status: 409, code: 'activation_limit' });
  });

  it('refetches the JWKS once for a rotated key', async () => {
    const rotated = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const rotatedJwk = { ...(await crypto.subtle.exportKey('jwk', rotated.publicKey)), kid: 'k2' };
    let jwksCalls = 0;
    const fetch = vi.fn(async () => json(++jwksCalls === 1 ? JWKS : { keys: [...JWKS.keys, rotatedJwk] })) as unknown as typeof globalThis.fetch;
    const file = await sign('opsapi-license+jwt', await licClaims(), 'k2', rotated.privateKey);
    const { claims } = await verifyLicenseFile(file, { baseUrl: BASE, fetch, now: t });
    expect(claims.lic).toBe('lic-1');
    expect(jwksCalls).toBe(2);
  });
});
