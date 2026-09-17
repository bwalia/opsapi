import apiClient, { buildQueryString } from '@/lib/api-client';
import type { FsPaginated, FsPageMeta } from '@/services/field-service.service';

/**
 * Simpro-aligned CRM API client — customer assets, asset types, service levels,
 * test history, contracts, the report pack and the Simpro sync console.
 * Backed by lapis/routes/field-service-{assets,contracts,reports,simpro}.lua.
 */

const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;
const BASE = '/api/v2/field-service';

export type SimproSyncState = 'synced' | 'pending' | 'conflict' | 'error' | 'local_only';

export interface AssetReadingDef {
  key: string;
  label: string;
  unit?: string;
  type: 'number' | 'text' | 'select' | 'rating';
  options?: string[];
  required?: boolean;
}

export interface AssetType {
  uuid: string;
  name: string;
  code?: string | null;
  discipline: string;
  is_fgas: boolean;
  default_service_months?: number | null;
  readings: AssetReadingDef[];
  failure_points: { key: string; label: string }[];
  consumables: string[];
}

export interface AssetServiceLevel {
  uuid: string;
  name: string;
  kind: string;
  frequency_months: number;
  last_service_date?: string | null;
  next_service_date?: string | null;
  estimated_hours?: number | null;
  contract_name?: string | null;
}

export interface AssetTest {
  uuid: string;
  tested_at: string;
  due_date?: string | null;
  result: 'pass' | 'fail' | 'advisory' | 'not_tested';
  condition_rating?: number | null;
  technician_name?: string | null;
  readings: { key: string; label: string; value: unknown; unit?: string | null }[];
  failure_points: { key: string; label: string; severity?: string }[];
  refrigerant_type?: string | null;
  refrigerant_added_kg?: number | null;
  refrigerant_recovered_kg?: number | null;
  leak_check_result?: string | null;
  notes?: string | null;
  recommendation?: string | null;
  service_level?: string | null;
  job_number?: string | null;
}

export interface Asset {
  uuid: string;
  asset_tag?: string | null;
  name: string;
  serial_number?: string | null;
  manufacturer?: string | null;
  model?: string | null;
  location_detail?: string | null;
  installed_at?: string | null;
  warranty_expires_at?: string | null;
  condition_rating?: number | null;
  condition_notes?: string | null;
  last_surveyed_at?: string | null;
  refrigerant_type?: string | null;
  refrigerant_charge_kg?: number | null;
  refrigerant_gwp?: number | null;
  co2e_tonnes?: number | null;
  leak_check_months?: number | null;
  next_leak_check_at?: string | null;
  status: string;
  archived: boolean;
  custom_fields?: Record<string, unknown>;
  site_uuid?: string | null;
  site_name?: string | null;
  site_postcode?: string | null;
  customer_uuid?: string | null;
  customer_name?: string | null;
  asset_type_uuid?: string | null;
  asset_type?: string | null;
  discipline?: string | null;
  is_fgas?: boolean | null;
  contract_uuid?: string | null;
  contract_name?: string | null;
  parent_uuid?: string | null;
  next_service_date?: string | null;
  open_failures?: number | null;
  simpro_id?: string | null;
  simpro_sync_state?: SimproSyncState;
  simpro_synced_at?: string | null;
  service_levels?: AssetServiceLevel[];
  recent_tests?: AssetTest[];
}

export interface AssetListParams {
  page?: number;
  per_page?: number;
  search?: string;
  discipline?: string;
  condition_min?: number;
  fgas_only?: boolean;
  service_overdue?: boolean;
  customer_uuid?: string;
  site_uuid?: string;
  contract_uuid?: string;
}

export interface Contract {
  uuid: string;
  contract_number?: string | null;
  name: string;
  description?: string | null;
  status: 'draft' | 'active' | 'expired' | 'cancelled';
  start_date?: string | null;
  end_date?: string | null;
  extension_months?: number | null;
  annual_value?: number | null;
  currency: string;
  response_hours?: number | null;
  resolve_hours?: number | null;
  quote_turnaround_hours?: number | null;
  covers_out_of_hours: boolean;
  customer_uuid?: string | null;
  customer_name?: string | null;
  asset_count?: number | null;
  site_count?: number | null;
  days_to_expiry?: number | null;
  custom_fields?: { published?: string | null; assumed?: string | null };
  simpro_sync_state?: SimproSyncState;
}

export type ReportColumnType = 'text' | 'number' | 'money' | 'hours' | 'date' | 'datetime';

export interface ReportColumn {
  key: string;
  label: string;
  type: ReportColumnType;
}

export interface ReportCatalogueEntry {
  key: string;
  title: string;
  group: string;
  filters: string[];
}

export type ReportRow = Record<string, unknown>;

export interface Report {
  key: string;
  title: string;
  description: string;
  generated_at: string;
  filters: Record<string, unknown>;
  columns: ReportColumn[];
  rows: ReportRow[];
  row_count: number;
  summary: Record<string, unknown>;
  asset?: Record<string, unknown>;
  service_levels?: AssetServiceLevel[];
}

export interface ReportFilters {
  date_from?: string;
  date_to?: string;
  customer_uuid?: string;
  site_uuid?: string;
  asset_uuid?: string;
  asset_type_uuid?: string;
  contract_uuid?: string;
  months?: number;
  weeks?: number;
  expiring_within_days?: number;
}

