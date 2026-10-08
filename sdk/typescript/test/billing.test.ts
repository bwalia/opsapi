import { readFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';
import {
  BillingError,
  createBilling,
  createLicensing,
  fingerprintHash,
  sha256Hex,
  tokenState,
  verifyLicenseFile,
  verifyToken,
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
  ver: 1,
  iss: BASE,
  aud: APP,
  sub: 'user_42',
  plan_key: 'pro',
  status: 'active',
  features: { reports: true, exports: false, projects: 10, seats: null },
  iat: clock,
  exp: clock + 900,
  grace_until: clock + 900 + 3600,
  access_until: null,
  updates_until: null,
  offline_policy: 'fail_open',
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
    await expect(billing.can('user_42', 'reports')).rejects.toMatchObject({ code: 'bad_signature' });
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
    const { fetch } = server((n) => (n === 1 ? tokenResponse({ offline_policy: 'fail_closed' }) : json({ error: 'down' }, 503)));
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

describe('licences (format v1)', () => {
  const t = 2_000_000;
  const machine = 'machine-0001';
  const salt = 'f3a9c1d27b4e8a6055c0e1b2d3f4a5b6';
  const licClaims = async (over: object = {}) => ({
    ver: 1,
    iss: BASE,
    aud: APP,
    sub: 'lic-1',
    iat: t,
    exp: t + 7 * 86400,
    grace_until: t + 37 * 86400,
    plan_key: 'pro',
    features: { reports: true },
    access_until: null,
    updates_until: null,
    fingerprint_hash: await fingerprintHash(salt, machine),
    offline_policy: 'fail_closed',
    ...over,
  });

  it('fingerprintHash = sha256(salt:lowercase(trim(id)))', async () => {
    expect(await fingerprintHash(salt, '  ABC ')).toBe(await sha256Hex(`${salt}:abc`));
  });

  it('valid -> refresh -> past_grace, offline policy decides past grace', async () => {
    const fp = await fingerprintHash(salt, machine);
    const file = await sign('opsapi-license+jwt', await licClaims());
    const at = (now: number) => verifyLicenseFile(file, { jwks: JWKS, fingerprintHash: fp, app: APP, now });
    expect(await at(t + 60)).toMatchObject({ state: 'valid', allowed: true, needsCheckIn: false });
    expect(await at(t + 8 * 86400)).toMatchObject({ state: 'refresh', allowed: true, needsCheckIn: true });
    expect(await at(t + 40 * 86400)).toMatchObject({ state: 'past_grace', allowed: false });
    const open = await sign('opsapi-license+jwt', await licClaims({ offline_policy: 'fail_open' }));
    expect((await verifyLicenseFile(open, { jwks: JWKS, now: t + 40 * 86400 })).allowed).toBe(true);
  });

  it('a fixed-term pass ends at access_until; the clock can\'t be turned back past highWater', async () => {
    const pass = await sign('opsapi-license+jwt', await licClaims({ access_until: t + 30 * 86400 }));
    expect((await verifyLicenseFile(pass, { jwks: JWKS, now: t + 31 * 86400 })).state).toBe('access_ended');
    expect(tokenState({ iat: t, exp: t + 100, grace_until: t + 200, access_until: null }, t - 5000, t + 1000)).toBe('past_grace');
  });

  it('refuses another machine, another app, another issuer, an entitlement token', async () => {
    const file = await sign('opsapi-license+jwt', await licClaims());
    const other = await fingerprintHash(salt, 'other');
    await expect(verifyLicenseFile(file, { jwks: JWKS, fingerprintHash: other, now: t })).rejects.toMatchObject({ code: 'wrong_machine' });
    await expect(verifyLicenseFile(file, { jwks: JWKS, app: 'another', now: t })).rejects.toMatchObject({ code: 'wrong_app' });
    await expect(verifyLicenseFile(file, { jwks: JWKS, iss: 'https://evil.test', now: t })).rejects.toMatchObject({ code: 'wrong_issuer' });
    const token = await sign('opsapi-entitlements+jwt', await licClaims());
    await expect(verifyLicenseFile(token, { jwks: JWKS, now: t })).rejects.toMatchObject({ code: 'bad_type' });
  });

  it('activate sends the publishable key, the fingerprint hash and an Idempotency-Key; maps error codes', async () => {
    const calls: { body: Record<string, unknown>; key: string | null }[] = [];
    const fetch = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      calls.push({ body: JSON.parse(String(init?.body)), key: new Headers(init?.headers).get('Idempotency-Key') });
      return calls.length === 1
        ? json({ success: true, data: { license_file: 'x.y.z', features: {} } })
        : json({ success: false, code: 'activation_limit', error: 'This licence is already active on 1 device(s), its limit' }, 409);
    }) as unknown as typeof globalThis.fetch;
    const licensing = createLicensing({ baseUrl: BASE, publishableKey: 'pk_test_abc', fetch });
    const fp = await fingerprintHash(salt, machine);
    const r = await licensing.activate({ licenseKey: 'ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2', fingerprintHash: fp, appVersion: '3.2.0', name: 'Laptop' });
    expect(r.license_file).toBe('x.y.z');
    expect(calls[0]!.body).toMatchObject({ pk: 'pk_test_abc', fingerprint_hash: fp, app_version: '3.2.0', name: 'Laptop' });
    expect(calls[0]!.body).not.toHaveProperty('fingerprint');
    expect(calls[0]!.key).toBeTruthy();
    await expect(licensing.activate({ licenseKey: 'k', fingerprintHash: fp, appVersion: '1' })).rejects.toMatchObject({
      status: 409,
      code: 'activation_limit',
    });
  });

  it('refetches the JWKS once for a rotated key', async () => {
    const rotated = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const rotatedJwk = { ...(await crypto.subtle.exportKey('jwk', rotated.publicKey)), kid: 'k2' };
    let jwksCalls = 0;
    const fetch = vi.fn(async () => json(++jwksCalls === 1 ? JWKS : { keys: [...JWKS.keys, rotatedJwk] })) as unknown as typeof globalThis.fetch;
    const file = await sign('opsapi-license+jwt', await licClaims(), 'k2', rotated.privateKey);
    const { claims } = await verifyLicenseFile(file, { baseUrl: BASE, fetch, now: t });
    expect(claims.sub).toBe('lic-1');
    expect(jwksCalls).toBe(2);
  });
});

