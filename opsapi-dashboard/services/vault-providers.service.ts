import apiClient from '@/lib/api-client';

export interface VaultProvider {
  id: number;
  uuid: string;
  provider_type: string;
  name: string;
  description?: string;
  config: Record<string, unknown>;
  status: 'active' | 'inactive' | 'error' | 'syncing';
  last_sync_at?: string;
  last_sync_status?: string;
  last_sync_error?: string;
  sync_direction: 'import' | 'export' | 'bidirectional';
  sync_frequency: 'manual' | 'hourly' | 'daily' | 'weekly';
  auto_sync: boolean;
  secrets_synced_count: number;
  created_at: string;
}

export interface SyncMapping {
  uuid: string;
  external_path: string;
  external_key: string;
  local_name: string;
  sync_status: string;
  last_synced_at?: string;
}

export interface SyncLog {
  uuid: string;
  action: string;
  secrets_processed: number;
  secrets_created: number;
  secrets_updated: number;
  secrets_failed: number;
  error_message?: string;
  duration_ms?: number;
  created_at: string;
}

export interface ProviderType {
  type: string;
  name: string;
  description: string;
  icon: string;
  config_fields: string[];
}

export interface SyncResult {
  processed: number;
  created: number;
  updated: number;
  failed: number;
  errors: Array<{ key: string; error: string }>;
}

export interface EnvImportResult {
  total: number;
  created: number;
  failed: number;
  errors: Array<{ key: string; error: string }>;
}

function withVaultKey(vaultKey: string) {
  return { headers: { 'X-Vault-Key': vaultKey } };
}

export const vaultProvidersService = {
  async getProviderTypes(vaultKey: string): Promise<ProviderType[]> {
    const response = await apiClient.get('/api/v2/vault/providers/types', withVaultKey(vaultKey));
    return response.data?.data || response.data || [];
  },

  async getProviders(vaultKey: string): Promise<VaultProvider[]> {
    const response = await apiClient.get('/api/v2/vault/providers', withVaultKey(vaultKey));
    return response.data?.data || response.data || [];
  },

  async createProvider(vaultKey: string, data: Record<string, unknown>): Promise<VaultProvider> {
    const response = await apiClient.post('/api/v2/vault/providers', data, withVaultKey(vaultKey));
    return response.data?.data || response.data;
  },

  async updateProvider(vaultKey: string, uuid: string, data: Record<string, unknown>): Promise<VaultProvider> {
    const response = await apiClient.put(`/api/v2/vault/providers/${uuid}`, data, withVaultKey(vaultKey));
    return response.data?.data || response.data;
  },

  async deleteProvider(vaultKey: string, uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/vault/providers/${uuid}`, withVaultKey(vaultKey));
  },

  async testConnection(vaultKey: string, providerType: string, config: Record<string, unknown>): Promise<{ connected: boolean; error?: string }> {
    const response = await apiClient.post('/api/v2/vault/providers/test-connection', { provider_type: providerType, config }, withVaultKey(vaultKey));
    return response.data?.data || response.data;
  },

  async triggerSync(vaultKey: string, uuid: string): Promise<SyncResult> {
    const response = await apiClient.post(`/api/v2/vault/providers/${uuid}/sync`, {}, withVaultKey(vaultKey));
    return response.data?.data || response.data;
  },

  async getMappings(vaultKey: string, uuid: string): Promise<SyncMapping[]> {
    const response = await apiClient.get(`/api/v2/vault/providers/${uuid}/mappings`, withVaultKey(vaultKey));
    return response.data?.data || response.data || [];
  },

  async getSyncLogs(vaultKey: string, uuid: string, page = 1): Promise<{ data: SyncLog[]; meta: { total: number } }> {
    const response = await apiClient.get(`/api/v2/vault/providers/${uuid}/logs?page=${page}`, withVaultKey(vaultKey));
    return response.data;
  },

  async importEnv(vaultKey: string, content: string, folderId?: number): Promise<EnvImportResult> {
    const response = await apiClient.post('/api/v2/vault/import/env', { content, folder_id: folderId }, withVaultKey(vaultKey));
    return response.data?.data || response.data;
  },

  async exportEnv(vaultKey: string): Promise<string> {
    const response = await apiClient.get('/api/v2/vault/export/env', { ...withVaultKey(vaultKey), responseType: 'text' });
    return response.data;
  },

  async exportJson(vaultKey: string): Promise<Record<string, string>> {
    const response = await apiClient.get('/api/v2/vault/export/json', withVaultKey(vaultKey));
    return response.data?.data || response.data;
  },

  async getExpiringSecrets(vaultKey: string, days = 30): Promise<unknown[]> {
    const response = await apiClient.get(`/api/v2/vault/secrets/expiring?days=${days}`, withVaultKey(vaultKey));
    return response.data?.data || response.data || [];
  },

  async rotateSecret(vaultKey: string, secretId: number, newValue?: string): Promise<{ rotated: boolean }> {
    const body: Record<string, unknown> = {};
    if (newValue) body.value = newValue;
    const response = await apiClient.post(`/api/v2/vault/secrets/${secretId}/rotate`, body, withVaultKey(vaultKey));
    return response.data?.data || response.data;
  },
};
