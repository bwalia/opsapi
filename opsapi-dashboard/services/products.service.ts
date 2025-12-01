import apiClient, { toFormData } from '@/lib/api-client';
import type { StoreProduct, Category, PaginatedResponse, PaginationParams } from '@/types';

export interface ProductFilters extends PaginationParams {
  status?: 'active' | 'draft' | 'archived';
  storeUuid?: string;
  categoryUuid?: string;
}

export const productsService = {
  async getStoreProducts(params: ProductFilters = {}): Promise<PaginatedResponse<StoreProduct>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.offset = ((params.page - 1) * (params.perPage || 10));
    if (params.perPage) queryParams.limit = params.perPage;
    if (params.status) queryParams.status = params.status;
    if (params.storeUuid) queryParams.store_uuid = params.storeUuid;
    if (params.categoryUuid) queryParams.category_uuid = params.categoryUuid;

    const response = await apiClient.get('/api/v2/products', { params: queryParams });

    // Handle API response
    const products = Array.isArray(response.data) ? response.data : response.data?.data || [];
    const total = response.data?.total || products.length;

    return {
      data: products,
      total,
      page: params.page || 1,
      perPage: params.perPage || 10,
      totalPages: Math.ceil(total / (params.perPage || 10)),
    };
  },

  async getStoreProduct(uuid: string): Promise<StoreProduct> {
    const response = await apiClient.get(`/api/v2/products/${uuid}`);
    return response.data;
  },

  async createStoreProduct(data: Partial<StoreProduct>): Promise<StoreProduct> {
    const response = await apiClient.post(
      '/api/v2/products',
      toFormData(data as Record<string, unknown>)
    );
    return response.data;
  },

  async updateStoreProduct(uuid: string, data: Partial<StoreProduct>): Promise<StoreProduct> {
    const response = await apiClient.put(
      `/api/v2/products/${uuid}`,
      toFormData(data as Record<string, unknown>)
    );
    return response.data;
  },

  async deleteStoreProduct(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/products/${uuid}`);
  },

  // Categories
  async getCategories(params: PaginationParams = {}): Promise<PaginatedResponse<Category>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.offset = ((params.page - 1) * (params.perPage || 10));
    if (params.perPage) queryParams.limit = params.perPage;

    const response = await apiClient.get('/api/v2/categories', { params: queryParams });

    const categories = Array.isArray(response.data) ? response.data : response.data?.data || [];
    const total = response.data?.total || categories.length;

    return {
      data: categories,
      total,
      page: params.page || 1,
      perPage: params.perPage || 10,
      totalPages: Math.ceil(total / (params.perPage || 10)),
    };
  },
};

export default productsService;
