import apiClient, { toFormData, buildQueryString } from '@/lib/api-client';

// ============================================================
// Types
// ============================================================

export type RenderTemplateType = 'cms_page' | 'domain_wslproxy' | 'domain_rule';

export interface RenderTemplate {
  uuid: string;
  name: string;
  slug: string;
  template_type: RenderTemplateType;
  content?: string;
  sample_data?: string;
  description?: string;
  is_default: boolean;
  /** Placeholder names ({{...}}) parsed from content, returned by the API. */
  placeholders?: string[];
  created_at?: string;
  updated_at?: string;
}

export interface RenderTemplateInput {
  name: string;
  slug?: string;
  template_type: RenderTemplateType;
  content?: string;
  sample_data?: string;
  description?: string;
  is_default?: boolean;
}

export interface RenderPreview {
  rendered: string;
  placeholders: string[];
}

const TYPE_LABELS: Record<RenderTemplateType, string> = {
  cms_page: 'Page layout',
  domain_wslproxy: 'Domain server (WSL Proxy JSON)',
  domain_rule: 'Domain rule (WSL Proxy JSON)',
};
export function renderTemplateTypeLabel(t: RenderTemplateType): string {
  return TYPE_LABELS[t] ?? t;
}

function unwrap<T>(response: { data?: unknown }): T {
  const body = response.data as { data?: T } | undefined;
  return (body?.data as T) ?? ([] as unknown as T);
}

// ============================================================
// Service
// ============================================================

export const renderTemplatesService = {
  async list(type?: RenderTemplateType, search?: string): Promise<RenderTemplate[]> {
    const qs = buildQueryString({ type, search });
    const response = await apiClient.get(`/api/v2/render-templates${qs}`);
    return unwrap<RenderTemplate[]>(response);
  },

  async get(uuid: string): Promise<RenderTemplate> {
    const response = await apiClient.get(`/api/v2/render-templates/${uuid}`);
    return unwrap<RenderTemplate>(response);
  },

  async create(data: RenderTemplateInput): Promise<RenderTemplate> {
    const payload: Record<string, unknown> = { ...data };
    if (data.is_default !== undefined) payload.is_default = data.is_default ? 'true' : 'false';
    const response = await apiClient.post('/api/v2/render-templates', toFormData(payload));
    return unwrap<RenderTemplate>(response);
  },

  async update(uuid: string, data: Partial<RenderTemplateInput>): Promise<RenderTemplate> {
    const payload: Record<string, unknown> = { ...data };
    if (data.is_default !== undefined) payload.is_default = data.is_default ? 'true' : 'false';
    const response = await apiClient.put(`/api/v2/render-templates/${uuid}`, toFormData(payload));
    return unwrap<RenderTemplate>(response);
  },

  async remove(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/render-templates/${uuid}`);
  },

  // Render a saved template with data (or its stored sample_data when omitted).
  async preview(uuid: string, data?: Record<string, unknown>): Promise<RenderPreview> {
    const response = await apiClient.post(
      `/api/v2/render-templates/${uuid}/preview`,
      toFormData({ data: data ? JSON.stringify(data) : undefined }),
    );
    return unwrap<RenderPreview>(response);
  },

  // Render ad-hoc content + data (live editor preview, nothing saved).
  async previewRaw(content: string, data?: Record<string, unknown>): Promise<RenderPreview> {
    const response = await apiClient.post(
      '/api/v2/render-templates/preview',
      toFormData({ content, data: data ? JSON.stringify(data) : undefined }),
    );
    return unwrap<RenderPreview>(response);
  },
};

export default renderTemplatesService;
