/**
 * The public billing API used by the hosted pages (/b/[app]/…): no dashboard
 * login, no workspace header. The app is identified by its id or publishable
 * key; the customer by a session from an emailed access link.
 */

const API = (process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010').replace(/\/+$/, '');

export class PublicApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code?: string
  ) {
    super(message);
  }
}

async function call<T>(method: string, path: string, body?: unknown, session?: string): Promise<T> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (session) headers['X-Billing-Session'] = session;
  const res = await fetch(API + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const json = (await res.json().catch(() => ({}))) as { data?: T; error?: string; code?: string };
  if (!res.ok) throw new PublicApiError(json.error || `Request failed (${res.status})`, res.status, json.code);
  return json.data as T;
}

export interface PublicApp {
  uuid: string;
  name: string;
  kind: string;
  publishable_key: string;
  display_name?: string;
  logo_url?: string;
  accent_color?: string;
  support_email?: string;
  terms_url?: string;
  privacy_url?: string;
  email_collection?: 'required' | 'optional' | 'none';
}

export interface MyDevice {
  uuid: string;
  name?: string | null;
  platform?: string | null;
  app_version?: string | null;
  last_seen_at: string;
  deactivated_at?: string | null;
}

export interface MyLicence {
  uuid: string;
  key_prefix: string;
  status: string;
  plan_name?: string | null;
  access_until?: string | null;
  updates_until?: string | null;
  max_activations?: number | null;
  activations: MyDevice[];
}

export interface MyAccount {
  customer: { email: string };
  licences: MyLicence[];
  purchases: { uuid: string; plan_name: string; amount: number; currency: string; status: string; created_at: string;
    access_until?: string | null; updates_until?: string | null }[];
  subscriptions: { uuid: string; plan_name?: string | null; status: string; current_period_end?: string | null }[];
}

const enc = encodeURIComponent;

export const billingPublic = {
  app: (app: string) => call<PublicApp>('GET', `/api/v2/public/billing/apps/${enc(app)}`),
  requestLink: (pk: string, email: string) => call<{ message: string }>('POST', '/api/v2/public/billing/access-link', { pk, email }),
  openSession: (pk: string, token: string) =>
    call<{ session: string; expires_in: number }>('POST', '/api/v2/public/billing/sessions', { pk, token }),
  me: (pk: string, session: string) => call<MyAccount>('GET', `/api/v2/public/billing/me?pk=${enc(pk)}`, undefined, session),
  reissue: (pk: string, session: string, licence: string) =>
    call<{ key: string }>('POST', `/api/v2/public/billing/me/licenses/${enc(licence)}/reissue?pk=${enc(pk)}`, {}, session),
  freeDevice: (pk: string, session: string, licence: string, device: string) =>
    call('DELETE', `/api/v2/public/billing/me/licenses/${enc(licence)}/activations/${enc(device)}?pk=${enc(pk)}`, undefined, session),
  signOut: (pk: string, session: string) => call('POST', `/api/v2/public/billing/me/logout?pk=${enc(pk)}`, {}, session),
};
