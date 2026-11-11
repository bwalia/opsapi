/**
 * Shop VIP (Trade) membership — admin views.
 * GET  /api/v2/shop/admin/membership/members  (shop.read)
 * POST /api/v2/shop/admin/membership/lookup   (shop.read) — VIP status for a page of emails.
 */
import apiClient, { buildQueryString } from '@/lib/api-client';
import type { ShopMember, ShopVipStatus } from '@/types/shop';

const BASE = '/api/v2/shop/admin/membership';

export const shopMembershipService = {
  async members(p: { q?: string; status?: string } = {}): Promise<ShopMember[]> {
    const qs = buildQueryString({ q: p.q || undefined, status: p.status || undefined });
    const res = await apiClient.get(`${BASE}/members${qs}`);
    const data = (res.data as { data?: ShopMember[] })?.data;
    return Array.isArray(data) ? data : [];
  },

  /** Map of lower-cased email → VIP status, for the emails that hold a membership in force. */
  async lookup(emails: string[]): Promise<Record<string, ShopVipStatus>> {
    if (emails.length === 0) return {};
    const res = await apiClient.post(`${BASE}/lookup`, { emails }, { headers: { 'Content-Type': 'application/json' } });
    const data = (res.data as { data?: unknown })?.data;
    // An empty Lua table encodes as [] — treat any non-object as "none".
    return data && typeof data === 'object' && !Array.isArray(data) ? (data as Record<string, ShopVipStatus>) : {};
  },
};

export default shopMembershipService;
