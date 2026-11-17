/**
 * Workstation AI Shop — back-office types.
 *
 * Mirrors the OpsAPI shop CONTRACT (shop/BUILD.prompt.md §2, §3, §5).
 * Money is always integer minor units (pence); currency GBP. Catalogue prices
 * are ex-VAT; VAT is computed server-side.
 */

import type { PaymentMethodPublic } from '@/lib/payment-methods';

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

/** Shop languages: the UK shop (en) and the Belgian shop (fr, nl). */
export const SHOP_SEO_LOCALES = ['en', 'fr', 'nl'] as const;
export type ShopSeoLocale = (typeof SHOP_SEO_LOCALES)[number];

/**
 * Search and page content for one language. target_keyword is staff-only: OpsAPI never sends it to the
 * shop. Empty title = "<keyword> | <brand>"; "{price}" in a description becomes the live "from" price.
 */
export interface ShopSeoBlock {
  target_keyword?: string;
  title?: string;
  description?: string;
  intro?: string;
  /** Products only: "Who it's for". */
  audience?: string[];
  /** Products only: product-specific questions (the shop adds shared ones). */
  faqs?: { q: string; a: string }[];
}
export type ShopSeo = Partial<Record<ShopSeoLocale, ShopSeoBlock>>;

/** A product photo; the first is the main photo. fallback_url is a JPEG copy of a WebP url. */
export interface ShopPhoto {
  url: string;
  fallback_url?: string | null;
  width?: number | null;
  height?: number | null;
  alt: Partial<Record<ShopSeoLocale, string>>;
}

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
  seo?: ShopSeo;
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
  seo?: ShopSeo;
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
  /** Admin document: the option's own stored delta (price_delta_minor is the effective one). */
  stored_price_delta_minor?: number;
  /** Admin document: true when a priced component product sets this option's price. */
  price_follows_component?: boolean;
  /** Manual cost (pence ex VAT) of one unit of the price delta. Editable; null = unknown. */
  cost_minor?: number | null;
  /** Read-only: the component product's cost when linked, else cost_minor. */
  effective_cost_minor?: number | null;
  cost_source?: ShopOptionCostSource;
}

export type ShopOptionCostSource = 'component' | 'option' | null;
export type ShopProductCostSource = 'supplier' | 'manual' | null;

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
  /** Manual cost (pence ex VAT). Editable; null = unknown. */
  cost_minor?: number | null;
  /** Read-only: the linked supplier item's cost. */
  supplier_cost_minor?: number | null;
  /** Read-only: supplier cost if linked, else manual cost, else null. */
  effective_cost_minor?: number | null;
  cost_source?: ShopProductCostSource;
  seo?: ShopSeo;
  photos?: ShopPhoto[];
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
  /** Manual cost in pence ex VAT; null clears it, omitted leaves it unchanged. */
  cost_minor?: number | null;
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
  seo?: ShopSeo;
  photos?: ShopPhoto[];
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
  /** Free-text (service) line typed in the back office: no product, no stock. */
  custom?: boolean;
  description?: string | null;
  /** YYYY-MM-DD service period, e.g. a membership month. */
  period_start?: string | null;
  period_end?: string | null;
}

/** Line payload for admin quote create/edit — re-priced server-side. */
export type ShopLineInput =
  | {
      uuid?: string;
      product_slug: string;
      qty: number;
      selections: ShopSelections;
      price_override_minor?: number | null;
    }
  | {
      uuid?: string;
      custom: true;
      name: string;
      description?: string;
      qty: number;
      unit_price_minor: number;
      vat_rate?: number;
      period_start?: string;
      period_end?: string;
    };

/** "Order Authorisation" (kind order) or an ordinary quote. */
export type ShopQuoteKind = 'quote' | 'order';

/** Structured delivery address (the supplier PO's "Deliver directly to"). */
export interface ShopDeliveryAddress {
  name?: string;
  company?: string;
  line1?: string;
  line2?: string;
  city?: string;
  county?: string;
  postcode?: string;
  country?: string;
  email?: string;
  phone?: string;
  vat_number?: string;
}

