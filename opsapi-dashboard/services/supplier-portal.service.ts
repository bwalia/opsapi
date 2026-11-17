/**
 * Supplier portal API client.
 *
 * Supplier side: /api/v2/supplier-portal (a supplier login's JWT; their own supplier's POs only).
 * Staff side:    /api/v2/purchase-orders/:uuid/portal...            (the PO page's supplier panel)
 *                /api/v2/shop/admin/suppliers/:uuid/portal-users... (Shop → Suppliers: portal logins)
 * Contract: lapis/routes/supplier-portal.lua (header) and lapis/queries/SupplierPortalQueries.lua (shapes).
 *
 * Envelope `{ success, data, meta? }`; errors `{ success: false, error, code }`.
 * Money is decimal text ("5256.65"). Uploads are multipart with field `file` (PDF/PNG/JPG ≤ 20 MB).
 * Writes never go to the offline outbox: payments and documents must not replay later behind anyone's back.
 */
import apiClient, { buildQueryString } from '@/lib/api-client';

const SP = '/api/v2/supplier-portal';
const PO = (uuid: string) => `/api/v2/purchase-orders/${encodeURIComponent(uuid)}/portal`;
const SUP = (uuid: string) => `/api/v2/shop/admin/suppliers/${encodeURIComponent(uuid)}/portal-users`;

const JSON_WRITE = { headers: { 'Content-Type': 'application/json' }, _noOutbox: true } as const;
const UPLOAD = { _noOutbox: true, timeout: 120000 } as const;

const API_BASE_URL = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';

// ---------------------------------------------------------------------------
// labels (mirror lapis/lib/supplier-portal.lua)
// ---------------------------------------------------------------------------

export type PortalStage =
  | 'draft'
  | 'sent'
  | 'acknowledged'
  | 'proforma_received'
  | 'part_paid'
  | 'paid'
  | 'dispatched'
  | 'delivered'
  | 'invoiced'
  | 'closed'
  | 'cancelled';

/** The order of the progress steps (cancelled is shown on its own). */
export const PORTAL_STAGES: PortalStage[] = [
  'sent',
  'acknowledged',
  'proforma_received',
  'part_paid',
  'paid',
  'dispatched',
  'delivered',
  'invoiced',
  'closed',
];

export const STAGE_LABELS: Record<PortalStage, string> = {
  draft: 'Draft',
  sent: 'Sent to supplier',
  acknowledged: 'Acknowledged',
  proforma_received: 'Proforma received',
  part_paid: 'Part paid',
  paid: 'Paid',
  dispatched: 'Dispatched',
  delivered: 'Delivered',
  invoiced: 'Final invoice received',
  closed: 'Closed',
  cancelled: 'Cancelled',
};

export const stageLabel = (s: string | null | undefined): string =>
  (s && STAGE_LABELS[s as PortalStage]) || (s ? s.replace(/_/g, ' ') : '');

export type PortalDocType =
  | 'purchase_order'
  | 'proforma'
  | 'payment_proof'
  | 'vat_invoice'
  | 'delivery_note'
  | 'proof_of_delivery'
  | 'credit_note'
  | 'other';

export const DOC_TYPE_LABELS: Record<PortalDocType, string> = {
  purchase_order: 'Our purchase order',
  proforma: 'Proforma invoice',
  payment_proof: 'Payment proof',
  vat_invoice: 'Final VAT invoice',
  delivery_note: 'Delivery note',
  proof_of_delivery: 'Proof of delivery',
  credit_note: 'Credit note',
  other: 'Other',
};

/** What a supplier may upload (our PO and our payment proofs only come from staff). */
export const SUPPLIER_DOC_TYPES: PortalDocType[] = [
  'proforma',
  'vat_invoice',
  'credit_note',
  'delivery_note',
  'proof_of_delivery',
  'other',
];

export const STAFF_DOC_TYPES: PortalDocType[] = [
  'purchase_order',
  'proforma',
  'vat_invoice',
  'credit_note',
  'payment_proof',
  'delivery_note',
  'proof_of_delivery',
  'other',
];

