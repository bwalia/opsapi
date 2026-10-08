/**
 * Billing & Entitlements (docs/BILLING_ENTITLEMENTS.md): apps, their features
 * and flat-tier plans, subscriptions + grants, licences. Each URL family is
 * its own RBAC module: billing, subscriptions, entitlements, licenses.
 */
import apiClient from '@/lib/api-client';

export type AppKind = 'web' | 'desktop' | 'self_hosted' | 'mobile';
export type OfflinePolicy = 'fail_open' | 'fail_closed';
export type FeatureType = 'boolean' | 'limit';
/** On/off features are booleans; limits are numbers, null = unlimited. */
export type FeatureValue = boolean | number | null;
export type FeatureMap = Record<string, FeatureValue>;

export interface BillingFeature {
  uuid: string;
  key: string;
  name: string;
  description?: string | null;
  type: FeatureType;
  unit?: string | null;
  sort_order: number;
}

export interface BillingApp {
  uuid: string;
  name: string;
  slug: string;
  kind: AppKind;
  mode: 'test' | 'live';
  publishable_key: string;
  offline_policy: OfflinePolicy;
  offline_grace_seconds: number;
  entitlement_ttl_seconds: number;
  past_due_grace_days: number;
  allowed_return_urls: string[];
  active: boolean;
  created_at: string;
  features?: BillingFeature[];
}

export type AppInput = Partial<
  Pick<
    BillingApp,
    | 'name'
    | 'slug'
    | 'kind'
    | 'mode'
    | 'offline_policy'
    | 'offline_grace_seconds'
    | 'entitlement_ttl_seconds'
    | 'past_due_grace_days'
    | 'allowed_return_urls'
    | 'active'
  >
>;

export interface BillingPlan {
  uuid: string;
  name: string;
  description?: string | null;
  plan_key: string;
  plan_type: 'subscription' | 'one_time';
  amount: number;
  currency: string;
  billing_interval: 'day' | 'week' | 'month' | 'year' | null;
  interval_count: number;
  trial_days: number;
  features: FeatureMap;
  is_default: boolean;
  is_public: boolean;
  active: boolean;
  sort_order: number;
}

export interface PlanInput {
  app?: string;
  name?: string;
  description?: string;
  plan_key?: string;
  amount?: number;
  currency?: string;
  billing_interval?: 'day' | 'week' | 'month' | 'year';
  interval_count?: number;
  trial_days?: number;
  features?: FeatureMap;
  is_default?: boolean;
  is_public?: boolean;
  active?: boolean;
}

export interface AppReport {
  active: number;
  trialing: number;
  past_due: number;
  churned_30d: number;
  new_30d: number;
  active_grants: number;
  active_licenses: number;
  active_activations: number;
  mrr: { currency: string; amount: number }[];
}

interface CustomerRef {
  customer_uuid: string;
  customer_email: string;
  customer_external_id?: string | null;
  app_uuid: string;
  app_name: string;
  plan_uuid?: string | null;
  plan_key?: string | null;
  plan_name?: string | null;
}

export interface Subscription extends CustomerRef {
  uuid: string;
  status: string;
  provider?: string;
  current_period_end?: string | null;
  cancel_at_period_end?: boolean;
  canceled_at?: string | null;
  trial_end?: string | null;
  created_at: string;
}

export interface Grant extends CustomerRef {
  uuid: string;
  features: FeatureMap;
  reason?: string | null;
  starts_at: string;
  expires_at?: string | null;
  granted_by?: string | null;
  revoked_at?: string | null;
  created_at: string;
}

export interface GrantInput {
  app: string;
  customer: string;
  plan?: string;
  features?: FeatureMap;
  reason?: string;
  starts_at?: string;
  expires_at?: string;
}

export interface Activation {
  uuid: string;
  name?: string | null;
  platform?: string | null;
  app_version?: string | null;
  first_seen_at: string;
  last_seen_at: string;
  deactivated_at?: string | null;
}

export type LicenseStatus = 'active' | 'suspended' | 'revoked' | 'expired';

export interface License extends CustomerRef {
  uuid: string;
  key_prefix: string;
  status: LicenseStatus;
  max_activations?: number | null;
  expires_at?: string | null;
  subscription_uuid?: string | null;
  active_activations: number;
  revoked_at?: string | null;
  created_at: string;
  activations?: Activation[];
}

export interface LicenseInput {
  app: string;
  customer: string;
  plan?: string;
  subscription?: string;
  max_activations?: number | null;
  expires_at?: string | null;
}

export interface Entitlements {
  plan: { uuid: string; key?: string | null; name: string } | null;
  status: 'none' | 'free' | 'granted' | 'active' | 'trialing' | 'past_due';
  features: FeatureMap;
  sources: { type: 'default_plan' | 'subscription' | 'grant'; uuid?: string; plan?: { name: string } | null }[];
  expires_at: number;
  policy: OfflinePolicy;
  grace_seconds: number;
}

export interface ListMeta {
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
}

export interface ListParams {
  app?: string;
  customer?: string;
  status?: string;
  page?: number;
  per_page?: number;
  include_revoked?: boolean;
}

// The API encodes an empty JSON object as [] — normalise feature maps.
const asMap = (v: unknown): FeatureMap => (v && typeof v === 'object' && !Array.isArray(v) ? (v as FeatureMap) : {});