describe('payments', () => {
  function recorder(answer: unknown, status = 200) {
    const calls: { url: string; method: string; body?: Record<string, unknown>; headers: Headers }[] = [];
    const fetch = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      calls.push({
        url: String(url).replace(BASE, ''),
        method: init?.method ?? 'GET',
        body: init?.body ? JSON.parse(String(init.body)) : undefined,
        headers: new Headers(init?.headers),
      });
      return json(status < 400 ? { success: true, data: answer } : answer, status);
    }) as unknown as typeof globalThis.fetch;
    return { fetch, calls };
  }

  it('public checkout: publishable key, plan, coupon, licence key for an upgrade; always an Idempotency-Key', async () => {
    const { fetch, calls } = recorder({ url: 'https://checkout.stripe.com/c/pay/cs_1', session_id: 'cs_1' }, 201);
    const licensing = createLicensing({ baseUrl: BASE, publishableKey: 'pk_test_abc', fetch });
    const r = await licensing.checkout({ planKey: 'lifetime', coupon: 'SAVE10', licenseKey: 'ABCDE' });
    expect(r.url).toContain('checkout.stripe.com');
    expect(calls[0]).toMatchObject({ url: '/api/v2/public/billing/checkout', method: 'POST' });
    expect(calls[0]!.body).toMatchObject({ pk: 'pk_test_abc', plan_key: 'lifetime', coupon: 'SAVE10', license_key: 'ABCDE' });
    expect(calls[0]!.headers.get('Idempotency-Key')).toBeTruthy();
  });

  it('order(): the success page reads the order by Stripe session id', async () => {
    const { fetch, calls } = recorder({ status: 'complete', key: 'ABCDE-FGHJK', key_emailed: true });
    const licensing = createLicensing({ baseUrl: BASE, publishableKey: 'pk_test_abc', fetch });
    const o = await licensing.order('cs_test_1');
    expect(o).toMatchObject({ status: 'complete', key: 'ABCDE-FGHJK' });
    expect(calls[0]).toMatchObject({ url: '/api/v2/public/billing/checkout/cs_test_1?pk=pk_test_abc', method: 'GET' });
  });

  it('server checkout and portal use the secret key; errors keep the server code', async () => {
    const ok = recorder({ url: 'https://checkout.stripe.com/x' }, 201);
    const billing = createBilling({ baseUrl: BASE, apiKey: 'opsk_secret', app: APP, fetch: ok.fetch });
    await billing.checkout({ plan: 'pro', customerExternalId: 'user_42', successUrl: 'https://app.test/ok', idempotencyKey: 'order-7' });
    expect(ok.calls[0]!.url).toBe('/api/v2/subscriptions/checkout');
    expect(ok.calls[0]!.headers.get('Authorization')).toBe('Bearer opsk_secret');
    expect(ok.calls[0]!.headers.get('Idempotency-Key')).toBe('order-7');
    expect(ok.calls[0]!.body).toMatchObject({ app: APP, plan: 'pro', customer_external_id: 'user_42', success_url: 'https://app.test/ok' });
    const bad = recorder({ success: false, code: 'no_subscription', error: 'There is no paid subscription to manage' }, 404);
    const b2 = createBilling({ baseUrl: BASE, apiKey: 'opsk_secret', app: APP, fetch: bad.fetch });
    await expect(b2.portal({ customerExternalId: 'user_42' })).rejects.toMatchObject({ status: 404, code: 'no_subscription' });
    expect(bad.calls[0]!.body).toMatchObject({ app: APP, customer_external_id: 'user_42' });
  });
});

describe('docs/licence-format-vectors.json (every published case)', () => {
  const v = JSON.parse(readFileSync(new URL('../../../docs/licence-format-vectors.json', import.meta.url), 'utf8'));
  for (const c of v.cases as { name: string; token: string; typ: string; now: number; expect: string; fingerprint_hash?: string; iss?: string; high_water?: number }[]) {
    it(c.name, async () => {
      let got: string;
      try {
        if (c.typ === 'opsapi-license+jwt') {
          got = (await verifyLicenseFile(c.token, { jwks: v.jwks, app: v.app_id, fingerprintHash: c.fingerprint_hash, iss: c.iss, now: c.now, highWater: c.high_water })).state;
        } else {
          const { claims } = await verifyToken<{ aud: string; iss: string; iat: number; exp: number; grace_until: number; access_until: number | null }>(c.token, v.jwks, c.typ);
          if (claims.aud !== v.app_id) throw new BillingError('wrong app', 0, 'wrong_app');
          if (c.iss && claims.iss !== c.iss) throw new BillingError('wrong issuer', 0, 'wrong_issuer');
          got = tokenState(claims, c.now, c.high_water ?? 0);
        }
      } catch (err) {
        got = `error:${(err as BillingError).code}`;
      }
      expect(got).toBe(c.expect);
    });
  }
});