/** Document types that are also a proforma / invoice / credit note record (need the invoice fields). */
export const DOC_INVOICE_KIND: Partial<Record<PortalDocType, InvoiceKind>> = {
  proforma: 'proforma',
  vat_invoice: 'invoice',
  credit_note: 'credit_note',
};

export type InvoiceKind = 'proforma' | 'invoice' | 'credit_note';

export const INVOICE_KIND_LABELS: Record<InvoiceKind, string> = {
  proforma: 'Proforma invoice',
  invoice: 'Final VAT invoice',
  credit_note: 'Credit note',
};

export type PaymentMethod = 'faster_payment' | 'bacs' | 'chaps' | 'card' | 'other';

export const PAYMENT_METHOD_LABELS: Record<PaymentMethod, string> = {
  faster_payment: 'Faster Payment',
  bacs: 'BACS',
  chaps: 'CHAPS',
  card: 'Card',
  other: 'Other',
};

export type BalanceState = 'nothing_due' | 'unpaid' | 'part_paid' | 'paid' | 'overpaid';

export const BALANCE_STATE_LABELS: Record<BalanceState, string> = {
  nothing_due: 'Nothing due',
  unpaid: 'Not paid yet',
  part_paid: 'Part paid',
  paid: 'Paid in full',
  overpaid: 'Overpaid',
};

export const BALANCE_BASIS_LABELS: Record<string, string> = {
  invoice: 'the final invoice',
  proforma: 'the latest proforma',
  purchase_order: 'the purchase order',
};

// ---------------------------------------------------------------------------
// shapes
// ---------------------------------------------------------------------------

/** Decimal text from the API ("5256.65"); some columns may arrive as numbers. */
export type Money = string | number;

export interface PortalBalance {
  state: BalanceState;
  basis: 'invoice' | 'proforma' | 'purchase_order';
  due: string;
  paid: string;
  balance: string;
  currency: string;
}

export interface PortalDocument {
  id: string;
  doc_type: PortalDocType;
  label: string;
  filename: string;
  content_type: string;
  size: number | null;
  created_at: string;
  uploaded_by_kind: 'staff' | 'supplier';
  uploaded_by: string | null;
  note: string | null;
  po_id?: string;
  po_number?: string;
  // staff only
  visible_to_supplier?: boolean;
  scan_status?: string;
  sha256?: string;
  deleted_at?: string | null;
  delete_reason?: string | null;
}

export interface InvoiceFlag {
  code: string;
  message: string;
}

export interface PortalInvoice {
  id: string;
  kind: InvoiceKind;
  label: string;
  number: string;
  invoice_date: string;
  due_date: string | null;
  supplier_order_ref: string | null;
  net: Money;
  vat: Money;
  total: Money;
  currency: string;
  payment_terms: string | null;
  incoterm: string | null;
  bank_details: string | null;
  document_id: string | null;
  created_by_kind: 'staff' | 'supplier';
  created_at: string;
  // staff only
  note?: string | null;
  flags?: InvoiceFlag[];
  superseded?: boolean;
}

export interface PortalPayment {
  id: string;
  amount: Money;
  currency: string;
  method: PaymentMethod;
  method_label: string;
  sent_on: string;
  cleared_on: string | null;
  payment_reference: string | null;
  against: { id: string; number: string; kind: InvoiceKind } | null;
  proof_document_id: string | null;
  created_at: string;
  voided: boolean;
  po_id?: string;
  po_number?: string;
  // staff only
  bank_transaction_id?: string | null;
  note?: string | null;
  voided_at?: string | null;
  void_reason?: string | null;
}

export interface PortalShipment {
  id: string;
  carrier: string;
  tracking_number: string | null;
  tracking_url: string | null;
  dispatched_on: string;
  expected_on: string | null;
  delivered_on: string | null;
  received_by: string | null;
  note: string | null;
  delivery_note: string | null;
  created_by_kind: 'staff' | 'supplier';
  pod_document_id: string | null;
}

export interface PortalMessage {
  id: string;
  body: string;
  author_kind: 'staff' | 'supplier';
  author: string | null;
  created_at: string;
  po_id?: string;
  po_number?: string;
}

