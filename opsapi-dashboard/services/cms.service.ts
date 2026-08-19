import apiClient, { toFormData, buildQueryString } from '@/lib/api-client';

// ============================================================
// Types
// ============================================================

export type PostStatus = 'draft' | 'published' | 'scheduled' | 'archived';
export type PostVisibility = 'public' | 'private';
export type PageStatus = 'draft' | 'published' | 'archived';

export interface CmsTaxonomyRef {
  uuid: string;
  name: string;
  slug: string;
}

export interface CmsCategory {
  uuid: string;
  name: string;
  slug: string;
  description?: string;
  parent_id?: number | null;
  position?: number;
  post_count?: number;
  created_at?: string;
  updated_at?: string;
}

export interface CmsTag {
  uuid: string;
  name: string;
  slug: string;
  post_count?: number;
  created_at?: string;
  updated_at?: string;
}

export const WEBHOOK_EVENTS = ['post.created', 'post.updated', 'post.deleted'] as const;
export type WebhookEvent = (typeof WEBHOOK_EVENTS)[number];

export interface CmsWebhook {
  uuid: string;
  name?: string;
  url: string;
  secret: string;         // HMAC signing secret (shown so the operator can configure the receiver)
  events: string;         // comma-separated
  active: boolean;
  last_status?: number | null;
  last_triggered_at?: string | null;
  created_at?: string;
  updated_at?: string;
}

export interface WebhookInput {
  name?: string;
  url: string;
  events?: string[] | string;
  secret?: string;
  active?: boolean;
}

export interface CmsPost {
  uuid: string;
  title: string;
  slug: string;
  excerpt?: string;
  content_html?: string;
  content_json?: string;
  featured_image_url?: string;
  status: PostStatus;
  visibility: PostVisibility;
  is_featured: boolean;
  author_uuid?: string;
  author_name?: string;
  published_at?: string | null;
  scheduled_at?: string | null;
  seo_title?: string;
  seo_description?: string;
  seo_keywords?: string;
  reading_minutes?: number;
  view_count?: number;
  category_id?: number | null;
  category?: CmsTaxonomyRef | null; // primary category (back-compat)
  categories?: CmsTaxonomyRef[]; // full set (many-to-many)
  tags?: CmsTaxonomyRef[];
  created_at?: string;
  updated_at?: string;
}

export interface CmsPage {
  uuid: string;
  title: string;
  slug: string;
  excerpt?: string;
  content_html?: string;
  content_json?: string;
  featured_image_url?: string;
  status: PageStatus;
  template?: string;
  menu_order?: number;
  show_in_nav?: boolean;
  parent_id?: number | null;
  author_uuid?: string;
  published_at?: string | null;
  seo_title?: string;
  seo_description?: string;
  seo_keywords?: string;
  created_at?: string;
  updated_at?: string;
}

export interface ListMeta {
  total: number;
  page: number;
  perPage: number;
  totalPages: number;
}

export interface PostListParams {
  page?: number;
  perPage?: number;
  status?: PostStatus | '';
  category?: string; // category uuid
  tag?: string; // tag slug
  search?: string;
  featured?: boolean;
}

export interface PostListResult {
  data: CmsPost[];
  meta: ListMeta;
}

export interface PostInput {
  title: string;
  slug?: string;
  excerpt?: string;
  content_html?: string;
  content_json?: string;
  featured_image_url?: string;
  status?: PostStatus;
  visibility?: PostVisibility;
  is_featured?: boolean;
  category_uuid?: string; // legacy single category (still accepted)
  category_uuids?: string[]; // multi-category (authoritative when present)
  tags?: string[];
  author_name?: string;
  scheduled_at?: string;
  seo_title?: string;
  seo_description?: string;
  seo_keywords?: string;
}

export interface PageInput {
  title: string;
  slug?: string;
  excerpt?: string;
  content_html?: string;
  content_json?: string;
  featured_image_url?: string;
  status?: PageStatus;
  template?: string;
  menu_order?: number;
  show_in_nav?: boolean;
  parent_uuid?: string;
  seo_title?: string;
  seo_description?: string;
  seo_keywords?: string;
}

// ============================================================
// Helpers
// ============================================================

function unwrapData<T>(response: { data?: unknown }): T {
  const body = response.data as { data?: T } | undefined;
  return (body?.data as T) ?? ([] as unknown as T);
}

// Serialize a post payload for the form-encoded body. `tags` is JSON-encoded so
// the backend's coerce_list gets a clean array (an empty [] clears the tags).
function serializePost(data: Partial<PostInput>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...data };
  if (data.tags !== undefined) out.tags = JSON.stringify(data.tags ?? []);
  if (data.category_uuids !== undefined) out.category_uuids = JSON.stringify(data.category_uuids ?? []);
  if (data.is_featured !== undefined) out.is_featured = data.is_featured ? 'true' : 'false';
  return out;
}

function serializePage(data: Partial<PageInput>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...data };
  if (data.show_in_nav !== undefined) out.show_in_nav = data.show_in_nav ? 'true' : 'false';
  return out;
}

// events → comma string (backend's normalize_events splits on comma); active → 'true'/'false'.
function serializeWebhook(data: WebhookInput): Record<string, unknown> {
  const out: Record<string, unknown> = { ...data };
  if (Array.isArray(data.events)) out.events = data.events.join(',');
  if (data.active !== undefined) out.active = data.active ? 'true' : 'false';
  return out;
}

