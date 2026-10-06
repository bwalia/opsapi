import apiClient, { buildQueryString } from '@/lib/api-client';

/**
 * AI usage — every model call the platform makes (assistant, tax
 * classification, statement reading, bookkeeping AI), metered server-side into
 * ai_usage. Backend: lapis/routes/ai-usage.lua. A "request" is what a person
 * asked for (one assistant message = one request, however many model calls).
 */

interface Usage {
  requests: number;
  model_calls: number;
  input_tokens: number;
  output_tokens: number;
}

export interface AiUsageSummary {
  days: number;
  totals: Usage & { failed: number; users: number; avg_latency_ms: number };
  series: (Usage & { day: string })[];
  members: (Usage & {
    user_uuid: string;
    email?: string;
    name?: string;
    failed: number;
    last_used_at?: string;
  })[];
  features: (Usage & { feature: string })[];
  models: (Omit<Usage, 'requests'> & { provider: string; model: string })[];
  /** Platform view only. */
  workspaces?: (Usage & { namespace_uuid?: string; name?: string; slug?: string; users: number })[];
}

export const aiUsageService = {
  /** The current workspace (RBAC `activity.read`). */
  async workspace(days: number): Promise<AiUsageSummary> {
    const res = await apiClient.get<{ data: AiUsageSummary }>(
      `/api/v2/namespace/ai-usage${buildQueryString({ days })}`
    );
    return res.data.data;
  },

  /** Every workspace (platform admins). */
  async platform(days: number): Promise<AiUsageSummary> {
    const res = await apiClient.get<{ data: AiUsageSummary }>(`/api/v2/admin/ai-usage${buildQueryString({ days })}`);
    return res.data.data;
  },
};
