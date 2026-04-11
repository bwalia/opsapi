import apiClient, { toFormData, buildQueryString } from '@/lib/api-client';

// ============================================================
// Types
// ============================================================

export interface CrmAccount {
  uuid: string;
  name: string;
  industry?: string;
  website?: string;
  email?: string;
  phone?: string;
  address_line1?: string;
  address_line2?: string;
  city?: string;
  state?: string;
  postal_code?: string;
  country?: string;
  owner_uuid?: string;
  owner_name?: string;
  status: 'active' | 'inactive';
  contact_count?: number;
  deal_count?: number;
  created_at: string;
  updated_at: string;
}

export interface CrmContact {
  uuid: string;
  first_name: string;
  last_name: string;
  email?: string;
  phone?: string;
  job_title?: string;
  account_uuid?: string;
  account_name?: string;
  owner_uuid?: string;
  owner_name?: string;
  status: 'active' | 'inactive';
  created_at: string;
  updated_at: string;
}

export interface CrmDeal {
  uuid: string;
  name: string;
  account_uuid?: string;
  account_name?: string;
  contact_uuid?: string;
  contact_name?: string;
  pipeline_uuid?: string;
  pipeline_name?: string;
  stage?: string;
  value?: number;
  currency?: string;
  probability?: number;
  expected_close_date?: string;
  owner_uuid?: string;
  owner_name?: string;
  status: 'open' | 'won' | 'lost';
  created_at: string;
  updated_at: string;
}

export interface CrmPipeline {
  uuid: string;
  name: string;
  stages: string[];
  is_default?: boolean;
  created_at: string;
  updated_at: string;
}

export interface CrmActivity {
  uuid: string;
  subject: string;
  type: 'call' | 'email' | 'meeting' | 'note' | 'task';
  description?: string;
  related_type?: 'account' | 'contact' | 'deal';
  related_uuid?: string;
  related_name?: string;
  due_date?: string;
  completed_at?: string;
  owner_uuid?: string;
  owner_name?: string;
  status: 'pending' | 'completed' | 'cancelled';
  created_at: string;
  updated_at: string;
}

export interface CrmDashboardStats {
  total_accounts: number;
  active_deals: number;
  total_deal_value: number;
  activities_today: number;
}

export interface CrmListParams {
  page?: number;
  perPage?: number;
  search?: string;
  status?: string;
  stage?: string;
  type?: string;
  orderBy?: string;
  orderDir?: 'asc' | 'desc';
}

export interface CrmPaginatedResponse<T> {
  data: T[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
  has_next: boolean;
  has_prev: boolean;
}

// ============================================================
// Helper to build query params
// ============================================================

function buildCrmParams(params: CrmListParams): Record<string, unknown> {
  const q: Record<string, unknown> = {};
  if (params.page) q.page = params.page;
  if (params.perPage) q.per_page = params.perPage;
  if (params.search) q.search = params.search;
  if (params.status && params.status !== 'all') q.status = params.status;
  if (params.stage && params.stage !== 'all') q.stage = params.stage;
  if (params.type && params.type !== 'all') q.type = params.type;
  if (params.orderBy) q.order_by = params.orderBy;
  if (params.orderDir) q.order_dir = params.orderDir;
  return q;
}

function parsePaginated<T>(response: { data: unknown }): CrmPaginatedResponse<T> {
  const d = response.data as Record<string, unknown>;
  return {
    data: Array.isArray(d?.data) ? d.data as T[] : [],
    total: (d?.total as number) || 0,
    page: (d?.page as number) || 1,
    per_page: (d?.per_page as number) || 10,
    total_pages: (d?.total_pages as number) || 0,
    has_next: (d?.has_next as boolean) || false,
    has_prev: (d?.has_prev as boolean) || false,
  };
}

// ============================================================
// Service
// ============================================================

export const crmService = {
  // ----------------------------------------------------------
  // Accounts
  // ----------------------------------------------------------

  async getAccounts(params: CrmListParams = {}): Promise<CrmPaginatedResponse<CrmAccount>> {
    const qs = buildQueryString(buildCrmParams(params));
    const response = await apiClient.get(`/api/v2/crm/accounts${qs}`);
    return parsePaginated<CrmAccount>(response);
  },

  async getAccount(uuid: string): Promise<CrmAccount> {
    const response = await apiClient.get(`/api/v2/crm/accounts/${uuid}`);
    return response.data;
  },

  async createAccount(data: Record<string, unknown>): Promise<CrmAccount> {
    const response = await apiClient.post('/api/v2/crm/accounts', toFormData(data));
    return response.data;
  },

  async updateAccount(uuid: string, data: Record<string, unknown>): Promise<CrmAccount> {
    const response = await apiClient.put(`/api/v2/crm/accounts/${uuid}`, toFormData(data));
    return response.data;
  },

  async deleteAccount(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/crm/accounts/${uuid}`);
  },

  // ----------------------------------------------------------
  // Contacts
  // ----------------------------------------------------------

  async getContacts(params: CrmListParams = {}): Promise<CrmPaginatedResponse<CrmContact>> {
    const qs = buildQueryString(buildCrmParams(params));
    const response = await apiClient.get(`/api/v2/crm/contacts${qs}`);
    return parsePaginated<CrmContact>(response);
  },

  async getContact(uuid: string): Promise<CrmContact> {
    const response = await apiClient.get(`/api/v2/crm/contacts/${uuid}`);
    return response.data;
  },

  async createContact(data: Record<string, unknown>): Promise<CrmContact> {
    const response = await apiClient.post('/api/v2/crm/contacts', toFormData(data));
    return response.data;
  },

  async updateContact(uuid: string, data: Record<string, unknown>): Promise<CrmContact> {
    const response = await apiClient.put(`/api/v2/crm/contacts/${uuid}`, toFormData(data));
    return response.data;
  },

  async deleteContact(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/crm/contacts/${uuid}`);
  },

