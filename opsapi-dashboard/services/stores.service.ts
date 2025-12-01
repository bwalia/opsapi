import apiClient, { toFormData } from '@/lib/api-client';
import type { Store, PaginatedResponse, PaginationParams } from '@/types';

export const storesService = {
  async getStores(params: PaginationParams = {}): Promise<PaginatedResponse<Store>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.offset = ((params.page - 1) * (params.perPage || 10));
    if (params.perPage) queryParams.limit = params.perPage;

    const response = await apiClient.get('/api/v2/stores', { params: queryParams });

    // Handle API response - the stores endpoint returns array directly or { data, total }
    const stores = Array.isArray(response.data) ? response.data : response.data?.data || [];
    const total = response.data?.total || stores.length;

    return {
      data: stores,
      total,
      page: params.page || 1,
      perPage: params.perPage || 10,
      totalPages: Math.ceil(total / (params.perPage || 10)),
    };
  },

  async getStore(uuid: string): Promise<Store> {
    const response = await apiClient.get(`/api/v2/stores/${uuid}`);
    return response.data;
  },

  async createStore(data: Partial<Store>): Promise<Store> {
    const response = await apiClient.post(
      '/api/v2/stores',
      toFormData(data as Record<string, unknown>)
    );
    return response.data;
  },

  async updateStore(uuid: string, data: Partial<Store>): Promise<Store> {
    const response = await apiClient.put(
      `/api/v2/stores/${uuid}`,
      toFormData(data as Record<string, unknown>)
    );
    return response.data;
  },

  async deleteStore(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/stores/${uuid}`);
  },
};

export default storesService;
