import apiClient from '@/lib/api-client';
import type { ApiKey, CreateApiKeyDto, CreatedApiKey } from '@/types';

/**
 * Namespace-scoped API keys (machine credentials).
 * Backend: lapis/routes/api-keys.lua. The api-client interceptor attaches the
 * auth token + X-Namespace-Id automatically; these endpoints require a JSON body
 * (not the default form-encoding) and return a { success, data, error } envelope.
 */
const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

/**
 * Surface the backend's own message. axios throws on a 4xx BEFORE we can read the
 * body, and the API answers errors as { error: "..." } — so a raw axios error
 * ("Request failed with status code 403") would otherwise reach the UI. Prefer
 * the response body, then the axios message, then a caller fallback.
 */
function messageFrom(err: unknown, fallback: string): string {
  if (typeof err === 'object' && err !== null) {
    const e = err as {
      response?: { data?: { error?: string; message?: string } };
      message?: string;
    };
    return e.response?.data?.error || e.response?.data?.message || e.message || fallback;
  }
  return fallback;
}

export const apiKeysService = {
  /** List the current namespace's keys (never returns the secret or its hash). */
  async list(): Promise<ApiKey[]> {
    const res = await apiClient.get<{ success: boolean; data: ApiKey[] }>('/api/v2/api-keys');
    return res.data?.data || [];
  },

  /** Create a key; the raw secret is returned ONCE in `data.key`. */
  async create(payload: CreateApiKeyDto): Promise<CreatedApiKey> {
    try {
      const res = await apiClient.post<{ success: boolean; data: CreatedApiKey; error?: string }>(
        '/api/v2/api-keys',
        payload,
        JSON_HEADERS,
      );
      if (!res.data?.success || !res.data?.data) {
        throw new Error(res.data?.error || 'Failed to create API key');
      }
      return res.data.data;
    } catch (err) {
      throw new Error(messageFrom(err, 'Failed to create API key'));
    }
  },

  /** Revoke a key (idempotent). */
  async revoke(uuid: string): Promise<void> {
    try {
      await apiClient.delete(`/api/v2/api-keys/${uuid}`);
    } catch (err) {
      throw new Error(messageFrom(err, 'Failed to revoke API key'));
    }
  },
};

export default apiKeysService;
