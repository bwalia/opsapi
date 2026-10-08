/**
 * Billing & Entitlements (docs/BILLING_ENTITLEMENTS.md): apps and their
 * settings, features, flat-tier plans (recurring / one-time / fixed-term),
 * upgrade paths, coupons, subscriptions, purchases, grants, licences.
 * Each URL family is its own RBAC module: billing, subscriptions, entitlements, licenses.
 */
import apiClient from '@/lib/api-client';

export type AppKind = 'web' | 'desktop' | 'self_hosted' | 'mobile';
export type FeatureType = 'boolean' | 'limit';
export type PurchaseType = 'recurring' | 'one_time' | 'fixed_term';
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
  released_at?: string | null;
}

/** Effective settings (defaults for the app's kind + what was set). */
export type AppSettings = Record<string, unknown> & {
  offline_policy: 'fail_open' | 'fail_closed';
  grace_days: number;
  fingerprint_salt: string;
  display_name?: string;
};

/** One field of the settings schema (GET /api/v2/billing/settings-schema). */
export interface SettingSpec {
  key: string;
  group: string;
  type: 'enum' | 'integer' | 'boolean' | 'string' | 'url' | 'email' | 'color' | 'origins' | 'urls' | 'object';
  label: string;
  help?: string;
  values?: string[];
  min?: number;
  max?: number;
  nullable?: boolean;
  readonly?: boolean;
  default?: unknown;
  fields?: { key: string; min: number; max: number; default: number }[];
}

export interface BillingApp {
  uuid: string;
  name: string;
  slug: string;
  kind: AppKind;
  mode: 'test' | 'live';
  publishable_key: string;
  active: boolean;
  created_at: string;
  settings: AppSettings;
  features?: BillingFeature[];
}

export interface AppInput {
  name?: string;
  slug?: string;
  kind?: AppKind;
  mode?: 'test' | 'live';
  active?: boolean;
  /** Only the settings to change. */
  settings?: Record<string, unknown>;
}

export interface BillingPlan {
  uuid: string;
  name: string;
  description?: string | null;
  plan_key: string;
  purchase_type: PurchaseType;
  plan_type: 'subscription' | 'one_time';
  amount: number;
  currency: string;
  billing_interval: 'day' | 'week' | 'month' | 'year' | null;
  interval_count: number;
  trial_days: number;
  term_days?: number | null;
  term_covers?: 'access' | 'updates' | null;
  updates_days?: number | null;
  store_products?: Record<string, string>;
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
  purchase_type?: PurchaseType;
  amount?: number;
  currency?: string;
  billing_interval?: 'day' | 'week' | 'month' | 'year';
  trial_days?: number;
  term_days?: number | null;
  term_covers?: 'access' | 'updates';
  updates_days?: number | null;
  store_products?: Record<string, string>;
  features?: FeatureMap;
  is_default?: boolean;
  is_public?: boolean;
  active?: boolean;
}

export interface UpgradePath {
  uuid: string;
  pricing: 'difference' | 'fixed' | 'free';
  amount?: number | null;
  currency?: string | null;
  active: boolean;
  from_plan_uuid: string;
  from_plan_key: string;
  from_plan_name: string;
  to_plan_uuid: string;
  to_plan_key: string;
  to_plan_name: string;
}

export interface Coupon {
  uuid: string;
  code: string;
  name?: string | null;
  discount_type: 'percent' | 'amount';
  percent_off?: number | null;
  amount_off?: number | null;
  currency?: string | null;
  duration: 'once' | 'repeating' | 'forever';
  duration_months?: number | null;
  plans?: string[] | null;
  max_redemptions?: number | null;
  per_customer_limit?: number | null;
  redemptions_count: number;
  starts_at?: string | null;
  expires_at?: string | null;
  active: boolean;
  app_uuid?: string | null;
  app_name?: string | null;
}

export type CouponInput = Partial<Omit<Coupon, 'uuid' | 'redemptions_count' | 'app_uuid' | 'app_name'>> & { app?: string };

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

export interface Purchase extends CustomerRef {
  uuid: string;
  purchase_type: 'one_time' | 'fixed_term';
  source: string;
  status: 'active' | 'refunded' | 'revoked';
  access_until?: string | null;
  updates_until?: string | null;
  amount: number;
  currency: string;
  coupon_code?: string | null;
  external_transaction_id?: string | null;
  refunded_amount?: number;
  created_at: string;
}

/** The workspace's Stripe account (Stripe Connect Express). */
export interface ConnectStatus {
  connected: boolean;
  mode: 'test' | 'live';
  account?: string;
  charges_enabled?: boolean;
  payouts_enabled?: boolean;
  details_submitted?: boolean;
  platform_fee_percent?: number;
}

