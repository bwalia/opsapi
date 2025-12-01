import apiClient, { toFormData } from '@/lib/api-client';
import type { Customer, PaginatedResponse, PaginationParams } from '@/types';

export interface CustomerFilters extends PaginationParams {
  storeUuid?: string;
}

export const customersService = {
  async getCustomers(params: CustomerFilters = {}): Promise<PaginatedResponse<Customer>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.offset = ((params.page - 1) * (params.perPage || 10));
    if (params.perPage) queryParams.limit = params.perPage;
    if (params.storeUuid) queryParams.store_uuid = params.storeUuid;

    const response = await apiClient.get('/api/v2/customers', { params: queryParams });

    // Handle API response
    const customers = Array.isArray(response.data) ? response.data : response.data?.data || [];
    const total = response.data?.total || customers.length;

    return {
      data: customers,
      total,
      page: params.page || 1,
      perPage: params.perPage || 10,
      totalPages: Math.ceil(total / (params.perPage || 10)),
    };
  },

  async getCustomer(uuid: string): Promise<Customer> {
    const response = await apiClient.get(`/api/v2/customers/${uuid}`);
    return response.data;
  },

  async createCustomer(data: Partial<Customer>): Promise<Customer> {
    const response = await apiClient.post(
      '/api/v2/customers',
      toFormData(data as Record<string, unknown>)
    );
    return response.data;
  },

  async updateCustomer(uuid: string, data: Partial<Customer>): Promise<Customer> {
    const response = await apiClient.put(
      `/api/v2/customers/${uuid}`,
      toFormData(data as Record<string, unknown>)
    );
    return response.data;
  },

  async deleteCustomer(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/customers/${uuid}`);
  },
};

export default customersService;
