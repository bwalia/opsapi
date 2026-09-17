import apiClient, { toFormData } from '@/lib/api-client';
import type { StoreProduct, Category, PaginatedResponse, PaginationParams } from '@/types';

export interface ProductFilters extends PaginationParams {
  status?: 'active' | 'draft' | 'archived';
  storeUuid?: string;
  categoryUuid?: string;
}

/**
 * The full storeproducts row as returned by GET /api/v2/products/:uuid.
 * Its column names differ from the leaner list-oriented `StoreProduct` type
 * (is_active vs status, inventory_quantity vs quantity, cost_price, …), so the
 * detail page types against this shape.
 */
export interface StoreProductDetail {
  uuid: string;
  name: string;
  slug?: string;
  sku?: string;
  barcode?: string;
  description?: string;
  short_description?: string;
  price: number;
  compare_price?: number;
  cost_price?: number;
  inventory_quantity?: number;
  total_inventory?: number;
  low_stock_threshold?: number;
  track_inventory?: boolean;
  is_active?: boolean;
  is_featured?: boolean;
  is_digital?: boolean;
  requires_shipping?: boolean;
  weight?: number;
  tags?: string;
  images?: string;
  thumbnail_url?: string;
  store_id?: number | string;
  category_id?: number | string;
  created_at?: string;
  updated_at?: string;
}

export const productsService = {
  async getStoreProducts(
    params: ProductFilters = {}
  ): Promise<PaginatedResponse<StoreProduct> & { currency?: string }> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.offset = ((params.page - 1) * (params.perPage || 10));
    if (params.perPage) queryParams.limit = params.perPage;
    if (params.status) queryParams.status = params.status;
    if (params.storeUuid) queryParams.store_uuid = params.storeUuid;
    if (params.categoryUuid) queryParams.category_uuid = params.categoryUuid;

    const response = await apiClient.get('/api/v2/products', { params: queryParams });

    // Handle API response. storeproducts rows use inventory_quantity / is_active,
    // but the list UI reads quantity / status — normalise so Stock and Status render.
    const raw = Array.isArray(response.data) ? response.data : response.data?.data || [];
    const products = raw.map((p: Record<string, unknown>) => ({
      ...p,
      quantity: (p.quantity ?? p.inventory_quantity ?? 0) as number,
      status: (p.status ?? (p.is_active === false ? 'draft' : 'active')) as 'active' | 'draft' | 'archived',
    })) as StoreProduct[];
    const total = response.data?.total || products.length;

    return {
      data: products,
      total,
      page: params.page || 1,
      perPage: params.perPage || 10,
      totalPages: Math.ceil(total / (params.perPage || 10)),
      // Store-level currency (products inherit it); undefined until first product sets it.
      currency: response.data?.currency || undefined,
    };
  },

  async getStoreProduct(uuid: string): Promise<StoreProductDetail> {
    const response = await apiClient.get(`/api/v2/products/${uuid}`);
    // The endpoint wraps the row as { permissions, data: {...} }.
    return (response.data?.data ?? response.data) as StoreProductDetail;
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

  /** Set/change the catalog's store-level currency (reused by every product). */
  async setCurrency(currency: string): Promise<string> {
    const response = await apiClient.put('/api/v2/products/currency', toFormData({ currency }));
    return response.data?.currency || currency;
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