export interface PortalTimelineEntry {
  action: string;
  detail: Record<string, unknown>;
  at: string;
  by: string | null;
  /** supplier view: supplier | buyer; staff view: staff | supplier | system */
  by_kind: string;
}

export interface SupplierMe {
  user: { name: string; email: string };
  supplier: { id: string; name: string };
  buyer: { name: string };
  emails_enabled: boolean;
}

export interface SupplierPoListItem {
  id: string;
  po_number: string;
  stage: PortalStage;
  stage_label: string;
  issue_date: string;
  expected_date: string | null;
  currency: string;
  total: Money;
  reference: string | null;
  deal_code: string | null;
  balance: PortalBalance;
  updated_at: string;
}

export interface SupplierPoItem {
  description: string;
  quantity: Money;
  unit_price: Money;
  tax_rate: Money;
  tax_amount: Money;
  line_total: Money;
}

/** The PO as a supplier sees it (lib/supplier-portal.lua supplierPo): never our customer. */
export interface SupplierPurchaseOrder {
  id: string;
  po_number: string;
  stage: PortalStage;
  stage_label: string;
  issue_date: string;
  expected_date?: string | null;
  currency: string;
  subtotal: Money;
  tax_total: Money;
  total: Money;
  reference?: string | null;
  deal_code?: string | null;
  notes?: string | null;
  terms?: string | null;
  delivery_address?: string | null;
  delivery_method?: string | null;
  drop_ship: boolean;
  drop_ship_kind?: 'confirmed' | 'legacy' | null;
  end_customer_po?: string | null;
  supplier_account_number?: string | null;
  buyer: { name?: string | null; bill_to?: string | null };
  sent_at?: string | null;
  acknowledged_at?: string | null;
  items: SupplierPoItem[];
  redacted?: boolean;
}

export interface SupplierCan {
  acknowledge: boolean;
  upload: boolean;
  upload_proforma: boolean;
  dispatch: boolean;
  mark_delivered: boolean;
  upload_invoice: boolean;
  message: boolean;
}

export interface SupplierPoDetail {
  purchase_order: SupplierPurchaseOrder;
  balance: PortalBalance;
  documents: PortalDocument[];
  invoices: PortalInvoice[];
  payments: PortalPayment[];
  shipments: PortalShipment[];
  messages: PortalMessage[];
  timeline: PortalTimelineEntry[];
  can: SupplierCan;
}

export interface PortalUser {
  id: string;
  name: string | null;
  email: string;
  status: 'invited' | 'active' | 'disabled';
  invited_at?: string;
  activated_at: string | null;
  last_seen_at: string | null;
  disabled_at: string | null;
}

export interface StaffPanel {
  purchase_order: {
    id: string;
    po_number: string;
    status: string;
    stage: PortalStage;
    stage_label: string;
    portal_stage: string | null;
    total: Money;
    subtotal: Money;
    tax_total: Money;
    currency: string;
    supplier_name: string;
    deal_code: string | null;
    drop_ship: boolean;
    drop_ship_kind: string | null;
    closed_at: string | null;
  };
  stages: PortalStage[];
  next_stages: ('acknowledged' | 'cancelled' | 'closed')[];
  balance: PortalBalance;
  has_final_invoice: boolean;
  documents: PortalDocument[];
  invoices: PortalInvoice[];
  payments: PortalPayment[];
  shipments: PortalShipment[];
  messages: PortalMessage[];
  timeline: PortalTimelineEntry[];
  supplier: { id: string; name: string; portal_enabled: boolean; users: PortalUser[] } | null;
  portal: { enabled: boolean; emails_enabled: boolean; supplier_can_see: boolean; notice: string };
  /** Present after some writes: what was emailed (or not). */
  notification?: unknown;
}

export interface PortalUsersResult {
  supplier: { id: string; name: string; portal_enabled: boolean };
  users: PortalUser[];
  portal: { enabled: boolean; emails_enabled: boolean };
}

export interface InviteResult {
  user: { id: string; email: string; name: string | null; status: string };
  set_password_path: string | null;
  expires_in_days: number;
  emailed: boolean;
  message: string;
}

