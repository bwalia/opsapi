/**
 * Shop legal record — the statements customers ticked (append-only), and erasure requests.
 * GET /api/v2/shop/admin/legal/acceptances (shop.read), POST …/erase (shop.delete).
 */
import apiClient, { buildQueryString } from '@/lib/api-client';
import type { ShopLegalAcceptance, ShopLegalListParams, ShopList } from '@/types/shop';

const BASE = '/api/v2/shop/admin/legal/acceptances';

export const shopLegalService = {
  async list(p: ShopLegalListParams = {}): Promise<ShopList<ShopLegalAcceptance>> {
    const qs = buildQueryString({
      q: p.q || undefined,
      document_key: p.document_key || undefined,
      checkpoint: p.checkpoint || undefined,
      limit: p.limit,
      offset: p.offset,
    });
    const res = await apiClient.get(`${BASE}${qs}`);
    const body = res.data as { data?: ShopLegalAcceptance[]; meta?: { total?: number; limit?: number; offset?: number } };
    const data = Array.isArray(body?.data) ? body.data : [];
    return {
      data,
      meta: { total: Number(body?.meta?.total ?? data.length), limit: Number(body?.meta?.limit ?? p.limit ?? 25), offset: Number(body?.meta?.offset ?? 0) },
    };
  },

  /** Erasure request: deletes every acceptance recorded for this email. The email goes in the body, never the URL. */
  async erase(email: string): Promise<{ erased: number }> {
    const res = await apiClient.post(`${BASE}/erase`, { email }, { headers: { 'Content-Type': 'application/json' } });
    return (res.data as { data: { erased: number } }).data;
  },
};

export default shopLegalService;
