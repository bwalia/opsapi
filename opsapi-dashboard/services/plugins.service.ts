import apiClient, { buildQueryString } from '@/lib/api-client';

/**
 * Plugin pages client. /dashboard/plugins/<plugin>/<key> shows either
 *  - a resource: a plugin's `sdk.crud` table gets a generic list/form page,
 *    driven by its schema (fields, columns, filters, the caller's rights), or
 *  - a custom page: the plugin's own HTML (manifest `pages`), shown in a
 *    sandboxed frame (components/plugins/PluginPageFrame).
 * New plugins need no dashboard rebuild. Backed by lapis/routes/plugins.lua +
 * helper/plugin-sdk.lua; guide: PLUGINS.md §6.
 */

export type PluginFieldType =
  'string' | 'text' | 'integer' | 'number' | 'boolean' | 'date' | 'datetime' | 'email' | 'url' | 'uuid' | 'json';

export interface PluginField {
  name: string;
  label: string;
  type: PluginFieldType;
  required: boolean;
  enum?: string[];
  min?: number;
  max?: number;
}

export interface PluginRef {
  code: string;
  name: string;
  api_prefix: string;
}

export interface PluginResourceSchema {
  kind: 'resource';
  plugin: PluginRef;
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

/** A plugin's own page (manifest `pages`), shown in a sandboxed frame. */
export interface PluginPageSchema {
  kind: 'page';
  plugin: PluginRef;
  key: string;
  label: string;
  description?: string;
  module: string;
  /** Path of the page's HTML on the API server (/plugin-ui/<code>/...). */
  url: string;
  /** API prefixes the page may call: the plugin's own, then its manifest's. */
  api: string[];
  can: { read: boolean; create: boolean; update: boolean; delete: boolean };
}

export type PluginScreen = PluginResourceSchema | PluginPageSchema;

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

/** One setting a plugin's manifest declares, as this workspace has it. */
export interface WorkspacePluginSetting extends PluginField {
  description?: string;
  /** Write-only: the value is never sent back, only whether one is set. */
  secret: boolean;
  is_set?: boolean;
  /** Used when no value is stored (not for secrets). */
  default?: unknown;
  value?: unknown;
}

export interface WorkspacePluginJob {
  name: string;
  every: string;
  at?: string;
  scope: 'workspace' | 'global';
  next_run_at?: string;
  last_run_at?: string;
  last_status?: 'ok' | 'failed';
}

/** An installed plugin, on or off in this workspace, with its settings. */
export interface WorkspacePlugin {
  code: string;
  name: string;
  description?: string;
  version: string;
  enabled: boolean;
  default_enabled: boolean;
  settings: WorkspacePluginSetting[];
  jobs: WorkspacePluginJob[];
}

const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;

function unwrap<T>(response: { data: unknown }): T {
  const body = response.data as { data?: T };
  return (body?.data ?? body) as T;
}

export const pluginService = {
  async getResource(plugin: string, resource: string): Promise<PluginScreen> {
    const res = await apiClient.get(
      `/api/v2/plugins/${encodeURIComponent(plugin)}/resources/${encodeURIComponent(resource)}`
    );
    const screen = unwrap<PluginScreen>(res);
    // Servers from before custom pages don't send `kind`.
    return screen.kind === 'page' ? screen : { ...screen, kind: 'resource' };
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

  /** Workspace -> Plugins: every installed plugin, on/off here, its settings and jobs. */
  async listForWorkspace(): Promise<WorkspacePlugin[]> {
    const plugins = unwrap<WorkspacePlugin[]>(await apiClient.get('/api/v2/namespace/plugins'));
    return Array.isArray(plugins) ? plugins : [];
  },

  /**
   * Turn a plugin on/off here and/or change settings. Settings are partial:
   * only the names sent change; null clears one (back to its default).
   */
  async updateForWorkspace(
    code: string,
    change: { enabled?: boolean; settings?: Record<string, unknown> }
  ): Promise<WorkspacePlugin> {
    return unwrap<WorkspacePlugin>(
      await apiClient.put(`/api/v2/namespace/plugins/${encodeURIComponent(code)}`, change, JSON_BODY)
    );
  },
};
