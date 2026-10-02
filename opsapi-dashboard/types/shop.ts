/**
 * Workstation AI Shop — back-office types.
 *
 * Mirrors the OpsAPI shop CONTRACT (shop/BUILD.prompt.md §2, §3, §5).
 * Money is always integer minor units (pence); currency GBP. Catalogue prices
 * are ex-VAT; VAT is computed server-side.
 */

// ============================================================
// Enums
// ============================================================

export const SHOP_PRODUCT_TYPES = [
  'workstation',
  'server',
  'gpu',
  'cpu',
  'memory',
  'storage',
  'networking',
  'peripheral',
  'software',
  'service',
] as const;
export type ShopProductType = (typeof SHOP_PRODUCT_TYPES)[number];

export const SHOP_PRICE_MODES = ['fixed', 'configurable', 'quote_only'] as const;
export type ShopPriceMode = (typeof SHOP_PRICE_MODES)[number];

export const SHOP_PRODUCT_STATUSES = ['draft', 'active', 'archived'] as const;
export type ShopProductStatus = (typeof SHOP_PRODUCT_STATUSES)[number];

export type ShopSelectionMode = 'single' | 'multi';

export const SHOP_RULE_KINDS = ['requires', 'excludes', 'power', 'max_total', 'attr_match'] as const;
export type ShopRuleKind = (typeof SHOP_RULE_KINDS)[number];

export const SHOP_ORDER_STATUSES = [
  'pending_payment',
  'paid',
  'processing',
  'shipped',
  'delivered',
  'cancelled',
  'refunded',
  'payment_failed',
] as const;
export type ShopOrderStatus = (typeof SHOP_ORDER_STATUSES)[number];

export const SHOP_QUOTE_STATUSES = ['draft', 'sent', 'accepted', 'expired', 'converted', 'cancelled'] as const;
export type ShopQuoteStatus = (typeof SHOP_QUOTE_STATUSES)[number];

export type ShopQuoteSource = 'cart' | 'chat' | 'admin';

export const SHOP_STOCK_REASONS = ['adjustment', 'restock', 'import', 'sale', 'release'] as const;
export type ShopStockReason = (typeof SHOP_STOCK_REASONS)[number];

export const SHOP_KNOWLEDGE_SOURCES = ['product', 'cms_post', 'faq', 'manual', 'url'] as const;
export type ShopKnowledgeSourceType = (typeof SHOP_KNOWLEDGE_SOURCES)[number];

// ============================================================
// Common
// ============================================================

export type ShopJson = Record<string, unknown>;

export interface ShopListMeta {
  total: number;
  limit: number;
  offset: number;
}

export interface ShopList<T> {
  data: T[];
  meta: ShopListMeta;
}

export interface ShopAvailability {
  in_stock: boolean;
  qty_available?: number | null;
  lead_time_days?: number;
  shortages?: { name: string; requested: number; available: number }[];
}

// ============================================================
// Catalogue
// ============================================================

export interface ShopCategory {
  id?: number;
  uuid: string;
  slug: string;
  name: string;
  description?: string | null;
  image_url?: string | null;
  parent_id?: number | null;
  parent_uuid?: string | null;
  parent_slug?: string | null;
  sort_order: number;
  is_active: boolean;
  product_count?: number;
  created_at?: string;
  updated_at?: string;
}

export interface ShopCategoryInput {
  slug?: string;
  name: string;
  description?: string;
  image_url?: string;
  parent_uuid?: string | null;
  sort_order?: number;
  is_active?: boolean;
}

export interface ShopOption {
  id?: number;
  uuid?: string;
  code: string;
  name: string;
  description?: string | null;
  price_delta_minor: number;
  component_product_id?: number | null;
  component_product_uuid?: string | null;
  /** As returned by the admin document. */
  component_product?: { uuid: string; name?: string; sku?: string } | null;
  component_product_sku?: string | null;
  /** NULL = untracked (when no component product). */
  stock_qty?: number | null;
  max_qty: number;
  is_default: boolean;
  is_active: boolean;
  sort_order: number;
  attributes: ShopJson;
  availability?: ShopAvailability;
  held?: number;
  /** Admin document: available units (own stock or component product's). */
  available?: number | null;
}

