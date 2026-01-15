import { apiClient, buildQueryString, toFormData } from '@/lib/api-client';
import type {
  Vault,
  VaultFolder,
  VaultSecret,
  VaultShare,
  VaultAccessLog,
  VaultStats,
  VaultResponse,
  VaultUnlockResponse,
  VaultSecretsResponse,
  VaultSecretResponse,
  VaultFoldersResponse,
  VaultStatsResponse,
  VaultSharesResponse,
  VaultAccessLogsResponse,
  CreateVaultDto,
  ChangeVaultKeyDto,
  CreateVaultFolderDto,
  UpdateVaultFolderDto,
  CreateVaultSecretDto,
  UpdateVaultSecretDto,
  ShareVaultSecretDto,
  VaultSecretListParams,
  VaultAccessLogParams,
  VaultShareableUser,
} from '@/types';

/**
 * Vault Key Storage (Session Only)
 *
 * IMPORTANT: The vault key is stored in sessionStorage for the duration of the session.
 * It is automatically cleared when the browser tab is closed.
 * The key is NEVER sent to the server for storage - it's only used for API calls.
 */
const VAULT_KEY_STORAGE_KEY = 'vault_session_key';

/**
 * Get the current vault key from session storage
 */
export function getVaultKey(): string | null {
  if (typeof window === 'undefined') return null;
  return sessionStorage.getItem(VAULT_KEY_STORAGE_KEY);
}

/**
 * Set the vault key in session storage
 */
export function setVaultKey(key: string): void {
  if (typeof window === 'undefined') return;
  sessionStorage.setItem(VAULT_KEY_STORAGE_KEY, key);
}

/**
 * Clear the vault key from session storage
 */
export function clearVaultKey(): void {
  if (typeof window === 'undefined') return;
  sessionStorage.removeItem(VAULT_KEY_STORAGE_KEY);
}

/**
 * Check if vault is unlocked (has key in session)
 */
export function isVaultUnlocked(): boolean {
  return !!getVaultKey();
}

/**
 * Add vault key header to request config
 */
function withVaultKey(vaultKey?: string): Record<string, string> {
  const key = vaultKey || getVaultKey();
  if (!key) {
    throw new Error('Vault key is required. Please unlock your vault first.');
  }
  return { 'X-Vault-Key': key };
}

/**
 * Vault Service
 *
 * Handles all vault-related API calls for secure secret management.
 *
 * SECURITY ARCHITECTURE:
 * - User provides a 16-character vault key for all encryption/decryption
 * - The vault key is NEVER stored on the server
 * - The vault key is stored in sessionStorage (cleared when tab closes)
 * - All secrets are encrypted with AES-256 using the user's key
 * - Secrets are decrypted server-side only when the vault key is provided
 */