export interface SimproCounts {
  synced: number;
  pending: number;
  errored: number;
  local_only: number;
  total: number;
}

export interface SimproStatus {
  connected: boolean;
  connection?: {
    uuid: string;
    name: string;
    base_url: string;
    company_id: string;
    mode: 'mock' | 'sandbox' | 'live';
    push_enabled: boolean;
    pull_enabled: boolean;
    is_active: boolean;
    last_pull_at?: string | null;
    last_push_at?: string | null;
    last_error?: string | null;
  };
  counts: Record<string, SimproCounts>;
  last_7_days: { status: string; n: number }[];
}

export interface SimproLogEntry {
  uuid: string;
  direction: 'push' | 'pull';
  entity_type: string;
  entity_uuid?: string | null;
  simpro_id?: string | null;
  operation: string;
  status: 'ok' | 'conflict' | 'error' | 'skipped';
  http_status?: number | null;
  error_message?: string | null;
  batch_uuid?: string | null;
  created_at: string;
}

export interface SimproSyncResult {
  batch_uuid: string;
  direction: 'push' | 'pull';
  mode: string;
  duration_seconds: number;
  results: Record<string, Record<string, number | string>>;
  failures?: Record<string, string>;
}

function unwrap<T>(response: { data: unknown }): T {
  const body = response.data as { data?: T };
  return (body?.data ?? body) as T;
}

function paginated<T>(response: { data: unknown }): FsPaginated<T> {
  const body = response.data as { data?: T[]; meta?: FsPageMeta };
  return {
    data: Array.isArray(body?.data) ? body.data : [],
    meta: body?.meta ?? { total: 0, page: 1, per_page: 20, total_pages: 0 },
  };
}

function qs(params: object): string {
  const q: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null || v === '' || v === 'all') continue;
    q[k] = typeof v === 'boolean' ? (v ? 'true' : undefined) : v;
  }
  return buildQueryString(q);
}

export const simproCrm = {
  // ---------------- Assets ----------------
  async getAssetTypes(): Promise<AssetType[]> {
    return unwrap<AssetType[]>(await apiClient.get(`${BASE}/asset-types`)) || [];
  },

  async getAssets(params: AssetListParams = {}): Promise<FsPaginated<Asset>> {
    return paginated<Asset>(await apiClient.get(`${BASE}/assets${qs(params)}`));
  },

  async getAsset(uuid: string): Promise<Asset> {
    return unwrap<Asset>(await apiClient.get(`${BASE}/assets/${uuid}`));
  },

  async recordTest(assetUuid: string, data: Record<string, unknown>): Promise<AssetTest> {
    return unwrap<AssetTest>(await apiClient.post(`${BASE}/assets/${assetUuid}/tests`, data, JSON_BODY));
  },

  // ---------------- Contracts ----------------
  async getContracts(params: { page?: number; per_page?: number; search?: string; status?: string } = {}) {
    return paginated<Contract>(await apiClient.get(`${BASE}/contracts${qs(params)}`));
  },

  // ---------------- Reports ----------------
  async getReports(): Promise<ReportCatalogueEntry[]> {
    return unwrap<ReportCatalogueEntry[]>(await apiClient.get(`${BASE}/reports`)) || [];
  },

  async runReport(key: string, filters: ReportFilters = {}): Promise<Report> {
    return unwrap<Report>(await apiClient.get(`${BASE}/reports/${key}${qs(filters)}`));
  },

  /** The same rows as runReport, as the server's CSV. Returns the file to save. */
  async downloadReportCsv(key: string, filters: ReportFilters = {}): Promise<{ blob: Blob; filename: string }> {
    const response = await apiClient.get(`${BASE}/reports/${key}${qs({ ...filters, format: 'csv' })}`, {
      responseType: 'blob',
    });
    const disposition = String(response.headers?.['content-disposition'] || '');
    const match = disposition.match(/filename="?([^";]+)"?/);
    return { blob: response.data as Blob, filename: match?.[1] || `${key}.csv` };
  },

  // ---------------- Simpro sync ----------------
  async getSimproStatus(): Promise<SimproStatus> {
    return unwrap<SimproStatus>(await apiClient.get(`${BASE}/simpro/status`));
  },

  async testSimpro(): Promise<{ mode: string; company?: string; base_url: string }> {
    return unwrap(await apiClient.post(`${BASE}/simpro/test`, {}, JSON_BODY));
  },

  async pullSimpro(entities?: string): Promise<SimproSyncResult> {
    return unwrap<SimproSyncResult>(await apiClient.post(`${BASE}/simpro/pull`, { entities }, JSON_BODY));
  },

  async pushSimpro(entities?: string): Promise<SimproSyncResult> {
    return unwrap<SimproSyncResult>(await apiClient.post(`${BASE}/simpro/push`, { entities }, JSON_BODY));
  },

  async getSimproLog(params: { page?: number; per_page?: number; status?: string; entity_type?: string } = {}) {
    return paginated<SimproLogEntry>(await apiClient.get(`${BASE}/simpro/log${qs(params)}`));
  },
};

export default simproCrm;