export interface ShopOptionGroup {
  id?: number;
  uuid?: string;
  code: string;
  name: string;
  description?: string | null;
  selection: ShopSelectionMode;
  required: boolean;
  min_qty: number;
  max_qty: number;
  sort_order: number;
  options: ShopOption[];
}

export interface ShopRuleParamsRequires {
  if: string; // "<group>.<option>"
  then_group: string;
  one_of: string[];
}
export interface ShopRuleParamsExcludes {
  a: string;
  b: string;
}
export interface ShopRuleParamsPower {
  budget_from: string;
  budget_attr: string;
  sum_attr: string;
  groups: string[];
  base_watts: number;
  headroom: number;
}
export interface ShopRuleParamsMaxTotal {
  group: string;
  attr: string;
  limit_attr: string;
}
export interface ShopRuleParamsAttrMatch {
  group: string;
  attr: string;
  equals_product_attr: string;
}

export type ShopRuleParams =
  | ShopRuleParamsRequires
  | ShopRuleParamsExcludes
  | ShopRuleParamsPower
  | ShopRuleParamsMaxTotal
  | ShopRuleParamsAttrMatch;

export interface ShopRule {
  id?: number;
  uuid?: string;
  kind: ShopRuleKind;
  params: ShopRuleParams | ShopJson;
  message: string;
  is_active: boolean;
  sort_order?: number;
}

/** Selections: {"<group_code>":[{"option":"<option_code>","qty":1}]} */
export type ShopSelections = Record<string, { option: string; qty: number }[]>;

/** Admin product document — Product(full) plus editable/internal fields. */
export interface ShopProduct {
  id?: number;
  uuid: string;
  sku: string;
  slug: string;
  name: string;
  brand?: string | null;
  product_type: ShopProductType;
  price_mode: ShopPriceMode;
  short_description?: string | null;
  description?: string | null;
  specs: Record<string, string>;
  attributes: ShopJson;
  images: string[];
  tags: string[];
  base_price_minor: number;
  from_price_minor?: number;
  currency: string;
  vat_rate: number;
  stock_qty: number;
  held?: number;
  /** stock_qty - held (admin list/document). */
  available?: number;
  low_stock?: boolean;
  low_stock_threshold: number;
  lead_time_days: number;
  allow_backorder: boolean;
  price_verified: boolean;
  status: ShopProductStatus;
  is_featured: boolean;
  sort_order: number;
  category_id?: number | null;
  category_uuid?: string | null;
  category?: { id?: number; uuid?: string; slug: string; name: string } | null;
  availability?: ShopAvailability;
  option_groups: ShopOptionGroup[];
  rules: ShopRule[];
  default_selections?: ShopSelections;
  has_embedding?: boolean;
  created_at?: string;
  updated_at?: string;
}

/** Row returned by GET /products (list) — option_groups/rules may be omitted. */
export type ShopProductListItem = Omit<ShopProduct, 'option_groups' | 'rules'> &
  Partial<Pick<ShopProduct, 'option_groups' | 'rules'>>;

/** Body for POST/PUT /products — one document, groups/options/rules replaced transactionally. */
export interface ShopProductInput {
  sku: string;
  slug: string;
  name: string;
  brand?: string;
  product_type: ShopProductType;
  price_mode: ShopPriceMode;
  short_description?: string;
  description?: string;
  specs: Record<string, string>;
  attributes: ShopJson;
  images: string[];
  tags: string[];
  base_price_minor: number;
  currency: string;
  vat_rate: number;
  stock_qty?: number;
  low_stock_threshold: number;
  lead_time_days: number;
  allow_backorder: boolean;
  price_verified: boolean;
  status: ShopProductStatus;
  is_featured: boolean;
  sort_order: number;
  category_id?: number | null;
  category_uuid?: string | null;
  option_groups: Omit<ShopOptionGroup, 'id' | 'uuid'>[];
  rules: Omit<ShopRule, 'id'>[];
}