/** Back-office order fields shared by quote create/update. */
export interface ShopQuoteOrderFields {
  kind?: ShopQuoteKind;
  /** Staff discount, pence ex VAT, off the whole order. */
  discount_minor?: number;
  discount_label?: string;
  /** true: work out the VIP Trade discount from the membership terms; false: remove it. */
  apply_trade_discount?: boolean;
  trade_discount_minor?: number;
  delivery_method?: string;
  delivery_address?: ShopDeliveryAddress | null;
  /** The end customer's own purchase order number (≤ 64 characters). null/'' clears it. */
  customer_po_number?: string | null;
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
  /** Private deal code (staff and suppliers only; never shown to the customer). */
  deal_code?: string | null;
  quote?: ShopRef | null;
  quote_uuid?: string | null;
  url_path?: string;
  public_url?: string;
  created_at: string;
  updated_at?: string;
  member_discount_minor?: number;
  discount_minor?: number;
  delivery_method?: string | null;
  delivery_address?: ShopDeliveryAddress | null;
  /** Supplier POs raised from this order. */
  purchase_orders?: ShopOrderPurchaseOrderRef[];
  /** The log the customer sees on their order page (comments + events), newest first. */
  customer_updates?: ShopCustomerUpdate[];
  /** The end customer's purchase order number (carried from the quote; editable on the order). */
  customer_po_number?: string | null;
  quote_number?: string | null;
  /** card (Stripe Checkout) | bank_transfer | cheque | other */
  payment_method?: ShopPaymentMethodKind;
  /** Bank-transfer orders: where to pay (workspace "Getting paid" methods) and the reference (order number). */
  payment_methods?: PaymentMethodPublic[];
  payment_reference?: string | null;
  /** What staff recorded when marking it paid. */
  paid_reference?: string | null;
  paid_amount_minor?: number | null;
  /** Accounting invoice raised from this order. */
  invoice_uuid?: string | null;
  /** Awaiting a bank transfer, and for how many days. */
  bank_transfer_due?: boolean;
  days_waiting?: number | null;
  /** Agreed delivery day (YYYY-MM-DD) and time window, set when staff approve a delivery change. */
  delivery_date?: string | null;
  delivery_window?: ShopDeliveryWindow | null;
  /** A customer's delivery change request is waiting for staff. */
  delivery_change_pending?: boolean;
  /** The customer's delivery change requests, newest first (order detail only). */
  delivery_change_requests?: ShopDeliveryChangeRequest[];
}

export type ShopDeliveryWindow = 'all_day' | 'am' | 'pm';

/** A signed-in customer asking to change where / when their order is delivered. Nothing changes until approved. */
export interface ShopDeliveryChangeRequest {
  uuid: string;
  status: 'pending' | 'approved' | 'declined' | 'cancelled';
  requested_address: ShopDeliveryAddress;
  /** null = keep the order's date / window. */
  requested_date: string | null;
  requested_window: ShopDeliveryWindow | null;
  customer_note: string | null;
  /** What the order said before (at request time; refreshed when approved). */
  previous_delivery_address: ShopDeliveryAddress | null;
  previous_delivery_date: string | null;
  previous_delivery_window: ShopDeliveryWindow | null;
  /** Shown to the customer on their order page (e.g. why it was declined). */
  staff_note: string | null;
  requested_by_email: string;
  decided_by: string | null;
  decided_at: string | null;
  cancelled_at: string | null;
  customer_notified_at: string | null;
  created_at: string;
}

/** An entry in the log the customer sees on their order page. */
export interface ShopCustomerUpdate {
  uuid?: string | null;
  kind: 'comment' | 'status' | 'delivery_address' | 'delivery_change' | 'email';
  at: string;
  status?: string | null;
  title?: string | null;
  message?: string | null;
  /** Admin view only. */
  author?: string | null;
  removable?: boolean;
}

/** PUT /shop/admin/orders/:uuid/delivery-address: staff change where the order is delivered. */
export interface ShopSetDeliveryAddressBody {
  address: ShopDeliveryAddress;
  staff_note?: string;
  /** Default true: open drop-ship supplier POs get the new "Deliver directly to" as well. */
  update_purchase_orders?: boolean;
}

export interface ShopSetDeliveryAddressResult {
  order: ShopOrder;
  /** Supplier POs updated; already_sent means the supplier has the old address and must be told. */
  purchase_orders: { po_number: string; supplier_name: string | null; status: string; already_sent: boolean }[];
}

