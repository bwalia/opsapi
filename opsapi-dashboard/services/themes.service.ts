import apiClient, { toFormData } from '@/lib/api-client';
import type {
  Theme,
  ThemeDetail,
  ThemeResolved,
  ThemeRevision,
  ThemeSchema,
  ThemeListMeta,
  ThemeListParams,
  ThemeCreateInput,
  ThemeUpdateInput,
  ThemePreset,
} from '@/types/theme';

type Envelope<T> = { success: boolean; data: T; meta?: ThemeListMeta; error?: string };

function unwrap<T>(payload: unknown): T {
  if (payload && typeof payload === 'object' && 'data' in (payload as Record<string, unknown>)) {
    return (payload as Envelope<T>).data;
  }
  return payload as T;
}

function unwrapList<T>(payload: unknown): { items: T[]; meta: ThemeListMeta } {
  if (payload && typeof payload === 'object') {
    const env = payload as Envelope<T[]>;
    const items = Array.isArray(env.data) ? env.data : [];
    return { items, meta: env.meta ?? { total: items.length } };
  }
  return { items: [], meta: { total: 0 } };
}

export const themesService = {
  async list(params: ThemeListParams = {}): Promise<{ items: Theme[]; meta: ThemeListMeta }> {
    const response = await apiClient.get('/api/v2/themes', { params });
    return unwrapList<Theme>(response.data);
  },

  async listPresets(project_code?: string): Promise<ThemePreset[]> {
    const response = await apiClient.get('/api/v2/themes/presets', {
      params: project_code ? { project_code } : undefined,
    });
    return unwrap<ThemePreset[]>(response.data) || [];
  },

  async listMarketplace(params: ThemeListParams = {}): Promise<{ items: Theme[]; meta: ThemeListMeta }> {
    const response = await apiClient.get('/api/v2/themes/marketplace', { params });
    return unwrapList<Theme>(response.data);
  },

  async getSchema(): Promise<ThemeSchema> {
    const response = await apiClient.get('/api/v2/themes/schema');
    return unwrap<ThemeSchema>(response.data);
  },

  async getActive(project_code?: string): Promise<ThemeResolved> {
    const response = await apiClient.get('/api/v2/themes/active', {
      params: project_code ? { project_code } : undefined,
    });
    return unwrap<ThemeResolved>(response.data);
  },

  async get(uuid: string): Promise<ThemeDetail> {
    const response = await apiClient.get(`/api/v2/themes/${uuid}`);
    return unwrap<ThemeDetail>(response.data);
  },

  async create(input: ThemeCreateInput): Promise<ThemeDetail> {
    const response = await apiClient.post(
      '/api/v2/themes',
      toFormData(input as unknown as Record<string, unknown>)
    );
    return unwrap<ThemeDetail>(response.data);
  },

  async install(source_uuid: string, project_code?: string): Promise<ThemeDetail> {
    const response = await apiClient.post(
      `/api/v2/themes/install/${source_uuid}`,
      toFormData(project_code ? { project_code } : {})
    );
    return unwrap<ThemeDetail>(response.data);
  },

  async update(uuid: string, input: ThemeUpdateInput): Promise<ThemeDetail> {
    const response = await apiClient.put(
      `/api/v2/themes/${uuid}`,
      toFormData(input as unknown as Record<string, unknown>)
    );
    return unwrap<ThemeDetail>(response.data);
  },

  async remove(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/themes/${uuid}`);
  },

  async activate(uuid: string): Promise<ThemeDetail> {
    const response = await apiClient.post(`/api/v2/themes/${uuid}/activate`, '');
    return unwrap<ThemeDetail>(response.data);
  },

  async duplicate(uuid: string, name?: string): Promise<ThemeDetail> {
    const response = await apiClient.post(
      `/api/v2/themes/${uuid}/duplicate`,
      toFormData(name ? { name } : {})
    );
    return unwrap<ThemeDetail>(response.data);
  },

  async revert(uuid: string, revision_uuid: string): Promise<ThemeDetail> {
    const response = await apiClient.post(
      `/api/v2/themes/${uuid}/revert`,
      toFormData({ revision_uuid })
    );
    return unwrap<ThemeDetail>(response.data);
  },

  async listRevisions(uuid: string): Promise<ThemeRevision[]> {
    const response = await apiClient.get(`/api/v2/themes/${uuid}/revisions`);
    return unwrap<ThemeRevision[]>(response.data) || [];
  },

  async publish(uuid: string): Promise<ThemeDetail> {
    const response = await apiClient.post(`/api/v2/themes/${uuid}/publish`, '');
    return unwrap<ThemeDetail>(response.data);
  },

  async unpublish(uuid: string): Promise<ThemeDetail> {
    const response = await apiClient.post(`/api/v2/themes/${uuid}/unpublish`, '');
    return unwrap<ThemeDetail>(response.data);
  },

  previewCssUrl(uuid: string): string {
    const base = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';
    return `${base}/api/v2/themes/${uuid}/preview.css`;
  },

  activeCssUrl(): string {
    const base = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';
    return `${base}/api/v2/themes/active/styles.css`;
  },
};

export default themesService;
