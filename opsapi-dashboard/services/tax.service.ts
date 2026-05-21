import apiClient, { buildQueryString } from '@/lib/api-client';

// ── Types ──────────────────────────────────────────────────────────────────────

export interface TaxBankAccount {
  id: number;
  uuid: string;
  user_id: number;
  namespace_id: number;
  bank_name: string;
  account_number?: string;
  sort_code?: string;
  account_type?: string;
  currency?: string;
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
  /** Legacy/optional — backend does not emit this; use processing_status/workflow_step. */
  status?: 'uploaded' | 'processing' | 'extracted' | 'classified' | 'error';
  /** Backend pipeline stage (UPPERCASE): UPLOADED → EXTRACTED → CLASSIFIED. */
  workflow_step?: string;
  /** Backend processing state (UPPERCASE): UPLOADED | CLASSIFYING | COMPLETED | ERROR. */
  processing_status?: string;
  transaction_count?: number;
  error_message?: string;
  created_at: string;
  updated_at: string;
  bank_name?: string;
  account_number?: string;
}

export interface TaxTransaction {
  id: number;
  uuid: string;
  statement_id: number;
  user_id: number;
  namespace_id: number;
  transaction_date: string;
  description: string;
  amount: number;
  balance?: number;
  transaction_type: 'credit' | 'debit';
  /** Category key/slug (the backend stores & returns `category`, e.g. "office_supplies"). */
  category?: string;
  category_id?: number;
  category_name?: string;
  hmrc_category?: string;
  confidence?: number;
  confidence_score?: number;
  classification_status?: string;
  classification_source?: string;
  is_tax_deductible?: boolean;
  is_business: boolean;
  is_verified: boolean;
  notes?: string;
  created_at: string;
  updated_at: string;
}

export interface TaxCategory {
  id: number;
  uuid: string;
  /** Snake_case identifier, e.g. "office_supplies". */
  key?: string;
  /** Display name. The API also returns this as `name` for compatibility. */
  label?: string;
  name: string;
  /** 'income' | 'expense'. Also returned as `category_type`. */
  type?: 'income' | 'expense';
  category_type?: 'income' | 'expense';
  is_tax_deductible?: boolean;
  is_deductible?: boolean;
  deduction_rate?: number;
  hmrc_category_id?: number;
  hmrc_box?: string;
  description?: string;
  examples?: string;
  is_active?: boolean;
}

export interface TaxCategoryInput {
  label: string;
  type: 'income' | 'expense';
  description?: string;
  is_tax_deductible?: boolean;
  key?: string;
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
export interface TaxTransactionFilters {
  page?: number;
  per_page?: number;
  statement_id?: number;
  category_id?: number;
  transaction_type?: string;
  is_verified?: boolean;
  is_business?: boolean;
  search?: string;
  date_from?: string;
  date_to?: string;
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

function normalizeList<T>(response: { data?: { data?: T[] } & T[] }): T[] {
  const d = response.data;
  if (!d) return [];
  if (Array.isArray(d)) return d;
  if (d && typeof d === 'object' && 'data' in d && Array.isArray((d as Record<string, unknown>).data)) {
    return (d as Record<string, unknown>).data as T[];
  }
  return [];
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

  // bankAccountId is the bank account's UUID (the list API returns `uuid as id`).
  // The upload route accepts it as bank_account_id and resolves it as the UUID.
  async uploadStatement(file: File, bankAccountId: string | number, statementDate?: string): Promise<TaxStatement> {
    const formData = new FormData();
    formData.append('file', file);
    formData.append('bank_account_id', String(bankAccountId));
    if (statementDate) formData.append('statement_date', statementDate);

    const response = await apiClient.post(`${TAX_BASE}/upload`, formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
      timeout: 60000,
    });
    return response.data?.data || response.data;
  },

  async deleteStatement(uuid: string): Promise<void> {
    await apiClient.delete(`${TAX_BASE}/statements/${uuid}`);
  },

  // ── Extraction ──────────────────────────────────────────────────────────────
  async extractTransactions(statementId: number): Promise<{ message: string; count?: number }> {
    const params = new URLSearchParams();
    params.append('statement_id', String(statementId));
    const response = await apiClient.post(`${TAX_BASE}/extract`, params.toString());
    return response.data;
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
    // The transactions list route returns the array under `items` (and `limit`),
    // unlike most list endpoints which use `data`/`per_page`. Accept both so the
    // dashboard works regardless of which shape the API emits.
    const list = Array.isArray(d?.items) ? d.items : (Array.isArray(d?.data) ? d.data : []);
    return {
      data: list,
      total: d?.total || 0,
      page: d?.page || 1,
      per_page: d?.limit || d?.per_page || 20,
      total_pages: d?.total_pages || 0,
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
  async classifyTransactions(statementId: number): Promise<{ message: string; classified?: number }> {
    const params = new URLSearchParams();
    params.append('statement_id', String(statementId));
    const response = await apiClient.post(`${TAX_BASE}/classify`, params.toString());
    return response.data;
  },

  async getClassificationProviders(): Promise<Array<{ name: string; available: boolean }>> {
    const response = await apiClient.get(`${TAX_BASE}/classify/providers`);
    return response.data?.data || response.data || [];
  },

  // ── Categories ──────────────────────────────────────────────────────────────
  async getCategories(opts: { includeInactive?: boolean } = {}): Promise<TaxCategory[]> {
    const params = opts.includeInactive ? { include_inactive: 'true' } : undefined;
    const response = await apiClient.get(`${TAX_BASE}/categories`, { params });
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

  async updateCategory(uuid: string, data: Partial<TaxCategoryInput> & { is_active?: boolean }): Promise<TaxCategory> {
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