export interface NewLinkResult {
  set_password_path: string | null;
  expires_in_days: number;
  emailed: boolean;
}

export interface DownloadLink {
  path: string;
  expires_in: number;
  expires_at: string;
  filename?: string;
}

/** Proforma / final invoice / credit note details as typed. */
export interface InvoiceInput {
  number: string;
  invoice_date: string;
  net?: string;
  vat?: string;
  total: string;
  supplier_order_ref?: string;
  payment_terms?: string;
  incoterm?: string;
  due_date?: string;
  bank_details?: string;
  currency?: string;
  note?: string;
}

export interface DispatchInput {
  carrier: string;
  tracking_number?: string;
  tracking_url?: string;
  dispatched_on?: string;
  expected_on?: string;
  note?: string;
}

export interface DeliveredInput {
  delivered_on?: string;
  received_by?: string;
  note?: string;
  shipment_id?: string;
}

export interface PaymentInput {
  amount: string;
  method: PaymentMethod;
  sent_on: string;
  cleared_on?: string;
  bank_transaction_id?: string;
  payment_reference?: string;
  invoice_id?: string;
  proof_document_id?: string;
  note?: string;
}

export interface UploadInput {
  file: File;
  doc_type: PortalDocType;
  note?: string;
  invoice?: InvoiceInput;
  /** Staff only (default true). */
  visible_to_supplier?: boolean;
}

export interface SupplierUploadResult {
  document: { id: string; doc_type: PortalDocType; filename: string; size: number };
  invoice?: { id: string; kind: InvoiceKind; number: string; total: string };
  stage: PortalStage;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function unwrap<T>(response: { data?: unknown }): T {
  return (response.data as { data?: T } | undefined)?.data as T;
}

const arr = <T>(v: unknown): T[] => (Array.isArray(v) ? (v as T[]) : []);

/** Drop empty strings and undefined so optional fields are left out. */
function clean<T extends object>(o: T): Partial<T> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(o)) {
    if (v === undefined || v === null) continue;
    if (typeof v === 'string' && v.trim() === '') continue;
    out[k] = typeof v === 'string' ? v.trim() : v;
  }
  return out as Partial<T>;
}

function uploadForm(input: UploadInput): FormData {
  const fd = new FormData();
  fd.append('file', input.file, input.file.name);
  fd.append('doc_type', input.doc_type);
  if (input.note?.trim()) fd.append('note', input.note.trim());
  if (input.invoice) fd.append('invoice', JSON.stringify(clean(input.invoice)));
  if (input.visible_to_supplier !== undefined) fd.append('visible_to_supplier', String(input.visible_to_supplier));
  return fd;
}

function normalizeDetail(d: SupplierPoDetail): SupplierPoDetail {
  return {
    ...d,
    purchase_order: { ...d.purchase_order, items: arr(d.purchase_order?.items), buyer: d.purchase_order?.buyer ?? {} },
    documents: arr(d.documents),
    invoices: arr(d.invoices),
    payments: arr(d.payments),
    shipments: arr(d.shipments),
    messages: arr(d.messages),
    timeline: arr(d.timeline),
    can: d.can ?? {
      acknowledge: false,
      upload: false,
      upload_proforma: false,
      dispatch: false,
      mark_delivered: false,
      upload_invoice: false,
      message: false,
    },
  };
}

function normalizePanel(p: StaffPanel): StaffPanel {
  return {
    ...p,
    stages: arr(p.stages),
    next_stages: arr(p.next_stages),
    documents: arr(p.documents),
    invoices: arr<PortalInvoice>(p.invoices).map((i) => ({ ...i, flags: arr(i.flags) })),
    payments: arr(p.payments),
    shipments: arr(p.shipments),
    messages: arr(p.messages),
    timeline: arr(p.timeline),
    supplier: p.supplier ? { ...p.supplier, users: arr(p.supplier.users) } : null,
  };
}

/** The API error: `{ message, code, status }` from `{ success: false, error, code }`. */
export interface PortalError {
  message: string;
  code?: string;
  status?: number;
}