export interface ShopProductListParams {
  q?: string;
  status?: ShopProductStatus | '';
  type?: ShopProductType | '';
  low_stock?: boolean;
  limit?: number;
  offset?: number;
}

// ============================================================
// Pricing / lines
// ============================================================

export interface ShopBreakdownItem {
  group: string;
  option: string;
  name: string;
  qty: number;
  price_delta_minor: number;
}

export interface ShopViolation {
  rule: string;
  message: string;
  groups?: string[];
}

export interface ShopPriced {
  product_slug: string;
  qty: number;
  selections: ShopSelections;
  unit_price_minor: number;
  line_subtotal_minor: number;
  line_vat_minor: number;
  line_total_minor: number;
  label: string;
  breakdown: ShopBreakdownItem[];
  violations: ShopViolation[];
  valid: boolean;
  availability?: ShopAvailability;
}

/** Immutable line snapshot stored on quotes/orders. */
export interface ShopLine extends ShopPriced {
  uuid: string;
  product_uuid?: string;
  product_name: string;
  sku?: string;
  image?: string | null;
  /** Admin-only: overrides the unit price on quotes. */
  price_override_minor?: number | null;
}

/** Line payload for admin quote create/edit — re-priced server-side. */
export interface ShopLineInput {
  uuid?: string;
  product_slug: string;
  qty: number;
  selections: ShopSelections;
  price_override_minor?: number | null;
}

export interface ShopTotals {
  subtotal_minor: number;
  vat_minor: number;
  shipping_minor: number;
  total_minor: number;
  currency: string;
}

// ============================================================
// Customers / addresses
// ============================================================

export interface ShopAddress {
  line1?: string;
  line2?: string;
  city?: string;
  state?: string;
  postal_code?: string;
  country?: string;
  [key: string]: unknown;
}

export interface ShopCustomer {
  name?: string;
  email?: string;
  company?: string;
  phone?: string;
  vat_number?: string;
  address?: ShopAddress | string | null;
  [key: string]: unknown;
}

export interface ShopRef {
  uuid: string;
  number?: string;
  quote_number?: string;
  order_number?: string;
  status?: string;
}

// ============================================================
// Orders
// ============================================================

export interface ShopTracking {
  carrier?: string;
  tracking_number?: string;
  url?: string;
  shipped_at?: string;
  [key: string]: unknown;
}

export interface ShopOrder extends ShopTotals {
  uuid: string;
  order_number: string;
  status: ShopOrderStatus;
  email?: string | null;
  customer?: ShopCustomer | null;
  shipping_address?: ShopAddress | null;
  billing_address?: ShopAddress | null;
  lines: ShopLine[];
  stripe_session_id?: string | null;
  stripe_payment_intent_id?: string | null;
  paid_at?: string | null;
  tracking?: ShopTracking | null;
  internal_notes?: string | null;
  quote?: ShopRef | null;
  quote_uuid?: string | null;
  url_path?: string;
  public_url?: string;
  created_at: string;
  updated_at?: string;
}

export interface ShopOrderUpdate {
  status?: ShopOrderStatus;
  tracking?: ShopTracking | null;
  internal_notes?: string;
}

// ============================================================
// Quotes
// ============================================================

export interface ShopQuote extends ShopTotals {
  uuid: string;
  quote_number: string;
  status: ShopQuoteStatus;
  source?: ShopQuoteSource;
  customer: ShopCustomer;
  lines: ShopLine[];
  notes?: string | null;
  internal_notes?: string | null;
  valid_until: string;
  viewed_at?: string | null;
  url_path?: string;
  /** SHOP_PUBLIC_URL + url_path — the customer capability link. */
  public_url?: string;
  order?: ShopRef | null;
  order_uuid?: string | null;
  chat_session_uuid?: string | null;
  crm_lead_id?: number | null;
  created_at: string;
  updated_at?: string;
}

