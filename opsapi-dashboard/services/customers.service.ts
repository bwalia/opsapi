import apiClient, { toFormData } from '@/lib/api-client';
import type { Customer, CreateCustomerDto, PaginatedResponse, PaginationParams } from '@/types';

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
    return response.data?.data || response.data;
  },

  async createCustomer(data: CreateCustomerDto): Promise<Customer> {
    // Prepare data for form encoding
    // addresses needs to be JSON stringified as the DB stores it as a JSON text field
    const formData: Record<string, unknown> = { ...data };
    if (data.addresses && Array.isArray(data.addresses)) {
      formData.addresses = JSON.stringify(data.addresses);
    }

    const response = await apiClient.post(
      '/api/v2/customers',
      toFormData(formData)
    );
    return response.data?.data || response.data;
  },

  async updateCustomer(uuid: string, data: Partial<CreateCustomerDto>): Promise<Customer> {
    // Prepare data for form encoding
    const formData: Record<string, unknown> = { ...data };
    if (data.addresses && Array.isArray(data.addresses)) {
      formData.addresses = JSON.stringify(data.addresses);
    }

    const response = await apiClient.put(
      `/api/v2/customers/${uuid}`,
      toFormData(formData)
    );
    return response.data?.data || response.data;
  },

  async deleteCustomer(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/customers/${uuid}`);
  },
};

export default customersService;