const data = <T>(res: { data: { data: T } }): T => res.data.data;
const list = <T>(res: { data: { data: T[]; meta: ListMeta } }) => ({ data: res.data.data, meta: res.data.meta });
const enc = encodeURIComponent;

export const billingService = {
  // ---- Apps (billing) ----
  listApps: async () => data<BillingApp[]>(await apiClient.get('/api/v2/billing/apps')),
  getApp: async (app: string) => data<BillingApp>(await apiClient.get(`/api/v2/billing/apps/${enc(app)}`)),
  createApp: async (input: AppInput) => data<BillingApp>(await apiClient.post('/api/v2/billing/apps', input)),
  updateApp: async (app: string, input: AppInput) =>
    data<BillingApp>(await apiClient.put(`/api/v2/billing/apps/${enc(app)}`, input)),
  deleteApp: async (app: string) => apiClient.delete(`/api/v2/billing/apps/${enc(app)}`),
  rotateKey: async (app: string) =>
    data<BillingApp>(await apiClient.post(`/api/v2/billing/apps/${enc(app)}/rotate-key`)),
  report: async (app: string) => data<AppReport>(await apiClient.get(`/api/v2/billing/apps/${enc(app)}/reports`)),

  addFeature: async (app: string, input: Partial<BillingFeature>) =>
    data<BillingFeature>(await apiClient.post(`/api/v2/billing/apps/${enc(app)}/features`, input)),
  updateFeature: async (app: string, key: string, input: Partial<BillingFeature>) =>
    data<BillingFeature>(await apiClient.put(`/api/v2/billing/apps/${enc(app)}/features/${enc(key)}`, input)),
  deleteFeature: async (app: string, key: string) =>
    apiClient.delete(`/api/v2/billing/apps/${enc(app)}/features/${enc(key)}`),

  // ---- Plans (billing; shared with the tax app's plans endpoint) ----
  listPlans: async (app: string) => {
    const plans = data<BillingPlan[]>(
      await apiClient.get('/api/v2/billing/plans', { params: { app, include_inactive: 'true' } })
    );
    return plans.map((p) => ({ ...p, amount: Number(p.amount), features: asMap(p.features) }));
  },
  createPlan: async (input: PlanInput) => data<BillingPlan>(await apiClient.post('/api/v2/billing/plans', input)),
  updatePlan: async (uuid: string, input: PlanInput) =>
    data<BillingPlan>(await apiClient.put(`/api/v2/billing/plans/${enc(uuid)}`, input)),
  deletePlan: async (uuid: string) => apiClient.delete(`/api/v2/billing/plans/${enc(uuid)}`),

  // ---- Subscriptions + grants (subscriptions) ----
  listSubscriptions: async (params: ListParams = {}) =>
    list<Subscription>(await apiClient.get('/api/v2/subscriptions', { params })),
  listGrants: async (params: ListParams = {}) => {
    const res = list<Grant>(await apiClient.get('/api/v2/subscriptions/grants', { params }));
    return { ...res, data: res.data.map((g) => ({ ...g, features: asMap(g.features) })) };
  },
  createGrant: async (input: GrantInput) => data<Grant>(await apiClient.post('/api/v2/subscriptions/grants', input)),
  revokeGrant: async (uuid: string) => apiClient.delete(`/api/v2/subscriptions/grants/${enc(uuid)}`),
  entitlements: async (app: string, customer: string) => {
    const e = data<Entitlements>(await apiClient.get('/api/v2/subscriptions/entitlements', { params: { app, customer } }));
    return { ...e, features: asMap(e.features) };
  },

  // ---- Licences (licenses) ----
  listLicenses: async (params: ListParams = {}) => list<License>(await apiClient.get('/api/v2/licenses', { params })),
  getLicense: async (uuid: string) => data<License>(await apiClient.get(`/api/v2/licenses/${enc(uuid)}`)),
  /** The key is returned once: show it, never store it. */
  createLicense: async (input: LicenseInput) =>
    data<{ license: License; key: string }>(await apiClient.post('/api/v2/licenses', input)),
  updateLicense: async (uuid: string, input: Partial<Pick<License, 'status' | 'max_activations' | 'expires_at'>>) =>
    data<License>(await apiClient.put(`/api/v2/licenses/${enc(uuid)}`, input)),
  revokeLicense: async (uuid: string) => data<License>(await apiClient.post(`/api/v2/licenses/${enc(uuid)}/revoke`)),
  removeActivation: async (uuid: string, activation: string) =>
    apiClient.delete(`/api/v2/licenses/${enc(uuid)}/activations/${enc(activation)}`),

  /** Customers for pickers (server-side search on email, name, external_id). */
  searchCustomers: async (search: string) => {
    const res = await apiClient.get('/api/v2/customers', { params: { search, perPage: 25 } });
    return (res.data?.data || []) as { uuid: string; email: string; first_name?: string; last_name?: string; external_id?: string }[];
  },
};

export const formatMinor = (amount: number, currency: string) =>
  new Intl.NumberFormat('en-GB', { style: 'currency', currency: currency.toUpperCase() }).format(amount / 100);

export const describeValue = (feature: Pick<BillingFeature, 'type' | 'unit'>, value: FeatureValue | undefined) => {
  if (feature.type === 'boolean') return value === true ? 'Included' : '—';
  if (value === null) return 'Unlimited';
  if (value === undefined || value === 0) return '—';
  return `${value}${feature.unit ? ` ${feature.unit}` : ''}`;
};
