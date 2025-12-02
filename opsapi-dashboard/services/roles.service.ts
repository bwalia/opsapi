import apiClient from '@/lib/api-client';
import type { Role, PaginatedResponse, PaginationParams } from '@/types';

export interface RoleFilters extends PaginationParams {
  search?: string;
}

export const rolesService = {
  /**
   * Get all roles with pagination
   */
  async getRoles(params: RoleFilters = {}): Promise<PaginatedResponse<Role>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.offset = (params.page - 1) * (params.perPage || 100);
    if (params.perPage) queryParams.limit = params.perPage;

    const response = await apiClient.get('/api/v2/roles', { params: queryParams });

    return {
      data: response.data?.data || [],
      total: response.data?.total || 0,
      page: params.page || 1,
      perPage: params.perPage || 100,
      totalPages: Math.ceil((response.data?.total || 0) / (params.perPage || 100)),
    };
  },

  /**
   * Get a single role by UUID
   */
  async getRole(uuid: string): Promise<Role> {
    const response = await apiClient.get(`/api/v2/roles/${uuid}`);
    return response.data;
  },

  /**
   * Create a new role
   */
  async createRole(data: { name: string; description?: string }): Promise<Role> {
    const response = await apiClient.post('/api/v2/roles', data);
    return response.data;
  },

  /**
   * Update an existing role
   */
  async updateRole(
    uuid: string,
    data: { name?: string; description?: string }
  ): Promise<Role> {
    const response = await apiClient.put(`/api/v2/roles/${uuid}`, data);
    return response.data;
  },

  /**
   * Delete a role
   */
  async deleteRole(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/roles/${uuid}`);
  },

  /**
   * Get all roles as options for select dropdowns
   */
  async getRoleOptions(): Promise<{ value: string; label: string }[]> {
    const response = await this.getRoles({ perPage: 100 });
    return response.data.map((role) => ({
      value: role.role_name,
      label: formatRoleName(role.role_name),
    }));
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
    administrative: 'bg-purple-100 text-purple-700 border-purple-200',
    admin: 'bg-purple-100 text-purple-700 border-purple-200',
    seller: 'bg-blue-100 text-blue-700 border-blue-200',
    buyer: 'bg-green-100 text-green-700 border-green-200',
    delivery_partner: 'bg-orange-100 text-orange-700 border-orange-200',
    manager: 'bg-indigo-100 text-indigo-700 border-indigo-200',
  };
  return colors[roleName.toLowerCase()] || 'bg-secondary-100 text-secondary-700 border-secondary-200';
}

export default rolesService;
