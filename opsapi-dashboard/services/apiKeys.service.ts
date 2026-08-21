import apiClient from '@/lib/api-client';
import type { ApiKey, CreateApiKeyDto, CreatedApiKey } from '@/types';

/**
 * Namespace-scoped API keys (machine credentials).
 * Backend: lapis/routes/api-keys.lua. The api-client interceptor attaches the
 * auth token + X-Namespace-Id automatically; these endpoints require a JSON body
 * (not the default form-encoding) and return a { success, data, error } envelope.
 */
const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

export const apiKeysService = {
  /** List the current namespace's keys (never returns the secret or its hash). */
  async list(): Promise<ApiKey[]> {
    const res = await apiClient.get<{ success: boolean; data: ApiKey[] }>('/api/v2/api-keys');
    return res.data?.data || [];
  },

  /** Create a key; the raw secret is returned ONCE in `data.key`. */
  async create(payload: CreateApiKeyDto): Promise<CreatedApiKey> {
    const res = await apiClient.post<{ success: boolean; data: CreatedApiKey; error?: string }>(
      '/api/v2/api-keys',
      payload,
      JSON_HEADERS,
    );
    if (!res.data?.success || !res.data?.data) {
      throw new Error(res.data?.error || 'Failed to create API key');
    }
    return res.data.data;
  },

  /** Revoke a key (idempotent). */
  async revoke(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/api-keys/${uuid}`);
  },
};

export default apiKeysService;
