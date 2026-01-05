import apiClient from '@/lib/api-client';
import type { PaginatedResponse, PaginationParams } from '@/types';

// Namespace Role type (different from legacy global Role)
export interface NamespaceRole {
  id: number;
  uuid: string;
  namespace_id: number;
  role_name: string;
  display_name: string;
  description?: string;
  permissions?: Record<string, string[]> | string;
  is_system: boolean;
  is_default: boolean;
  priority: number;
  member_count?: number;
  created_at?: string;
  updated_at?: string;
}

export interface RoleFilters extends PaginationParams {
  search?: string;
}

export interface CreateRoleData {
  role_name: string;
  display_name?: string;
  description?: string;
  permissions?: Record<string, string[]>;
  is_default?: boolean;
  priority?: number;
}

export interface UpdateRoleData {
  role_name?: string;
  display_name?: string;
  description?: string;
  permissions?: Record<string, string[]>;
  is_default?: boolean;
  priority?: number;
}

export const rolesService = {
  /**
   * Get all roles for the current namespace
   * Uses the namespace context from the JWT token (X-Namespace-Id header)
   */
  async getRoles(params: RoleFilters = {}): Promise<PaginatedResponse<NamespaceRole>> {
    const response = await apiClient.get('/api/v2/namespace/roles');

    const roles = response.data?.data || [];

    return {
      data: roles,
      total: response.data?.total || roles.length,
      page: params.page || 1,
      perPage: params.perPage || 100,
      totalPages: 1,
    };
  },

  /**
   * Get a single role by ID
   */
  async getRole(id: string | number): Promise<{ role: NamespaceRole; members?: unknown[] }> {
    const response = await apiClient.get(`/api/v2/namespace/roles/${id}`);
    return response.data;
  },

  /**
   * Create a new role in the current namespace
   */
  async createRole(data: CreateRoleData): Promise<{ message: string; role: NamespaceRole }> {
    const response = await apiClient.post('/api/v2/namespace/roles', data);
    return response.data;
  },

  /**
   * Update an existing role
   */
  async updateRole(id: string | number, data: UpdateRoleData): Promise<{ message: string; role: NamespaceRole }> {
    const response = await apiClient.put(`/api/v2/namespace/roles/${id}`, data);
    return response.data;
  },

  /**
   * Delete a role
   */
  async deleteRole(id: string | number): Promise<{ message: string }> {
    const response = await apiClient.delete(`/api/v2/namespace/roles/${id}`);
    return response.data;
  },

  /**
   * Get all roles as options for select dropdowns
   */
  async getRoleOptions(): Promise<{ value: string; label: string; id: number }[]> {
    const response = await this.getRoles({ perPage: 100 });
    return response.data.map((role) => ({
      value: role.role_name,
      label: role.display_name || formatRoleName(role.role_name),
      id: role.id,
    }));
  },

  /**
   * Get available modules and actions for permissions
   */
  async getPermissionsMeta(): Promise<{ modules: string[]; actions: string[] }> {
    const response = await apiClient.get('/api/v2/namespace/roles/meta/permissions');
    return response.data;
  },
};

/**
 * Format role name for display (e.g., "delivery_partner" -> "Delivery Partner")
 */
export function formatRoleName(roleName: string): string {
  return roleName
    .split('_')
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');
}

/**
 * Get role badge color based on role name
 */
export function getRoleColor(roleName: string): string {
  const colors: Record<string, string> = {
    owner: 'bg-red-100 text-red-700 border-red-200',
    admin: 'bg-purple-100 text-purple-700 border-purple-200',
    administrative: 'bg-purple-100 text-purple-700 border-purple-200',
    manager: 'bg-indigo-100 text-indigo-700 border-indigo-200',
    member: 'bg-blue-100 text-blue-700 border-blue-200',
    viewer: 'bg-gray-100 text-gray-700 border-gray-200',
    seller: 'bg-blue-100 text-blue-700 border-blue-200',
    buyer: 'bg-green-100 text-green-700 border-green-200',
    delivery_partner: 'bg-orange-100 text-orange-700 border-orange-200',
    customer: 'bg-teal-100 text-teal-700 border-teal-200',
  };
  return colors[roleName.toLowerCase()] || 'bg-secondary-100 text-secondary-700 border-secondary-200';
}

export default rolesService;
