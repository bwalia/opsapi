/**
 * Workstation AI Shop — admin API client.
 *
 * Base `/api/v2/shop/admin` (JWT + namespace headers added by api-client).
 * Envelope `{ success, data, meta? }`; lists return `{ data: [...], meta: { total, limit, offset } }`.
 * Bodies are JSON (the shop routes parse JSON, not form-encoded).
 * Contract: workstation-website/shop/BUILD.prompt.md §5.
 */
import apiClient, { buildQueryString } from '@/lib/api-client';
import type { PurchaseOrder, PurchaseOrderParty } from '@/services/purchase-orders.service';
import type {
  ShopCategory,
  ShopCategoryInput,
  ShopChatSession,
  ShopCredit,
  ShopBelowCostReport,
  ShopPriceChange,
  ShopPriceChangeStatus,
  ShopSupplier,
  ShopSupplierInput,
  ShopSupplierItem,
  ShopSupplierSummary,
  ShopCreditGrant,
  ShopCreditStatus,
  ShopDashboardKpis,
  ShopImportResult,
  ShopKnowledgeDoc,
  ShopKnowledgeInput,
  ShopKnowledgeSourceType,
  ShopList,
  ShopListMeta,
  ShopMarketApplyResult,
  ShopMarketApplyStrategy,
  ShopMarketObservation,
  ShopMarketOverviewParams,
  ShopMarketOverviewRow,
  ShopMarketProductDetail,
  ShopMarketSource,
  ShopMarketSourceInput,
  ShopMarketUpsertResult,
  ShopDeliveryChangeDecision,
  ShopSetDeliveryAddressBody,
  ShopCustomerUpdate,
  ShopSetDeliveryAddressResult,
  ShopDeliveryChangeRequest,
  ShopOrder,
  ShopOrderInvoiceResult,
  ShopOrderMarkPaid,
  ShopOrderStatus,
  ShopOrderUpdate,
  ShopOrderUpdateInfo,
  ShopOrderUpdatePreview,
  ShopOrderUpdateSendResult,
  ShopProduct,
  ShopProductInput,
  ShopProductListItem,
  ShopProductListParams,
  ShopQuote,
  ShopQuoteCreate,
  ShopQuoteSendResult,
  ShopTradeDiscountPreview,
  ShopQuoteStatus,
  ShopQuoteUpdate,
  ShopQuoteRevise,
  ShopQuoteQuickFilter,
  ShopPurchaseOrderPreview,
  ShopSupplierPurchaseOrder,
  ShopReconcileResult,
  ShopReindexResult,
  ShopStockAdjust,
  ShopStockMovement,
  ShopStockRow,
  ShopDeal,
  ShopDealSearch,
  ShopSupplierRequest,
  ShopSupplierRequestDraft,
  ShopSupplierRequestInput,
} from '@/types/shop';

const BASE = '/api/v2/shop/admin';

export interface ShopOrderPurchaseOrderInput {
  /** A shop supplier: fills name, email, phone, address and costs from its price file (values here override). */
  supplier_uuid?: string;
  supplier_name?: string;
  supplier_email?: string;
  supplier_phone?: string;
  supplier_address?: string;
  expected_date?: string;
  delivery_method?: string;
  notes?: string;
  /** Supplier cost per order line, pounds ex VAT, by line uuid. */
  costs?: Record<string, string>;
  include_custom?: boolean;
  /** Supplier delivers straight to the customer (they see the customer's address): needs confirm_drop_ship. */
  drop_ship?: boolean;
  /** "I confirm the supplier will see this delivery address" (logged on the deal). */
  confirm_drop_ship?: boolean;
}
const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;

interface Envelope<T> {
  success?: boolean;
  data?: T;
  meta?: Partial<ShopListMeta>;
}

function unwrap<T>(response: { data?: unknown }): T {
  const body = response.data as Envelope<T> | undefined;
  return body?.data as T;
}

function unwrapList<T>(response: { data?: unknown }, limit?: number, offset?: number): ShopList<T> {
  const body = response.data as Envelope<T[]> | undefined;
  const data = Array.isArray(body?.data) ? body!.data : [];
  return {
    data,
    meta: {
      total: Number(body?.meta?.total ?? data.length),
      limit: Number(body?.meta?.limit ?? limit ?? data.length),
      offset: Number(body?.meta?.offset ?? offset ?? 0),
    },
  };
}

const num = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

/** First defined value among candidate keys (flat or dotted path). */
function pick(obj: Record<string, unknown>, ...keys: string[]): unknown {
  for (const k of keys) {
    const v = k.split('.').reduce<unknown>(
      (acc, part) => (acc && typeof acc === 'object' ? (acc as Record<string, unknown>)[part] : undefined),
      obj
    );
    if (v !== undefined && v !== null) return v;
  }
  return undefined;
}

