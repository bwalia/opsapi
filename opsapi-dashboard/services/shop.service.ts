/**
 * Workstation AI Shop — admin API client.
 *
 * Base `/api/v2/shop/admin` (JWT + namespace headers added by api-client).
 * Envelope `{ success, data, meta? }`; lists return `{ data: [...], meta: { total, limit, offset } }`.
 * Bodies are JSON (the shop routes parse JSON, not form-encoded).
 * Contract: workstation-website/shop/BUILD.prompt.md §5.
 */
import apiClient, { buildQueryString } from '@/lib/api-client';
import type {
  ShopCategory,
  ShopCategoryInput,
  ShopChatSession,
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
  ShopOrder,
  ShopOrderStatus,
  ShopOrderUpdate,
  ShopProduct,
  ShopProductInput,
  ShopProductListItem,
  ShopProductListParams,
  ShopQuote,
  ShopQuoteCreate,
  ShopQuoteStatus,
  ShopQuoteUpdate,
  ShopReconcileResult,
  ShopReindexResult,
  ShopStockAdjust,
  ShopStockMovement,
  ShopStockRow,
} from '@/types/shop';

const BASE = '/api/v2/shop/admin';
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
  limit?: number;
  offset?: number;
}

export interface ShopQuoteListParams {
  status?: ShopQuoteStatus | '';
  q?: string;
  limit?: number;
  offset?: number;
}

export interface ShopPageParams {
  limit?: number;
  offset?: number;
}

export const shopService = {
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
  async getOrders(params: ShopOrderListParams = {}): Promise<ShopList<ShopOrder>> {
    const qs = buildQueryString({ status: params.status, q: params.q, limit: params.limit, offset: params.offset });
    const res = await apiClient.get(`${BASE}/orders${qs}`);
    return unwrapList<ShopOrder>(res, params.limit, params.offset);
  },

  async getOrder(uuid: string): Promise<ShopOrder> {
    const res = await apiClient.get(`${BASE}/orders/${uuid}`);
    return unwrap<ShopOrder>(res);
  },

  async updateOrder(uuid: string, body: ShopOrderUpdate): Promise<ShopOrder> {
    const res = await apiClient.put(`${BASE}/orders/${uuid}`, body, JSON_BODY);
    return unwrap<ShopOrder>(res);
  },

  // ---------------- Quotes ----------------
  async getQuotes(params: ShopQuoteListParams = {}): Promise<ShopList<ShopQuote>> {
    const qs = buildQueryString({ status: params.status, q: params.q, limit: params.limit, offset: params.offset });
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

  // ---------------- Chats ----------------
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
