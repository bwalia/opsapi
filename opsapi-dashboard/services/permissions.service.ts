import apiClient from '@/lib/api-client';
import type {
  Permission,
  PaginatedResponse,
  PaginationParams,
  PermissionAction,
  UserPermissions,
} from '@/types';

export interface PermissionFilters extends PaginationParams {
  role?: string;
  module?: string;
}

// Module metadata from API
export interface ModuleMeta {
  value: string;
  label: string;
  icon: string;
  description?: string;
  category?: string;
}

// Default icon mapping for common modules (fallback when API doesn't provide one)
const DEFAULT_MODULE_ICONS: Record<string, string> = {
  dashboard: 'LayoutDashboard',
  users: 'Users',
  roles: 'Shield',
  stores: 'Store',
  products: 'Package',
  orders: 'ShoppingCart',
  customers: 'UserCheck',
  settings: 'Settings',
  namespaces: 'Building2',
  namespace: 'Building2',
  services: 'Rocket',
  chat: 'MessageCircle',
  delivery: 'Truck',
  reports: 'BarChart',
  projects: 'Kanban',
  vault: 'Lock',
  notifications: 'Bell',
  media: 'Image',
};

export const permissionsService = {
  /**
   * Get all permissions with pagination
   */
  async getPermissions(params: PermissionFilters = {}): Promise<PaginatedResponse<Permission>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.offset = (params.page - 1) * (params.perPage || 10);
    if (params.perPage) queryParams.limit = params.perPage;
    if (params.role) queryParams.role = params.role;
    if (params.module) queryParams.module = params.module;

    const response = await apiClient.get('/api/v2/permissions', { params: queryParams });

    // Ensure data is always an array (API may return {} for empty results)
    const rawData = response.data?.data;
    const data = Array.isArray(rawData) ? rawData : [];

    return {
      data,
      total: response.data?.total || 0,
      page: params.page || 1,
      perPage: params.perPage || 10,
      totalPages: Math.ceil((response.data?.total || 0) / (params.perPage || 10)),
    };
  },

  /**
   * Get a single permission by UUID
   */
  async getPermission(uuid: string): Promise<Permission> {
    const response = await apiClient.get(`/api/v2/permissions/${uuid}`);
    return response.data;
  },

  /**
   * Create a new permission
   */
  async createPermission(data: {
    role: string;
    module_machine_name: string;
    permissions: string;
  }): Promise<Permission> {
    const response = await apiClient.post('/api/v2/permissions', data);
    return response.data;
  },

  /**
   * Update an existing permission
   */
  async updatePermission(
    uuid: string,
    data: { permissions?: string }
  ): Promise<Permission> {
    const response = await apiClient.put(`/api/v2/permissions/${uuid}`, data);
    return response.data;
  },

  /**
   * Delete a permission
   */
  async deletePermission(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/permissions/${uuid}`);
  },

  /**
   * Batch update permissions for a role (single API call)
   * This is the recommended method for updating role permissions efficiently
   */
  async batchUpdatePermissions(
    roleName: string,
    permissions: UserPermissions
  ): Promise<{ message: string; updated: number; created: number; deleted: number }> {
    const response = await apiClient.post('/api/v2/permissions/batch', {
      role: roleName,
      permissions: JSON.stringify(permissions),
    });
    return response.data;
  },

  /**
   * Get permissions for a specific role from the API
   */
  async getPermissionsForRole(roleName: string): Promise<UserPermissions> {
    try {
      const response = await this.getPermissions({ role: roleName, perPage: 100 });
      if (response.data.length > 0) {
        return parsePermissionsFromAPI(response.data);
      }
    } catch {
      // Fall back to empty permissions if API fails
    }

    return getEmptyPermissions();
  },

  /**
   * Check if a role has a specific permission
   */
  hasPermission(
    permissions: UserPermissions,
    module: string,
    action: PermissionAction
  ): boolean {
    const raw = permissions[module];
    const modulePermissions = Array.isArray(raw) ? raw : [];
    return modulePermissions.includes(action) || modulePermissions.includes('manage');
  },

  /**
   * Check if a role can access a module (has any permission)
   */
  canAccessModule(permissions: UserPermissions, module: string): boolean {
    const raw = permissions[module];
    const modulePermissions = Array.isArray(raw) ? raw : [];
    return modulePermissions.length > 0;
  },

  /**
   * Fetch available modules from API (for permission UIs)
   */
  async fetchAvailableModules(): Promise<ModuleMeta[]> {
    try {
      const response = await apiClient.get('/api/v2/modules/available');
      const modules = response.data?.modules || [];
      return modules.map((m: { machine_name: string; name: string; description?: string; category?: string }) => ({
        value: m.machine_name,
        label: m.name,
        icon: DEFAULT_MODULE_ICONS[m.machine_name] || 'Box',
        description: m.description || '',
        category: m.category || 'General',
      }));
    } catch {
      return [];
    }
  },

  /**
   * Fetch namespace-scoped modules from permissions meta API
   */
  async fetchNamespaceModules(): Promise<ModuleMeta[]> {
    try {
      const response = await apiClient.get('/api/v2/namespace/roles/meta/permissions');
      const modules = response.data?.modules || [];
      return modules.map((m: { name: string; display_name: string; description?: string; category?: string }) => ({
        value: m.name,
        label: m.display_name,
        icon: DEFAULT_MODULE_ICONS[m.name] || 'Box',
        description: m.description || '',
        category: m.category || 'General',
      }));
    } catch {
      return [];
    }
  },
};

/**
 * Parse permissions from API response into UserPermissions map
 * Accepts all modules — no filtering against hardcoded list
 */
const VALID_ACTIONS: readonly string[] = ['create', 'read', 'update', 'delete', 'manage'];

function parsePermissionsFromAPI(permissions: Permission[]): UserPermissions {
  const result: UserPermissions = {};

  for (const perm of permissions) {
    const module = perm.module_machine_name;
    if (module) {
      const actions = perm.permissions
        .split(',')
        .map((a) => a.trim())
        .filter((a) => VALID_ACTIONS.includes(a)) as PermissionAction[];
      result[module] = actions;
    }
  }

  return result;
}

/**
 * Get empty permissions object (dynamic — no hardcoded modules)
 * Optionally accepts a module list to pre-populate keys
 */
function getEmptyPermissions(modules?: string[]): UserPermissions {
  const result: UserPermissions = {};
  if (modules) {
    for (const mod of modules) {
      result[mod] = [];
    }
  }
  return result;
}

/**
 * All available permission actions (these are truly fixed)
 */
export const PERMISSION_ACTIONS: { value: PermissionAction; label: string }[] = [
  { value: 'create', label: 'Create' },
  { value: 'read', label: 'Read' },
  { value: 'update', label: 'Update' },
  { value: 'delete', label: 'Delete' },
  { value: 'manage', label: 'Full Access' },
];

export { getEmptyPermissions };
export default permissionsService;