/** Tolerate flat or nested KPI payloads from GET /dashboard. */
function normalizeKpis(raw: Record<string, unknown> | undefined): ShopDashboardKpis {
  const r = raw ?? {};
  let rate = num(pick(r, 'quote_conversion_rate', 'conversion_rate', 'conversion.quote_to_order', 'quote_to_order_rate'));
  if (rate > 1) rate = rate / 100; // tolerate a percentage
  return {
    orders_today: num(pick(r, 'orders_today', 'orders.today')),
    orders_7d: num(pick(r, 'orders_7d', 'orders.7d', 'orders.d7')),
    orders_30d: num(pick(r, 'orders_30d', 'orders.30d', 'orders.d30')),
    revenue_paid_30d_minor: num(pick(r, 'revenue_paid_30d_minor', 'revenue_30d_minor', 'revenue.paid_30d_minor')),
    open_quotes: num(pick(r, 'open_quotes', 'open_quotes_count', 'quotes.open')),
    open_quotes_value_minor: num(pick(r, 'open_quotes_value_minor', 'open_quotes_total_minor', 'quotes.open_value_minor')),
    low_stock_count: num(pick(r, 'low_stock_count', 'low_stock', 'stock.low')),
    chats_7d: num(pick(r, 'chats_7d', 'chats.7d', 'chat_sessions_7d')),
    quote_conversion_rate: rate,
    currency: String(pick(r, 'currency') ?? 'GBP'),
  };
}

export interface ShopOrderListParams {
  status?: ShopOrderStatus | '';
  q?: string;
  /** Awaiting a bank transfer, oldest first. */
  bank_transfer_due?: boolean;
  /** Paid with no supplier PO yet | a customer's delivery change request is waiting. */
  filter?: 'needs_supplier_po' | 'delivery_change_pending' | '';
  limit?: number;
  offset?: number;
}

export interface ShopQuoteListParams {
  status?: ShopQuoteStatus | '';
  q?: string;
  filter?: ShopQuoteQuickFilter | '';
  kind?: 'quote' | 'order' | '';
  limit?: number;
  offset?: number;
}

export interface ShopPageParams {
  limit?: number;
  offset?: number;
}

/** Shop-wide settings. checkout_enabled false = no online payment for orders, enquiries (quotes) only. */
export interface ShopSettings {
  checkout_enabled: boolean;
  /** "Bill to" on supplier purchase orders raised from paid shop orders. */
  po_bill_to?: PurchaseOrderParty | null;
  /** Where the staff "new order" alert goes (unset: the Leads → Notifications admin email). */
  order_alert_email?: string | null;
  /**
   * "Customer emails from the shop": order update emails staff send from the order page, and the
   * outcome of a delivery change request. Off by default (test sends to staff always work).
   */
  customer_delivery_notifications?: boolean;
  /** Start of every new deal code (default WS). */
  deal_code_prefix?: string;
  /** Random characters after the prefix (default 8 = XXXX-XXXX). */
  deal_code_length?: number;
  /** Our delivery address for supplier POs (unset: the Bill to address). */
  po_deliver_to?: PurchaseOrderParty | null;
  /** UK delivery the shop publishes (product page, search results). 0 = included. Pence ex VAT. */
  delivery_cost_minor?: number;
  /** In-stock items: working days before dispatch ("Ships in 1–2 days"). */
  delivery_handling_min_days?: number;
  delivery_handling_max_days?: number;
  /** Courier days after dispatch. */
  delivery_transit_min_days?: number;
  delivery_transit_max_days?: number;
  /** How long a new quote holds its price (also the shop's "price valid until"). */
  quote_valid_days?: number;
  /** Supplier portal: invited supplier contacts can sign in and see their own purchase orders. Off by default. */
  supplier_portal_enabled?: boolean;
  /** Supplier portal emails: suppliers are emailed about payments, documents and messages. Off by default. */
  supplier_portal_emails_enabled?: boolean;
  updated_at: string | null;
}

/** Delivery and quote-validity settings, editable together. */
export const SHOP_DELIVERY_KEYS = [
  'delivery_cost_minor',
  'delivery_handling_min_days',
  'delivery_handling_max_days',
  'delivery_transit_min_days',
  'delivery_transit_max_days',
  'quote_valid_days',
] as const;

