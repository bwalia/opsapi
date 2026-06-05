import apiClient, { buildQueryString } from '@/lib/api-client';

// ── Types ──────────────────────────────────────────────────────────────────────

export interface TaxBankAccount {
  // The list endpoint returns `uuid as id`, so `id` is the uuid STRING that all
  // bank-account endpoints (show/update/delete/upload) key on — not a numeric id.
  // `uuid` is not returned by the list; keep it optional for other responses.
  id: string;
  uuid?: string;
  user_id?: number;
  namespace_id?: number;
  bank_name: string;
  account_name?: string;
  account_number?: string;
  sort_code?: string;
  account_type?: string;
  currency?: string;
  is_primary?: boolean;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface TaxStatement {
  id: number;
  uuid: string;
  bank_account_id: number;
  user_id: number;
  namespace_id: number;
  file_url?: string;
  file_name?: string;
  file_type?: string;
  file_size?: number;
  statement_date?: string;
  start_date?: string;
  end_date?: string;
  // The API exposes workflow_step (UPLOADED/EXTRACTED/CLASSIFIED) and
  // processing_status (UPLOADED/PROCESSING/COMPLETED/ERROR), not a lowercase
  // `status`. Use statementStatus() to derive the UI status from these.
  status?: 'uploaded' | 'processing' | 'extracted' | 'classified' | 'error';
  workflow_step?: string;
  processing_status?: string;
  transaction_count?: number;
  error_message?: string;
  created_at: string;
  updated_at: string;
  bank_name?: string;
  account_number?: string;
}

// Mirrors the backend GET /api/v2/tax/transactions list item shape.
export interface TaxTransaction {
  uuid: string;
  transaction_date: string;
  description: string;
  amount: number;
  balance?: number;
  transaction_type: 'CREDIT' | 'DEBIT';
  category?: string;
  hmrc_category?: string;
  confidence_score?: number;
  is_tax_deductible?: boolean;
  is_vat_applicable?: boolean;
  vat_rate?: number;
  confirmation_status?: string;
  classification_status?: string;
  is_manually_reviewed?: boolean;
  user_notes?: string;
  created_at?: string;
  statement_uuid?: string;
  statement_file_name?: string;
  statement_tax_year?: string;
  bank_account_uuid?: string;
  bank_name?: string;
  account_name?: string;
}

export interface TaxTransactionSummary {
  total_transactions: number;
  total_income: number;
  total_expenses: number;
  pending_classification: number;
}

export interface TaxExtractionResult {
  message: string;
  parsed: number;   // total transactions read from the statement
  saved: number;    // newly inserted
  skipped: number;  // skipped as duplicates of existing rows
  failed: number;   // failed to insert
}

export interface TaxCategory {
  id: number;
  uuid: string;
  key?: string;
  name: string;
  hmrc_box?: string;
  category_type: 'income' | 'expense';
  is_deductible: boolean;
  description?: string;
  // true => seeded global category (read-only); false => owned by this namespace.
  is_global?: boolean;
}

export interface TaxCategoryInput {
  name: string;
  category_type: 'income' | 'expense';
  is_deductible?: boolean;
  description?: string;
}

export interface TaxReportCategoryBreakdown {
  category_name: string;
  category_type: string;
  total_amount: number;
  transaction_count: number;
  is_deductible: boolean;
}

export interface TaxReportHmrcBoxes {
  box_number: string;
  box_name: string;
  amount: number;
}

export interface TaxReportMonthlyTrend {
  month: string;
  income: number;
  expenses: number;
  net: number;
}

export interface TaxCalculation {
  tax_year: string;
  total_income: number;
  total_expenses: number;
  taxable_income: number;
  personal_allowance: number;
  tax_bands: Array<{
    band: string;
    rate: number;
    taxable_amount: number;
    tax_amount: number;
  }>;
  total_tax: number;
  national_insurance: number;
  total_due: number;
}

export interface TaxDashboardStats {
  total_bank_accounts: number;
  total_statements: number;
  total_transactions: number;
  classified_transactions: number;
  unclassified_transactions: number;
  total_income: number;
  total_expenses: number;
}

// Filter types
// All filtering/sorting/pagination is applied server-side; these map 1:1
// to the query params the backend's build_user_filters / SORT_COLUMNS accept.
export interface TaxTransactionFilters {
  page?: number;
  limit?: number;
  statement_id?: number;
  search?: string;
  transaction_type?: 'CREDIT' | 'DEBIT' | string;
  category?: string;
  hmrc_category?: string;
  classification_status?: 'PENDING' | 'CONFIRMED' | 'MODIFIED' | string;
  is_tax_deductible?: boolean;
  amount_min?: number;
  amount_max?: number;
  date_from?: string;
  date_to?: string;
  bank_account_id?: number;
  sort_by?: string;
  sort_order?: 'ASC' | 'DESC';
}

export interface TaxStatementFilters {
  page?: number;
  per_page?: number;
  bank_account_id?: number;
  status?: string;
}

// Paginated response
export interface PaginatedResponse<T> {
  data: T[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function buildParams(filters: Record<string, unknown> | object): Record<string, string | number> {
  const params: Record<string, string | number> = {};
  Object.entries(filters).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '' && value !== 'all') {
      params[key] = value as string | number;
    }
  });
  return params;
}

