/**
 * @opsapi/client/billing — OpsAPI Billing & Entitlements.
 *
 * Server side (`createBilling`, with a secret `opsk_` key scoped to
 * `entitlements`): ask what a customer may use, cache the answer as a signed
 * ES256 token until it expires, and follow the app's offline policy when
 * OpsAPI can't be reached.
 *
 * Desktop / self-hosted (`createLicensing` with the app's publishable key,
 * `verifyLicenseFile`): activate a licence key on a machine and check the
 * signed licence file offline.
 *
 * Web Crypto + fetch only: Node 20+, browsers, Deno, Bun and edge runtimes.
 */

export type FeatureValue = boolean | number | null;

/** What a customer may use in an app right now. */
export interface Entitlements {
  /** The plan that decides it: subscription, granted plan, or the free default. */
  plan: string | null;
  /** none | free | granted | active | trialing | past_due */
  status: string;
  /** feature key -> true/false (on/off) or a number (limit; null = unlimited). */
  features: Record<string, FeatureValue>;
  /** Unix seconds after which OpsAPI must be asked again. */
  expiresAt: number;
  /** What to do when OpsAPI can't be reached after expiresAt. */
  policy: 'fail_open' | 'fail_closed';
  /** fail_open keeps these entitlements this long past expiresAt. */
  graceSeconds: number;
  /** Access ends here (unix seconds); null = no end. */
  accessUntil: number | null;
  /** Releases covered until here (unix seconds); null = all. */
  updatesUntil: number | null;
  /** True when served from cache because OpsAPI was unreachable (fail_open). */
  stale?: boolean;
}

/** OpsAPI said no, or couldn't be reached and the app's policy blocks access. */
export class BillingError extends Error {
  override readonly name = 'BillingError';
  constructor(
    message: string,
    /** HTTP status; 0 when OpsAPI couldn't be reached. */
    readonly status: number,
    /** Machine-readable code, e.g. invalid_license, activation_limit, not_configured. */
    readonly code?: string,
  ) {
    super(message);
  }
}

type Fetch = typeof fetch;
interface Jwk extends JsonWebKey {
  kid?: string;
}
export interface Jwks {
  keys: Jwk[];
}

// ---------------------------------------------------------------------------
// ES256 (JWS) verification
// ---------------------------------------------------------------------------

const enc = new TextEncoder();

function b64urlBytes(s: string): Uint8Array<ArrayBuffer> {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64urlJson<T>(s: string): T {
  return JSON.parse(new TextDecoder().decode(b64urlBytes(s))) as T;
}

export interface VerifiedToken<C> {
  header: { alg: string; typ: string; kid?: string };
  claims: C;
}

/**
 * Check a compact ES256 JWS against a JWKS (signature and `typ` only; callers
 * check the claims). Throws BillingError('invalid_token') when it doesn't verify.
 */
export async function verifyToken<C = Record<string, unknown>>(
  token: string,
  jwks: Jwks,
  typ: string,
): Promise<VerifiedToken<C>> {
  const parts = typeof token === 'string' ? token.split('.') : [];
  if (parts.length !== 3) throw new BillingError('Malformed token', 0, 'malformed');
  const [head, body, sig] = parts as [string, string, string];
  let header: VerifiedToken<C>['header'];
  try {
    header = b64urlJson(head);
  } catch {
    throw new BillingError('Malformed token', 0, 'malformed');
  }
  if (header.alg !== 'ES256') throw new BillingError('Only ES256 tokens are accepted', 0, 'bad_alg');
  if (header.typ !== typ) throw new BillingError(`Expected a ${typ} token`, 0, 'bad_type');
  const jwk = jwks.keys.find((k) => k.kid === header.kid) ?? (header.kid ? undefined : jwks.keys[0]);
  if (!jwk) throw new BillingError(`Unknown signing key ${header.kid}`, 0, 'unknown_key');
  const key = await crypto.subtle.importKey(
    'jwk',
    { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y },
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify'],
  );
  const raw = b64urlBytes(sig);
  const ok = raw.length === 64 && (await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, raw, enc.encode(`${head}.${body}`)));
  if (!ok) throw new BillingError('Token signature is not valid', 0, 'bad_signature');
  const claims = b64urlJson<C & { ver?: number }>(body);
  if (claims.ver !== 1) throw new BillingError('Unknown token format version', 0, 'bad_version');
  return { header, claims };
}