export const shopService = {
  // ---------------- Settings ----------------
  async getSettings(): Promise<ShopSettings> {
    const res = await apiClient.get(`${BASE}/settings`);
    return unwrap<ShopSettings>(res);
  },

  async updateSettings(
    body: Partial<Pick<ShopSettings, 'checkout_enabled' | 'po_bill_to' | 'order_alert_email' | 'customer_delivery_notifications' | 'supplier_portal_enabled' | 'supplier_portal_emails_enabled' | 'deal_code_prefix' | 'deal_code_length' | 'po_deliver_to' | (typeof SHOP_DELIVERY_KEYS)[number]>>,
  ): Promise<ShopSettings> {
    const res = await apiClient.put(`${BASE}/settings`, body, JSON_BODY);
    return unwrap<ShopSettings>(res);
  },

  // ---------------- Dashboard / ops ----------------
  async getDashboard(): Promise<ShopDashboardKpis> {
    const res = await apiClient.get(`${BASE}/dashboard`);
    return normalizeKpis(unwrap<Record<string, unknown>>(res));
  },

  async reconcile(): Promise<ShopReconcileResult> {
    const res = await apiClient.post(`${BASE}/reconcile`, {}, JSON_BODY);
    return unwrap<ShopReconcileResult>(res) ?? {};
  },

  // ---------------- Categories ----------------
  async getCategories(): Promise<ShopCategory[]> {
    const res = await apiClient.get(`${BASE}/categories${buildQueryString({ limit: 500 })}`);
    return unwrapList<ShopCategory>(res).data;
  },

  async createCategory(input: ShopCategoryInput): Promise<ShopCategory> {
    const res = await apiClient.post(`${BASE}/categories`, input, JSON_BODY);
    return unwrap<ShopCategory>(res);
  },

  async updateCategory(uuid: string, input: Partial<ShopCategoryInput>): Promise<ShopCategory> {
    const res = await apiClient.put(`${BASE}/categories/${uuid}`, input, JSON_BODY);
    return unwrap<ShopCategory>(res);
  },

  async deleteCategory(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/categories/${uuid}`);
  },

  // ---------------- Products ----------------
  async getProducts(params: ShopProductListParams = {}): Promise<ShopList<ShopProductListItem>> {
    const qs = buildQueryString({
      q: params.q,
      status: params.status,
      type: params.type,
      low_stock: params.low_stock ? 1 : undefined,
      limit: params.limit,
      offset: params.offset,
    });
    const res = await apiClient.get(`${BASE}/products${qs}`);
    return unwrapList<ShopProductListItem>(res, params.limit, params.offset);
  },

  async getProduct(uuid: string): Promise<ShopProduct> {
    const res = await apiClient.get(`${BASE}/products/${uuid}`);
    return unwrap<ShopProduct>(res);
  },

  async createProduct(input: ShopProductInput): Promise<ShopProduct> {
    const res = await apiClient.post(`${BASE}/products`, input, JSON_BODY);
    return unwrap<ShopProduct>(res);
  },

  /** Replaces option groups/options/rules transactionally (upsert by code, deactivate missing). */
  async updateProduct(uuid: string, input: ShopProductInput): Promise<ShopProduct> {
    const res = await apiClient.put(`${BASE}/products/${uuid}`, input, JSON_BODY);
    return unwrap<ShopProduct>(res);
  },

  /** Archives instead of hard-deleting when the product is referenced. */
  async deleteProduct(uuid: string): Promise<{ archived?: boolean } | undefined> {
    const res = await apiClient.delete(`${BASE}/products/${uuid}`);
    return unwrap<{ archived?: boolean }>(res);
  },

  // ---------------- Stock ----------------
  async adjustProductStock(uuid: string, body: ShopStockAdjust): Promise<unknown> {
    const res = await apiClient.post(`${BASE}/products/${uuid}/stock`, body, JSON_BODY);
    return unwrap<unknown>(res);
  },

  async adjustOptionStock(uuid: string, body: ShopStockAdjust): Promise<unknown> {
    const res = await apiClient.post(`${BASE}/options/${uuid}/stock`, body, JSON_BODY);
    return unwrap<unknown>(res);
  },

  async getStock(params: { low_only?: boolean } = {}): Promise<ShopStockRow[]> {
    const qs = buildQueryString({ low_only: params.low_only ? 1 : undefined });
    const res = await apiClient.get(`${BASE}/stock${qs}`);
    return unwrapList<ShopStockRow>(res).data;
  },

  /**
   * Movement history. NOT in §5 of the contract — assumed
   * `GET /stock/movements?product_uuid=|option_uuid=&limit=`. Callers must handle 404.
   */
  async getStockMovements(params: { product_uuid?: string; option_uuid?: string; limit?: number }): Promise<ShopStockMovement[]> {
    const qs = buildQueryString({
      product_uuid: params.product_uuid,
      option_uuid: params.option_uuid,
      limit: params.limit ?? 50,
    });
    const res = await apiClient.get(`${BASE}/stock/movements${qs}`);
    return unwrapList<ShopStockMovement>(res).data;
  },

  async importCatalog(body: { categories: unknown[]; products: unknown[] }): Promise<ShopImportResult> {
    const res = await apiClient.post(`${BASE}/import`, body, JSON_BODY);
    return unwrap<ShopImportResult>(res) ?? {};
  },

  // ---------------- Orders ----------------
  async getOrders(params: ShopOrderListParams = {}): Promise<ShopList<ShopOrder> & { bankTransferDue: number; deliveryChangePending: number }> {
    const qs = buildQueryString({
      status: params.status,
      q: params.q,
      filter: params.filter || undefined,
      limit: params.limit,
      offset: params.offset,
      bank_transfer_due: params.bank_transfer_due ? 'true' : undefined,
    });
    const res = await apiClient.get(`${BASE}/orders${qs}`);
    const meta = (res.data as { meta?: { bank_transfer_due_count?: number; delivery_change_pending_count?: number } } | undefined)?.meta;
    return {
      ...unwrapList<ShopOrder>(res, params.limit, params.offset),
      bankTransferDue: num(meta?.bank_transfer_due_count),
      deliveryChangePending: num(meta?.delivery_change_pending_count),
    };
  },

  /** The customer's delivery change requests on an order, newest first. */
  async getDeliveryChanges(orderUuid: string): Promise<ShopDeliveryChangeRequest[]> {
    const res = await apiClient.get(`${BASE}/orders/${orderUuid}/delivery-changes`);
    return unwrap<ShopDeliveryChangeRequest[]>(res) ?? [];
  },

  /** Apply the requested address / date / window to the order. Idempotent; 409 once the order has shipped. */
  async approveDeliveryChange(orderUuid: string, requestUuid: string, staffNote?: string): Promise<ShopDeliveryChangeDecision> {
    const res = await apiClient.post(`${BASE}/orders/${orderUuid}/delivery-changes/${requestUuid}/approve`, { staff_note: staffNote || undefined }, JSON_BODY);
    return unwrap<ShopDeliveryChangeDecision>(res);
  },

  /** Staff change the delivery address (UK; 409 once shipped). Open drop-ship supplier POs follow by default. */
  async setDeliveryAddress(orderUuid: string, body: ShopSetDeliveryAddressBody): Promise<ShopSetDeliveryAddressResult> {
    const res = await apiClient.put(`${BASE}/orders/${orderUuid}/delivery-address`, body, JSON_BODY);
    return unwrap<ShopSetDeliveryAddressResult>(res);
  },

  /** Post an update the customer sees on their order page (plain text, ≤ 2000 characters). */
  async addCustomerUpdate(orderUuid: string, message: string): Promise<ShopCustomerUpdate> {
    const res = await apiClient.post(`${BASE}/orders/${orderUuid}/updates`, { message }, JSON_BODY);
    return unwrap<ShopCustomerUpdate>(res);
  },

  /** Hide an update from the customer's order page. */
  async removeCustomerUpdate(orderUuid: string, updateUuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/orders/${orderUuid}/updates/${updateUuid}`);
  },

  /** Decline with a reason (shown to the customer on their order page). Idempotent. */
  async declineDeliveryChange(orderUuid: string, requestUuid: string, staffNote: string): Promise<ShopDeliveryChangeDecision> {
    const res = await apiClient.post(`${BASE}/orders/${orderUuid}/delivery-changes/${requestUuid}/decline`, { staff_note: staffNote }, JSON_BODY);
    return unwrap<ShopDeliveryChangeDecision>(res);
  },

  /** "Email the customer": presets filled in for this order, the recipient, the switch and the history. */
  async getOrderUpdateEmail(orderUuid: string): Promise<ShopOrderUpdateInfo> {
    const res = await apiClient.get(`${BASE}/orders/${orderUuid}/update-email/presets`);
    return unwrap<ShopOrderUpdateInfo>(res);
  },

  /** Render the update email for this order (the workspace's template version if it has one). */
  async previewOrderUpdateEmail(orderUuid: string, body: { preset?: string; headline?: string; message?: string }): Promise<ShopOrderUpdatePreview> {
    const res = await apiClient.post(`${BASE}/orders/${orderUuid}/update-email/preview`, body, JSON_BODY);
    return unwrap<ShopOrderUpdatePreview>(res);
  },

  /**
   * Send the update email. test: a [TEST] copy to the signed-in user only. A real send needs Shop settings →
   * "Customer emails from the shop" on (409 CUSTOMER_EMAILS_OFF) and allows 5 per order per 24 hours.
   */
  async sendOrderUpdateEmail(orderUuid: string, body: { preset?: string; headline: string; message: string; test?: boolean }): Promise<ShopOrderUpdateSendResult> {
    const res = await apiClient.post(`${BASE}/orders/${orderUuid}/update-email`, body, JSON_BODY);
    return unwrap<ShopOrderUpdateSendResult>(res);
  },

  /** Record a payment that arrived outside Stripe (bank transfer, cheque, other); the order becomes paid. */
  async markOrderPaid(uuid: string, body: ShopOrderMarkPaid): Promise<ShopOrder> {
    const res = await apiClient.post(`${BASE}/orders/${uuid}/mark-paid`, body, JSON_BODY);
    return unwrap<ShopOrder>(res);
  },

  /** Draft accounting invoice from the order (idempotent: returns the existing one). */
  async createOrderInvoice(uuid: string, body: { payment_method_uuid?: string } = {}): Promise<ShopOrderInvoiceResult> {
    const res = await apiClient.post(`${BASE}/orders/${uuid}/invoice`, body, JSON_BODY);
    return unwrap<ShopOrderInvoiceResult>(res);
  },

  async getOrder(uuid: string): Promise<ShopOrder> {
    const res = await apiClient.get(`${BASE}/orders/${uuid}`);
    return unwrap<ShopOrder>(res);
  },

  /** What the supplier PO would say (supplier details, costs from the price file, Bill to, Deliver to). */
  async previewOrderPurchaseOrder(uuid: string, supplierUuid?: string, dropShip = false): Promise<ShopPurchaseOrderPreview> {
    const qs = buildQueryString({ supplier_uuid: supplierUuid, drop_ship: dropShip ? 'true' : undefined });
    const res = await apiClient.get(`${BASE}/orders/${uuid}/purchase-order/preview${qs}`);
    return unwrap<ShopPurchaseOrderPreview>(res);
  },

  /** Draft a supplier PO for a paid order (Bill to us, the deal code as reference, delivered to us unless a confirmed drop-ship). */
  async createOrderPurchaseOrder(uuid: string, body: ShopOrderPurchaseOrderInput): Promise<PurchaseOrder> {
    const res = await apiClient.post(`${BASE}/orders/${uuid}/purchase-order`, body, JSON_BODY);
    return unwrap<PurchaseOrder>(res);
  },

  async updateOrder(uuid: string, body: ShopOrderUpdate): Promise<ShopOrder> {
    const res = await apiClient.put(`${BASE}/orders/${uuid}`, body, JSON_BODY);
    return unwrap<ShopOrder>(res);
  },

  // ---------------- Deal codes (private) ----------------
  /** The deal page: customer, quotes, orders, POs, supplier requests, notes, compare table, audit. Logged. */
  async getDeal(code: string): Promise<ShopDeal> {
    const res = await apiClient.get(`${BASE}/deals/${encodeURIComponent(code)}`);
    return unwrap<ShopDeal>(res);
  },

  /** By deal code, WSQ number, order number, supplier quote reference or customer email. */
  async searchDeals(q: string): Promise<ShopDealSearch> {
    const res = await apiClient.get(`${BASE}/deals/search${buildQueryString({ q })}`);
    return unwrap<ShopDealSearch>(res) ?? { exact: null, results: [] };
  },

  /** Put a quote (with its revisions) or an order (with its POs) on another deal, or on a new one. */
  async linkDealCode(kind: 'quote' | 'order', uuid: string, body: { deal_code?: string; new?: boolean }): Promise<{ deal_code: string; previous: string | null; moved: boolean }> {
    const res = await apiClient.post(`${BASE}/${kind}s/${uuid}/deal-code`, body, JSON_BODY);
    return unwrap(res);
  },

  async createSupplierRequest(code: string, body: ShopSupplierRequestInput): Promise<ShopSupplierRequest> {
    const res = await apiClient.post(`${BASE}/deals/${encodeURIComponent(code)}/supplier-requests`, body, JSON_BODY);
    return unwrap<ShopSupplierRequest>(res);
  },

  async updateSupplierRequest(uuid: string, body: ShopSupplierRequestInput): Promise<ShopSupplierRequest> {
    const res = await apiClient.put(`${BASE}/supplier-requests/${uuid}`, body, JSON_BODY);
    return unwrap<ShopSupplierRequest>(res);
  },

  async deleteSupplierRequest(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/supplier-requests/${uuid}`);
  },

  /** A draft email (subject "Price request: <code>", the spec, no customer details). Nothing is sent. */
  async supplierRequestEmailDraft(uuid: string): Promise<ShopSupplierRequestDraft> {
    const res = await apiClient.post(`${BASE}/supplier-requests/${uuid}/email-draft`, {}, JSON_BODY);
    return unwrap<ShopSupplierRequestDraft>(res);
  },

  // ---------------- Quotes ----------------
  async getQuotes(params: ShopQuoteListParams = {}): Promise<ShopList<ShopQuote>> {
    const qs = buildQueryString({ status: params.status, q: params.q, filter: params.filter, kind: params.kind, limit: params.limit, offset: params.offset });
    const res = await apiClient.get(`${BASE}/quotes${qs}`);
    return unwrapList<ShopQuote>(res, params.limit, params.offset);
  },

  async getQuote(uuid: string): Promise<ShopQuote> {
    const res = await apiClient.get(`${BASE}/quotes/${uuid}`);
    return unwrap<ShopQuote>(res);
  },

  /** Editing `lines` re-prices them server-side; `price_override_minor` per line is admin-only. */
  async updateQuote(uuid: string, body: ShopQuoteUpdate): Promise<ShopQuote> {
    const res = await apiClient.put(`${BASE}/quotes/${uuid}`, body, JSON_BODY);
    return unwrap<ShopQuote>(res);
  },

  async createQuote(body: ShopQuoteCreate): Promise<ShopQuote> {
    const res = await apiClient.post(`${BASE}/quotes`, body, JSON_BODY);
    return unwrap<ShopQuote>(res);
  },

  /** Email the customer the Order Authorisation / quote (PDF attached, link to confirm and pay).
   *  opts.test: send it to you instead, marked TEST, with a preview link; the quote isn't marked as sent. */
  async sendQuote(uuid: string, to?: string, opts: { test?: boolean } = {}): Promise<ShopQuoteSendResult> {
    const body: Record<string, unknown> = {};
    if (to) body.to = to;
    if (opts.test) body.test = true;
    const res = await apiClient.post(`${BASE}/quotes/${uuid}/send`, body, JSON_BODY);
    return unwrap<ShopQuoteSendResult>(res);
  },

  /** A revision for small corrections: copy numbered <original>-R<n> (draft); the old one is cancelled. */
  async reviseQuote(uuid: string, body: ShopQuoteRevise): Promise<ShopQuote> {
    const res = await apiClient.post(`${BASE}/quotes/${uuid}/revise`, body, JSON_BODY);
    return unwrap<ShopQuote>(res);
  },

  /** New Order Authorisation from a quote: same lines and prices, VIP discount, delivery = customer address. */
  async createOrderFromQuote(uuid: string, body: { apply_trade_discount?: boolean } = {}): Promise<ShopQuote> {
    const res = await apiClient.post(`${BASE}/quotes/${uuid}/order-authorisation`, body, JSON_BODY);
    return unwrap<ShopQuote>(res);
  },

  /** Save the quote's customer to the CRM (company account + contact). */
  async saveQuoteCustomerToCrm(uuid: string): Promise<{ account_uuid: string | null; contact_uuid: string | null; account_created: boolean; contact_created: boolean }> {
    const res = await apiClient.post(`${BASE}/quotes/${uuid}/crm-customer`, {}, JSON_BODY);
    return unwrap(res);
  },

  /** The VIP Trade discount the customer's membership gives this quote. */
  async getQuoteTradeDiscount(uuid: string): Promise<ShopTradeDiscountPreview> {
    const res = await apiClient.get(`${BASE}/quotes/${uuid}/trade-discount`);
    return unwrap<ShopTradeDiscountPreview>(res);
  },

  // ---------------- Chats ----------------
  // ---------------- Suppliers ----------------
  async getSuppliers(): Promise<ShopSupplier[]> {
    const res = await apiClient.get(`${BASE}/suppliers`);
    return unwrap<ShopSupplier[]>(res) ?? [];
  },

  async createSupplier(body: ShopSupplierInput): Promise<ShopSupplier> {
    return unwrap<ShopSupplier>(await apiClient.post(`${BASE}/suppliers`, body, JSON_BODY));
  },

  async updateSupplier(uuid: string, body: ShopSupplierInput): Promise<ShopSupplier> {
    return unwrap<ShopSupplier>(await apiClient.put(`${BASE}/suppliers/${uuid}`, body, JSON_BODY));
  },

  /** POs raised with this supplier. meta.available false: purchase orders aren't deployed here. */
  async getSupplierPurchaseOrders(uuid: string, params: { limit?: number; offset?: number } = {}): Promise<ShopList<ShopSupplierPurchaseOrder>> {
    const qs = buildQueryString({ limit: params.limit, offset: params.offset });
    return unwrapList<ShopSupplierPurchaseOrder>(await apiClient.get(`${BASE}/suppliers/${uuid}/purchase-orders${qs}`), params.limit, params.offset);
  },

  async deleteSupplier(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/suppliers/${uuid}`);
  },

  async syncSupplier(uuid: string): Promise<ShopSupplierSummary> {
    return unwrap<ShopSupplierSummary>(await apiClient.post(`${BASE}/suppliers/${uuid}/sync`, {}, { ...JSON_BODY, timeout: 300000 }));
  },

  /** Upload a price file (sent as the raw body). */
  async importSupplierFile(uuid: string, file: File): Promise<ShopSupplierSummary> {
    const res = await apiClient.post(`${BASE}/suppliers/${uuid}/import`, await file.text(), {
      headers: { 'Content-Type': file.type || 'text/plain' },
      timeout: 300000,
    });
    return unwrap<ShopSupplierSummary>(res);
  },

  async getSupplierItems(
    uuid: string,
    params: ShopPageParams & { q?: string; linked?: 'true' | 'false' | ''; changed?: boolean } = {}
  ): Promise<ShopList<ShopSupplierItem>> {
    const qs = buildQueryString({ q: params.q, linked: params.linked || undefined, changed: params.changed ? 'true' : undefined, limit: params.limit, offset: params.offset });
    return unwrapList<ShopSupplierItem>(await apiClient.get(`${BASE}/suppliers/${uuid}/items${qs}`), params.limit, params.offset);
  },

  async linkSupplierItem(itemUuid: string, body: { product_uuid: string | null; pricing_source?: 'supplier' | 'manual'; margin_pct?: number | null }) {
    return unwrap<{ linked: boolean; pricing?: { applied: number; pending: number; unchanged: number } }>(
      await apiClient.post(`${BASE}/supplier-items/${itemUuid}/link`, body, JSON_BODY)
    );
  },

  async getPriceChanges(params: ShopPageParams & { status?: ShopPriceChangeStatus | '' } = {}): Promise<ShopList<ShopPriceChange>> {
    const qs = buildQueryString({ status: params.status || undefined, limit: params.limit, offset: params.offset });
    return unwrapList<ShopPriceChange>(await apiClient.get(`${BASE}/price-changes${qs}`), params.limit, params.offset);
  },

  async decidePriceChange(uuid: string, approve: boolean): Promise<ShopPriceChange> {
    return unwrap<ShopPriceChange>(await apiClient.post(`${BASE}/price-changes/${uuid}/${approve ? 'approve' : 'reject'}`, {}, JSON_BODY));
  },

  /** Products/options priced below cost, products with no known cost, and (optionally) open quotes below cost. */
  async getBelowCostReport(includeQuotes = false): Promise<ShopBelowCostReport> {
    const qs = buildQueryString({ include_quotes: includeQuotes ? 'true' : undefined });
    return unwrap<ShopBelowCostReport>(await apiClient.get(`${BASE}/pricing/below-cost${qs}`));
  },

  // ---------------- Credits (loyalty) ----------------
  async getCredits(params: ShopPageParams & { q?: string; status?: ShopCreditStatus | '' } = {}): Promise<ShopList<ShopCredit>> {
    const qs = buildQueryString({ q: params.q, status: params.status, limit: params.limit, offset: params.offset });
    const res = await apiClient.get(`${BASE}/credits${qs}`);
    return unwrapList<ShopCredit>(res, params.limit, params.offset);
  },

  async grantCredit(body: ShopCreditGrant): Promise<ShopCredit> {
    const res = await apiClient.post(`${BASE}/credits`, body, JSON_BODY);
    return unwrap<ShopCredit>(res);
  },

  async voidCredit(uuid: string, reason?: string): Promise<ShopCredit> {
    const res = await apiClient.post(`${BASE}/credits/${uuid}/void`, { reason }, JSON_BODY);
    return unwrap<ShopCredit>(res);
  },

  async getChats(params: ShopPageParams & { q?: string } = {}): Promise<ShopList<ShopChatSession>> {
    const qs = buildQueryString({ q: params.q, limit: params.limit, offset: params.offset });
    const res = await apiClient.get(`${BASE}/chats${qs}`);
    return unwrapList<ShopChatSession>(res, params.limit, params.offset);
  },

  async getChat(uuid: string): Promise<ShopChatSession> {
    const res = await apiClient.get(`${BASE}/chats/${uuid}`);
    return unwrap<ShopChatSession>(res);
  },

  // ---------------- Knowledge ----------------
  /** One row per source document (chunks aggregated server-side). */
  async getKnowledge(params: { source_type?: ShopKnowledgeSourceType | ''; q?: string; limit?: number; offset?: number } = {}): Promise<ShopList<ShopKnowledgeDoc>> {
    const qs = buildQueryString({ source_type: params.source_type, q: params.q, limit: params.limit, offset: params.offset });
    const res = await apiClient.get(`${BASE}/knowledge${qs}`);
    return unwrapList<ShopKnowledgeDoc>(res, params.limit, params.offset);
  },

  async addKnowledge(body: ShopKnowledgeInput): Promise<unknown> {
    const res = await apiClient.post(`${BASE}/knowledge`, body, JSON_BODY);
    return unwrap<unknown>(res);
  },

  /** source_type scopes the delete (product uuids and FAQ slugs live in one table). */
  async deleteKnowledge(sourceRef: string, sourceType?: ShopKnowledgeSourceType): Promise<void> {
    await apiClient.delete(`${BASE}/knowledge/${encodeURIComponent(sourceRef)}${buildQueryString({ source_type: sourceType })}`);
  },

  async reindexKnowledge(sources: ('products' | 'cms_posts')[]): Promise<ShopReindexResult> {
    const res = await apiClient.post(`${BASE}/knowledge/reindex`, { sources }, JSON_BODY);
    return unwrap<ShopReindexResult>(res) ?? {};
  },

  // ---------------- Market prices (MARKET.prompt.md §A) ----------------
  async getMarketOverview(params: ShopMarketOverviewParams = {}): Promise<ShopMarketOverviewRow[]> {
    const qs = buildQueryString({
      stale: params.stale === undefined ? undefined : params.stale ? 1 : 0,
      diff_gt: params.diff_gt,
      q: params.q,
      anomalies: params.anomalies ? 1 : undefined,
    });
    const res = await apiClient.get(`${BASE}/market/overview${qs}`);
    return unwrapList<ShopMarketOverviewRow>(res).data;
  },

  async getMarketProduct(uuid: string, history = 100): Promise<ShopMarketProductDetail> {
    const res = await apiClient.get(`${BASE}/market/products/${uuid}${buildQueryString({ history })}`);
    return unwrap<ShopMarketProductDetail>(res);
  },

  async getMarketSources(params: { product_uuid?: string; active?: boolean } = {}): Promise<ShopMarketSource[]> {
    const qs = buildQueryString({
      product_uuid: params.product_uuid,
      active: params.active === undefined ? undefined : params.active ? 1 : 0,
    });
    const res = await apiClient.get(`${BASE}/market/sources${qs}`);
    return unwrapList<ShopMarketSource>(res).data;
  },

  async createMarketSource(input: ShopMarketSourceInput): Promise<ShopMarketSource> {
    const res = await apiClient.post(`${BASE}/market/sources`, input, JSON_BODY);
    return unwrap<ShopMarketSource>(res);
  },

  async updateMarketSource(uuid: string, input: Partial<ShopMarketSourceInput>): Promise<ShopMarketSource> {
    const res = await apiClient.put(`${BASE}/market/sources/${uuid}`, input, JSON_BODY);
    return unwrap<ShopMarketSource>(res);
  },

  async deleteMarketSource(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/market/sources/${uuid}`);
  },

  async upsertMarketSources(sources: ShopMarketSourceInput[]): Promise<ShopMarketUpsertResult> {
    const res = await apiClient.post(`${BASE}/market/sources/upsert`, { sources }, JSON_BODY);
    return unwrap<ShopMarketUpsertResult>(res);
  },

  /** Accept an anomalous observation (> 40 % change) so it counts in summaries. */
  async acceptMarketObservation(uuid: string): Promise<ShopMarketObservation> {
    const res = await apiClient.post(`${BASE}/market/observations/${uuid}/accept`, {}, JSON_BODY);
    return unwrap<ShopMarketObservation>(res);
  },

  /** Sets base_price_minor (ex VAT) and price_verified=true. Nothing changes prices automatically. */
  async applyMarketPrice(uuid: string, strategy: ShopMarketApplyStrategy, valueMinor?: number): Promise<ShopMarketApplyResult> {
    const body = strategy === 'value' ? { strategy, value_minor: valueMinor } : { strategy };
    const res = await apiClient.post(`${BASE}/market/products/${uuid}/apply-price`, body, JSON_BODY);
    return unwrap<ShopMarketApplyResult>(res);
  },
};

export default shopService;