export interface ShopDeliveryChangeDecision {
  request: ShopDeliveryChangeRequest;
  /** Clicked twice: it was already decided this way. */
  already: boolean;
  customer_notified: boolean;
  customer_notifications_enabled: boolean;
  order: ShopOrder;
}

/** "Email the customer" on the order page: a preset filled in for the order. */
export interface ShopOrderUpdatePreset {
  key: 'received_reserved' | 'in_stock_book_delivery' | 'dispatched' | 'delayed' | 'custom' | string;
  label: string;
  headline: string;
  message: string;
}

/** One update email sent for an order (tests to staff included). */
export interface ShopOrderUpdateEmail {
  uuid: string;
  kind: string;
  headline: string;
  body: string;
  subject: string | null;
  to_email: string;
  sent_by: string | null;
  test: boolean;
  created_at: string;
}

export interface ShopOrderUpdateInfo {
  presets: ShopOrderUpdatePreset[];
  /** The customer's email (null: the order has none, so it can't be emailed). */
  to: string | null;
  customer_name: string | null;
  /** Shop settings → "Customer emails from the shop". Off: only test sends to staff. */
  customer_emails_enabled: boolean;
  email_configured: boolean;
  /** The signed-in staff member's email (where test sends go). */
  test_to: string | null;
  signature: string;
  limits: { headline_max: number; message_max: number; per_day: number; sent_last_24h: number };
  history: ShopOrderUpdateEmail[];
}

export interface ShopOrderUpdatePreview {
  subject: string;
  html: string;
  /** The workspace has its own version of the template (Settings → Email templates). */
  customised: boolean;
  to: string | null;
  headline: string;
  message: string;
  kind: string;
  warnings: string[];
}

export interface ShopOrderUpdateSendResult {
  sent: boolean;
  test: boolean;
  to: string;
  subject: string;
  logged: boolean;
  history: ShopOrderUpdateEmail[];
  order: ShopOrder;
}

export type ShopPaymentMethodKind = 'card' | 'bank_transfer' | 'cheque' | 'other';

export interface ShopOrderMarkPaid {
  method: 'bank_transfer' | 'cheque' | 'other';
  reference?: string;
  /** YYYY-MM-DD */
  paid_at?: string;
  amount_minor?: number;
}

export interface ShopOrderInvoiceResult {
  existing: boolean;
  invoice_uuid: string;
  invoice_number: string;
  status: string;
  total_amount?: number | null;
  order_total_minor?: number;
}

export interface ShopOrderPurchaseOrderRef {
  uuid: string;
  po_number: string;
  status: string;
  supplier_name: string;
  total: number | string;
  currency?: string;
  created_at: string;
  sent_at?: string | null;
  received_at?: string | null;
  billed_at?: string | null;
  shop_supplier_uuid?: string | null;
}

export interface ShopOrderUpdate {
  status?: ShopOrderStatus;
  tracking?: ShopTracking | null;
  internal_notes?: string;
  customer_po_number?: string | null;
}

/** A line of the supplier PO preview (GET /orders/:uuid/purchase-order/preview). Cost: pounds ex VAT. */
export interface ShopPurchaseOrderPreviewLine {
  uuid: string;
  description: string;
  qty: number;
  vat_rate: number;
  custom: boolean;
  included: boolean;
  cost: string | null;
  cost_source: 'entered' | 'supplier_price_file' | null;
}