/** SHA-256 hex, as OpsAPI stores machine fingerprints. */
export async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', enc.encode(text));
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
}

const trim = (url: string) => url.replace(/\/+$/, '');

/** OpsAPI couldn't be reached or failed (5xx), as opposed to saying no. */
const isOutage = (err: unknown) =>
  err instanceof BillingError && ((err.status === 0 && err.code === 'unreachable') || err.status >= 500);

/** Fetches and caches the JWKS; refetches once when it meets an unknown key id. */
function jwksSource(baseUrl: string, doFetch: Fetch, fixed?: Jwks) {
  let cached: { jwks: Jwks; at: number } | undefined = fixed ? { jwks: fixed, at: Infinity } : undefined;
  const load = async (): Promise<Jwks> => {
    let res: Response;
    try {
      res = await doFetch(`${trim(baseUrl)}/api/v2/public/billing/jwks.json`);
    } catch (err) {
      throw new BillingError(`OpsAPI unreachable: ${(err as Error).message}`, 0, 'unreachable');
    }
    if (!res.ok) throw new BillingError(`Could not load signing keys (${res.status})`, res.status);
    const jwks = (await res.json()) as Jwks;
    cached = { jwks, at: Date.now() };
    return jwks;
  };
  return async <C>(token: string, typ: string): Promise<VerifiedToken<C>> => {
    if (!cached || Date.now() - cached.at > 10 * 60_000) await load();
    try {
      return await verifyToken<C>(token, cached!.jwks, typ);
    } catch (err) {
      // A rotated key: refresh the JWKS once, unless the keys were given to us.
      if (err instanceof BillingError && err.code === 'unknown_key' && !fixed) {
        return verifyToken<C>(token, await load(), typ);
      }
      throw err;
    }
  };
}

// ---------------------------------------------------------------------------
// Server side: entitlements
// ---------------------------------------------------------------------------

export interface BillingOptions {
  /** Your OpsAPI, e.g. https://api.example.com */
  baseUrl: string;
  /** A workspace API key (opsk_…) scoped to `entitlements`. Server side only. */
  apiKey: string;
  /** The app's id (uuid) or slug. */
  app: string;
  /** Custom fetch (tests, proxies). */
  fetch?: Fetch;
  /** Refresh this many seconds before a token expires. Default 30. */
  refreshSkewSeconds?: number;
  /** Current time in unix seconds (tests). */
  now?: () => number;
}

interface EntitlementClaims {
  ver: 1;
  aud: string;
  sub: string;
  plan_key: string | null;
  status: string;
  features: Record<string, FeatureValue> | unknown[];
  exp: number;
  grace_until: number;
  access_until: number | null;
  updates_until: number | null;
  offline_policy: 'fail_open' | 'fail_closed';
}

export interface CustomerInput {
  email?: string;
  first_name?: string;
  last_name?: string;
}

/** Find the customer id for a request (your user id), or null when signed out. */
export type CustomerIdOf<R> = (req: R) => string | null | undefined | Promise<string | null | undefined>;

