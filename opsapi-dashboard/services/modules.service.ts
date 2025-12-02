import apiClient from '@/lib/api-client';
import type { Module, PaginatedResponse, PaginationParams } from '@/types';

export interface ModuleFilters extends PaginationParams {
  search?: string;
}

export const modulesService = {
  /**
   * Get all modules with pagination
   */
  async getModules(params: ModuleFilters = {}): Promise<PaginatedResponse<Module>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.offset = (params.page - 1) * (params.perPage || 100);
    if (params.perPage) queryParams.limit = params.perPage;

    const response = await apiClient.get('/api/v2/modules', { params: queryParams });

    return {
      data: response.data?.data || [],
      total: response.data?.total || 0,
      page: params.page || 1,
      perPage: params.perPage || 100,
      totalPages: Math.ceil((response.data?.total || 0) / (params.perPage || 100)),
    };
  },

  /**
   * Get a single module by UUID
   */
  async getModule(uuid: string): Promise<Module> {
    const response = await apiClient.get(`/api/v2/modules/${uuid}`);
    return response.data;
  },

  /**
   * Create a new module
   */
  async createModule(data: {
    name: string;
    machine_name: string;
    description?: string;
    icon?: string;
  }): Promise<Module> {
    const response = await apiClient.post('/api/v2/modules', data);
    return response.data;
  },

  /**
   * Update an existing module
   */
  async updateModule(
    uuid: string,
    data: { name?: string; description?: string; icon?: string }
  ): Promise<Module> {
    const response = await apiClient.put(`/api/v2/modules/${uuid}`, data);
    return response.data;
  },

  /**
   * Delete a module
   */
  async deleteModule(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/modules/${uuid}`);
  },
};

export default modulesService;