export function portalError(err: unknown, fallback: string): PortalError {
  const e = err as { response?: { status?: number; data?: { error?: unknown; code?: unknown } } };
  const data = e?.response?.data;
  const raw = data?.error;
  let message = fallback;
  let code: string | undefined = typeof data?.code === 'string' ? data.code : undefined;
  if (typeof raw === 'string' && raw) message = raw;
  else if (raw && typeof raw === 'object') {
    const o = raw as { message?: unknown; code?: unknown };
    if (typeof o.message === 'string' && o.message) message = o.message;
    if (!code && typeof o.code === 'string') code = o.code;
  }
  if (e?.response?.status === 413 && message === fallback) message = 'The file is too big: the limit is 20 MB.';
  return { message, code, status: e?.response?.status };
}

/** Open a signed download link (a plain GET answered with Content-Disposition: attachment). */
export function openDownload(link: DownloadLink): void {
  if (typeof window === 'undefined' || !link?.path) return;
  const url = /^https?:\/\//.test(link.path) ? link.path : `${API_BASE_URL}${link.path}`;
  const a = document.createElement('a');
  a.href = url;
  a.rel = 'noopener noreferrer';
  if (link.filename) a.download = link.filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
}

/** Accepted upload types and size (the server checks the bytes again). */
export const UPLOAD_ACCEPT = '.pdf,.png,.jpg,.jpeg,application/pdf,image/png,image/jpeg';
export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024;

export function checkUploadFile(file: File | null | undefined): string | null {
  if (!file) return 'Choose a file (PDF, PNG or JPG)';
  if (file.size > MAX_UPLOAD_BYTES) return 'The file is too big: the limit is 20 MB.';
  if (!/\.(pdf|png|jpe?g)$/i.test(file.name)) return 'Only PDF, PNG or JPG files can be uploaded.';
  return null;
}

// ---------------------------------------------------------------------------
// supplier
// ---------------------------------------------------------------------------

export const supplierPortalService = {
  async me(): Promise<SupplierMe> {
    return unwrap<SupplierMe>(await apiClient.get(`${SP}/me`));
  },

  async listPurchaseOrders(
    params: { stage?: 'open' | 'all' | PortalStage; search?: string; page?: number; perPage?: number } = {}
  ): Promise<{ data: SupplierPoListItem[]; total: number; page: number; perPage: number }> {
    const res = await apiClient.get(`${SP}/purchase-orders${buildQueryString(params)}`);
    const body = (res.data ?? {}) as { data?: unknown; meta?: { total?: number; page?: number; perPage?: number } };
    const data = arr<SupplierPoListItem>(body.data);
    return {
      data,
      total: Number(body.meta?.total ?? data.length),
      page: Number(body.meta?.page ?? params.page ?? 1),
      perPage: Number(body.meta?.perPage ?? params.perPage ?? 25),
    };
  },

  async getPurchaseOrder(uuid: string): Promise<SupplierPoDetail> {
    return normalizeDetail(unwrap<SupplierPoDetail>(await apiClient.get(`${SP}/purchase-orders/${encodeURIComponent(uuid)}`)));
  },

  /** Returns the refreshed PO. */
  async acknowledge(uuid: string, note?: string): Promise<SupplierPoDetail> {
    const res = await apiClient.post(`${SP}/purchase-orders/${encodeURIComponent(uuid)}/acknowledge`, clean({ note }), JSON_WRITE);
    return normalizeDetail(unwrap<SupplierPoDetail>(res));
  },

  async uploadDocument(uuid: string, input: UploadInput): Promise<SupplierUploadResult> {
    const res = await apiClient.post(`${SP}/purchase-orders/${encodeURIComponent(uuid)}/documents`, uploadForm(input), UPLOAD);
    return unwrap<SupplierUploadResult>(res);
  },

  async dispatch(uuid: string, input: DispatchInput): Promise<{ shipment: { id: string }; stage: PortalStage }> {
    const res = await apiClient.post(`${SP}/purchase-orders/${encodeURIComponent(uuid)}/dispatch`, clean(input), JSON_WRITE);
    return unwrap(res);
  },

  /** With a file: multipart (the proof of delivery). Without: JSON (a POD / delivery note is already uploaded). */
  async delivered(uuid: string, input: DeliveredInput, file?: File | null): Promise<{ stage: PortalStage }> {
    const url = `${SP}/purchase-orders/${encodeURIComponent(uuid)}/delivered`;
    if (file) {
      const fd = new FormData();
      fd.append('file', file, file.name);
      for (const [k, v] of Object.entries(clean(input))) fd.append(k, String(v));
      return unwrap(await apiClient.post(url, fd, UPLOAD));
    }
    return unwrap(await apiClient.post(url, clean(input), JSON_WRITE));
  },

  async postMessage(uuid: string, body: string): Promise<{ id: string }> {
    const res = await apiClient.post(`${SP}/purchase-orders/${encodeURIComponent(uuid)}/messages`, { body }, JSON_WRITE);
    return unwrap(res);
  },

  async documents(docType?: PortalDocType): Promise<PortalDocument[]> {
    return arr(unwrap(await apiClient.get(`${SP}/documents${buildQueryString({ doc_type: docType })}`)));
  },

  async documentLink(docUuid: string): Promise<DownloadLink> {
    return unwrap<DownloadLink>(await apiClient.post(`${SP}/documents/${encodeURIComponent(docUuid)}/link`, {}, JSON_WRITE));
  },

  async payments(): Promise<PortalPayment[]> {
    return arr(unwrap(await apiClient.get(`${SP}/payments`)));
  },

  async messages(): Promise<PortalMessage[]> {
    return arr(unwrap(await apiClient.get(`${SP}/messages`)));
  },
};