export function createBilling(opts: BillingOptions) {
  const doFetch = opts.fetch ?? globalThis.fetch.bind(globalThis);
  const base = trim(opts.baseUrl);
  const now = opts.now ?? (() => Math.floor(Date.now() / 1000));
  const skew = opts.refreshSkewSeconds ?? 30;
  const verify = jwksSource(base, doFetch);
  const cache = new Map<string, Entitlements>();
  const inflight = new Map<string, Promise<Entitlements>>();
  let appId: string | undefined; // the token's `aud`, pinned on first sight

  const url = (externalId: string) =>
    `${base}/api/v2/entitlements/${encodeURIComponent(opts.app)}/customers/${encodeURIComponent(externalId)}`;

  async function call(method: string, externalId: string, body?: unknown) {
    let res: Response;
    try {
      res = await doFetch(url(externalId), {
        method,
        headers: { Authorization: `Bearer ${opts.apiKey}`, 'Content-Type': 'application/json', Accept: 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (err) {
      throw new BillingError(`OpsAPI unreachable: ${(err as Error).message}`, 0, 'unreachable');
    }
    const json = (await res.json().catch(() => ({}))) as { data?: unknown; error?: unknown; code?: string };
    if (!res.ok) {
      const msg = typeof json.error === 'string' ? json.error : `OpsAPI answered ${res.status}`;
      throw new BillingError(msg, res.status, json.code);
    }
    return json.data;
  }

  async function fetchFresh(externalId: string): Promise<Entitlements> {
    const data = (await call('GET', externalId)) as { token: string | null };
    if (!data?.token) {
      throw new BillingError('OpsAPI returned no signed token: set BILLING_SIGNING_KEY on the server', 503, 'not_configured');
    }
    const { claims } = await verify<EntitlementClaims>(data.token, 'opsapi-entitlements+jwt');
    if (claims.sub !== externalId) throw new BillingError('Token is for another customer', 0, 'invalid_token');
    if (appId && claims.aud !== appId) throw new BillingError('Token is for another app', 0, 'invalid_token');
    appId = claims.aud;
    const ent: Entitlements = {
      plan: claims.plan_key ?? null,
      status: claims.status,
      // OpsAPI writes an empty feature map as [].
      features: Array.isArray(claims.features) ? {} : claims.features,
      expiresAt: claims.exp,
      policy: claims.offline_policy,
      graceSeconds: Math.max(0, (claims.grace_until ?? claims.exp) - claims.exp),
      accessUntil: claims.access_until ?? null,
      updatesUntil: claims.updates_until ?? null,
    };
    cache.set(externalId, ent);
    return ent;
  }

  /**
   * The customer's entitlements: cached until the token expires, then asked
   * again. If OpsAPI can't be reached (or errors with 5xx), a `fail_open` app
   * keeps the last answer for its grace period (marked `stale`); otherwise
   * this throws BillingError (status 0 / 5xx). 4xx answers and tokens that
   * don't verify always throw.
   */
  async function getEntitlements(externalId: string): Promise<Entitlements> {
    const hit = cache.get(externalId);
    if (hit && now() < hit.expiresAt - skew) return hit;
    let pending = inflight.get(externalId);
    if (!pending) {
      pending = fetchFresh(externalId).finally(() => inflight.delete(externalId));
      inflight.set(externalId, pending);
    }
    try {
      return await pending;
    } catch (err) {
      if (isOutage(err) && hit) {
        if (now() < hit.expiresAt) return hit; // still valid, just inside the refresh window
        if (hit.policy === 'fail_open' && now() < hit.expiresAt + hit.graceSeconds) return { ...hit, stale: true };
      }
      throw err;
    }
  }

  /** Is a feature on (or a limit above 0)? OpsAPI unreachable + nothing usable cached = false. */
  async function can(externalId: string, feature: string): Promise<boolean> {
    try {
      const v = (await getEntitlements(externalId)).features[feature];
      return v === true || v === null || (typeof v === 'number' && v > 0);
    } catch (err) {
      if (isOutage(err)) return false;
      throw err;
    }
  }

  /** A limit: a number, null = unlimited, 0 when the feature is off (or OpsAPI can't be reached). */
  async function limit(externalId: string, feature: string): Promise<number | null> {
    try {
      const v = (await getEntitlements(externalId)).features[feature];
      return v === null ? null : typeof v === 'number' ? v : 0;
    } catch (err) {
      if (isOutage(err)) return 0;
      throw err;
    }
  }

  const denial = (feature: string, upgradeUrl?: string) => ({
    error: `Your plan doesn't include ${feature}`,
    code: 'feature_required',
    feature,
    ...(upgradeUrl ? { upgrade_url: upgradeUrl } : {}),
  });

  return {
    getEntitlements,
    can,
    limit,

    /** Create or update the customer your app knows as `externalId` (email is required the first time). */
    async upsertCustomer(externalId: string, input: CustomerInput) {
      const data = await call('PUT', externalId, input);
      cache.delete(externalId);
      return data as { uuid: string; external_id: string; email: string };
    },

    /**
     * Record a purchase your server verified itself (App Store, Google Play or any
     * other channel). It resolves to the same entitlements as a Stripe sale.
     * Idempotent on (source, externalTransactionId).
     */
    async recordPurchase(input: {
      customerExternalId: string;
      email?: string;
      source: 'app_store' | 'play_store' | 'external' | 'manual';
      externalTransactionId: string;
      originalTransactionId?: string;
      planKey?: string;
      storeProductId?: string;
      /** Unix seconds, for subscriptions. */
      expiresAt?: number;
      amount?: number;
      currency?: string;
      status?: 'active' | 'refunded' | 'canceled';
    }) {
      let res: Response;
      try {
        res = await doFetch(`${base}/api/v2/entitlements/${encodeURIComponent(opts.app)}/purchases`, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${opts.apiKey}`,
            'Content-Type': 'application/json',
            'Idempotency-Key': `${input.source}:${input.externalTransactionId}:${input.status ?? 'active'}`,
          },
          body: JSON.stringify({
            customer_external_id: input.customerExternalId, email: input.email, source: input.source,
            external_transaction_id: input.externalTransactionId, original_transaction_id: input.originalTransactionId,
            plan_key: input.planKey, store_product_id: input.storeProductId, expires_at: input.expiresAt,
            amount: input.amount, currency: input.currency, status: input.status,
          }),
        });
      } catch (err) {
        throw new BillingError(`OpsAPI unreachable: ${(err as Error).message}`, 0, 'unreachable');
      }
      const json = (await res.json().catch(() => ({}))) as { data?: unknown; error?: string; code?: string };
      if (!res.ok) throw new BillingError(json.error ?? `OpsAPI answered ${res.status}`, res.status, json.code);
      cache.delete(input.customerExternalId);
      return json.data as { purchase?: unknown; subscription?: unknown; license?: unknown; key?: string; duplicate?: boolean };
    },

    /** Drop cached entitlements (all, or one customer), e.g. from a subscription.* / billing.grant.* webhook. */
    invalidate(externalId?: string) {
      if (externalId === undefined) cache.clear();
      else cache.delete(externalId);
    },

    /**
     * Express / Connect middleware: next() when the customer has `feature`,
     * else 402 { code: 'feature_required' } (401 when getCustomerId returns nothing).
     */
    requireFeature<Req = unknown>(feature: string, getCustomerId: CustomerIdOf<Req>, options: { upgradeUrl?: string } = {}) {
      return async (
        req: Req,
        res: { status(code: number): { json(body: unknown): unknown } },
        next: (err?: unknown) => void,
      ) => {
        try {
          const id = await getCustomerId(req);
          if (!id) return void res.status(401).json({ error: 'Sign in first', code: 'unauthenticated' });
          if (await can(id, feature)) return next();
          res.status(402).json(denial(feature, options.upgradeUrl));
        } catch (err) {
          next(err);
        }
      };
    },

    /**
     * Fetch-style handlers (Next.js route handlers, Hono, Bun, Deno): run
     * `handler` when the customer has `feature`, else answer 402.
     */
    withFeature<A extends unknown[]>(
      feature: string,
      getCustomerId: CustomerIdOf<Request>,
      handler: (req: Request, ...rest: A) => Response | Promise<Response>,
      options: { upgradeUrl?: string } = {},
    ) {
      return async (req: Request, ...rest: A): Promise<Response> => {
        const id = await getCustomerId(req);
        if (!id) return Response.json({ error: 'Sign in first', code: 'unauthenticated' }, { status: 401 });
        if (!(await can(id, feature))) return Response.json(denial(feature, options.upgradeUrl), { status: 402 });
        return handler(req, ...rest);
      };
    },
  };
}

// ---------------------------------------------------------------------------
// Desktop / self-hosted: licences (docs/LICENCE_FORMAT.md)
// ---------------------------------------------------------------------------

export interface LicenseClaims {
  ver: 1;
  iss: string;
  /** App id */
  aud: string;
  /** Licence id */
  sub: string;
  iat: number;
  /** Refresh by (unix seconds). */
  exp: number;
  /** Valid without a refresh until here. */
  grace_until: number;
  plan_key: string | null;
  features: Record<string, FeatureValue>;
  /** Access ends here; null = perpetual. */
  access_until: number | null;
  /** Releases covered until here; null = all. */
  updates_until: number | null;
  /** SHA-256 hex of salt + ":" + machine id. */
  fingerprint_hash: string;
  offline_policy: 'fail_open' | 'fail_closed';
}

/** LICENCE_FORMAT.md §5.2. */
export type TokenState = 'valid' | 'refresh' | 'past_grace' | 'access_ended';

export interface LicenseResult {
  /** Save this; verifyLicenseFile() checks it offline. */
  license_file: string;
  license: { uuid: string; status: string; access_until: number | null; updates_until: number | null };
  plan: { uuid: string; key?: string | null; name: string } | null;
  features: Record<string, FeatureValue>;
  expires_at: number;
  grace_until: number;
}

export interface PublicAppInfo {
  uuid: string;
  name: string;
  kind: string;
  fingerprint_salt: string;
  offline_policy: 'fail_open' | 'fail_closed';
  refresh_interval_days: number;
  grace_days: number;
  display_name?: string;
  support_email?: string;
  plans: unknown[];
  features: unknown[];
}

/** fingerprint_hash = hex(SHA-256(salt + ":" + lowercase(trim(machineId)))) — LICENCE_FORMAT.md §6. */
export async function fingerprintHash(salt: string, machineId: string): Promise<string> {
  return sha256Hex(`${salt}:${machineId.trim().toLowerCase()}`);
}

export interface LicensingOptions {
  baseUrl: string;
  /** The app's publishable key (pk_test_… / pk_live_…). Safe to ship in your app. */
  publishableKey: string;
  fetch?: Fetch;
}

export interface LicenseRequest {
  licenseKey: string;
  /** fingerprintHash(salt, machineId): never send a raw machine id. */
  fingerprintHash: string;
  appVersion: string;
  name?: string;
  platform?: string;
}

const idempotencyKey = () =>
  typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;

export function createLicensing(opts: LicensingOptions) {
  const doFetch = opts.fetch ?? globalThis.fetch.bind(globalThis);
  const base = trim(opts.baseUrl);

  async function send<T>(method: string, path: string, body?: Record<string, unknown>): Promise<T> {
    let res: Response;
    try {
      res = await doFetch(`${base}${path}`, {
        method,
        headers: {
          Accept: 'application/json',
          ...(body ? { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey() } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch (err) {
      throw new BillingError(`OpsAPI unreachable: ${(err as Error).message}`, 0, 'unreachable');
    }
    const json = (await res.json().catch(() => ({}))) as { data?: T; error?: string; code?: string };
    if (!res.ok) throw new BillingError(json.error ?? `OpsAPI answered ${res.status}`, res.status, json.code);
    return json.data as T;
  }

  const licenceBody = (r: Partial<LicenseRequest>) => ({
    pk: opts.publishableKey,
    license_key: r.licenseKey,
    fingerprint_hash: r.fingerprintHash,
    app_version: r.appVersion,
    name: r.name,
    platform: r.platform,
  });

  return {
    /** Public app info: the fingerprint salt, offline settings, branding, public plans. */
    appInfo: () => send<PublicAppInfo>('GET', `/api/v2/public/billing/apps/${encodeURIComponent(opts.publishableKey)}`),
    /** Use a seat on this machine. Throws BillingError (code activation_limit, invalid_license, license_revoked, …). */
    activate: (r: LicenseRequest) => send<LicenseResult>('POST', '/api/v2/public/licenses/activate', licenceBody(r)),
    /** Re-check an activated machine and get a fresh licence file. */
    validate: (r: Omit<LicenseRequest, 'name' | 'platform'>) =>
      send<LicenseResult>('POST', '/api/v2/public/licenses/validate', licenceBody(r)),
    /** Give this machine's seat back. */
    deactivate: (r: Pick<LicenseRequest, 'licenseKey' | 'fingerprintHash'>) =>
      send<{ deactivated: true }>('POST', '/api/v2/public/licenses/deactivate', licenceBody(r)),
    /** Email the customer a link to the hosted "my licences" page (always succeeds: no enumeration). */
    requestAccessLink: (email: string) =>
      send<{ message: string }>('POST', '/api/v2/public/billing/access-link', { pk: opts.publishableKey, email }),
  };
}

const SKEW = 300;

/** LICENCE_FORMAT.md §5: the state of a verified token at `now` (clock may not go back past highWater). */
export function tokenState(
  claims: Pick<LicenseClaims, 'iat' | 'exp' | 'grace_until' | 'access_until'>,
  now: number,
  highWater = 0,
): TokenState {
  const t = Math.max(now, highWater, claims.iat - SKEW);
  if (claims.access_until != null && t > claims.access_until + SKEW) return 'access_ended';
  if (t <= claims.exp + SKEW) return 'valid';
  if (t <= claims.grace_until + SKEW) return 'refresh';
  return 'past_grace';
}

export interface VerifyLicenseOptions {
  /** The public keys: embed them in your app for fully offline checks… */
  jwks?: Jwks;
  /** …or fetch them from your OpsAPI. */
  baseUrl?: string;
  /** This machine's fingerprint hash: the file must have been issued to it. */
  fingerprintHash?: string;
  /** The app id (uuid) the file must be for. */
  app?: string;
  /** Pin the issuer (your OpsAPI URL). */
  iss?: string;
  /** Unix seconds (tests). */
  now?: number;
  /** The latest time this app has seen (persist it): the clock can't be turned back past it. */
  highWater?: number;
  fetch?: Fetch;
}

/**
 * Check a licence file offline (LICENCE_FORMAT.md §4–5). Throws BillingError when
 * it must not be trusted (bad_signature, wrong_machine, wrong_app, …). Otherwise
 * returns its claims and state: `allowed` is what the app should do right now if
 * it can't reach OpsAPI; `needsCheckIn` = call validate() when online.
 */
export async function verifyLicenseFile(
  file: string,
  options: VerifyLicenseOptions,
): Promise<{ claims: LicenseClaims; state: TokenState; allowed: boolean; needsCheckIn: boolean }> {
  if (!options.jwks && !options.baseUrl) throw new Error('verifyLicenseFile needs jwks or baseUrl');
  const verify = jwksSource(options.baseUrl ?? '', options.fetch ?? globalThis.fetch.bind(globalThis), options.jwks);
  const { claims } = await verify<LicenseClaims>(file, 'opsapi-license+jwt');
  if (options.app && claims.aud !== options.app) throw new BillingError('Licence is for another app', 0, 'wrong_app');
  if (options.iss && claims.iss !== options.iss) throw new BillingError('Licence is from another issuer', 0, 'wrong_issuer');
  if (options.fingerprintHash !== undefined && claims.fingerprint_hash !== options.fingerprintHash) {
    throw new BillingError('Licence was activated on another machine', 0, 'wrong_machine');
  }
  if (Array.isArray(claims.features)) claims.features = {};
  const state = tokenState(claims, options.now ?? Math.floor(Date.now() / 1000), options.highWater ?? 0);
  const allowed = state === 'valid' || state === 'refresh' || (state === 'past_grace' && claims.offline_policy === 'fail_open');
  return { claims, state, allowed, needsCheckIn: state !== 'valid' };
}