export interface ShopPurchaseOrderPreview {
  order_uuid: string;
  order_number: string;
  order_status: string;
  can_raise: boolean;
  supplier: {
    uuid: string | null;
    name: string | null;
    email: string | null;
    phone: string | null;
    address: string | null;
    account_number: string | null;
    po_notes: string | null;
  };
  last_supplier_uuid: string | null;
  bill_to: Record<string, string> | null;
  /** The deal code: the PO's reference (the supplier never sees the customer or our quote number). */
  deal_code: string | null;
  /** Where the supplier delivers by default: us (Shop → Settings, else Bill to). */
  deliver_to: Record<string, string> | null;
  deliver_to_text: string | null;
  /** The customer's address: only on the PO for a confirmed drop-ship. */
  ship_to: ShopDeliveryAddress;
  ship_to_text: string | null;
  drop_ship?: boolean;
  delivery_method: string | null;
  customer_po_number: string | null;
  notes: string;
  lines: ShopPurchaseOrderPreviewLine[];
  missing_costs: number;
  currency: string;
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
  /** Private deal code (staff and suppliers only; never shown to the customer). */
  deal_code?: string | null;
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
  kind?: ShopQuoteKind;
  /** "Order Authorisation" or "Quote". */
  document_title?: string;
  discount_minor?: number;
  discount_label?: string | null;
  trade_discount_minor?: number;
  /** Before discounts. */
  list_subtotal_minor?: number;
  list_vat_minor?: number;
  delivery_method?: string | null;
  delivery_address?: ShopDeliveryAddress | null;
  sent_at?: string | null;
  authorised_at?: string | null;
  authorised_by_name?: string | null;
  payable?: boolean;
  /** The end customer's purchase order number. */
  customer_po_number?: string | null;
  /** 0 = the original; n = <original number>-R<n>. */
  revision_no?: number;
  revision_of?: { uuid: string; quote_number: string } | null;
  superseded_by?: { uuid: string; quote_number: string; url_path?: string } | null;
  /** The whole chain (original first) when there is more than one. */
  revisions?: ShopQuoteRevisionRef[];
  /** Authorised, has an order, converted or superseded: the customer can't change it. */
  locked_for_customer?: boolean;
  /** Turned into an order: lines, prices, customer and delivery are locked. */
  has_order?: boolean;
  can_revise?: boolean;
  can_edit?: boolean;
  order_number?: string | null;
  order_status?: string | null;
  order_paid_at?: string | null;
}

export interface ShopQuoteRevisionRef {
  uuid: string;
  quote_number: string;
  revision_no: number;
  status: ShopQuoteStatus;
  superseded: boolean;
  created_at: string;
}

export interface ShopQuoteRevise {
  reason: string;
  customer?: ShopCustomer;
  delivery_address?: ShopDeliveryAddress | null;
  delivery_method?: string;
  customer_po_number?: string | null;
  valid_until?: string;
}

/** Quick filters on the quotes list. */
export type ShopQuoteQuickFilter = 'awaiting_authorisation' | 'awaiting_payment' | 'needs_supplier_po' | 'bank_transfer_due';

export interface ShopQuoteSendResult {
  to: string;
  test?: boolean;
  attached: boolean;
  pdf_error?: string | null;
  quote: ShopQuote;
}

export interface ShopTradeDiscountPreview {
  member: boolean;
  discount_minor: number;
  tier: 'founding' | 'standard' | null;
  pct: number | null;
  cap_remaining_minor: number | null;
}

export interface ShopQuoteUpdate extends ShopQuoteOrderFields {
  status?: ShopQuoteStatus;
  notes?: string;
  internal_notes?: string;
  valid_until?: string;
  customer?: ShopCustomer;
  lines?: ShopLineInput[];
  shipping_minor?: number;
}