export const vaultService = {
  // ============================================
  // Vault Management
  // ============================================

  /**
   * Get vault info (without unlocking)
   */
  async getVault(): Promise<Vault | null> {
    try {
      const response = await apiClient.get<VaultResponse>('/api/v2/vault');
      return response.data.data || null;
    } catch (error: unknown) {
      const axiosError = error as { response?: { status?: number } };
      if (axiosError.response?.status === 404) {
        return null; // No vault exists yet
      }
      throw error;
    }
  },

  /**
   * Create a new vault with a vault key
   */
  async createVault(data: CreateVaultDto): Promise<Vault> {
    const response = await apiClient.post<VaultResponse>(
      '/api/v2/vault',
      toFormData(data as unknown as Record<string, unknown>)
    );

    if (!response.data.success || !response.data.data) {
      throw new Error(response.data.error || 'Failed to create vault');
    }

    // Store the vault key in session
    setVaultKey(data.vault_key);

    return response.data.data;
  },

  /**
   * Unlock vault (verify key and store in session)
   */
  async unlockVault(vaultKey: string): Promise<VaultUnlockResponse['data']> {
    const response = await apiClient.post<VaultUnlockResponse>(
      '/api/v2/vault/unlock',
      toFormData({ vault_key: vaultKey })
    );

    if (!response.data.success || !response.data.data) {
      throw new Error(response.data.error || 'Failed to unlock vault');
    }

    // Store the vault key in session
    setVaultKey(vaultKey);

    return response.data.data;
  },

  /**
   * Lock vault (clear key from session)
   */
  lockVault(): void {
    clearVaultKey();
  },

  /**
   * Change vault key
   */
  async changeVaultKey(data: ChangeVaultKeyDto): Promise<void> {
    const response = await apiClient.put<VaultResponse>(
      '/api/v2/vault/key',
      toFormData(data as unknown as Record<string, unknown>)
    );

    if (!response.data.success) {
      throw new Error(response.data.error || 'Failed to change vault key');
    }

    // Update the stored key
    setVaultKey(data.new_vault_key);
  },

  /**
   * Get vault statistics
   */
  async getStats(): Promise<VaultStats> {
    const response = await apiClient.get<VaultStatsResponse>('/api/v2/vault/stats');
    return response.data.data;
  },

  // ============================================
  // Folder Management
  // ============================================

  /**
   * Get all folders in the vault
   */
  async getFolders(vaultKey?: string): Promise<VaultFolder[]> {
    const response = await apiClient.get<VaultFoldersResponse>('/api/v2/vault/folders', {
      headers: withVaultKey(vaultKey),
    });
    return response.data.data;
  },

  /**
   * Create a folder
   */
  async createFolder(data: CreateVaultFolderDto, vaultKey?: string): Promise<VaultFolder> {
    const response = await apiClient.post<{ success: boolean; data: VaultFolder; message?: string }>(
      '/api/v2/vault/folders',
      toFormData(data as unknown as Record<string, unknown>),
      { headers: withVaultKey(vaultKey) }
    );
    return response.data.data;
  },

  /**
   * Update a folder
   */
  async updateFolder(
    folderId: string,
    data: UpdateVaultFolderDto,
    vaultKey?: string
  ): Promise<VaultFolder> {
    const response = await apiClient.put<{ success: boolean; data: VaultFolder }>(
      `/api/v2/vault/folders/${folderId}`,
      toFormData(data as unknown as Record<string, unknown>),
      { headers: withVaultKey(vaultKey) }
    );
    return response.data.data;
  },

  /**
   * Delete a folder
   */
  async deleteFolder(folderId: string, vaultKey?: string): Promise<void> {
    await apiClient.delete(`/api/v2/vault/folders/${folderId}`, {
      headers: withVaultKey(vaultKey),
    });
  },

  // ============================================
  // Secret Management
  // ============================================

  /**
   * Get all secrets (metadata only, no values)
   */
  async getSecrets(params?: VaultSecretListParams, vaultKey?: string): Promise<VaultSecretsResponse['data']> {
    const queryString = buildQueryString({
      folder_id: params?.folder_id,
      secret_type: params?.secret_type === 'all' ? undefined : params?.secret_type,
      search: params?.search,
      page: params?.page,
      per_page: params?.perPage,
    });

    const response = await apiClient.get<VaultSecretsResponse>(
      `/api/v2/vault/secrets${queryString}`,
      { headers: withVaultKey(vaultKey) }
    );
    return response.data.data;
  },

  /**
   * Read a secret (decrypt and return value)
   */
  async readSecret(secretId: string, vaultKey?: string): Promise<VaultSecret> {
    const response = await apiClient.get<VaultSecretResponse>(
      `/api/v2/vault/secrets/${secretId}`,
      { headers: withVaultKey(vaultKey) }
    );

    if (!response.data.success || !response.data.data) {
      throw new Error(response.data.error || 'Failed to read secret');
    }

    return response.data.data;
  },

  /**
   * Create a secret
   */
  async createSecret(data: CreateVaultSecretDto, vaultKey?: string): Promise<VaultSecret> {
    const formData: Record<string, unknown> = { ...data };
    if (data.tags) {
      formData.tags = JSON.stringify(data.tags);
    }
    if (data.metadata) {
      formData.metadata = JSON.stringify(data.metadata);
    }

    const response = await apiClient.post<VaultSecretResponse>(
      '/api/v2/vault/secrets',
      toFormData(formData),
      { headers: withVaultKey(vaultKey) }
    );

    if (!response.data.success || !response.data.data) {
      throw new Error(response.data.error || 'Failed to create secret');
    }

    return response.data.data;
  },

  /**
   * Update a secret
   */
  async updateSecret(
    secretId: string,
    data: UpdateVaultSecretDto,
    vaultKey?: string
  ): Promise<VaultSecret> {
    const formData: Record<string, unknown> = { ...data };
    if (data.tags) {
      formData.tags = JSON.stringify(data.tags);
    }
    if (data.metadata) {
      formData.metadata = JSON.stringify(data.metadata);
    }

    const response = await apiClient.put<VaultSecretResponse>(
      `/api/v2/vault/secrets/${secretId}`,
      toFormData(formData),
      { headers: withVaultKey(vaultKey) }
    );

    if (!response.data.success || !response.data.data) {
      throw new Error(response.data.error || 'Failed to update secret');
    }

    return response.data.data;
  },

  /**
   * Delete a secret
   */
  async deleteSecret(secretId: string, vaultKey?: string): Promise<void> {
    await apiClient.delete(`/api/v2/vault/secrets/${secretId}`, {
      headers: withVaultKey(vaultKey),
    });
  },

  // ============================================
  // Secret Sharing
  // ============================================

  /**
   * Share a secret with another user
   */
  async shareSecret(
    secretId: string,
    data: ShareVaultSecretDto,
    vaultKey?: string
  ): Promise<VaultShare> {
    const response = await apiClient.post<{ success: boolean; data: VaultShare; message?: string }>(
      `/api/v2/vault/secrets/${secretId}/share`,
      toFormData(data as unknown as Record<string, unknown>),
      { headers: withVaultKey(vaultKey) }
    );
    return response.data.data;
  },

  /**
   * Get shares for a secret
   */
  async getSecretShares(secretId: string): Promise<VaultShare[]> {
    const response = await apiClient.get<VaultSharesResponse>(
      `/api/v2/vault/secrets/${secretId}/shares`
    );
    return response.data.data;
  },

  /**
   * Revoke a share
   */
  async revokeShare(shareId: string): Promise<void> {
    await apiClient.delete(`/api/v2/vault/shares/${shareId}`);
  },

  /**
   * Get secrets shared with me
   */
  async getSharedWithMe(): Promise<VaultShare[]> {
    const response = await apiClient.get<VaultSharesResponse>('/api/v2/vault/shared');
    return response.data.data;
  },

  // ============================================
  // Audit Logs
  // ============================================

  /**
   * Get vault access logs
   */
  async getAccessLogs(params?: VaultAccessLogParams): Promise<VaultAccessLogsResponse['data']> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.perPage,
      action: params?.action,
      start_date: params?.start_date,
      end_date: params?.end_date,
    });

    const response = await apiClient.get<VaultAccessLogsResponse>(
      `/api/v2/vault/logs${queryString}`
    );
    return response.data.data;
  },

  // ============================================
  // User Search for Sharing
  // ============================================

  /**
   * Search users in namespace for sharing secrets
   */
  async searchUsers(query: string, limit?: number): Promise<VaultShareableUser[]> {
    const queryString = buildQueryString({
      q: query,
      limit: limit || 10,
    });

    const response = await apiClient.get<{ success: boolean; data: VaultShareableUser[] }>(
      `/api/v2/vault/users/search${queryString}`
    );
    return response.data.data || [];
  },
};

export default vaultService;