// ---------------------------------------------------------------------------
// staff: the PO page's supplier panel
// ---------------------------------------------------------------------------

export const purchaseOrderPortalService = {
  async getPanel(poUuid: string): Promise<StaffPanel> {
    return normalizePanel(unwrap<StaffPanel>(await apiClient.get(PO(poUuid))));
  },

  async link(poUuid: string, supplierId: string, confirm = false): Promise<StaffPanel> {
    const res = await apiClient.post(`${PO(poUuid)}/link`, { supplier_id: supplierId, confirm: confirm || undefined }, JSON_WRITE);
    return normalizePanel(unwrap<StaffPanel>(res));
  },

  async setStage(
    poUuid: string,
    body: { to: 'acknowledged' | 'cancelled' | 'closed'; reason?: string; force?: boolean }
  ): Promise<StaffPanel> {
    return normalizePanel(unwrap<StaffPanel>(await apiClient.post(`${PO(poUuid)}/stage`, clean(body), JSON_WRITE)));
  },

  async uploadDocument(poUuid: string, input: UploadInput): Promise<StaffPanel> {
    return normalizePanel(unwrap<StaffPanel>(await apiClient.post(`${PO(poUuid)}/documents`, uploadForm(input), UPLOAD)));
  },

  async documentLink(poUuid: string, docUuid: string): Promise<DownloadLink> {
    return unwrap<DownloadLink>(
      await apiClient.post(`${PO(poUuid)}/documents/${encodeURIComponent(docUuid)}/link`, {}, JSON_WRITE)
    );
  },

  async removeDocument(poUuid: string, docUuid: string, reason: string): Promise<StaffPanel> {
    const res = await apiClient.post(`${PO(poUuid)}/documents/${encodeURIComponent(docUuid)}/remove`, { reason }, JSON_WRITE);
    return normalizePanel(unwrap<StaffPanel>(res));
  },

  /** A proforma / final invoice / credit note that came by email (no file), or for a document already uploaded. */
  async recordInvoice(poUuid: string, body: InvoiceInput & { kind: InvoiceKind; document_id?: string }): Promise<StaffPanel> {
    return normalizePanel(unwrap<StaffPanel>(await apiClient.post(`${PO(poUuid)}/invoices`, clean(body), JSON_WRITE)));
  },

  async removeInvoice(poUuid: string, invUuid: string, reason: string): Promise<StaffPanel> {
    const res = await apiClient.post(`${PO(poUuid)}/invoices/${encodeURIComponent(invUuid)}/remove`, { reason }, JSON_WRITE);
    return normalizePanel(unwrap<StaffPanel>(res));
  },

  /** With a file (the bank's confirmation): multipart; otherwise JSON. */
  async recordPayment(poUuid: string, body: PaymentInput, proof?: File | null): Promise<StaffPanel> {
    const url = `${PO(poUuid)}/payments`;
    if (proof) {
      const fd = new FormData();
      fd.append('file', proof, proof.name);
      for (const [k, v] of Object.entries(clean(body))) fd.append(k, String(v));
      return normalizePanel(unwrap<StaffPanel>(await apiClient.post(url, fd, UPLOAD)));
    }
    return normalizePanel(unwrap<StaffPanel>(await apiClient.post(url, clean(body), JSON_WRITE)));
  },

  async updatePayment(
    poUuid: string,
    payUuid: string,
    body: { cleared_on?: string; bank_transaction_id?: string; payment_reference?: string; note?: string }
  ): Promise<StaffPanel> {
    const res = await apiClient.put(`${PO(poUuid)}/payments/${encodeURIComponent(payUuid)}`, clean(body), JSON_WRITE);
    return normalizePanel(unwrap<StaffPanel>(res));
  },

  async voidPayment(poUuid: string, payUuid: string, reason: string): Promise<StaffPanel> {
    const res = await apiClient.post(`${PO(poUuid)}/payments/${encodeURIComponent(payUuid)}/void`, { reason }, JSON_WRITE);
    return normalizePanel(unwrap<StaffPanel>(res));
  },

  async dispatch(poUuid: string, input: DispatchInput): Promise<StaffPanel> {
    return normalizePanel(unwrap<StaffPanel>(await apiClient.post(`${PO(poUuid)}/dispatch`, clean(input), JSON_WRITE)));
  },

  async delivered(poUuid: string, input: DeliveredInput, file?: File | null): Promise<StaffPanel> {
    const url = `${PO(poUuid)}/delivered`;
    if (file) {
      const fd = new FormData();
      fd.append('file', file, file.name);
      for (const [k, v] of Object.entries(clean(input))) fd.append(k, String(v));
      return normalizePanel(unwrap<StaffPanel>(await apiClient.post(url, fd, UPLOAD)));
    }
    return normalizePanel(unwrap<StaffPanel>(await apiClient.post(url, clean(input), JSON_WRITE)));
  },

  async postMessage(poUuid: string, body: string): Promise<StaffPanel> {
    return normalizePanel(unwrap<StaffPanel>(await apiClient.post(`${PO(poUuid)}/messages`, { body }, JSON_WRITE)));
  },
};

