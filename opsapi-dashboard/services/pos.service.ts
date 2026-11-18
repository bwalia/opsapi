/**
 * Point of Sale: selling in person from a store (lapis/queries/PosQueries.lua, /api/v2/pos/*).
 * Money is decimal text ("12.50").
 */
import apiClient, { buildQueryString } from '@/lib/api-client';

export interface PosProduct {
  uuid: string;
  name: string;
  sku: string | null;
  barcode: string | null;
  price: string;
  image: string | null;
  /** null when the product doesn't track stock. */
  stock: number | null;
  available: boolean;
}

export interface PosCatalogue {
  store: { uuid: string; name: string; currency: string; tax_rate: number };
  products: PosProduct[];
}

export type PosPaymentMethod = 'cash' | 'card' | 'other';

export interface PosSaleInput {
  store_uuid: string;
  items: { product_uuid: string; quantity: number }[];
  discount_amount?: string;
  customer?: { email?: string };
  payment: { method: PosPaymentMethod; tendered?: string; reference?: string };
  note?: string;
}

export interface PosReceipt {
  uuid: string;
  order_number: string;
  sold_at: string;
  store: { uuid: string; name: string; address: string; contact: string };
  items: { name: string; sku: string | null; quantity: number; price: string; total: string }[];
  currency: string;
  subtotal: string;
  tax: string;
  discount: string;
  total: string;
  payment: { method: PosPaymentMethod | null; label: string | null; tendered: string | null; change: string | null; reference: string | null };
  customer_email: string | null;
}

export interface PosSummary {
  date: string;
  timezone: string;
  currency: string;
  sales: number;
  total: string;
  by_method: { method: string; label: string; sales: number; total: string }[];
}

const JSON_BODY = { headers: { 'Content-Type': 'application/json' } };

export const posService = {
  async products(storeUuid: string, q?: string): Promise<PosCatalogue> {
    const res = await apiClient.get(`/api/v2/pos/products${buildQueryString({ store_uuid: storeUuid, q: q || undefined, limit: 500 })}`);
    return res.data.data as PosCatalogue;
  },
  /** The same idempotency key makes a retried "Complete sale" safe (never two sales). */
  async sale(input: PosSaleInput, idempotencyKey: string): Promise<PosReceipt> {
    const res = await apiClient.post('/api/v2/pos/sales', input, { headers: { ...JSON_BODY.headers, 'Idempotency-Key': idempotencyKey } });
    return res.data.data as PosReceipt;
  },
  async receipt(uuid: string): Promise<PosReceipt> {
    const res = await apiClient.get(`/api/v2/pos/sales/${uuid}/receipt`);
    return res.data.data as PosReceipt;
  },
  async emailReceipt(uuid: string, email: string): Promise<{ sent: boolean; to: string }> {
    const res = await apiClient.post(`/api/v2/pos/sales/${uuid}/email-receipt`, { email }, JSON_BODY);
    return res.data.data;
  },
  async summary(storeUuid: string, date?: string): Promise<PosSummary> {
    const res = await apiClient.get(`/api/v2/pos/summary${buildQueryString({ store_uuid: storeUuid, date: date || undefined })}`);
    return res.data.data as PosSummary;
  },
};
