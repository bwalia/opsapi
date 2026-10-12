import apiClient from '@/lib/api-client';
import { errorMessage } from '@/lib/plugin-bridge';
import type { ApiKey, ApiKeyScopes, CreatedApiKey } from '@/types';

/**
 * The signed-in member's own personal API keys in the current workspace.
 * Backend: /api/v2/me/api-keys (lapis/routes/api-keys.lua). Any member may
 * mint keys for themselves; a key never holds more than the member's role.
 *
 * `_replay: true` keeps these writes out of the offline outbox: a key minted
 * later by a background replay would have a secret nobody ever sees, and a
 * revoke must really have happened before the UI says so.
 */
const WRITE = { headers: { 'Content-Type': 'application/json' }, _replay: true };

export type MyApiKey = ApiKey & { created_via?: string | null };
export type CreatedMyApiKey = CreatedApiKey & { created_at?: string };

export interface CreateMyApiKeyDto {
  name: string;
  /** 1–365, default 90 on the server. */
  expires_in_days?: number;
  /** Omit for the "AI agent (MCP)" preset, narrowed to the member's role. */
  scopes?: ApiKeyScopes;
}

function fail(err: unknown, fallback: string): never {
  const e = err as { response?: { data?: unknown }; message?: string } | null;
  throw new Error(errorMessage(e?.response?.data) || e?.message || fallback);
}

export const myApiKeysService = {
  async list(): Promise<MyApiKey[]> {
    try {
      const res = await apiClient.get<{ data: MyApiKey[] }>('/api/v2/me/api-keys');
      return res.data?.data || [];
    } catch (err) {
      fail(err, 'Failed to load your API keys');
    }
  },

  /** The raw secret comes back once, in `key`. */
  async create(payload: CreateMyApiKeyDto): Promise<CreatedMyApiKey> {
    try {
      const res = await apiClient.post<{ data?: CreatedMyApiKey }>('/api/v2/me/api-keys', payload, WRITE);
      if (!res.data?.data?.key) throw new Error('No key was returned. Please try again.');
      return res.data.data;
    } catch (err) {
      fail(err, 'Failed to create API key');
    }
  },

  async revoke(uuid: string): Promise<void> {
    try {
      await apiClient.delete(`/api/v2/me/api-keys/${encodeURIComponent(uuid)}`, { _replay: true });
    } catch (err) {
      fail(err, 'Failed to revoke API key');
    }
  },
};

export default myApiKeysService;
