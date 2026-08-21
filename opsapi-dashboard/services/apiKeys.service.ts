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
 * Build a request config that targets a specific namespace. When `nsId` is
 * given (e.g. a platform admin managing another tenant), it is sent as an
 * explicit `X-Namespace-Id`, which the api-client interceptor now respects
 * instead of the caller's current namespace. Omit it to use the current one.
 */
function nsConfig(nsId?: string, extraHeaders?: Record<string, string>) {
  const headers: Record<string, string> = { ...extraHeaders };
  if (nsId) headers['X-Namespace-Id'] = nsId;
  return Object.keys(headers).length ? { headers } : undefined;
}

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
  /**
   * List a namespace's keys (never returns the secret or its hash).
   * Pass `nsId` to target a specific namespace (admin), else the current one.
   */
  async list(nsId?: string): Promise<ApiKey[]> {
    const res = await apiClient.get<{ success: boolean; data: ApiKey[] }>(
      '/api/v2/api-keys',
      nsConfig(nsId),
    );
    return res.data?.data || [];
  },

  /** Create a key; the raw secret is returned ONCE in `data.key`. */
  async create(payload: CreateApiKeyDto, nsId?: string): Promise<CreatedApiKey> {
    try {
      const res = await apiClient.post<{ success: boolean; data: CreatedApiKey; error?: string }>(
        '/api/v2/api-keys',
        payload,
        nsConfig(nsId, JSON_HEADERS.headers),
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
  async revoke(uuid: string, nsId?: string): Promise<void> {
    try {
      await apiClient.delete(`/api/v2/api-keys/${uuid}`, nsConfig(nsId));
    } catch (err) {
      throw new Error(messageFrom(err, 'Failed to revoke API key'));
    }
  },
};

export default apiKeysService;
