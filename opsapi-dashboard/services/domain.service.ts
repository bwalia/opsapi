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
  rule_path?: string;
  server_template_uuid?: string;
  rule_template_uuid?: string;
  // Which managed repo this domain syncs to (blank -> namespace default repo).
  sync_repo_uuid?: string;
  created_at: string;
  updated_at: string;
}

/** A managed GitHub repo a namespace can sync domains to (beyond the default). */
export interface DomainSyncRepo {
  uuid: string;
  name?: string;
  owner: string;
  repo: string;
  branch?: string;
  github_integration_id?: string;
}

/** One repo group's result — the sync groups domains by resolved repo and opens
 *  one PR per repo, so each entry is an independent success/failure. */
export interface RepoSyncResult {
  repo: string;
  repo_name?: string;
  branch: string;
  ok: boolean;
  error?: string;
  /** The PR target (base) branch — changes are never pushed here directly. */
  base_branch?: string;
  /** The head branch the sync committed to (created off base). */
  head_branch?: string;
  commit?: string;
  pr_url?: string;
  pr_number?: number;
  count?: number;
  rules?: number;
  warnings?: string[];
  /** Attached rules already present in the repo (reused, not re-pushed). */
  skipped?: { rule_id: string; path: string; reason: string }[];
  files?: { path: string; server_name: string; content?: string }[];
}

export interface SyncToRepoResult {
  environment: string;
  dry_run?: boolean;
  any_failed?: boolean;
  repos: RepoSyncResult[];
}

export interface WslproxyStatus {
  connected: boolean;
  api_url?: string;
  email?: string;
  has_secret?: boolean;
  connected_at?: string;
}

/** A shared WSL Proxy rule, as returned by the control-plane API. */
export interface WslproxyRule {
  id: string;
  name?: string;
  profile_id?: string;
  [key: string]: unknown;
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
  // Write-only convenience: paste a repo URL and the backend derives
  // owner/repo (and branch). owner/repo are what the API stores + returns.
  repo_url?: string;
  owner?: string;
  repo?: string;
  branch?: string;
  github_integration_id?: string;
  data_base?: string;
  default_environment?: string;
  // Rule generation. default_backend is used when a domain has no proxy_target;
  // sync_rules toggles emitting rule files at all.
  default_backend?: string;
  default_rule_id?: string;
  sync_rules?: boolean;
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

  // Every domain (uuid, name, environment, assigned repo) with no page cap —
  // for the sync modal's assignment matrix.
  async listAllDomains(): Promise<Pick<Domain, 'uuid' | 'domain_name' | 'environment' | 'sync_repo_uuid'>[]> {
    const response = await apiClient.get('/api/v2/domains/all');
    return unwrap<Pick<Domain, 'uuid' | 'domain_name' | 'environment' | 'sync_repo_uuid'>[]>(response);
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

  // Sync selected domains, each to its assigned repo (one PR per repo). The
  // api-client posts form-urlencoded, so the structured fields (domain_uuids
  // array, assignments map) are sent as JSON STRINGS — the backend decodes them.
  async syncToRepo(data: {
    environment?: string;
    dry_run?: boolean;
    domain_uuids?: string[];
    assignments?: Record<string, string>;
    message?: string;
  }): Promise<SyncToRepoResult> {
    const payload: Record<string, unknown> = {
      environment: data.environment,
      dry_run: data.dry_run ? 'true' : 'false',
      domain_uuids: JSON.stringify(data.domain_uuids ?? []),
      assignments: JSON.stringify(data.assignments ?? {}),
    };
    if (data.message) payload.message = data.message;
    const response = await apiClient.post('/api/v2/domains/sync-to-repo', toFormData(payload));
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

  // ---- Managed sync repos (multi-repo targets) ----
  async listSyncRepos(): Promise<DomainSyncRepo[]> {
    const response = await apiClient.get('/api/v2/domains/sync-repos');
    return unwrap<DomainSyncRepo[]>(response);
  },

  async createSyncRepo(data: { name?: string; repo_url?: string; owner?: string; repo?: string; branch?: string; github_integration_id?: string }): Promise<DomainSyncRepo> {
    const response = await apiClient.post('/api/v2/domains/sync-repos', toFormData(data));
    return unwrap<DomainSyncRepo>(response);
  },

  async updateSyncRepo(uuid: string, data: Record<string, unknown>): Promise<DomainSyncRepo> {
    const response = await apiClient.put(`/api/v2/domains/sync-repos/${uuid}`, toFormData(data));
    return unwrap<DomainSyncRepo>(response);
  },

  async deleteSyncRepo(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/domains/sync-repos/${uuid}`);
  },

  // ---- WSL Proxy connection + shared rules ----
  async getWslproxyStatus(): Promise<WslproxyStatus> {
    const response = await apiClient.get('/api/v2/domains/wslproxy/status');
    return unwrap<WslproxyStatus>(response);
  },

  async connectWslproxy(data: { api_url: string; email?: string; password: string }): Promise<WslproxyStatus> {
    const response = await apiClient.post('/api/v2/domains/wslproxy/connect', toFormData(data));
    return unwrap<WslproxyStatus>(response);
  },

  async disconnectWslproxy(): Promise<void> {
    await apiClient.delete('/api/v2/domains/wslproxy/disconnect');
  },

  /** Searchable list of shared rules for the domain form's rule dropdown,
   *  optionally scoped to an environment (rule profile_id). */
  async listWslproxyRules(search?: string, environment?: string): Promise<WslproxyRule[]> {
    const qs = buildQueryString({ search: search || undefined, environment: environment || undefined });
    const response = await apiClient.get(`/api/v2/domains/wslproxy/rules${qs}`);
    return unwrap<WslproxyRule[]>(response);
  },
};

export default domainService;
