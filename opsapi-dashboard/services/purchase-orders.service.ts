import apiClient from '@/lib/api-client';

// Purchase order lifecycle. Transitions are enforced by the backend
// (queries/PurchaseOrderQueries.lua); the UI only offers the valid next steps.
export type PurchaseOrderStatus =
  | 'draft'
  | 'sent'
  | 'acknowledged'
  | 'partially_received'
  | 'received'
  | 'billed'
  | 'cancelled';

export const PURCHASE_ORDER_STATUSES: { value: PurchaseOrderStatus; label: string }[] = [
  { value: 'draft', label: 'Draft' },
  { value: 'sent', label: 'Sent' },
  { value: 'acknowledged', label: 'Acknowledged' },
  { value: 'partially_received', label: 'Partially Received' },
  { value: 'received', label: 'Received' },
  { value: 'billed', label: 'Billed' },
  { value: 'cancelled', label: 'Cancelled' },
];

export interface PurchaseOrderFilters {
  page?: number;
  perPage?: number;
  status?: PurchaseOrderStatus | 'all';
  search?: string;
  supplier?: string;
  projectUuid?: string;
  dateFrom?: string;
  dateTo?: string;
  orderBy?: 'created_at' | 'issue_date' | 'expected_date' | 'po_number' | 'total' | 'supplier_name' | 'status';
  orderDir?: 'asc' | 'desc';
}

export interface PurchaseOrderItem {
  uuid: string;
  description: string;
  quantity: number;
  unit_price: number;
  tax_rate: number;
  tax_amount: number;
  line_total: number;
  received_quantity: number;
  /** Quantity / pennies already on (non-voided) bills. */
  billed_quantity: number;
  billed_net: number;
  billed_tax: number;
  sort_order?: number;
  created_at?: string;
  updated_at?: string;
}

export interface PurchaseOrderReceipt {
  at: string;
  by?: string;
  note?: string;
  /** quantity = received in this receipt; received_quantity = the line's running total after it. */
  lines: { item_uuid: string; quantity?: number; received_quantity?: number }[];
}

export interface PurchaseOrderBillLine {
  item_uuid: string;
  quantity: number;
  net: number;
  tax: number;
}

export interface PurchaseOrderBill {
  uuid: string;
  at?: string;
  net: number;
  tax: number;
  gross: number;
  currency?: string;
  bill_date?: string;
  category?: string;
  notes?: string;
  /** Pending expense in the purchase ledger (Bookkeeping on, GBP orders). */
  expense_uuid?: string | null;
  /** Why nothing was posted to the ledger (e.g. a non-GBP order). */
  ledger_note?: string;
  lines: PurchaseOrderBillLine[];
  voided_at?: string;
  void_reason?: string;
}

export interface PurchaseOrderClosure {
  at?: string;
  reason?: string;
  short?: { item_uuid: string; ordered: number; received: number }[];
}

export interface PurchaseOrderMetadata {
  receipts: PurchaseOrderReceipt[];
  bills: PurchaseOrderBill[];
  /** Set when the order was closed short. */
  closed?: PurchaseOrderClosure;
  cancelled_reason?: string;
  [key: string]: unknown;
}

export interface PurchaseOrderProjectLink {
  uuid: string;
  name: string;
  status?: string;
}

export interface PurchaseOrder {
  uuid: string;
  po_number: string;
  status: PurchaseOrderStatus;
  supplier_name: string;
  supplier_email?: string | null;
  supplier_phone?: string | null;
  supplier_address?: string | null;
  supplier_company_uuid?: string | null;
  reference?: string | null;
  issue_date: string;
  expected_date?: string | null;
  delivery_address?: string | null;
  currency: string;
  notes?: string | null;
  terms?: string | null;
  subtotal: number;
  tax_total: number;
  total: number;
  project_uuid?: string | null;
  project?: PurchaseOrderProjectLink | null;
  metadata: PurchaseOrderMetadata;
  created_by_uuid?: string | null;
  item_count?: number;
  items: PurchaseOrderItem[];
  sent_at?: string | null;
  acknowledged_at?: string | null;
  received_at?: string | null;
  billed_at?: string | null;
  cancelled_at?: string | null;
  created_at: string;
  updated_at: string;
  // Set on the convert-to-bill response: the bill just made, and whether a
  // purchase-ledger expense was created for it.
  bill?: PurchaseOrderBill;
  accounting_expense_created?: boolean;
}

