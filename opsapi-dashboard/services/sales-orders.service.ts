/**
 * Sales orders: every order of the workspace in one list — the shop's and the online stores', whatever channel
 * they came through. Contract: lapis/queries/SalesOrderQueries.lua (GET /api/v2/sales-orders).
 */
import apiClient, { buildQueryString } from '@/lib/api-client';

export type SalesOrderStage =
  | 'awaiting_payment' | 'confirmed' | 'processing' | 'shipped' | 'delivered' | 'cancelled' | 'refunded' | 'failed';
export type SalesOrderStageFilter = SalesOrderStage | 'in_progress' | '';
export type SalesOrderChannel = 'online' | 'phone' | 'in_person' | 'email' | 'pos' | 'staff' | 'quote';

export interface SalesOrder {
  source: 'shop' | 'store';
  uuid: string;
  order_number: string;
  placed_at: string;
  stage: SalesOrderStage;
  payment: 'pending' | 'paid' | 'refunded' | 'failed';
  total: string;
  currency: string;
  customer_name?: string | null;
  customer_email?: string | null;
  company?: string | null;
  channel: SalesOrderChannel;
  /** Shop orders open their own page; store orders open in Sales Orders. */
  path?: string | null;
}

export interface SalesOrderStats {
  total: number;
  awaiting_payment: number;
  in_progress: number;
  delivered: number;
  /** Paid totals per currency. */
  revenue: Record<string, string>;
}

export interface SalesOrderList {
  data: SalesOrder[];
  total: number;
  sources: ('shop' | 'store')[];
  stats: SalesOrderStats;
}

export interface SalesOrderParams {
  q?: string;
  stage?: SalesOrderStageFilter;
  source?: 'shop' | 'store' | '';
  channel?: SalesOrderChannel | '';
  from?: string;
  to?: string;
  page?: number;
  per_page?: number;
}

export const salesOrdersService = {
  async list(params: SalesOrderParams = {}): Promise<SalesOrderList> {
    const res = await apiClient.get(`/api/v2/sales-orders${buildQueryString({
      q: params.q || undefined, stage: params.stage || undefined, source: params.source || undefined,
      channel: params.channel || undefined, from: params.from || undefined, to: params.to || undefined,
      page: params.page, per_page: params.per_page,
    })}`);
    const body = res.data ?? {};
    const meta = body.meta ?? {};
    const stats = meta.stats ?? {};
    return {
      data: Array.isArray(body.data) ? body.data : [],
      total: Number(meta.total ?? 0),
      sources: Array.isArray(meta.sources) ? meta.sources : [],
      stats: {
        total: Number(stats.total ?? 0),
        awaiting_payment: Number(stats.awaiting_payment ?? 0),
        in_progress: Number(stats.in_progress ?? 0),
        delivered: Number(stats.delivered ?? 0),
        revenue: stats.revenue && !Array.isArray(stats.revenue) ? stats.revenue : {},
      },
    };
  },
};
