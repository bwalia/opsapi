/**
 * Product variations (sizes, colours, …) for staff: lapis/queries/CatalogVariantQueries.lua
 * (/api/v2/catalog/products/:uuid/variants, /api/v2/catalog/variants/:uuid; RBAC products).
 */
import apiClient from '@/lib/api-client';

export interface CatalogVariant {
  uuid: string;
  title: string;
  option1: string | null;
  option2: string | null;
  option3: string | null;
  sku: string | null;
  /** Its own price, or null to use the product's. */
  price: string | null;
  effective_price: string;
  stock: number;
  is_active: boolean;
  position: number;
}

export interface CatalogVariantInput {
  title?: string;
  option1?: string;
  option2?: string;
  option3?: string;
  sku?: string;
  price?: string | null;
  stock?: number;
  is_active?: boolean;
}

const JSON_BODY = { headers: { 'Content-Type': 'application/json' } };

export const catalogVariantsService = {
  async list(productUuid: string): Promise<{ product: { uuid: string; name: string; price: string; track_inventory: boolean }; variants: CatalogVariant[] }> {
    const res = await apiClient.get(`/api/v2/catalog/products/${productUuid}/variants`);
    return res.data.data;
  },
  async create(productUuid: string, body: CatalogVariantInput): Promise<CatalogVariant> {
    const res = await apiClient.post(`/api/v2/catalog/products/${productUuid}/variants`, body, JSON_BODY);
    return res.data.data;
  },
  async update(uuid: string, body: CatalogVariantInput): Promise<CatalogVariant> {
    const res = await apiClient.put(`/api/v2/catalog/variants/${uuid}`, body, JSON_BODY);
    return res.data.data;
  },
  async remove(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/catalog/variants/${uuid}`);
  },
};
