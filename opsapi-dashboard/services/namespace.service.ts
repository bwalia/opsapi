import { apiClient, buildQueryString, toFormData, NAMESPACE_KEY } from '@/lib/api-client';
import type {
  Namespace,
  NamespaceWithMembership,
  NamespaceMember,
  NamespaceRole,
  NamespacePermissions,
  NamespaceSwitchResponse,
  NamespaceStats,
  CreateNamespaceDto,
  UpdateNamespaceDto,
  CreateNamespaceRoleDto,
  UpdateNamespaceRoleDto,
  InviteMemberDto,
  PaginatedResponse,
  PaginationParams,
  NamespaceModuleMeta,
  NamespaceActionMeta,
  UserNamespaceSettings,
  UserNamespacesResponse,
  UpdateUserNamespaceSettingsDto,
  CreateNamespaceResponse,
} from '@/types';

// Local storage key for user namespace settings
const USER_NAMESPACE_SETTINGS_KEY = 'user_namespace_settings';

/**
 * Namespace Service
 * Handles all namespace-related API calls and local storage management
 */
export const namespaceService = {
  // ============================================
  // User Namespace Settings (USER-FIRST Architecture)
  // ============================================

  /**
   * Get user's namespace settings (default namespace, last active namespace)
   */
  async getUserNamespaceSettings(): Promise<UserNamespaceSettings | null> {
    try {
      const response = await apiClient.get<{ settings: UserNamespaceSettings }>(
        '/api/v2/user/namespace-settings'
      );
      const settings = response.data.settings;
      if (settings) {
        this.setUserNamespaceSettingsInStorage(settings);
      }
      return settings;
    } catch {
      return null;
    }
  },

  /**
   * Update user's default namespace
   */
  async updateUserNamespaceSettings(data: UpdateUserNamespaceSettingsDto): Promise<UserNamespaceSettings> {
    const response = await apiClient.put<{ settings: UserNamespaceSettings; message: string }>(
      '/api/v2/user/namespace-settings',
      toFormData(data as unknown as Record<string, unknown>)
    );
    const settings = response.data.settings;
    if (settings) {
      this.setUserNamespaceSettingsInStorage(settings);
    }
    return settings;
  },

  /**
   * Set user's default namespace by namespace ID or UUID
   */
  async setDefaultNamespace(namespaceId: number | string): Promise<UserNamespaceSettings> {
    return this.updateUserNamespaceSettings({ default_namespace_id: namespaceId });
  },

  // ============================================
  // User Namespace Operations
  // ============================================

  /**
   * Get all namespaces for the current user with settings
   */
  async getUserNamespaces(): Promise<UserNamespacesResponse> {
    const response = await apiClient.get<UserNamespacesResponse>(
      '/api/v2/user/namespaces'
    );
    return response.data;
  },

  /**
   * Get all namespaces for the current user (legacy - returns array only)
   */
  async getUserNamespacesList(): Promise<NamespaceWithMembership[]> {
    const response = await this.getUserNamespaces();
    return response.data || [];
  },

  /**
   * Get a specific namespace by ID
   */
  async getNamespace(id: string): Promise<NamespaceWithMembership> {
    const response = await apiClient.get<{ namespace: NamespaceWithMembership }>(
      `/api/v2/user/namespaces/${id}`
    );
    return response.data.namespace;
  },

  /**
   * Create a new namespace (user becomes owner)
   * Returns namespace, membership, and new token with namespace context
   */
  async createNamespace(data: CreateNamespaceDto): Promise<CreateNamespaceResponse> {
    const response = await apiClient.post<CreateNamespaceResponse>(
      '/api/v2/user/namespaces',
      toFormData(data as unknown as Record<string, unknown>)
    );

    // Update local storage with new namespace
    if (response.data.namespace) {
      this.setCurrentNamespace(response.data.namespace);
    }

    // Update token if provided
    if (response.data.token && typeof window !== 'undefined') {
      localStorage.setItem('auth_token', response.data.token);
    }

    return response.data;
  },

  /**
   * Switch to a different namespace
   */
  async switchNamespace(namespaceId: string): Promise<NamespaceSwitchResponse> {
    const response = await apiClient.post<NamespaceSwitchResponse>(
      `/api/v2/user/namespaces/${namespaceId}/switch`
    );

    // Update local storage with new namespace
    if (response.data.namespace) {
      this.setCurrentNamespace(response.data.namespace);
    }

    // Update token if provided
    if (response.data.token && typeof window !== 'undefined') {
      localStorage.setItem('auth_token', response.data.token);
    }

    return response.data;
  },

  // ============================================
  // Current Namespace Operations
  // ============================================

  /**
   * Get current namespace details
   */
  async getCurrentNamespace(): Promise<Namespace> {
    const response = await apiClient.get<{ namespace: Namespace }>('/api/v2/namespace');
    return response.data.namespace;
  },

  /**
   * Update current namespace
   */
  async updateCurrentNamespace(data: UpdateNamespaceDto): Promise<Namespace> {
    const response = await apiClient.put<{ namespace: Namespace }>(
      '/api/v2/namespace',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.namespace;
  },

  /**
   * Get namespace statistics
   */
  async getNamespaceStats(): Promise<NamespaceStats> {
    const response = await apiClient.get<{ stats: NamespaceStats }>('/api/v2/namespace/stats');
    return response.data.stats;
  },

  // ============================================
  // Member Management
  // ============================================

  /**
   * Get all members of current namespace
   */
  async getMembers(params?: PaginationParams & { status?: string; search?: string; role_id?: number }): Promise<PaginatedResponse<NamespaceMember>> {
    const queryString = buildQueryString((params || {}) as Record<string, unknown>);
    const response = await apiClient.get<PaginatedResponse<NamespaceMember>>(
      `/api/v2/namespace/members${queryString}`
    );
    return response.data;
  },

  /**
   * Get a specific member
   */
  async getMember(memberId: string): Promise<NamespaceMember> {
    const response = await apiClient.get<{ member: NamespaceMember }>(
      `/api/v2/namespace/members/${memberId}`
    );
    return response.data.member;
  },

  /**
   * Invite a new member to the namespace
   */
  async inviteMember(data: InviteMemberDto): Promise<NamespaceMember> {
    const response = await apiClient.post<{ member: NamespaceMember }>(
      '/api/v2/namespace/members',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.member;
  },

  /**
   * Update member (change roles, status)
   */
  async updateMember(memberId: string, data: { role_ids?: number[]; status?: string }): Promise<NamespaceMember> {
    const response = await apiClient.put<{ member: NamespaceMember }>(
      `/api/v2/namespace/members/${memberId}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.member;
  },

  /**
   * Remove a member from namespace
   */
  async removeMember(memberId: string): Promise<void> {
    await apiClient.delete(`/api/v2/namespace/members/${memberId}`);
  },

  /**
   * Transfer ownership to another member
   */
  async transferOwnership(memberId: string): Promise<void> {
    await apiClient.post(`/api/v2/namespace/members/${memberId}/transfer-ownership`);
  },

  /**
   * Leave the current namespace
   */
  async leaveNamespace(): Promise<void> {
    await apiClient.post('/api/v2/namespace/leave');
  },

  // ============================================
  // Role Management
  // ============================================

  /**
   * Get all roles in current namespace
   */
  async getRoles(params?: { include_member_count?: boolean }): Promise<NamespaceRole[]> {
    const queryString = buildQueryString((params || {}) as Record<string, unknown>);
    const response = await apiClient.get<{ roles: NamespaceRole[] }>(
      `/api/v2/namespace/roles${queryString}`
    );
    return response.data.roles;
  },

  /**
   * Get a specific role
   */
  async getRole(roleId: string): Promise<NamespaceRole> {
    const response = await apiClient.get<{ role: NamespaceRole }>(
      `/api/v2/namespace/roles/${roleId}`
    );
    return response.data.role;
  },

  /**
   * Create a new role
   */
  async createRole(data: CreateNamespaceRoleDto): Promise<NamespaceRole> {
    const response = await apiClient.post<{ role: NamespaceRole }>(
      '/api/v2/namespace/roles',
      toFormData({
        ...data,
        permissions: data.permissions ? JSON.stringify(data.permissions) : undefined,
      } as unknown as Record<string, unknown>)
    );
    return response.data.role;
  },

  /**
   * Update a role
   */
  async updateRole(roleId: string, data: UpdateNamespaceRoleDto): Promise<NamespaceRole> {
    const response = await apiClient.put<{ role: NamespaceRole }>(
      `/api/v2/namespace/roles/${roleId}`,
      toFormData({
        ...data,
        permissions: data.permissions ? JSON.stringify(data.permissions) : undefined,
      } as unknown as Record<string, unknown>)
    );
    return response.data.role;
  },

  /**
   * Delete a role
   */
  async deleteRole(roleId: string): Promise<void> {
    await apiClient.delete(`/api/v2/namespace/roles/${roleId}`);
  },

  /**
   * Get available modules and actions for permissions
   */
  async getPermissionsMeta(): Promise<{ modules: NamespaceModuleMeta[]; actions: NamespaceActionMeta[] }> {
    const response = await apiClient.get<{ modules: NamespaceModuleMeta[]; actions: NamespaceActionMeta[] }>(
      '/api/v2/namespace/roles/meta/permissions'
    );
    return response.data;
  },

  // ============================================
  // Local Storage Management
  // ============================================

  /**
   * Get current namespace from local storage
   */
  getCurrentNamespaceFromStorage(): Namespace | null {
    if (typeof window === 'undefined') return null;
    const data = localStorage.getItem(NAMESPACE_KEY);
    if (!data) return null;
    try {
      return JSON.parse(data);
    } catch {
      return null;
    }
  },

  /**
   * Set current namespace in local storage
   */
  setCurrentNamespace(namespace: Namespace | null): void {
    if (typeof window === 'undefined') return;
    if (namespace) {
      localStorage.setItem(NAMESPACE_KEY, JSON.stringify(namespace));
    } else {
      localStorage.removeItem(NAMESPACE_KEY);
    }
  },

  /**
   * Clear namespace from local storage
   */
  clearNamespace(): void {
    if (typeof window === 'undefined') return;
    localStorage.removeItem(NAMESPACE_KEY);
  },

  /**
   * Get user namespace settings from local storage
   */
  getUserNamespaceSettingsFromStorage(): UserNamespaceSettings | null {
    if (typeof window === 'undefined') return null;
    const data = localStorage.getItem(USER_NAMESPACE_SETTINGS_KEY);
    if (!data) return null;
    try {
      return JSON.parse(data);
    } catch {
      return null;
    }
  },

  /**
   * Set user namespace settings in local storage
   */
  setUserNamespaceSettingsInStorage(settings: UserNamespaceSettings | null): void {
    if (typeof window === 'undefined') return;
    if (settings) {
      localStorage.setItem(USER_NAMESPACE_SETTINGS_KEY, JSON.stringify(settings));
    } else {
      localStorage.removeItem(USER_NAMESPACE_SETTINGS_KEY);
    }
  },

  /**
   * Clear all namespace-related data from local storage
   */
  clearAllNamespaceData(): void {
    if (typeof window === 'undefined') return;
    localStorage.removeItem(NAMESPACE_KEY);
    localStorage.removeItem(USER_NAMESPACE_SETTINGS_KEY);
  },

  // ============================================
  // Permission Helpers
  // ============================================

  /**
   * Parse permissions from string or object
   */
  parsePermissions(permissions: string | NamespacePermissions | undefined): NamespacePermissions {
    if (!permissions) {
      return {} as NamespacePermissions;
    }
    if (typeof permissions === 'string') {
      try {
        return JSON.parse(permissions);
      } catch {
        return {} as NamespacePermissions;
      }
    }
    return permissions;
  },

  /**
   * Check if permissions include a specific action on a module
   */
  hasPermission(
    permissions: NamespacePermissions | undefined,
    module: keyof NamespacePermissions,
    action: string
  ): boolean {
    if (!permissions) return false;
    const modulePerms = permissions[module];
    if (!modulePerms || !Array.isArray(modulePerms)) return false;
    return modulePerms.includes(action as never) || modulePerms.includes('manage' as never);
  },

  // ============================================
  // Admin Operations (Platform Level)
  // ============================================

  /**
   * Get all namespaces (admin only)
   */
  async getAllNamespaces(params?: PaginationParams & { status?: string; search?: string }): Promise<PaginatedResponse<Namespace>> {
    const queryString = buildQueryString((params || {}) as Record<string, unknown>);
    const response = await apiClient.get<PaginatedResponse<Namespace>>(
      `/api/v2/admin/namespaces${queryString}`
    );
    return response.data;
  },

  /**
   * Get single namespace by ID (admin only)
   */
  async getNamespaceById(id: string | number): Promise<Namespace> {
    const response = await apiClient.get<{ namespace: Namespace }>(
      `/api/v2/admin/namespaces/${id}`
    );
    return response.data.namespace;
  },

  /**
   * Create namespace (admin only)
   */
  async createNamespaceAdmin(data: CreateNamespaceDto & {
    owner_uuid?: string;
    status?: string;
    plan?: string;
    max_users?: number;
    max_stores?: number;
  }): Promise<{ namespace: Namespace; membership: NamespaceMember }> {
    const response = await apiClient.post<{
      message: string;
      namespace: Namespace;
      membership: NamespaceMember;
    }>(
      '/api/v2/admin/namespaces',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data;
  },

  /**
   * Update namespace (admin only)
   */
  async updateNamespaceAdmin(id: string | number, data: Partial<CreateNamespaceDto> & {
    status?: string;
    plan?: string;
    max_users?: number;
    max_stores?: number;
  }): Promise<Namespace> {
    const response = await apiClient.put<{ message: string; namespace: Namespace }>(
      `/api/v2/admin/namespaces/${id}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.namespace;
  },

  /**
   * Delete/Archive namespace (admin only)
   */
  async deleteNamespaceAdmin(id: string | number): Promise<void> {
    await apiClient.delete(`/api/v2/admin/namespaces/${id}`);
  },

  /**
   * Get namespace statistics (admin only)
   */
  async getNamespaceStatsAdmin(id: string | number): Promise<NamespaceStats> {
    const response = await apiClient.get<{ stats: NamespaceStats }>(
      `/api/v2/admin/namespaces/${id}/stats`
    );
    return response.data.stats;
  },

  /**
   * Transfer namespace ownership (admin only)
   */
  async transferOwnershipAdmin(namespaceId: string | number, newOwnerUuid: string): Promise<void> {
    await apiClient.post(
      `/api/v2/admin/namespaces/${namespaceId}/transfer-ownership`,
      toFormData({ new_owner_uuid: newOwnerUuid })
    );
  },
};

export default namespaceService;
