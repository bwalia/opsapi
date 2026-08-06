import apiClient, { toFormData, buildQueryString } from '@/lib/api-client';

// ============================================================
// Types
// ============================================================

export type DomainStatus = 'active' | 'expiring_soon' | 'expired' | 'error' | 'pending';

export interface Domain {
  uuid: string;
  namespace_id?: number;
  domain_name: string;
  registrar?: string;
  dns_provider?: string;
  cloudflare_zone_id?: string;
  status: DomainStatus;
  registration_expires_at?: string;
  registrar_status?: string;
  ssl_expires_at?: string;
  ssl_issuer?: string;
  last_checked_at?: string;
  last_check_error?: string;
  alert_threshold_days?: number;
  auto_renew?: boolean;
  owner_user_uuid?: string;
  notes?: string;
  // WSL Proxy vhost fields
  environment?: string;
  wslproxy_rule_id?: string;
  ssl_email?: string;
  ssl_enabled?: boolean;
  ssl_auto_renew?: boolean;
  ssl_force_https?: boolean;
  ssl_staging?: boolean;
  wslproxy_root?: string;
  listen_ports?: string;
  proxy_target?: string;
  created_at: string;
  updated_at: string;
}

export interface SyncToRepoResult {
  environment: string;
  repo?: string;
  branch?: string;
  commit?: string;
  count: number;
  dry_run?: boolean;
  files: { path: string; server_name: string; content?: string }[];
}

export interface DomainStats {
  total_domains: number;
  expired: number;
  expiring_soon: number;
  errored: number;
  reg_expiring_30d: number;
  ssl_expiring_30d: number;
}

export interface DomainCredential {
  uuid: string;
  provider: string;
  label?: string;
  account_id?: string;
  email?: string;
  has_secret: boolean;
  created_at: string;
  updated_at: string;
}

export interface CloudflareZone {
  id: string;
  name: string;
  status?: string;
}

export interface CloudflareRecord {
  id: string;
  type: string;
  name: string;
  content: string;
  ttl?: number;
  proxied?: boolean;
  priority?: number;
}

export interface DomainSyncConfig {
  uuid: string;
  name: string;
  destination_type: string;
  github_repo?: string;
  github_branch?: string;
  file_path?: string;
  commit_author_name?: string;
  commit_author_email?: string;
  github_token_secret_ref?: string;
  github_token_secret_key?: string;
  opsapi_base_url?: string;
  opsapi_token_secret_key?: string;
  schedule?: string;
  is_enabled?: boolean;
  last_synced_at?: string;
  last_status?: string;
  last_error?: string;
  created_at: string;
  updated_at: string;
}

export interface DomainListParams {
  page?: number;
  perPage?: number;
  search?: string;
  status?: string;
  dnsProvider?: string;
  expiringWithinDays?: number;
  all?: boolean;
}

