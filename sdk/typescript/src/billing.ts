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
  if (parts.length !== 3) throw new BillingError('Malformed token', 0, 'invalid_token');
  const [head, body, sig] = parts as [string, string, string];
  let header: VerifiedToken<C>['header'];
  try {
    header = b64urlJson(head);
  } catch {
    throw new BillingError('Malformed token', 0, 'invalid_token');
  }
  if (header.alg !== 'ES256' || header.typ !== typ) {
    throw new BillingError(`Expected an ES256 ${typ} token`, 0, 'invalid_token');
  }
  const jwk = jwks.keys.find((k) => k.kid === header.kid) ?? (header.kid ? undefined : jwks.keys[0]);
  if (!jwk) throw new BillingError(`Unknown signing key ${header.kid}`, 0, 'unknown_key');
  const key = await crypto.subtle.importKey(
    'jwk',
    { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y },
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify'],
  );
  const ok = await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    b64urlBytes(sig),
    enc.encode(`${head}.${body}`),
  );
  if (!ok) throw new BillingError('Token signature is not valid', 0, 'invalid_token');
  return { header, claims: b64urlJson<C>(body) };
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
  aud: string;
  sub: string;
  plan: string | null;
  status: string;
  features: Record<string, FeatureValue> | unknown[];
  exp: number;
  grace: number;
  policy: 'fail_open' | 'fail_closed';
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
    const json = (await res.json().catch(() => ({}))) as { data?: unknown; error?: unknown };
    if (!res.ok) {
      const msg = typeof json.error === 'string' ? json.error : `OpsAPI answered ${res.status}`;
      throw new BillingError(msg, res.status);
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
      plan: claims.plan ?? null,
      status: claims.status,
      // OpsAPI writes an empty feature map as [].
      features: Array.isArray(claims.features) ? {} : claims.features,
      expiresAt: claims.exp,
      policy: claims.policy,
      graceSeconds: claims.grace ?? 0,
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
// Desktop / self-hosted: licences
// ---------------------------------------------------------------------------

export interface LicenseClaims {
  iss: string;
  /** App id */
  aud: string;
  /** Customer (your user id, else OpsAPI's customer uuid) */
  sub: string;
  /** Licence id */
  lic: string;
  /** SHA-256 hex of the machine fingerprint */
  fp: string;
  plan: string | null;
  features: Record<string, FeatureValue>;
  iat: number;
  /** Check in with OpsAPI after this (unix seconds)… */
  exp: number;
  /** …and stop working offline after this. */
  offline_until: number;
  policy: 'fail_open' | 'fail_closed';
}

export interface LicenseResult {
  /** Save this; verifyLicenseFile() checks it offline. */
  license_file: string;
  license: { uuid: string; status: string; expires_at: number | null };
  plan: { uuid: string; key?: string | null; name: string } | null;
  features: Record<string, FeatureValue>;
  expires_at: number;
  offline_until: number;
}

export interface LicensingOptions {
  baseUrl: string;
  /** The app's publishable key (pk_test_… / pk_live_…). Safe to ship in your app. */
  publishableKey: string;
  fetch?: Fetch;
}

export interface LicenseRequest {
  licenseKey: string;
  /** A stable id for this machine (hashed before it is stored). 8-512 characters. */
  fingerprint: string;
  name?: string;
  platform?: string;
  appVersion?: string;
}

export function createLicensing(opts: LicensingOptions) {
  const doFetch = opts.fetch ?? globalThis.fetch.bind(globalThis);
  const base = trim(opts.baseUrl);

  async function post<T>(action: string, r: LicenseRequest): Promise<T> {
    let res: Response;
    try {
      res = await doFetch(`${base}/api/v2/public/licenses/${action}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({
          pk: opts.publishableKey,
          license_key: r.licenseKey,
          fingerprint: r.fingerprint,
          name: r.name,
          platform: r.platform,
          app_version: r.appVersion,
        }),
      });
    } catch (err) {
      throw new BillingError(`OpsAPI unreachable: ${(err as Error).message}`, 0, 'unreachable');
    }
    const json = (await res.json().catch(() => ({}))) as { data?: T; error?: string; code?: string };
    if (!res.ok) throw new BillingError(json.error ?? `OpsAPI answered ${res.status}`, res.status, json.code);
    return json.data as T;
  }

  return {
    /** Use a seat on this machine. Throws BillingError (code activation_limit, invalid_license, license_revoked, …). */
    activate: (r: LicenseRequest) => post<LicenseResult>('activate', r),
    /** Re-check an activated machine and get a fresh licence file. */
    validate: (r: Omit<LicenseRequest, 'name' | 'platform'>) => post<LicenseResult>('validate', r as LicenseRequest),
    /** Give this machine's seat back. */
    deactivate: (r: Pick<LicenseRequest, 'licenseKey' | 'fingerprint'>) =>
      post<{ deactivated: true }>('deactivate', r as LicenseRequest),
  };
}

export interface VerifyLicenseOptions {
  /** The public keys: embed them in your app for fully offline checks… */
  jwks?: Jwks;
  /** …or fetch them from your OpsAPI. */
  baseUrl?: string;
  /** This machine's fingerprint: the file must have been issued to it. */
  fingerprint?: string;
  /** The app id (uuid) the file must be for. */
  app?: string;
  /** Unix seconds (tests). */
  now?: number;
  fetch?: Fetch;
}

/**
 * Check a licence file offline. Returns its claims and whether it is time to
 * check in (`needsCheckIn`: past `exp`, call validate() when online). Throws
 * BillingError when it isn't genuine, isn't for this machine/app, or is past
 * `offline_until`.
 */
export async function verifyLicenseFile(
  file: string,
  options: VerifyLicenseOptions,
): Promise<{ claims: LicenseClaims; needsCheckIn: boolean }> {
  if (!options.jwks && !options.baseUrl) throw new Error('verifyLicenseFile needs jwks or baseUrl');
  const verify = jwksSource(options.baseUrl ?? '', options.fetch ?? globalThis.fetch.bind(globalThis), options.jwks);
  const { claims } = await verify<LicenseClaims>(file, 'opsapi-license+jwt');
  if (options.app && claims.aud !== options.app) throw new BillingError('Licence is for another app', 0, 'wrong_app');
  if (options.fingerprint !== undefined && claims.fp !== (await sha256Hex(options.fingerprint))) {
    throw new BillingError('Licence was activated on another machine', 0, 'wrong_machine');
  }
  const t = options.now ?? Math.floor(Date.now() / 1000);
  if (t >= claims.offline_until) {
    throw new BillingError('Licence file expired: connect to the internet to renew it', 0, 'expired');
  }
  if (Array.isArray(claims.features)) claims.features = {};
  return { claims, needsCheckIn: t >= claims.exp };
}