export interface ShopQuoteCreate extends ShopQuoteOrderFields {
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

/** Order credit (loyalty, VIP fee refunds, admin). Money in pence, applied before VAT. */
export type ShopCreditStatus = 'available' | 'reserved' | 'used' | 'void';
export type ShopCreditSource = 'loyalty' | 'vip_refund' | 'admin';
export const SHOP_CREDIT_STATUSES: ShopCreditStatus[] = ['available', 'reserved', 'used', 'void'];

export interface ShopCredit {
  uuid: string;
  email: string;
  amount_minor: number;
  min_order_minor: number;
  source: ShopCreditSource;
  reason: string | null;
  status: ShopCreditStatus;
  expires_at: string | null;
  expired: boolean;
  created_by: string | null;
  created_at: string;
  earned_order_number: string | null;
  used_order_number: string | null;
  reserved_order_number: string | null;
  crm_lead_uuid: string | null;
  /** Only on create: whether the customer email was queued. */
  notified?: boolean;
}

export interface ShopCreditGrant {
  email: string;
  amount_minor: number;
  min_order_minor?: number;
  reason: string;
  expires_in_days?: number;
  notify?: boolean;
}

/** Supplier catalogue sync. Costs are pence ex VAT. */
export type ShopSupplierFormat = 'csv' | 'json' | 'xml';
export type ShopSupplierAuth = 'none' | 'basic' | 'bearer' | 'header';
export const SHOP_SUPPLIER_FIELDS = ['supplier_sku', 'name', 'cost', 'mpn', 'brand', 'category', 'stock', 'lead_time_days', 'rrp', 'url', 'ean'] as const;
export type ShopSupplierField = (typeof SHOP_SUPPLIER_FIELDS)[number];

export interface ShopSupplierSummary {
  records: number;
  kept: number;
  filtered_out: number;
  invalid: number;
  created: number;
  updated: number;
  cost_changed: number;
  big_cost_changes: number;
  deactivated: number;
  auto_linked: number;
  invalid_examples: string[];
  pricing?: { applied: number; pending: number; unchanged: number; lead_times_updated: number };
}

export interface ShopSupplier {
  uuid: string;
  name: string;
  feed_format: ShopSupplierFormat;
  feed_url: string | null;
  feed_options: { delimiter?: string; records_path?: string; record_tag?: string };
  auth_type: ShopSupplierAuth;
  auth_username: string | null;
  auth_header_name: string | null;
  has_auth_secret: boolean;
  mapping: Partial<Record<ShopSupplierField, string>>;
  filter: { keywords?: string[] };
  prices_include_vat: boolean;
  default_margin_pct: number;
  change_threshold_pct: number;
  update_lead_times: boolean;
  sync_hours: number;
  is_active: boolean;
  last_synced_at: string | null;
  last_status: 'ok' | 'error' | 'running' | null;
  last_error: string | null;
  last_summary: ShopSupplierSummary | null;
  item_counts: { active: number; total: number; linked: number };
  contact_email?: string | null;
  /** How we raise purchase orders with them. */
  po_email?: string | null;
  po_phone?: string | null;
  po_address?: string | null;
  /** Our account number with them (printed on POs). */
  account_number?: string | null;
  /** Printed on every PO to them. */
  po_notes?: string | null;
}

/** A PO raised with a shop supplier (GET /suppliers/:uuid/purchase-orders). */
export interface ShopSupplierPurchaseOrder {
  uuid: string;
  po_number: string;
  status: string;
  supplier_name: string;
  reference: string | null;
  issue_date: string | null;
  expected_date: string | null;
  currency: string;
  total: number | string;
  created_at: string;
  sent_at: string | null;
  received_at: string | null;
  billed_at: string | null;
  shop_order_uuid: string | null;
  shop_order_number: string | null;
  end_customer_po: string | null;
}

export type ShopSupplierInput = Partial<Omit<ShopSupplier, 'uuid' | 'has_auth_secret' | 'last_synced_at' | 'last_status' | 'last_error' | 'last_summary' | 'item_counts'>> & {
  /** Write-only: omitted = keep, '' = remove. */
  auth_secret?: string;
};

export interface ShopSupplierItem {
  uuid: string;
  supplier_sku: string;
  mpn: string | null;
  name: string;
  brand: string | null;
  cost_minor: number;
  previous_cost_minor: number | null;
  cost_change_pct: number | null;
  stock_qty: number | null;
  in_stock: boolean | null;
  lead_time_days: number | null;
  is_active: boolean;
  cost_changed_at: string | null;
  product_uuid: string | null;
  product_sku: string | null;
  product_name: string | null;
  pricing_source: 'manual' | 'supplier' | null;
  product_price_minor: number | null;
  product_margin_pct: number | null;
}

/** blocked_below_cost: a supplier price (or an approval) that would sell below cost; never applied. */
export type ShopPriceChangeStatus = 'pending' | 'applied' | 'approved' | 'rejected' | 'superseded' | 'blocked_below_cost';
export const SHOP_PRICE_CHANGE_STATUSES: ShopPriceChangeStatus[] = [
  'pending',
  'applied',
  'approved',
  'rejected',
  'superseded',
  'blocked_below_cost',
];

export interface ShopPriceChange {
  uuid: string;
  product_uuid: string;
  product_sku: string;
  product_name: string;
  old_price_minor: number;
  new_price_minor: number;
  current_price_minor: number;
  cost_minor: number;
  margin_pct: number;
  change_pct: number | null;
  status: ShopPriceChangeStatus;
  supplier_name: string | null;
  supplier_sku: string | null;
  decided_by: string | null;
  decided_at: string | null;
  created_at: string;
}

/** One item in a 422 BELOW_COST save refusal. */
export interface ShopBelowCostItem {
  kind: 'product' | 'option';
  name: string;
  product_name?: string;
  group_code?: string;
  option_code?: string;
  price_minor: number;
  cost_minor: number;
  message: string;
}

/** GET /pricing/below-cost */
export interface ShopBelowCostProduct {
  uuid: string;
  sku: string;
  name: string;
  status: ShopProductStatus;
  price_mode: ShopPriceMode;
  price_minor: number;
  cost_minor: number;
  cost_source: ShopProductCostSource;
  margin_minor: number;
}

export interface ShopBelowCostOption {
  product_uuid: string;
  product_sku: string;
  product_name: string;
  group_code: string;
  group_name: string;
  option_code: string;
  option_name: string;
  price_minor: number;
  cost_minor: number;
  cost_source: ShopOptionCostSource;
  margin_minor: number;
}

export interface ShopBelowCostQuote {
  uuid: string;
  quote_number: string;
  status: string;
  kind: string;
  customer_name: string | null;
  lines: { line_uuid: string; product_name: string; qty: number; unit_price_minor: number; unit_cost_minor: number }[];
}

export interface ShopBelowCostReport {
  products: ShopBelowCostProduct[];
  options: ShopBelowCostOption[];
  missing_cost: { products: number; options: number };
  missing_cost_products: { uuid: string; sku: string; name: string }[];
  quotes?: ShopBelowCostQuote[];
}

export interface ShopChatSession {
  uuid: string;
  email?: string | null;
  /** Given by the visitor at chat start, else from their CRM lead. */
  contact_name?: string | null;
  contact_phone?: string | null;
  /** Visitor address as seen by the edge (wslproxy X-WSL-Client-IP). */
  client_ip?: string | null;
  /** ISO 3166-1 alpha-2 from the edge's geo lookup. */
  country?: string | null;
  /** Started by a signed-in shop member. */
  is_member?: boolean;
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

// ============================================================
// Market prices (shop/MARKET.prompt.md §A) — third-party reference data
// ============================================================

export const SHOP_MARKET_FETCH_MODES = ['direct', 'firecrawl'] as const;
export type ShopMarketFetchMode = (typeof SHOP_MARKET_FETCH_MODES)[number];

export const SHOP_MARKET_STATUSES = ['ok', 'no_price', 'mismatch', 'http_error', 'blocked', 'rejected', 'anomaly'] as const;
export type ShopMarketStatus = (typeof SHOP_MARKET_STATUSES)[number];

export const SHOP_MARKET_AVAILABILITY = ['in_stock', 'limited', 'out_of_stock', 'preorder', 'backorder', 'unknown'] as const;
export type ShopMarketAvailability = (typeof SHOP_MARKET_AVAILABILITY)[number];

export type ShopMarketMethod = 'json_ld' | 'meta' | 'microdata' | 'llm';

export interface ShopMarketMatch {
  mpn?: string;
  gtin?: string;
  title_must_include?: string[];
  variant_hint?: string;
}

export interface ShopMarketObservation {
  uuid: string;
  source_uuid: string | null;
  source_name: string | null;
  url: string | null;
  price_minor: number | null;
  currency: string;
  price_ex_vat_minor: number | null;
  price_inc_vat_minor: number | null;
  availability: ShopMarketAvailability;
  stock_qty: number | null;
  title: string | null;
  method: ShopMarketMethod;
  confidence: number | null;
  evidence: string | null;
  flags: { anomaly?: boolean; previous_price_minor?: number; change_pct?: number; anomaly_accepted?: boolean; [k: string]: unknown };
  accepted: boolean;
  fetched_at: string;
  created_at: string;
  /** Only on a source's latest_observation: within the freshness window. */
  fresh?: boolean;
}

export interface ShopMarketSource {
  uuid: string;
  product_uuid: string;
  product_sku: string;
  product_name: string;
  name: string;
  url: string;
  fetch_mode: ShopMarketFetchMode;
  prices_include_vat: boolean;
  currency: string;
  match: ShopMarketMatch;
  is_active: boolean;
  last_checked_at: string | null;
  last_status: ShopMarketStatus | null;
  last_error: string | null;
  created_at: string;
  updated_at: string;
  /** Present on GET /market/products/:uuid. */
  latest_observation?: ShopMarketObservation | null;
  pending_anomalies?: number;
}

export interface ShopMarketSourceInput {
  product_uuid?: string;
  product_sku?: string;
  name: string;
  url: string;
  fetch_mode?: ShopMarketFetchMode;
  prices_include_vat?: boolean;
  currency?: string;
  match?: ShopMarketMatch;
  is_active?: boolean;
}

export interface ShopMarketSummary {
  min_ex_vat_minor: number | null;
  median_ex_vat_minor: number | null;
  max_ex_vat_minor: number | null;
  sources_in_stock: number;
  /** Sources with an accepted, fresh observation. */
  sources_total: number;
  priced_sources?: number;
  freshest_at: string | null;
  fresh_days?: number;
}

export interface ShopMarketProductDetail {
  product: {
    uuid: string;
    sku: string;
    slug: string;
    name: string;
    brand: string | null;
    base_price_minor: number;
    vat_rate: number;
    currency: string;
    price_verified: boolean;
    stock_qty: number;
    available: number;
    lead_time_days: number;
    status: ShopProductStatus;
  };
  sources: ShopMarketSource[];
  summary: ShopMarketSummary;
  /** Recent observations across all sources, newest first. */
  observations: ShopMarketObservation[];
}

export interface ShopMarketOverviewRow {
  product_uuid: string;
  sku: string;
  slug: string;
  name: string;
  brand: string | null;
  status: ShopProductStatus;
  vat_rate: number;
  price_verified: boolean;
  our_price_ex_vat_minor: number;
  market_min_ex_vat_minor: number | null;
  market_median_ex_vat_minor: number | null;
  market_max_ex_vat_minor: number | null;
  /** (ours − median) / median × 100. */
  diff_pct: number | null;
  in_stock_sources: number;
  fresh_sources: number;
  total_sources: number;
  configured_sources: number;
  failing_sources: number;
  pending_anomalies: number;
  freshest_at: string | null;
  last_checked_at: string | null;
  stale: boolean;
}

export interface ShopMarketOverviewParams {
  stale?: boolean;
  diff_gt?: number;
  q?: string;
  anomalies?: boolean;
}

export type ShopMarketApplyStrategy = 'median' | 'min' | 'value';

export interface ShopMarketApplyResult {
  product_uuid: string;
  sku: string;
  strategy: ShopMarketApplyStrategy;
  previous_price_minor: number;
  base_price_minor: number;
  price_verified: boolean;
  summary: ShopMarketSummary;
}

export interface ShopMarketUpsertResult {
  received: number;
  created: number;
  updated: number;
  failed: number;
  errors: { index: number; product_sku: string | null; url: string | null; error: string }[];
}

// ---------------------------------------------------------------------------------------------
// Legal record (GET /api/v2/shop/admin/legal/acceptances): what customers ticked, append-only.

export const SHOP_LEGAL_CHECKPOINTS = ['register', 'quote', 'checkout', 'trade_join', 'chat', 'enquiry', 'contact'] as const;
export type ShopLegalCheckpoint = (typeof SHOP_LEGAL_CHECKPOINTS)[number];

export interface ShopLegalAcceptance {
  uuid: string;
  email: string;
  document_key: string;
  document_version: string;
  content_hash: string | null;
  statement: string;
  checkpoint: ShopLegalCheckpoint;
  subject_ref: string | null;
  client_ip: string | null;
  user_agent: string | null;
  created_at: string;
  /** True only for "register": the person was signed in, so the email is theirs. */
  email_confirmed: boolean;
}

export interface ShopLegalListParams {
  q?: string;
  document_key?: string;
  checkpoint?: ShopLegalCheckpoint | '';
  limit?: number;
  offset?: number;
}

// ---------------- VIP (Trade) membership ----------------
export type ShopMembershipTier = 'founding' | 'standard';
export type ShopMembershipStatus = 'active' | 'past_due' | 'canceled' | 'expired';

/** A row of GET /shop/admin/membership/members (name/company/phone come from the customer's CRM lead). */
export interface ShopMember {
  uuid: string;
  email: string;
  tier: ShopMembershipTier;
  billing_interval: 'month' | 'year';
  status: ShopMembershipStatus;
  net_minor: number;
  vat_minor: number;
  joined_at: string | null;
  current_period_end: string | null;
  cancel_at_period_end: boolean;
  fees_paid_net_minor: number;
  fees_credited_net_minor: number;
  terms_version: string;
  lead_uuid: string | null;
  name: string | null;
  company: string | null;
  phone: string | null;
}

/** VIP status of one email (POST /shop/admin/membership/lookup): only memberships in force. */
export interface ShopVipStatus {
  email: string;
  uuid: string;
  tier: ShopMembershipTier;
  billing_interval: 'month' | 'year';
  status: 'active' | 'past_due';
  joined_at: string | null;
  current_period_end: string | null;
  cancel_at_period_end: boolean;
}

// ============================================================
// Deal codes (private: staff and suppliers only)
// ============================================================

export interface ShopSupplierRequestLine {
  /** The line of our quote this prices (for the compare table). */
  line_uuid?: string | null;
  description: string;
  qty: number;
  /** Their price per unit, pence ex VAT. */
  unit_price_minor?: number | null;
  note?: string | null;
}

export interface ShopSupplierRequest {
  uuid: string;
  deal_code: string;
  supplier_uuid: string | null;
  supplier_name: string;
  contact_name: string | null;
  contact_email: string | null;
  sent_at: string | null;
  spec: string | null;
  lines: ShopSupplierRequestLine[];
  supplier_quote_ref: string | null;
  lead_time: string | null;
  valid_until: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

export type ShopSupplierRequestInput = Partial<Omit<ShopSupplierRequest, 'uuid' | 'deal_code' | 'created_at' | 'updated_at'>>;

export interface ShopSupplierRequestDraft {
  to: string | null;
  subject: string;
  body: string;
  mailto: string;
  sent: false;
}

export interface ShopDealCompareCell {
  request_uuid: string;
  supplier_name: string;
  cost_unit_minor?: number | null;
  profit_unit_minor?: number | null;
  profit_line_minor?: number | null;
  below_cost: boolean;
}

export interface ShopDealCompareRow {
  line_uuid: string;
  description: string;
  qty: number;
  our_unit_minor: number | null;
  suppliers: ShopDealCompareCell[];
}

export interface ShopDealAuditEntry {
  action: string;
  detail: Record<string, unknown> | null;
  at: string;
  by: string | null;
}

export interface ShopDeal {
  deal_code: string;
  customer: { name: string | null; email: string | null; phone: string | null; company: string | null };
  leads: { uuid: string; name: string; email: string | null; phone: string | null; company: string | null; status: string; source: string | null; created_at: string }[];
  quotes: { uuid: string; quote_number: string; revision_no: number; kind: ShopQuoteKind; status: ShopQuoteStatus; total_minor: number; subtotal_minor: number; currency: string; created_at: string; superseded: boolean; order_uuid: string | null; order_number: string | null }[];
  orders: { uuid: string; order_number: string; status: ShopOrderStatus; total_minor: number; subtotal_minor: number; currency: string; paid_at: string | null; created_at: string; quote_number: string | null }[];
  purchase_orders: { uuid: string; po_number: string; status: string; supplier_name: string; total: string | number; currency: string; reference: string | null; created_at: string; sent_at: string | null; drop_ship: boolean; drop_ship_confirmed: boolean; legacy_drop_ship: boolean }[];
  supplier_requests: ShopSupplierRequest[];
  notes: { source: string; uuid: string; kind: 'quote' | 'order'; text: string }[];
  /** Our customer lines (the newest live quote, else the order): new requests start from these. */
  lines: { uuid: string; description: string; qty: number; unit_price_minor: number | null }[];
  lines_from: string | null;
  compare: { rows: ShopDealCompareRow[]; below_cost_count: number };
  audit: ShopDealAuditEntry[];
}

export interface ShopDealSearchResult {
  deal_code: string;
  matched_by: 'deal_code' | 'quote_number' | 'order_number' | 'supplier_quote_ref' | 'customer_email';
  match: string;
  customer?: string | null;
}

export interface ShopDealSearch {
  /** Set when the query is a full deal code of this workspace: open the deal page. */
  exact: string | null;
  results: ShopDealSearchResult[];
}