// ============================================================
// Service
// ============================================================

export const cmsService = {
  // ---------------- Posts (blog articles) ----------------
  async getPosts(params: PostListParams = {}): Promise<PostListResult> {
    const qs = buildQueryString({
      page: params.page,
      perPage: params.perPage,
      status: params.status,
      category: params.category,
      tag: params.tag,
      search: params.search,
      featured: params.featured ? 'true' : undefined,
    });
    const response = await apiClient.get(`/api/v2/cms/posts${qs}`);
    const body = response.data as { data?: CmsPost[]; meta?: ListMeta };
    return {
      data: Array.isArray(body?.data) ? body.data : [],
      meta: body?.meta ?? { total: 0, page: 1, perPage: 20, totalPages: 1 },
    };
  },

  async getPost(uuid: string): Promise<CmsPost> {
    const response = await apiClient.get(`/api/v2/cms/posts/${uuid}`);
    return unwrapData<CmsPost>(response);
  },

  async createPost(data: PostInput): Promise<CmsPost> {
    const response = await apiClient.post('/api/v2/cms/posts', toFormData(serializePost(data)));
    return unwrapData<CmsPost>(response);
  },

  async updatePost(uuid: string, data: Partial<PostInput>): Promise<CmsPost> {
    const response = await apiClient.put(`/api/v2/cms/posts/${uuid}`, toFormData(serializePost(data)));
    return unwrapData<CmsPost>(response);
  },

  async deletePost(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/cms/posts/${uuid}`);
  },

  // ---------------- Pages (static site pages) ----------------
  async getPages(params: { status?: PageStatus | ''; search?: string } = {}): Promise<CmsPage[]> {
    const qs = buildQueryString({ status: params.status, search: params.search });
    const response = await apiClient.get(`/api/v2/cms/pages${qs}`);
    return unwrapData<CmsPage[]>(response);
  },

  async getPage(uuid: string): Promise<CmsPage> {
    const response = await apiClient.get(`/api/v2/cms/pages/${uuid}`);
    return unwrapData<CmsPage>(response);
  },

  async createPage(data: PageInput): Promise<CmsPage> {
    const response = await apiClient.post('/api/v2/cms/pages', toFormData(serializePage(data)));
    return unwrapData<CmsPage>(response);
  },

  async updatePage(uuid: string, data: Partial<PageInput>): Promise<CmsPage> {
    const response = await apiClient.put(`/api/v2/cms/pages/${uuid}`, toFormData(serializePage(data)));
    return unwrapData<CmsPage>(response);
  },

  async deletePage(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/cms/pages/${uuid}`);
  },

  // ---------------- Categories ----------------
  async getCategories(search?: string): Promise<CmsCategory[]> {
    const qs = buildQueryString({ search });
    const response = await apiClient.get(`/api/v2/cms/categories${qs}`);
    return unwrapData<CmsCategory[]>(response);
  },

  async createCategory(data: { name: string; slug?: string; description?: string; parent_uuid?: string; position?: number }): Promise<CmsCategory> {
    const response = await apiClient.post('/api/v2/cms/categories', toFormData(data));
    return unwrapData<CmsCategory>(response);
  },

  async updateCategory(uuid: string, data: { name?: string; slug?: string; description?: string; parent_uuid?: string; position?: number }): Promise<CmsCategory> {
    const response = await apiClient.put(`/api/v2/cms/categories/${uuid}`, toFormData(data));
    return unwrapData<CmsCategory>(response);
  },

  async deleteCategory(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/cms/categories/${uuid}`);
  },

  // ---------------- Tags ----------------
  async getTags(search?: string): Promise<CmsTag[]> {
    const qs = buildQueryString({ search });
    const response = await apiClient.get(`/api/v2/cms/tags${qs}`);
    return unwrapData<CmsTag[]>(response);
  },

  async createTag(data: { name: string; slug?: string }): Promise<CmsTag> {
    const response = await apiClient.post('/api/v2/cms/tags', toFormData(data));
    return unwrapData<CmsTag>(response);
  },

  async updateTag(uuid: string, data: { name?: string; slug?: string }): Promise<CmsTag> {
    const response = await apiClient.put(`/api/v2/cms/tags/${uuid}`, toFormData(data));
    return unwrapData<CmsTag>(response);
  },

  async deleteTag(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/cms/tags/${uuid}`);
  },

  // ---------------- Webhooks ----------------
  async getWebhooks(): Promise<CmsWebhook[]> {
    const response = await apiClient.get('/api/v2/cms/webhooks');
    return unwrapData<CmsWebhook[]>(response);
  },

  async createWebhook(data: WebhookInput): Promise<CmsWebhook> {
    const response = await apiClient.post('/api/v2/cms/webhooks', toFormData(serializeWebhook(data)));
    return unwrapData<CmsWebhook>(response);
  },

  async updateWebhook(uuid: string, data: WebhookInput): Promise<CmsWebhook> {
    const response = await apiClient.put(`/api/v2/cms/webhooks/${uuid}`, toFormData(serializeWebhook(data)));
    return unwrapData<CmsWebhook>(response);
  },

  async deleteWebhook(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/cms/webhooks/${uuid}`);
  },
};

export default cmsService;
