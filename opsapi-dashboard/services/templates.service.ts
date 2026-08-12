import apiClient, { toFormData, buildQueryString } from '@/lib/api-client';

// The API wraps single objects as { success, data }. Unwrap to the inner object
// (tolerating a already-unwrapped body). Returning the envelope was leaving every
// field undefined on the client (empty PROPERTIES, uncontrolled inputs, blank
// preview, broken save).
function unwrap<T>(response: { data?: unknown }): T {
  const body = response.data as { data?: T } | undefined;
  return (body && 'data' in body ? (body.data as T) : (body as unknown as T));
}

// Template type
export type TemplateType = 'invoice' | 'timesheet';

// Template filters for server-side filtering
export interface TemplateFilters {
  page?: number;
  perPage?: number;
  type?: TemplateType | 'all';
  search?: string;
  orderBy?: 'created_at' | 'updated_at' | 'name';
  orderDir?: 'asc' | 'desc';
}

// Document template
export interface DocumentTemplate {
  id: number;
  uuid: string;
  type: TemplateType;
  name: string;
  description?: string;
  is_default: boolean;
  template_html: string;
  template_css?: string;
  header_html?: string;
  footer_html?: string;
  config: Record<string, unknown>;
  page_size: string;
  page_orientation: string;
  margin_top: string;
  margin_bottom: string;
  margin_left: string;
  margin_right: string;
  version: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

// Template version history entry
export interface TemplateVersion {
  version: number;
  created_at: string;
  updated_by?: string;
  change_summary?: string;
}

// Template variable for insertion
export interface TemplateVariable {
  path: string;
  description: string;
  example: string;
}

// Paginated response from API
export interface TemplatesResponse {
  data: DocumentTemplate[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
  has_next: boolean;
  has_prev: boolean;
}

// Create/update template payload
export interface TemplatePayload {
  name: string;
  type: TemplateType;
  description?: string;
  template_html?: string;
  template_css?: string;
  header_html?: string;
  footer_html?: string;
  config?: Record<string, unknown>;
  page_size?: string;
  page_orientation?: string;
  margin_top?: string;
  margin_bottom?: string;
  margin_left?: string;
  margin_right?: string;
  is_active?: boolean;
}

export const templatesService = {
  /**
   * Get templates with server-side pagination and filtering
   */
  async getTemplates(params: TemplateFilters = {}): Promise<TemplatesResponse> {
    const queryParams: Record<string, string | number> = {};

    if (params.page) queryParams.page = params.page;
    if (params.perPage) queryParams.per_page = params.perPage;
    if (params.type && params.type !== 'all') queryParams.type = params.type;
    if (params.search) queryParams.search = params.search;
    if (params.orderBy) queryParams.order_by = params.orderBy;
    if (params.orderDir) queryParams.order_dir = params.orderDir;

    const response = await apiClient.get('/api/v2/templates', { params: queryParams });

    const data = Array.isArray(response.data?.data) ? response.data.data : [];

    return {
      data,
      total: response.data?.total || 0,
      page: response.data?.page || params.page || 1,
      per_page: response.data?.per_page || params.perPage || 10,
      total_pages: response.data?.total_pages || 0,
      has_next: response.data?.has_next || false,
      has_prev: response.data?.has_prev || false,
    };
  },

  /**
   * Get single template by UUID
   */
  async getTemplate(uuid: string): Promise<DocumentTemplate> {
    const response = await apiClient.get(`/api/v2/templates/${uuid}`);
    return unwrap<DocumentTemplate>(response);
  },

  /**
   * Create a new template
   */
  async createTemplate(data: TemplatePayload): Promise<DocumentTemplate> {
    const response = await apiClient.post(
      '/api/v2/templates',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return unwrap<DocumentTemplate>(response);
  },

  /**
   * Update an existing template
   */
  async updateTemplate(uuid: string, data: Partial<TemplatePayload>): Promise<DocumentTemplate> {
    const response = await apiClient.put(
      `/api/v2/templates/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return unwrap<DocumentTemplate>(response);
  },

  /**
   * Delete a template
   */
  async deleteTemplate(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/templates/${uuid}`);
  },

  /**
   * Clone a template with a new name
   */
  async cloneTemplate(uuid: string, name: string): Promise<DocumentTemplate> {
    const response = await apiClient.post(
      `/api/v2/templates/${uuid}/clone`,
      toFormData({ name })
    );
    return unwrap<DocumentTemplate>(response);
  },

  /**
   * Set a template as the default for its type
   */
  async setDefault(uuid: string): Promise<DocumentTemplate> {
    const response = await apiClient.post(`/api/v2/templates/${uuid}/set-default`);
    return unwrap<DocumentTemplate>(response);
  },

  /**
   * Get version history for a template
   */
  async getVersions(uuid: string): Promise<TemplateVersion[]> {
    const response = await apiClient.get(`/api/v2/templates/${uuid}/versions`);
    return response.data?.data || [];
  },

  /**
   * Restore a template to a specific version
   */
  async restoreVersion(uuid: string, version: number): Promise<DocumentTemplate> {
    const response = await apiClient.post(
      `/api/v2/templates/${uuid}/versions/${version}/restore`
    );
    return unwrap<DocumentTemplate>(response);
  },

  /**
   * Preview a template rendered with sample data
   */
  async previewTemplate(uuid: string, data?: Record<string, unknown>): Promise<{ html: string }> {
    const response = await apiClient.post(
      `/api/v2/templates/${uuid}/preview`,
      toFormData({ data: JSON.stringify(data ?? {}) }),
    );
    const d = unwrap<{ rendered_html?: string; html?: string }>(response);
    return { html: d?.rendered_html ?? d?.html ?? '' };
  },

  /**
   * Preview raw HTML with data (without saving)
   */
  async previewRaw(html: string, data: Record<string, unknown>): Promise<{ html: string }> {
    const response = await apiClient.post(
      '/api/v2/templates/preview-raw',
      toFormData({ template_html: html, data: JSON.stringify(data ?? {}) }),
    );
    const d = unwrap<{ rendered_html?: string; html?: string }>(response);
    return { html: d?.rendered_html ?? d?.html ?? '' };
  },

  /**
   * Get available template variables for a given type
   */
  async getVariables(type: TemplateType): Promise<TemplateVariable[]> {
    const response = await apiClient.get(`/api/v2/templates/variables/${type}`);
    return response.data?.data || [];
  },

  /**
   * Generate PDF for an invoice using a template
   */
  async generateInvoicePdf(invoiceUuid: string, templateUuid?: string): Promise<Blob> {
    const query = templateUuid ? buildQueryString({ template_uuid: templateUuid }) : '';
    const response = await apiClient.get(
      `/api/v2/invoices/${invoiceUuid}/pdf${query}`,
      { responseType: 'blob' }
    );
    return response.data;
  },

  /**
   * Generate PDF for a timesheet using a template
   */
  async generateTimesheetPdf(timesheetUuid: string, templateUuid?: string): Promise<Blob> {
    const query = templateUuid ? buildQueryString({ template_uuid: templateUuid }) : '';
    const response = await apiClient.get(
      `/api/v2/timesheets/${timesheetUuid}/pdf${query}`,
      { responseType: 'blob' }
    );
    return response.data;
  },
};

export default templatesService;