export interface ShopQuoteUpdate {
  status?: ShopQuoteStatus;
  notes?: string;
  internal_notes?: string;
  valid_until?: string;
  customer?: ShopCustomer;
  lines?: ShopLineInput[];
  shipping_minor?: number;
}

export interface ShopQuoteCreate {
  customer: ShopCustomer;
  lines: ShopLineInput[];
  notes?: string;
  internal_notes?: string;
  valid_until?: string;
  shipping_minor?: number;
  status?: ShopQuoteStatus;
  source: 'admin';
}

// ============================================================
// Stock
// ============================================================

export interface ShopStockRow {
  kind: 'product' | 'option';
  uuid: string;
  product_uuid?: string;
  product_name: string;
  sku?: string;
  group_name?: string | null;
  option_name?: string | null;
  option_code?: string | null;
  stock_qty: number;
  held: number;
  available: number;
  low_stock_threshold: number;
  allow_backorder?: boolean;
  lead_time_days?: number;
  is_low?: boolean;
}

export interface ShopStockAdjust {
  delta: number;
  reason: ShopStockReason;
  note?: string;
}

export interface ShopStockMovement {
  uuid?: string;
  product_uuid?: string | null;
  option_uuid?: string | null;
  delta: number;
  reason: ShopStockReason;
  ref?: string | null;
  note?: string | null;
  user_name?: string | null;
  created_at: string;
}

export interface ShopImportResult {
  categories?: { created?: number; updated?: number };
  products?: { created?: number; updated?: number };
  [key: string]: unknown;
}

// ============================================================
// Chats
// ============================================================

export interface ShopChatMessage {
  role: 'user' | 'assistant' | 'system' | 'tool' | string;
  content: string;
  at?: string;
  tools?: string[];
}

export interface ShopChatSession {
  uuid: string;
  email?: string | null;
  cart_uuid?: string | null;
  cart?: ShopRef | null;
  quote_uuid?: string | null;
  quote?: ShopRef | null;
  order_uuid?: string | null;
  order?: ShopRef | null;
  messages?: ShopChatMessage[];
  summary?: string | null;
  /** List rows only: first user message (preview). */
  first_user_message?: string | null;
  quote_number?: string | null;
  order_number?: string | null;
  message_count: number;
  created_at: string;
  updated_at?: string;
}

// ============================================================
// Knowledge (RAG)
// ============================================================

export interface ShopKnowledgeChunk {
  uuid?: string;
  source_type: ShopKnowledgeSourceType;
  source_ref: string;
  title: string;
  url?: string | null;
  chunk_index: number;
  content: string;
  has_embedding?: boolean;
  created_at?: string;
  updated_at?: string;
}

/** Row returned by GET /knowledge — one per source document (chunks aggregated). */
export interface ShopKnowledgeDoc {
  source_type: ShopKnowledgeSourceType;
  source_ref: string;
  title: string;
  url?: string | null;
  /** Number of chunks indexed for this source. */
  chunks: number;
  embedded_chunks: number;
  has_embedding: boolean;
  characters?: number;
  /** First ~240 chars of chunk 0. */
  preview?: string | null;
  updated_at?: string;
}

export interface ShopKnowledgeInput {
  source_type: 'faq' | 'manual' | 'url';
  title: string;
  url?: string;
  content: string;
}

export interface ShopReindexResult {
  products?: number;
  cms_posts?: number;
  chunks?: number;
  [key: string]: unknown;
}

// ============================================================
// Dashboard / reconcile
// ============================================================

/** Normalised KPI set for GET /dashboard (see shopService.getDashboard). */
export interface ShopDashboardKpis {
  orders_today: number;
  orders_7d: number;
  orders_30d: number;
  revenue_paid_30d_minor: number;
  open_quotes: number;
  open_quotes_value_minor: number;
  low_stock_count: number;
  chats_7d: number;
  /** 0..1 */
  quote_conversion_rate: number;
  currency: string;
}

export interface ShopReconcileResult {
  released?: number;
  cancelled?: number;
  marked_paid?: number;
  [key: string]: unknown;
}