export interface PlanChange {
  uuid: string;
  kind: 'new' | 'upgrade' | 'downgrade' | 'renewal' | 'cancel';
  source: string;
  amount: number;
  currency?: string | null;
  coupon_code?: string | null;
  from_plan_name?: string | null;
  to_plan_name?: string | null;
  app_name: string;
  customer_uuid: string;
  customer_email: string;
  actor?: string | null;
  note?: string | null;
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
  source?: string;
  max_activations?: number | null;
  access_until?: string | null;
  updates_until?: string | null;
  key_rotated_at?: string | null;
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
  max_activations?: number | null;
  access_until?: string | null;
  updates_until?: string | null;
}

export interface SaleInput {
  app: string;
  customer?: string;
  customer_external_id?: string;
  email?: string;
  plan: string;
  amount?: number;
  coupon?: string;
  note?: string;
  expires_at?: string;
}

/** What a sale or upgrade returns; `key` is a new licence key, shown once. */
export interface SaleResult {
  purchase?: Purchase;
  subscription?: { uuid: string; status: string };
  license?: License;
  key?: string;
  amount?: number;
  discount?: number;
  currency?: string;
  from_plan?: { name: string };
  to_plan?: { name: string };
}

export interface Entitlements {
  plan: { uuid: string; key?: string | null; name: string } | null;
  status: 'none' | 'free' | 'granted' | 'purchased' | 'active' | 'trialing' | 'past_due';
  features: FeatureMap;
  sources: { type: string; uuid?: string; plan?: { name: string } | null }[];
  access_until?: number | null;
  updates_until?: number | null;
  expires_at: number;
  offline_policy: 'fail_open' | 'fail_closed';
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
  kind?: string;
  source?: string;
  search?: string;
  page?: number;
  per_page?: number;
  include_revoked?: boolean;
}

// The API encodes an empty JSON object as [] — normalise maps.
const asMap = <T = FeatureValue>(v: unknown): Record<string, T> =>
  v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, T>) : {};

const data = <T>(res: { data: { data: T } }): T => res.data.data;
const list = <T>(res: { data: { data: T[]; meta: ListMeta } }) => ({ data: res.data.data, meta: res.data.meta });
const enc = encodeURIComponent;
const normPlan = (p: BillingPlan): BillingPlan => ({
  ...p,
  amount: Number(p.amount),
  features: asMap(p.features),
  store_products: asMap<string>(p.store_products),
});

