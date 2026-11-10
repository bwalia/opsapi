/**
 * Shop Analytics — GET /api/v2/shop/admin/analytics (+ /export CSV).
 * RBAC module "shop_analytics" (read).
 */
import apiClient from '@/lib/api-client';
import type { ShopAnalyticsExport, ShopAnalyticsQuery, ShopAnalyticsReport, ShopSurveyReport } from '@/types/shop-analytics';

const BASE = '/api/v2/shop/admin/analytics';

export const SHOP_ANALYTICS_MODULE = 'shop_analytics';

function params(q: ShopAnalyticsQuery): Record<string, string> {
  const p: Record<string, string> = {};
  if (q.from) p.from = q.from;
  if (q.to) p.to = q.to;
  if (!q.from && q.days) p.days = String(q.days);
  if (q.bucket) p.bucket = q.bucket;
  if (q.compare === false) p.compare = 'false';
  return p;
}

export const shopAnalyticsService = {
  async getReport(q: ShopAnalyticsQuery, signal?: AbortSignal): Promise<ShopAnalyticsReport> {
    const res = await apiClient.get(BASE, { params: params(q), signal });
    return (res.data as { data: ShopAnalyticsReport }).data;
  },

  /** "What do I need?" survey funnel and drop-off for the same window. */
  async getSurvey(q: ShopAnalyticsQuery, signal?: AbortSignal): Promise<ShopSurveyReport> {
    const res = await apiClient.get(`${BASE}/survey`, { params: params({ from: q.from, to: q.to, days: q.days }), signal });
    return (res.data as { data: ShopSurveyReport }).data;
  },

  /** The server's CSV for one export. Returns the file to save. */
  async downloadCsv(report: ShopAnalyticsExport, q: ShopAnalyticsQuery): Promise<{ blob: Blob; filename: string }> {
    const res = await apiClient.get(`${BASE}/export`, {
      params: { ...params(q), report },
      responseType: 'blob',
    });
    const disposition = String(res.headers?.['content-disposition'] || '');
    const match = disposition.match(/filename="?([^";]+)"?/);
    return { blob: res.data as Blob, filename: match?.[1] || `shop-${report}.csv` };
  },
};

export default shopAnalyticsService;
