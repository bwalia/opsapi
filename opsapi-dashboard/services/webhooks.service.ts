import apiClient, { buildQueryString } from '@/lib/api-client';

/**
 * Workspace webhooks: send this namespace's events (invoice paid, lead
 * created, …) to your own URLs, signed and retried. Backed by
 * lapis/routes/namespace-webhooks.lua (/api/v2/namespace/webhooks).
 */

export interface WebhookDeliverySummary {
  status: DeliveryStatus;
  response_status?: number;
  updated_at: string;
  event: string;
}

export interface Webhook {
  uuid: string;
  url: string;
  description?: string;
  events: string[];
  is_active: boolean;
  created_at: string;
  updated_at: string;
  last_delivery?: WebhookDeliverySummary | null;
  pending_count?: number;
  dead_count?: number;
}

export interface WebhookEventGroup {
  entity: string;
  owner: string;
  /** false when the current user can't read this data (can't subscribe). */
  allowed: boolean;
  events: string[];
}

export type DeliveryStatus = 'pending' | 'running' | 'done' | 'dead';

export interface WebhookDelivery {
  id: number;
  event_id: string;
  event: string;
  status: DeliveryStatus;
  attempts: number;
  response_status?: number;
  duration_ms?: number;
  last_error?: string;
  next_attempt_at?: string;
  created_at: string;
  updated_at: string;
}

export interface WebhookInput {
  url?: string;
  description?: string | null;
  events?: string[];
  is_active?: boolean;
}

export interface WebhookTestResult {
  delivered: boolean;
  error?: string;
  response_status?: number;
  duration_ms?: number;
}

const BASE = '/api/v2/namespace/webhooks';
const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;

function unwrap<T>(response: { data: unknown }): T {
  const body = response.data as { data?: T };
  return (body?.data ?? body) as T;
}

export const webhooksService = {
  async list(): Promise<Webhook[]> {
    const data = unwrap<Webhook[]>(await apiClient.get(BASE));
    return Array.isArray(data) ? data : [];
  },

  async events(): Promise<WebhookEventGroup[]> {
    const data = unwrap<WebhookEventGroup[]>(await apiClient.get(`${BASE}/events`));
    return Array.isArray(data) ? data : [];
  },

  /** Returns the webhook and its signing secret, which is shown only once. */
  async create(input: WebhookInput): Promise<{ webhook: Webhook; secret: string }> {
    return unwrap(await apiClient.post(BASE, input, JSON_BODY));
  },

  async update(uuid: string, input: WebhookInput): Promise<Webhook> {
    return unwrap(await apiClient.put(`${BASE}/${uuid}`, input, JSON_BODY));
  },

  async remove(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/${uuid}`);
  },

  async rotateSecret(uuid: string): Promise<string> {
    return unwrap<{ secret: string }>(await apiClient.post(`${BASE}/${uuid}/rotate-secret`)).secret;
  },

  async test(uuid: string): Promise<WebhookTestResult> {
    return unwrap(await apiClient.post(`${BASE}/${uuid}/test`));
  },

  async deliveries(
    uuid: string,
    params: { page?: number; per_page?: number; status?: DeliveryStatus | '' } = {}
  ): Promise<{ data: WebhookDelivery[]; meta: { page: number; total: number; total_pages: number } }> {
    const res = await apiClient.get(`${BASE}/${uuid}/deliveries${buildQueryString(params)}`);
    const body = res.data as { data?: WebhookDelivery[]; meta?: { page: number; total: number; total_pages: number } };
    return {
      data: Array.isArray(body?.data) ? body.data : [],
      meta: body?.meta ?? { page: 1, total: 0, total_pages: 0 },
    };
  },

  async redeliver(uuid: string, deliveryId: number): Promise<void> {
    await apiClient.post(`${BASE}/${uuid}/deliveries/${deliveryId}/redeliver`);
  },
};