export interface DomainPaginatedResponse {
  data: Domain[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
}

export interface ManifestResponse {
  kind: string;
  filename: string;
  manifest: string;
  apply_hint?: string;
}

export interface PipelineStep {
  name: string;
  type: string;
  workflow?: string;
  status: 'pending' | 'running' | 'success' | 'failed';
  run_id?: number;
  run_url?: string;
  conclusion?: string;
  commit?: string;
  error?: string;
  started_at?: string;
  finished_at?: string;
}

export interface DomainSyncSettings {
  uuid?: string;
  owner?: string;
  repo?: string;
  branch?: string;
  github_integration_id?: string;
  data_base?: string;
  default_environment?: string;
}

export interface GithubIntegrationLite {
  uuid: string;
  name?: string;
  github_username?: string;
}

export interface PipelineRun {
  uuid: string;
  status: 'pending' | 'running' | 'success' | 'failed';
  environment: string;
  owner?: string;
  repo?: string;
  branch?: string;
  commit_sha?: string;
  current_step?: number;
  steps: PipelineStep[];
  error?: string;
  started_at?: string;
  finished_at?: string;
  created_at: string;
}

// ============================================================
// Helpers
// ============================================================

function buildDomainParams(params: DomainListParams): Record<string, unknown> {
  const q: Record<string, unknown> = {};
  if (params.page) q.page = params.page;
  if (params.perPage) q.per_page = params.perPage;
  if (params.search) q.search = params.search;
  if (params.status && params.status !== 'all') q.status = params.status;
  if (params.dnsProvider && params.dnsProvider !== 'all') q.dns_provider = params.dnsProvider;
  if (params.expiringWithinDays) q.expiring_within_days = params.expiringWithinDays;
  if (params.all) q.all = 'true';
  return q;
}

function parsePaginated(response: { data: unknown }): DomainPaginatedResponse {
  const d = response.data as Record<string, unknown>;
  return {
    data: Array.isArray(d?.data) ? (d.data as Domain[]) : [],
    total: (d?.meta as Record<string, number>)?.total ?? 0,
    page: (d?.meta as Record<string, number>)?.page ?? 1,
    per_page: (d?.meta as Record<string, number>)?.per_page ?? 20,
    total_pages: (d?.meta as Record<string, number>)?.total_pages ?? 0,
  };
}

function unwrap<T>(response: { data: unknown }): T {
  const d = response.data as Record<string, unknown>;
  return (d?.data ?? d) as T;
}

// ============================================================
// Service
// ============================================================

export const domainService = {
  // ---- Domains ----
  async getDomains(params: DomainListParams = {}): Promise<DomainPaginatedResponse> {
    const qs = buildQueryString(buildDomainParams(params));
    const response = await apiClient.get(`/api/v2/domains${qs}`);
    return parsePaginated(response);
  },

  async getDomain(uuid: string): Promise<Domain> {
    const response = await apiClient.get(`/api/v2/domains/${uuid}`);
    return unwrap<Domain>(response);
  },

  async createDomain(data: Record<string, unknown>): Promise<Domain> {
    const response = await apiClient.post('/api/v2/domains', toFormData(data));
    return unwrap<Domain>(response);
  },

  async updateDomain(uuid: string, data: Record<string, unknown>): Promise<Domain> {
    const response = await apiClient.put(`/api/v2/domains/${uuid}`, toFormData(data));
    return unwrap<Domain>(response);
  },

  async deleteDomain(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/domains/${uuid}`);
  },

  async refreshExpiry(uuid: string): Promise<{ domain: Domain; check: Record<string, unknown> }> {
    const response = await apiClient.post(`/api/v2/domains/${uuid}/refresh-expiry`, toFormData({}));
    return unwrap(response);
  },

  async refreshAll(): Promise<Record<string, number>> {
    const response = await apiClient.post('/api/v2/domains/refresh-expiry', toFormData({}));
    return unwrap(response);
  },

  async getStats(): Promise<DomainStats> {
    const response = await apiClient.get('/api/v2/domains/stats');
    return unwrap<DomainStats>(response);
  },

  async syncToRepo(data: Record<string, unknown>): Promise<SyncToRepoResult> {
    const response = await apiClient.post('/api/v2/domains/sync-to-repo', toFormData(data));
    return unwrap<SyncToRepoResult>(response);
  },

  // ---- Pipeline (opsapi-driven: sync → dns-reconcile → wslproxy-register → auto-tag) ----
  async runPipeline(data: Record<string, unknown>): Promise<PipelineRun> {
    const response = await apiClient.post('/api/v2/domains/pipeline/run', toFormData(data));
    return unwrap<PipelineRun>(response);
  },

  async getPipelineRun(uuid: string): Promise<PipelineRun> {
    const response = await apiClient.get(`/api/v2/domains/pipeline/runs/${uuid}`);
    return unwrap<PipelineRun>(response);
  },

  async listPipelineRuns(): Promise<PipelineRun[]> {
    const response = await apiClient.get('/api/v2/domains/pipeline/runs');
    return unwrap<PipelineRun[]>(response);
  },

  // ---- Credentials ----
  async listCredentials(): Promise<DomainCredential[]> {
    const response = await apiClient.get('/api/v2/domains/credentials');
    return unwrap<DomainCredential[]>(response);
  },

  async saveCredential(data: Record<string, unknown>): Promise<DomainCredential> {
    const response = await apiClient.post('/api/v2/domains/credentials', toFormData(data));
    return unwrap<DomainCredential>(response);
  },

  async verifyCloudflare(): Promise<{ valid: boolean; status?: string }> {
    const response = await apiClient.post('/api/v2/domains/credentials/verify', toFormData({}));
    return unwrap(response);
  },

  async deleteCredential(provider: string): Promise<void> {
    await apiClient.delete(`/api/v2/domains/credentials/${provider}`);
  },

  // ---- Cloudflare DNS ----
  async listZones(name?: string): Promise<CloudflareZone[]> {
    const qs = buildQueryString(name ? { name } : {});
    const response = await apiClient.get(`/api/v2/domains/cloudflare/zones${qs}`);
    return unwrap<CloudflareZone[]>(response);
  },

  async listRecords(uuid: string): Promise<{ zone_id: string; records: CloudflareRecord[] }> {
    const response = await apiClient.get(`/api/v2/domains/${uuid}/cloudflare/records`);
    return unwrap(response);
  },

  async createRecord(uuid: string, data: Record<string, unknown>): Promise<CloudflareRecord> {
    const response = await apiClient.post(`/api/v2/domains/${uuid}/cloudflare/records`, toFormData(data));
    return unwrap<CloudflareRecord>(response);
  },

  async updateRecord(uuid: string, recordId: string, data: Record<string, unknown>): Promise<CloudflareRecord> {
    const response = await apiClient.put(`/api/v2/domains/${uuid}/cloudflare/records/${recordId}`, toFormData(data));
    return unwrap<CloudflareRecord>(response);
  },

  async deleteRecord(uuid: string, recordId: string): Promise<void> {
    await apiClient.delete(`/api/v2/domains/${uuid}/cloudflare/records/${recordId}`);
  },

  // ---- Sync configs (k3s job) ----
  async listSyncConfigs(): Promise<DomainSyncConfig[]> {
    const response = await apiClient.get('/api/v2/domains/sync-configs');
    return unwrap<DomainSyncConfig[]>(response);
  },

  async createSyncConfig(data: Record<string, unknown>): Promise<DomainSyncConfig> {
    const response = await apiClient.post('/api/v2/domains/sync-configs', toFormData(data));
    return unwrap<DomainSyncConfig>(response);
  },

  async updateSyncConfig(uuid: string, data: Record<string, unknown>): Promise<DomainSyncConfig> {
    const response = await apiClient.put(`/api/v2/domains/sync-configs/${uuid}`, toFormData(data));
    return unwrap<DomainSyncConfig>(response);
  },

  async deleteSyncConfig(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/domains/sync-configs/${uuid}`);
  },

  async getManifest(uuid: string): Promise<ManifestResponse> {
    const response = await apiClient.get(`/api/v2/domains/sync-configs/${uuid}/manifest`);
    return unwrap<ManifestResponse>(response);
  },

  async runNow(uuid: string): Promise<ManifestResponse> {
    const response = await apiClient.post(`/api/v2/domains/sync-configs/${uuid}/run-now`, toFormData({}));
    return unwrap<ManifestResponse>(response);
  },

  // ---- Sync settings (persisted target: repo + branch + GitHub auth) ----
  async getSyncSettings(): Promise<{ settings: DomainSyncSettings | null; integration_name?: string }> {
    const response = await apiClient.get('/api/v2/domains/sync-settings');
    return unwrap(response);
  },

  async saveSyncSettings(data: Record<string, unknown>): Promise<DomainSyncSettings> {
    const response = await apiClient.put('/api/v2/domains/sync-settings', toFormData(data));
    return unwrap<DomainSyncSettings>(response);
  },

  async listGithubIntegrations(): Promise<GithubIntegrationLite[]> {
    const response = await apiClient.get('/api/v2/domains/github-integrations');
    return unwrap<GithubIntegrationLite[]>(response);
  },
};

export default domainService;