  // ----------------------------------------------------------
  // Deals
  // ----------------------------------------------------------

  async getDeals(params: CrmListParams = {}): Promise<CrmPaginatedResponse<CrmDeal>> {
    const qs = buildQueryString(buildCrmParams(params));
    const response = await apiClient.get(`/api/v2/crm/deals${qs}`);
    return parsePaginated<CrmDeal>(response);
  },

  async getDeal(uuid: string): Promise<CrmDeal> {
    const response = await apiClient.get(`/api/v2/crm/deals/${uuid}`);
    return response.data;
  },

  async createDeal(data: Record<string, unknown>): Promise<CrmDeal> {
    const response = await apiClient.post('/api/v2/crm/deals', toFormData(data));
    return response.data;
  },

  async updateDeal(uuid: string, data: Record<string, unknown>): Promise<CrmDeal> {
    const response = await apiClient.put(`/api/v2/crm/deals/${uuid}`, toFormData(data));
    return response.data;
  },

  async deleteDeal(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/crm/deals/${uuid}`);
  },

  async getDealsByPipeline(pipelineUuid: string): Promise<CrmPaginatedResponse<CrmDeal>> {
    const response = await apiClient.get(`/api/v2/crm/pipelines/${pipelineUuid}/deals`);
    return parsePaginated<CrmDeal>(response);
  },

  async getDashboardStats(): Promise<CrmDashboardStats> {
    const response = await apiClient.get('/api/v2/crm/dashboard/stats');
    return response.data;
  },

  // ----------------------------------------------------------
  // Pipelines
  // ----------------------------------------------------------

  async getPipelines(): Promise<CrmPipeline[]> {
    const response = await apiClient.get('/api/v2/crm/pipelines');
    return Array.isArray(response.data?.data) ? response.data.data : [];
  },

  async getPipeline(uuid: string): Promise<CrmPipeline> {
    const response = await apiClient.get(`/api/v2/crm/pipelines/${uuid}`);
    return response.data;
  },

  async createPipeline(data: Record<string, unknown>): Promise<CrmPipeline> {
    const response = await apiClient.post('/api/v2/crm/pipelines', toFormData(data));
    return response.data;
  },

  async updatePipeline(uuid: string, data: Record<string, unknown>): Promise<CrmPipeline> {
    const response = await apiClient.put(`/api/v2/crm/pipelines/${uuid}`, toFormData(data));
    return response.data;
  },

  async deletePipeline(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/crm/pipelines/${uuid}`);
  },

  // ----------------------------------------------------------
  // Activities
  // ----------------------------------------------------------

  async getActivities(params: CrmListParams = {}): Promise<CrmPaginatedResponse<CrmActivity>> {
    const qs = buildQueryString(buildCrmParams(params));
    const response = await apiClient.get(`/api/v2/crm/activities${qs}`);
    return parsePaginated<CrmActivity>(response);
  },

  async createActivity(data: Record<string, unknown>): Promise<CrmActivity> {
    const response = await apiClient.post('/api/v2/crm/activities', toFormData(data));
    return response.data;
  },

  async updateActivity(uuid: string, data: Record<string, unknown>): Promise<CrmActivity> {
    const response = await apiClient.put(`/api/v2/crm/activities/${uuid}`, toFormData(data));
    return response.data;
  },

  async deleteActivity(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/crm/activities/${uuid}`);
  },

  async completeActivity(uuid: string): Promise<CrmActivity> {
    const response = await apiClient.put(`/api/v2/crm/activities/${uuid}/complete`, toFormData({}));
    return response.data;
  },
};

export default crmService;
