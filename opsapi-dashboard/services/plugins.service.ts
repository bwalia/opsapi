import apiClient, { buildQueryString } from '@/lib/api-client';

/**
 * Plugin pages client. A backend plugin (projects/<plugin>/, see PLUGINS.md)
 * that declares a resource with `sdk.crud` gets a generic list/form page at
 * /dashboard/plugins/<plugin>/<resource>. The page is driven by the resource's
 * schema (fields, columns, filters, the caller's rights), so new plugins need
 * no dashboard rebuild. Backed by lapis/routes/plugins.lua + helper/plugin-sdk.lua.
 */

export type PluginFieldType =
  'string' | 'text' | 'integer' | 'number' | 'boolean' | 'date' | 'datetime' | 'email' | 'uuid' | 'json';

export interface PluginField {
  name: string;
  label: string;
  type: PluginFieldType;
  required: boolean;
  enum?: string[];
  min?: number;
  max?: number;
}

export interface PluginResourceSchema {
  plugin: { code: string; name: string };
  key: string;
  label: string;
  module: string;
  api_path: string;
  fields: PluginField[];
  columns: string[];
  filters: PluginField[];
  searchable: boolean;
  sortable: string[];
  can: { create: boolean; update: boolean; delete: boolean };
}

export type PluginRecord = Record<string, unknown> & { uuid: string };

export interface PluginPageMeta {
  page: number;
  per_page: number;
  total: number;
  total_pages: number;
}

export interface PluginListParams {
  page?: number;
  per_page?: number;
  q?: string;
  sort?: string;
  order?: 'asc' | 'desc';
  /** Filter values keyed by field name. */
  filters?: Record<string, string>;
}

const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;

function unwrap<T>(response: { data: unknown }): T {
  const body = response.data as { data?: T };
  return (body?.data ?? body) as T;
}

export const pluginService = {
  async getResource(plugin: string, resource: string): Promise<PluginResourceSchema> {
    const res = await apiClient.get(
      `/api/v2/plugins/${encodeURIComponent(plugin)}/resources/${encodeURIComponent(resource)}`
    );
    return unwrap<PluginResourceSchema>(res);
  },

  async list(
    schema: PluginResourceSchema,
    { filters, ...params }: PluginListParams
  ): Promise<{ data: PluginRecord[]; meta: PluginPageMeta }> {
    const res = await apiClient.get(`${schema.api_path}${buildQueryString({ ...params, ...filters })}`);
    const body = res.data as { data?: PluginRecord[]; meta?: PluginPageMeta };
    return {
      data: Array.isArray(body?.data) ? body.data : [],
      meta: body?.meta ?? {
        page: 1,
        per_page: params.per_page ?? 20,
        total: 0,
        total_pages: 0,
      },
    };
  },

  async create(schema: PluginResourceSchema, payload: Record<string, unknown>): Promise<PluginRecord> {
    return unwrap<PluginRecord>(await apiClient.post(schema.api_path, payload, JSON_BODY));
  },

  async update(schema: PluginResourceSchema, uuid: string, payload: Record<string, unknown>): Promise<PluginRecord> {
    return unwrap<PluginRecord>(
      await apiClient.put(`${schema.api_path}/${encodeURIComponent(uuid)}`, payload, JSON_BODY)
    );
  },

  async remove(schema: PluginResourceSchema, uuid: string): Promise<void> {
    await apiClient.delete(`${schema.api_path}/${encodeURIComponent(uuid)}`);
  },
};