// ---------------------------------------------------------------------------
// staff: supplier portal logins (Shop → Suppliers)
// ---------------------------------------------------------------------------

export const supplierPortalUsersService = {
  async list(supplierUuid: string): Promise<PortalUsersResult> {
    const r = unwrap<PortalUsersResult>(await apiClient.get(SUP(supplierUuid)));
    return { ...r, users: arr(r?.users) };
  },

  async invite(supplierUuid: string, body: { email: string; name?: string }): Promise<InviteResult> {
    return unwrap<InviteResult>(await apiClient.post(SUP(supplierUuid), clean(body), JSON_WRITE));
  },

  async newLink(supplierUuid: string, userUuid: string): Promise<NewLinkResult> {
    return unwrap<NewLinkResult>(
      await apiClient.post(`${SUP(supplierUuid)}/${encodeURIComponent(userUuid)}/link`, {}, JSON_WRITE)
    );
  },

  async disable(supplierUuid: string, userUuid: string): Promise<PortalUsersResult> {
    const r = unwrap<PortalUsersResult>(
      await apiClient.post(`${SUP(supplierUuid)}/${encodeURIComponent(userUuid)}/disable`, {}, JSON_WRITE)
    );
    return { ...r, users: arr(r?.users) };
  },

  async enable(supplierUuid: string, userUuid: string): Promise<PortalUsersResult> {
    const r = unwrap<PortalUsersResult>(
      await apiClient.post(`${SUP(supplierUuid)}/${encodeURIComponent(userUuid)}/enable`, {}, JSON_WRITE)
    );
    return { ...r, users: arr(r?.users) };
  },
};

export default supplierPortalService;