export interface PurchaseOrdersResponse {
  data: PurchaseOrder[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
}

/** Money is never added across currencies: values come per currency. */
export interface PurchaseOrderCurrencyStats {
  currency: string;
  total_count: number;
  total_value: number;
  open_count: number;
  open_value: number;
  to_bill_count: number;
  to_bill_value: number;
  billed_value: number;
}

export interface PurchaseOrderStats {
  total_count: number;
  draft_count: number;
  open_count: number;
  overdue_count: number;
  to_bill_count: number;
  by_currency: PurchaseOrderCurrencyStats[];
  by_status: { status: PurchaseOrderStatus; count: number }[];
}

export interface PurchaseOrderItemPayload {
  description: string;
  quantity: number;
  unit_price: number;
  tax_rate?: number;
}

export interface PurchaseOrderPayload {
  supplier_name: string;
  supplier_email?: string;
  supplier_phone?: string;
  supplier_address?: string;
  supplier_company_uuid?: string;
  reference?: string;
  issue_date?: string;
  expected_date?: string;
  delivery_address?: string;
  currency?: string;
  notes?: string;
  terms?: string;
  project_uuid?: string;
  items?: PurchaseOrderItemPayload[];
}

/** quantity = what arrived now (added to the line; never above what is outstanding). */
export interface ReceiveLinePayload {
  item_uuid: string;
  quantity: number;
}

export interface ConvertToBillPayload {
  bill_date?: string;
  category?: string;
  notes?: string;
}

// The backend speaks JSON for this module (receive/items carry nested arrays).
const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

const num = (v: unknown) => Number(v ?? 0) || 0;

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
/** Objects of an array; anything else (old or malformed metadata) -> []. */
const objects = (v: unknown) => (Array.isArray(v) ? v.filter(isObj) : []);

// Decimal columns arrive as strings/numbers; metadata `{}` may arrive as `[]`.
function normalizeItem(raw: Record<string, unknown>): PurchaseOrderItem {
  return {
    ...(raw as unknown as PurchaseOrderItem),
    uuid: (raw.uuid ?? raw.id) as string,
    quantity: num(raw.quantity),
    unit_price: num(raw.unit_price),
    tax_rate: num(raw.tax_rate),
    tax_amount: num(raw.tax_amount),
    line_total: num(raw.line_total),
    received_quantity: num(raw.received_quantity),
    billed_quantity: num(raw.billed_quantity),
    billed_net: num(raw.billed_net),
    billed_tax: num(raw.billed_tax),
  };
}

function normalizeBill(b: Record<string, unknown>): PurchaseOrderBill {
  return {
    ...(b as unknown as PurchaseOrderBill),
    uuid: String(b.uuid ?? ''),
    net: num(b.net),
    tax: num(b.tax),
    gross: num(b.gross),
    lines: objects(b.lines).map((l) => ({
      item_uuid: String(l.item_uuid ?? ''),
      quantity: num(l.quantity),
      net: num(l.net),
      tax: num(l.tax),
    })),
  };
}

function normalizeMetadata(raw: unknown): PurchaseOrderMetadata {
  const m = isObj(raw) ? raw : {};
  return {
    ...m,
    receipts: objects(m.receipts).map((r) => ({
      ...(r as unknown as PurchaseOrderReceipt),
      lines: objects(r.lines) as PurchaseOrderReceipt['lines'],
    })),
    bills: objects(m.bills).map(normalizeBill),
    closed: isObj(m.closed) ? (m.closed as PurchaseOrderClosure) : undefined,
  };
}

function normalizePurchaseOrder(raw: Record<string, unknown> | null | undefined): PurchaseOrder {
  const r = (raw ?? {}) as Record<string, unknown>;
  return {
    ...(r as unknown as PurchaseOrder),
    uuid: (r.uuid ?? r.id) as string,
    subtotal: num(r.subtotal),
    tax_total: num(r.tax_total),
    total: num(r.total),
    item_count: r.item_count != null ? num(r.item_count) : undefined,
    metadata: normalizeMetadata(r.metadata),
    bill: isObj(r.bill) ? normalizeBill(r.bill) : undefined,
    project: (r.project as PurchaseOrderProjectLink | undefined) ?? null,
    items: Array.isArray(r.items) ? (r.items as Record<string, unknown>[]).map(normalizeItem) : [],
  };
}

// Idempotency-Key per attempt: a retry of the same request whose answer never
// arrived (network error) reuses it, so the server replays instead of doing it
// twice. Any answer from the server ends the attempt.
const pendingKeys = new Map<string, { body: string; key: string }>();
async function idempotent<T>(scope: string, body: unknown, send: (config: object) => Promise<T>): Promise<T> {
  const sig = JSON.stringify(body ?? null);
  const prev = pendingKeys.get(scope);
  const key = prev && prev.body === sig ? prev.key : crypto.randomUUID();
  pendingKeys.set(scope, { body: sig, key });
  try {
    const result = await send({ headers: { ...JSON_HEADERS.headers, 'Idempotency-Key': key } });
    pendingKeys.delete(scope);
    return result;
  } catch (error) {
    if ((error as { response?: unknown })?.response) pendingKeys.delete(scope);
    throw error;
  }
}

const unwrap = (body: { data?: unknown } | undefined) =>
  (body?.data ?? body) as Record<string, unknown>;

export const purchaseOrdersService = {
  async getPurchaseOrders(params: PurchaseOrderFilters = {}): Promise<PurchaseOrdersResponse> {
    const q: Record<string, string | number> = {};
    if (params.page) q.page = params.page;
    if (params.perPage) q.perPage = params.perPage;
    if (params.status && params.status !== 'all') q.status = params.status;
    if (params.search) q.search = params.search;
    if (params.supplier) q.supplier = params.supplier;
    if (params.projectUuid) q.project_uuid = params.projectUuid;
    if (params.dateFrom) q.from_date = params.dateFrom;
    if (params.dateTo) q.to_date = params.dateTo;
    if (params.orderBy) q.order_by = params.orderBy;
    if (params.orderDir) q.order_dir = params.orderDir;

    const response = await apiClient.get('/api/v2/purchase-orders', { params: q });
    const body = response.data ?? {};
    const list = Array.isArray(body.data) ? body.data : [];
    const meta = body.meta ?? {};
    return {
      data: list.map(normalizePurchaseOrder),
      total: meta.total ?? list.length,
      page: meta.page ?? params.page ?? 1,
      per_page: meta.perPage ?? params.perPage ?? 20,
      total_pages: meta.totalPages ?? 1,
    };
  },

  async getStats(): Promise<PurchaseOrderStats> {
    const response = await apiClient.get('/api/v2/purchase-orders/stats');
    const r = unwrap(response.data);
    return {
      total_count: num(r.total_count),
      draft_count: num(r.draft_count),
      open_count: num(r.open_count),
      overdue_count: num(r.overdue_count),
      to_bill_count: num(r.to_bill_count),
      by_currency: objects(r.by_currency).map((c) => ({
        currency: String(c.currency || 'GBP'),
        total_count: num(c.total_count),
        total_value: num(c.total_value),
        open_count: num(c.open_count),
        open_value: num(c.open_value),
        to_bill_count: num(c.to_bill_count),
        to_bill_value: num(c.to_bill_value),
        billed_value: num(c.billed_value),
      })),
      by_status: objects(r.by_status).map((s) => ({ status: s.status as PurchaseOrderStatus, count: num(s.count) })),
    };
  },

  async getPurchaseOrder(uuid: string): Promise<PurchaseOrder> {
    const response = await apiClient.get(`/api/v2/purchase-orders/${uuid}`);
    return normalizePurchaseOrder(unwrap(response.data));
  },

  async createPurchaseOrder(data: PurchaseOrderPayload): Promise<PurchaseOrder> {
    const response = await idempotent('create', data, (config) =>
      apiClient.post('/api/v2/purchase-orders', data, config)
    );
    return normalizePurchaseOrder(unwrap(response.data));
  },

  async updatePurchaseOrder(uuid: string, data: Partial<PurchaseOrderPayload>): Promise<PurchaseOrder> {
    const response = await apiClient.put(`/api/v2/purchase-orders/${uuid}`, data, JSON_HEADERS);
    return normalizePurchaseOrder(unwrap(response.data));
  },

  async deletePurchaseOrder(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/purchase-orders/${uuid}`);
  },

  /** draft -> sent without emailing. */
  async markSent(uuid: string): Promise<PurchaseOrder> {
    const response = await apiClient.post(`/api/v2/purchase-orders/${uuid}/send`, {}, JSON_HEADERS);
    return normalizePurchaseOrder(unwrap(response.data));
  },

  /**
   * Email the PO (browser-built PDF as base64) to the supplier; marks a draft sent.
   * `message` says what happened: queued for sending, or handed to the workspace's mail server.
   */
  async emailPurchaseOrder(
    uuid: string,
    data: { pdf_base64?: string; filename?: string; to?: string; message?: string }
  ): Promise<{ message: string; to: string; status: PurchaseOrderStatus; via: 'workspace' | 'platform' }> {
    const response = await idempotent(`email:${uuid}`, data, (config) =>
      apiClient.post(`/api/v2/purchase-orders/${uuid}/email`, data, config)
    );
    return unwrap(response.data) as unknown as {
      message: string;
      to: string;
      status: PurchaseOrderStatus;
      via: 'workspace' | 'platform';
    };
  },

  async acknowledge(uuid: string): Promise<PurchaseOrder> {
    const response = await apiClient.post(`/api/v2/purchase-orders/${uuid}/acknowledge`, {}, JSON_HEADERS);
    return normalizePurchaseOrder(unwrap(response.data));
  },

  /** items[].quantity is what arrived now; receive_all takes in everything outstanding. */
  async receive(
    uuid: string,
    data: { items?: ReceiveLinePayload[]; receive_all?: boolean; note?: string }
  ): Promise<PurchaseOrder> {
    const response = await idempotent(`receive:${uuid}`, data, (config) =>
      apiClient.post(`/api/v2/purchase-orders/${uuid}/receive`, data, config)
    );
    return normalizePurchaseOrder(unwrap(response.data));
  },

  /** Bills what has been received and not billed yet (can be done again as more arrives). */
  async convertToBill(uuid: string, data: ConvertToBillPayload = {}): Promise<PurchaseOrder> {
    const response = await idempotent(`bill:${uuid}`, data, (config) =>
      apiClient.post(`/api/v2/purchase-orders/${uuid}/convert-to-bill`, data, config)
    );
    return normalizePurchaseOrder(unwrap(response.data));
  },

  /** Void a bill whose ledger expense is still pending; its quantities can be billed again. */
  async voidBill(uuid: string, billUuid: string, reason?: string): Promise<PurchaseOrder> {
    const response = await apiClient.post(
      `/api/v2/purchase-orders/${uuid}/bills/${billUuid}/void`,
      { reason },
      JSON_HEADERS
    );
    return normalizePurchaseOrder(unwrap(response.data));
  },

  /** Close a partially received PO short: no more goods are coming. */
  async closeShort(uuid: string, reason: string): Promise<PurchaseOrder> {
    const response = await apiClient.post(`/api/v2/purchase-orders/${uuid}/close`, { reason }, JSON_HEADERS);
    return normalizePurchaseOrder(unwrap(response.data));
  },

  async cancel(uuid: string, reason?: string): Promise<PurchaseOrder> {
    const response = await apiClient.post(`/api/v2/purchase-orders/${uuid}/cancel`, { reason }, JSON_HEADERS);
    return normalizePurchaseOrder(unwrap(response.data));
  },

  async addItem(uuid: string, data: PurchaseOrderItemPayload): Promise<PurchaseOrderItem> {
    const response = await apiClient.post(`/api/v2/purchase-orders/${uuid}/items`, data, JSON_HEADERS);
    return normalizeItem(unwrap(response.data));
  },

  async updateItem(itemUuid: string, data: Partial<PurchaseOrderItemPayload>): Promise<PurchaseOrderItem> {
    const response = await apiClient.put(`/api/v2/purchase-orders/items/${itemUuid}`, data, JSON_HEADERS);
    return normalizeItem(unwrap(response.data));
  },

  async deleteItem(itemUuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/purchase-orders/items/${itemUuid}`);
  },
};

/** Pull the backend's message out of an axios error: `{ error: "..." }` or `{ error: { message } }`. */
export function purchaseOrderError(error: unknown, fallback: string): string {
  const err = (error as { response?: { data?: { error?: unknown } } })?.response?.data?.error;
  const msg = isObj(err) ? err.message : err;
  return typeof msg === 'string' && msg ? msg : fallback;
}

export default purchaseOrdersService;
