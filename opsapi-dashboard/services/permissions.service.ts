import apiClient from '@/lib/api-client';
import type {
  Permission,
  PaginatedResponse,
  PaginationParams,
  DashboardModule,
  PermissionAction,
  UserPermissions,
} from '@/types';

export interface PermissionFilters extends PaginationParams {
  role?: string;
  module?: string;
}

// Default permissions for each role
const DEFAULT_ROLE_PERMISSIONS: Record<string, UserPermissions> = {
  administrative: {
    dashboard: ['read', 'manage'],
    users: ['create', 'read', 'update', 'delete', 'manage'],
    roles: ['create', 'read', 'update', 'delete', 'manage'],
    stores: ['create', 'read', 'update', 'delete', 'manage'],
    products: ['create', 'read', 'update', 'delete', 'manage'],
    orders: ['create', 'read', 'update', 'delete', 'manage'],
    customers: ['create', 'read', 'update', 'delete', 'manage'],
    settings: ['read', 'update', 'manage'],
    namespaces: ['create', 'read', 'update', 'delete', 'manage'],
    services: ['create', 'read', 'update', 'delete', 'manage'],
  },
  seller: {
    dashboard: ['read'],
    users: [],
    roles: [],
    stores: ['create', 'read', 'update'],
    products: ['create', 'read', 'update', 'delete'],
    orders: ['read', 'update'],
    customers: ['read'],
    settings: ['read', 'update'],
    namespaces: [],
    services: ['read'],
  },
  buyer: {
    dashboard: ['read'],
    users: [],
    roles: [],
    stores: ['read'],
    products: ['read'],
    orders: ['read'],
    customers: [],
    settings: ['read', 'update'],
    namespaces: [],
    services: [],
  },
  delivery_partner: {
    dashboard: ['read'],
    users: [],
    roles: [],
    stores: [],
    products: [],
    orders: ['read', 'update'],
    customers: [],
    settings: ['read', 'update'],
    namespaces: [],
    services: [],
  },
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
   * Get permissions for a specific role from the API or defaults
   */
  async getPermissionsForRole(roleName: string): Promise<UserPermissions> {
    // Try to get permissions from API first
    try {
      const response = await this.getPermissions({ role: roleName, perPage: 100 });
      if (response.data.length > 0) {
        return parsePermissionsFromAPI(response.data);
      }
    } catch {
      // Fall back to defaults if API fails
    }

    // Return default permissions for the role
    return DEFAULT_ROLE_PERMISSIONS[roleName.toLowerCase()] || getEmptyPermissions();
  },

  /**
   * Get default permissions for a role (no API call)
   */
  getDefaultPermissions(roleName: string): UserPermissions {
    return DEFAULT_ROLE_PERMISSIONS[roleName.toLowerCase()] || getEmptyPermissions();
  },

  /**
   * Check if a role has a specific permission
   */
  hasPermission(
    permissions: UserPermissions,
    module: DashboardModule,
    action: PermissionAction
  ): boolean {
    const modulePermissions = permissions[module] || [];
    return modulePermissions.includes(action) || modulePermissions.includes('manage');
  },

  /**
   * Check if a role can access a module (has any permission)
   */
  canAccessModule(permissions: UserPermissions, module: DashboardModule): boolean {
    const modulePermissions = permissions[module] || [];
    return modulePermissions.length > 0;
  },
};

/**
 * Parse permissions from API response into UserPermissions map
 */
function parsePermissionsFromAPI(permissions: Permission[]): UserPermissions {
  const result = getEmptyPermissions();

  for (const perm of permissions) {
    const module = perm.module_machine_name as DashboardModule;
    if (module && result[module] !== undefined) {
      const actions = perm.permissions.split(',').map((a) => a.trim()) as PermissionAction[];
      result[module] = actions;
    }
  }

  return result;
}

/**
 * Get empty permissions object
 */
function getEmptyPermissions(): UserPermissions {
  return {
    dashboard: [],
    users: [],
    roles: [],
    stores: [],
    products: [],
    orders: [],
    customers: [],
    settings: [],
    namespaces: [],
    services: [],
  };
}

/**
 * All available modules for permission configuration
 */
export const DASHBOARD_MODULES: { value: DashboardModule; label: string; icon: string }[] = [
  { value: 'dashboard', label: 'Dashboard', icon: 'LayoutDashboard' },
  { value: 'users', label: 'Users', icon: 'Users' },
  { value: 'roles', label: 'Roles', icon: 'Shield' },
  { value: 'stores', label: 'Stores', icon: 'Store' },
  { value: 'products', label: 'Products', icon: 'Package' },
  { value: 'orders', label: 'Orders', icon: 'ShoppingCart' },
  { value: 'customers', label: 'Customers', icon: 'UserCheck' },
  { value: 'settings', label: 'Settings', icon: 'Settings' },
  { value: 'namespaces', label: 'Namespaces', icon: 'Building2' },
  { value: 'services', label: 'Services', icon: 'Rocket' },
];

/**
 * All available permission actions
 */
export const PERMISSION_ACTIONS: { value: PermissionAction; label: string }[] = [
  { value: 'create', label: 'Create' },
  { value: 'read', label: 'Read' },
  { value: 'update', label: 'Update' },
  { value: 'delete', label: 'Delete' },
  { value: 'manage', label: 'Full Access' },
];

export default permissionsService;