// ── Service ───────────────────────────────────────────────────────────────────

const TAX_BASE = '/api/v2/tax';

export const taxService = {
  // ── Dashboard Stats ─────────────────────────────────────────────────────────
  async getDashboardStats(): Promise<TaxDashboardStats> {
    const response = await apiClient.get(`${TAX_BASE}/dashboard/stats`);
    return response.data?.data || response.data || {};
  },

  // ── Bank Accounts ───────────────────────────────────────────────────────────
  async getBankAccounts(): Promise<TaxBankAccount[]> {
    const response = await apiClient.get(`${TAX_BASE}/bank-accounts`);
    const d = response.data;
    if (Array.isArray(d?.data)) return d.data;
    if (Array.isArray(d)) return d;
    return [];
  },

  async getBankAccount(uuid: string): Promise<TaxBankAccount> {
    const response = await apiClient.get(`${TAX_BASE}/bank-accounts/${uuid}`);
    return response.data?.data || response.data;
  },

  async createBankAccount(data: {
    bank_name: string;
    account_number?: string;
    sort_code?: string;
    account_type?: string;
    currency?: string;
  }): Promise<TaxBankAccount> {
    const params = new URLSearchParams();
    Object.entries(data).forEach(([k, v]) => {
      if (v !== undefined && v !== null) params.append(k, String(v));
    });
    const response = await apiClient.post(`${TAX_BASE}/bank-accounts`, params.toString());
    return response.data?.data || response.data;
  },

  async updateBankAccount(uuid: string, data: Partial<TaxBankAccount>): Promise<TaxBankAccount> {
    const params = new URLSearchParams();
    Object.entries(data).forEach(([k, v]) => {
      if (v !== undefined && v !== null) params.append(k, String(v));
    });
    const response = await apiClient.put(`${TAX_BASE}/bank-accounts/${uuid}`, params.toString());
    return response.data?.data || response.data;
  },

  async deleteBankAccount(uuid: string): Promise<void> {
    await apiClient.delete(`${TAX_BASE}/bank-accounts/${uuid}`);
  },

  // ── Statements ──────────────────────────────────────────────────────────────
  async getStatements(filters: TaxStatementFilters = {}): Promise<PaginatedResponse<TaxStatement>> {
    const response = await apiClient.get(`${TAX_BASE}/statements`, { params: buildParams(filters as unknown as Record<string, unknown>) });
    const d = response.data;
    return {
      data: Array.isArray(d?.data) ? d.data : [],
      total: d?.total || 0,
      page: d?.page || 1,
      per_page: d?.per_page || 20,
      total_pages: d?.total_pages || 0,
    };
  },

  async getStatement(uuid: string): Promise<TaxStatement> {
    const response = await apiClient.get(`${TAX_BASE}/statements/${uuid}`);
    return response.data?.data || response.data;
  },

  async uploadStatement(file: File, bankAccountId: string, statementDate?: string): Promise<TaxStatement> {
    const formData = new FormData();
    formData.append('file', file);
    // Backend /tax/upload identifies the account by uuid (sent as bank_account_id).
    formData.append('bank_account_id', bankAccountId);
    if (statementDate) formData.append('statement_date', statementDate);

    const response = await apiClient.post(`${TAX_BASE}/upload`, formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
      timeout: 60000,
    });
    return response.data?.data || response.data;
  },

  // The statements list returns `s.uuid as id`, so the identifier the UI holds
  // (statement.id) is the uuid STRING the backend keys delete/show/update on.
  // Accept string | number to match that loosely-typed reality (extract/classify
  // do the same), so callers can pass statement.id directly.
  async deleteStatement(uuid: string | number): Promise<void> {
    await apiClient.delete(`${TAX_BASE}/statements/${uuid}`);
  },

  // ── Extraction ──────────────────────────────────────────────────────────────
  async extractTransactions(statementId: number): Promise<TaxExtractionResult> {
    const params = new URLSearchParams();
    params.append('statement_id', String(statementId));
    const response = await apiClient.post(`${TAX_BASE}/extract`, params.toString());
    const d = response.data || {};
    return {
      message: d.message || 'Extraction complete',
      parsed: d.transactions_parsed ?? d.transactions_saved ?? 0,
      saved: d.transactions_saved ?? d.transactions_extracted ?? 0,
      skipped: d.transactions_skipped ?? 0,
      failed: d.transactions_failed ?? 0,
    };
  },

  async getExtractedTransactions(statementId: number): Promise<TaxTransaction[]> {
    const response = await apiClient.get(`${TAX_BASE}/extract/${statementId}`);
    const d = response.data;
    if (Array.isArray(d?.data)) return d.data;
    if (Array.isArray(d)) return d;
    return [];
  },

  // ── Transactions ────────────────────────────────────────────────────────────
  async getTransactions(filters: TaxTransactionFilters = {}): Promise<PaginatedResponse<TaxTransaction>> {
    const response = await apiClient.get(`${TAX_BASE}/transactions`, { params: buildParams(filters as unknown as Record<string, unknown>) });
    const d = response.data;
    // The transactions list route returns the array under `items` (and the page
    // size as `limit`), unlike most list endpoints which use `data`/`per_page`.
    // Accept both shapes so the table doesn't silently render empty when only
    // `total` is read correctly (the symptom: "60 results" header with no rows).
    const list = Array.isArray(d?.items) ? d.items : (Array.isArray(d?.data) ? d.data : []);
    return {
      data: list,
      total: d?.total || 0,
      page: d?.page || 1,
      per_page: d?.limit || d?.per_page || 25,
      total_pages: d?.total_pages || 0,
    };
  },

  // Server-side aggregate over ALL of the user's transactions (not just a page).
  async getTransactionsSummary(): Promise<TaxTransactionSummary> {
    const response = await apiClient.get(`${TAX_BASE}/transactions/summary`);
    const d = response.data;
    return {
      total_transactions: d?.total_transactions || 0,
      total_income: d?.total_income || 0,
      total_expenses: d?.total_expenses || 0,
      pending_classification: d?.pending_classification || 0,
    };
  },

  async updateTransaction(uuid: string, data: Partial<TaxTransaction>): Promise<TaxTransaction> {
    const params = new URLSearchParams();
    Object.entries(data).forEach(([k, v]) => {
      if (v !== undefined && v !== null) params.append(k, String(v));
    });
    const response = await apiClient.put(`${TAX_BASE}/transactions/${uuid}`, params.toString());
    return response.data?.data || response.data;
  },

  // ── Classification ──────────────────────────────────────────────────────────
  async classifyTransactions(
    statementId: number,
    profileType?: string,
  ): Promise<{ message: string; classified?: number; profile_type?: string }> {
    const params = new URLSearchParams();
    params.append('statement_id', String(statementId));
    // Optional per-run business profile. When provided it wins over the user's saved
    // default; when omitted the backend uses the saved default (then sole_trader).
    if (profileType) params.append('profile_type', profileType);
    // AI classification runs the LLM per transaction (a local model can take
    // several seconds each), so a whole statement easily exceeds the global
    // 30s axios timeout and the request gets cancelled. Allow up to 5 minutes.
    const response = await apiClient.post(`${TAX_BASE}/classify`, params.toString(), {
      timeout: 300000,
    });
    return response.data;
  },

  async getClassificationProviders(): Promise<Array<{ name: string; available: boolean }>> {
    const response = await apiClient.get(`${TAX_BASE}/classify/providers`);
    return response.data?.data || response.data || [];
  },

  // ── Business profile (drives classification) ─────────────────────────────────
  async getProfileOptions(): Promise<
    Array<{ profile_key: string; display_name: string; sa_form: string; filing_supported: boolean }>
  > {
    const response = await apiClient.get(`${TAX_BASE}/profiles`);
    return response.data?.data || [];
  },

  // The user's saved default business profile key (may be null if never set).
  async getDefaultProfileKey(): Promise<string | null> {
    const response = await apiClient.get(`${TAX_BASE}/profile`);
    return response.data?.default_profile_key ?? null;
  },

  async setDefaultProfileKey(profileKey: string): Promise<void> {
    await apiClient.put(`${TAX_BASE}/profile/preferences`, { default_profile_key: profileKey });
  },

  // ── Categories ──────────────────────────────────────────────────────────────
  async getCategories(): Promise<TaxCategory[]> {
    const response = await apiClient.get(`${TAX_BASE}/categories`);
    const d = response.data;
    if (Array.isArray(d?.data)) return d.data;
    if (Array.isArray(d)) return d;
    return [];
  },

  async createCategory(data: TaxCategoryInput): Promise<TaxCategory> {
    const params = new URLSearchParams();
    Object.entries(data).forEach(([k, v]) => {
      if (v !== undefined && v !== null) params.append(k, String(v));
    });
    const response = await apiClient.post(`${TAX_BASE}/categories`, params.toString());
    return response.data?.data || response.data;
  },

  async updateCategory(uuid: string, data: Partial<TaxCategoryInput>): Promise<TaxCategory> {
    const params = new URLSearchParams();
    Object.entries(data).forEach(([k, v]) => {
      if (v !== undefined && v !== null) params.append(k, String(v));
    });
    const response = await apiClient.put(`${TAX_BASE}/categories/${uuid}`, params.toString());
    return response.data?.data || response.data;
  },

  async deleteCategory(uuid: string): Promise<void> {
    await apiClient.delete(`${TAX_BASE}/categories/${uuid}`);
  },

  // ── Reports ─────────────────────────────────────────────────────────────────
  async getCategoryBreakdown(taxYear?: string): Promise<TaxReportCategoryBreakdown[]> {
    const qs = taxYear ? buildQueryString({ tax_year: taxYear }) : '';
    const response = await apiClient.get(`${TAX_BASE}/reports/category-breakdown${qs}`);
    return response.data?.data || response.data || [];
  },

  async getHmrcBoxes(taxYear?: string): Promise<TaxReportHmrcBoxes[]> {
    const qs = taxYear ? buildQueryString({ tax_year: taxYear }) : '';
    const response = await apiClient.get(`${TAX_BASE}/reports/hmrc-boxes${qs}`);
    return response.data?.data || response.data || [];
  },

  async getMonthlyTrend(taxYear?: string): Promise<TaxReportMonthlyTrend[]> {
    const qs = taxYear ? buildQueryString({ tax_year: taxYear }) : '';
    const response = await apiClient.get(`${TAX_BASE}/reports/monthly-trend${qs}`);
    return response.data?.data || response.data || [];
  },

  async getTaxCalculation(taxYear: string): Promise<TaxCalculation> {
    const params = new URLSearchParams();
    params.append('tax_year', taxYear);
    const response = await apiClient.post(`${TAX_BASE}/reports/tax-calculation`, params.toString());
    return response.data?.data || response.data;
  },
};

export default taxService;