export const billingService = {
  // ---- Apps (billing) ----
  settingsSchema: async (kind?: AppKind) =>
    data<SettingSpec[]>(await apiClient.get('/api/v2/billing/settings-schema', { params: { kind } })),
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
  listPlans: async (app: string) =>
    data<BillingPlan[]>(
      await apiClient.get('/api/v2/billing/plans', { params: { app, include_inactive: 'true' } })
    ).map(normPlan),
  createPlan: async (input: PlanInput) => data<BillingPlan>(await apiClient.post('/api/v2/billing/plans', input)),
  updatePlan: async (uuid: string, input: PlanInput) =>
    data<BillingPlan>(await apiClient.put(`/api/v2/billing/plans/${enc(uuid)}`, input)),
  deletePlan: async (uuid: string) => apiClient.delete(`/api/v2/billing/plans/${enc(uuid)}`),

  // ---- Upgrade paths + coupons (billing) ----
  listUpgrades: async (app: string) =>
    data<UpgradePath[]>(await apiClient.get(`/api/v2/billing/apps/${enc(app)}/upgrades`)),
  createUpgrade: async (app: string, input: { from_plan: string; to_plan: string; pricing: string; amount?: number; currency?: string }) =>
    data<UpgradePath>(await apiClient.post(`/api/v2/billing/apps/${enc(app)}/upgrades`, input)),
  updateUpgrade: async (app: string, uuid: string, input: Partial<UpgradePath>) =>
    data<UpgradePath>(await apiClient.put(`/api/v2/billing/apps/${enc(app)}/upgrades/${enc(uuid)}`, input)),
  deleteUpgrade: async (app: string, uuid: string) =>
    apiClient.delete(`/api/v2/billing/apps/${enc(app)}/upgrades/${enc(uuid)}`),
  listCoupons: async (params: ListParams = {}) => list<Coupon>(await apiClient.get('/api/v2/billing/coupons', { params })),
  createCoupon: async (input: CouponInput) => data<Coupon>(await apiClient.post('/api/v2/billing/coupons', input)),
  updateCoupon: async (uuid: string, input: CouponInput) =>
    data<Coupon>(await apiClient.put(`/api/v2/billing/coupons/${enc(uuid)}`, input)),
  deleteCoupon: async (uuid: string) => apiClient.delete(`/api/v2/billing/coupons/${enc(uuid)}`),

  // ---- Subscriptions, purchases, grants, upgrades, history (subscriptions) ----
  listSubscriptions: async (params: ListParams = {}) =>
    list<Subscription>(await apiClient.get('/api/v2/subscriptions', { params })),
  listPurchases: async (params: ListParams = {}) =>
    list<Purchase>(await apiClient.get('/api/v2/subscriptions/purchases', { params })),
  /** Record a sale by hand; a licensed app returns the new licence key once. */
  sell: async (input: SaleInput) => data<SaleResult>(await apiClient.post('/api/v2/subscriptions/purchases', input)),
  revokePurchase: async (uuid: string) => apiClient.post(`/api/v2/subscriptions/purchases/${enc(uuid)}/revoke`),
  /** Refund a Stripe purchase (all of it, or `amount` in minor units); Stripe's webhook applies it. */
  refundPurchase: async (uuid: string, amount?: number) =>
    data<{ refund: string; status: string; amount: number }>(
      await apiClient.post(`/api/v2/subscriptions/purchases/${enc(uuid)}/refund`, amount ? { amount } : {})
    ),

  // ---- Payments: Stripe Connect (billing) ----
  connectStatus: async () => data<ConnectStatus>(await apiClient.get('/api/v2/billing/connect')),
  /** Start or resume Stripe onboarding: returns the Stripe-hosted URL to send the admin to. */
  connectOnboard: async (country?: string) =>
    data<{ url: string }>(await apiClient.post('/api/v2/billing/connect/onboard', country ? { country } : {})),
  upgrade: async (input: { app: string; customer: string; to_plan: string; coupon?: string; note?: string }, quote = false) =>
    data<SaleResult>(await apiClient.post('/api/v2/subscriptions/upgrade', input, { params: quote ? { quote: 1 } : {} })),
  planChanges: async (params: ListParams = {}) =>
    list<PlanChange>(await apiClient.get('/api/v2/subscriptions/plan-changes', { params })),
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
  updateLicense: async (
    uuid: string,
    input: Partial<Pick<License, 'status' | 'max_activations' | 'access_until' | 'updates_until'>>
  ) => data<License>(await apiClient.put(`/api/v2/licenses/${enc(uuid)}`, input)),
  revokeLicense: async (uuid: string) => data<License>(await apiClient.post(`/api/v2/licenses/${enc(uuid)}/revoke`)),
  /** A new key for a lost one (shown once); the old key stops working, devices are kept. */
  reissueLicense: async (uuid: string) =>
    data<{ license: License; key: string }>(await apiClient.post(`/api/v2/licenses/${enc(uuid)}/reissue`)),
  removeActivation: async (uuid: string, activation: string) =>
    apiClient.delete(`/api/v2/licenses/${enc(uuid)}/activations/${enc(activation)}`),

  /** Customers for pickers (server-side search on email, name, external_id). */
  searchCustomers: async (search: string) => {
    const res = await apiClient.get('/api/v2/customers', { params: { search, perPage: 25 } });
    return (res.data?.data || []) as { uuid: string; email: string; first_name?: string; last_name?: string; external_id?: string }[];
  },
};

export const formatMinor = (amount: number, currency: string) =>
  new Intl.NumberFormat('en-GB', { style: 'currency', currency: (currency || 'gbp').toUpperCase() }).format(amount / 100);

export const describeValue = (feature: Pick<BillingFeature, 'type' | 'unit'>, value: FeatureValue | undefined) => {
  if (feature.type === 'boolean') return value === true ? 'Included' : '—';
  if (value === null) return 'Unlimited';
  if (value === undefined || value === 0) return '—';
  return `${value}${feature.unit ? ` ${feature.unit}` : ''}`;
};

export const PURCHASE_TYPE_LABELS: Record<PurchaseType, string> = {
  recurring: 'Subscription',
  one_time: 'One-time (lifetime)',
  fixed_term: 'Fixed term',
};

/** "£99.00 / month", "£99.00 once", "£9.00 for 30 days" */
export const describePrice = (p: BillingPlan) => {
  if (p.amount === 0) return 'Free';
  const price = formatMinor(p.amount, p.currency);
  if (p.purchase_type === 'recurring') return `${price} / ${p.billing_interval ?? 'month'}`;
  if (p.purchase_type === 'fixed_term') return `${price} for ${p.term_days} days${p.term_covers === 'updates' ? ' of updates' : ''}`;
  return `${price} once`;
};
