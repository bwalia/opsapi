/**
 * Purchase invoices: every supplier invoice, proforma and credit note across purchase orders, with what is
 * paid, owed and overdue. Contract: lapis/queries/PurchaseInvoiceQueries.lua (GET /api/v2/purchase-invoices,
 * RBAC purchase_orders read). Recording one goes through the PO's supplier panel API (supplier-portal.service).
 * Money is decimal text ("5256.65").
 */
import apiClient, { buildQueryString } from '@/lib/api-client';

export type PurchaseInvoiceState = 'unpaid' | 'part_paid' | 'overdue' | 'paid' | 'proforma' | 'credit';
export type PurchaseInvoiceFilter = PurchaseInvoiceState | 'owed' | '';

export interface PurchaseInvoice {
  uuid: string;
  kind: 'invoice' | 'proforma' | 'credit_note';
  number: string;
  state: PurchaseInvoiceState;
  invoice_date: string;
  due_date: string | null;
  days_late: number | null;
  net: string;
  vat: string;
  total: string;
  paid: string;
  outstanding: string;
  currency: string;
  supplier_name: string;
  supplier_order_ref: string | null;
  payment_terms: string | null;
  has_document: boolean;
  recorded_by: 'staff' | 'supplier';
  purchase_order: { uuid: string; po_number: string };
}

export interface PurchaseInvoiceTotals {
  owed: string;
  overdue: string;
  paid: string;
  owed_count: number;
  overdue_count: number;
}

export interface PurchaseInvoiceList {
  data: PurchaseInvoice[];
  total: number;
  /** Per currency (an empty list when there is nothing). */
  summary: Record<string, PurchaseInvoiceTotals>;
}

export const purchaseInvoicesService = {
  async list(params: { q?: string; state?: PurchaseInvoiceFilter; from?: string; to?: string; limit?: number; offset?: number } = {}): Promise<PurchaseInvoiceList> {
    const res = await apiClient.get(`/api/v2/purchase-invoices${buildQueryString({
      q: params.q || undefined, state: params.state || undefined, from: params.from || undefined, to: params.to || undefined,
      limit: params.limit, offset: params.offset,
    })}`);
    const body = res.data ?? {};
    const meta = body.meta ?? {};
    const summary = meta.summary && !Array.isArray(meta.summary) ? meta.summary : {};
    return { data: Array.isArray(body.data) ? body.data : [], total: Number(meta.total ?? 0), summary };
  },
};
