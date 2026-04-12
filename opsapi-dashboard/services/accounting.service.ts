import apiClient, { toFormData, buildQueryString } from '@/lib/api-client';

// ── Types ──────────────────────────────────────────────────────────────────────

export interface AccountingAccount {
  id: number;
  uuid: string;
  code: string;
  name: string;
  account_type: 'asset' | 'liability' | 'equity' | 'revenue' | 'expense';
  sub_type?: string;
  description?: string;
  is_system: boolean;
  is_active: boolean;
  normal_balance: 'debit' | 'credit';
  current_balance: number;
  parent_id?: number;
  depth: number;
  created_at: string;
}

export interface JournalEntry {
  id: number;
  uuid: string;
  entry_number: string;
  entry_date: string;
  description: string;
  reference?: string;
  status: string;
  total_amount: number;
  lines?: JournalLine[];
  created_at: string;
}

export interface JournalLine {
  id: number;
  account_id: number;
  account_code?: string;
  account_name?: string;
  debit_amount: number;
  credit_amount: number;
  description?: string;
}

export interface BankTransaction {
  id: number;
  uuid: string;
  transaction_date: string;
  description: string;
  amount: number;
  balance?: number;
  transaction_type: string;
  category?: string;
  is_reconciled: boolean;
  ai_category_suggestion?: string;
  ai_vat_suggestion?: string;
  ai_confidence?: number;
  created_at: string;
}

export interface Expense {
  id: number;
  uuid: string;
  expense_date: string;
  description: string;
  amount: number;
  category: string;
  vendor?: string;
  vat_rate: number;
  vat_amount: number;
  is_vat_reclaimable: boolean;
  status: string;
  receipt_url?: string;
  created_at: string;
}

export interface VatReturn {
  id: number;
  uuid: string;
  period_start: string;
  period_end: string;
  status: string;
  box1_vat_due_sales: number;
  box2_vat_due_acquisitions: number;
  box3_total_vat_due: number;
  box4_vat_reclaimed: number;
  box5_net_vat: number;
  box6_total_sales: number;
  box7_total_purchases: number;
  created_at: string;
}

export interface TrialBalance {
  accounts: Array<{
    code: string;
    name: string;
    account_type: string;
    total_debits: number;
    total_credits: number;
    net_balance: number;
  }>;
  total_debits: number;
  total_credits: number;
  is_balanced: boolean;
}

export interface BalanceSheet {
  assets: Array<{ code: string; name: string; balance: number }>;
  liabilities: Array<{ code: string; name: string; balance: number }>;
  equity: Array<{ code: string; name: string; balance: number }>;
  total_assets: number;
  total_liabilities: number;
  total_equity: number;
  as_of_date: string;
}

export interface ProfitAndLoss {
  revenue: Array<{ code: string; name: string; amount: number }>;
  expenses: Array<{ code: string; name: string; amount: number }>;
  total_revenue: number;
  total_expenses: number;
  net_profit: number;
  period_start: string;
  period_end: string;
}

export interface ExpenseSummary {
  categories: Array<{ category: string; total: number; count: number }>;
  total: number;
  period_start: string;
  period_end: string;
}

export interface DashboardStats {
  cash_balance: number;
  expenses_this_month: number;
  vat_owed: number;
  unreconciled_count: number;
  total_revenue: number;
  total_expenses: number;
}

export interface AiCategorization {
  category: string;
  account_code: string;
  confidence: number;
  reasoning: string;
}

export interface AiVatSuggestion {
  vat_rate: number;
  vat_amount: number;
  is_reclaimable: boolean;
  reasoning: string;
}

export interface AiQueryResponse {
  answer: string;
  data?: unknown;
}

export interface AiStatusResponse {
  available: boolean;
  model?: string;
}

// Pagination response
export interface PaginatedResponse<T> {
  data: T[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
  has_next: boolean;
  has_prev: boolean;
}

// Filter types
export interface AccountFilters {
  page?: number;
  perPage?: number;
  account_type?: string;
  is_active?: boolean;
  search?: string;
}

export interface TransactionFilters {
  page?: number;
  perPage?: number;
  is_reconciled?: boolean;
  date_from?: string;
  date_to?: string;
  search?: string;
}

export interface ExpenseFilters {
  page?: number;
  perPage?: number;
  status?: string;
  category?: string;
  date_from?: string;
  date_to?: string;
  search?: string;
}

export interface JournalFilters {
  page?: number;
  perPage?: number;
  status?: string;
  date_from?: string;
  date_to?: string;
  search?: string;
}

// ── API Base Path ──────────────────────────────────────────────────────────────

const BASE = '/api/v2/accounting';

// ── Helper ─────────────────────────────────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function buildParams(filters: any): Record<string, string | number> {
  const params: Record<string, string | number> = {};
  Object.entries(filters).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '' && value !== 'all') {
      if (key === 'perPage') {
        params.per_page = value as number;
      } else {
        params[key] = value as string | number;
      }
    }
  });
  return params;
}

// ── Service ────────────────────────────────────────────────────────────────────

export const accountingService = {
  // ── Chart of Accounts ──────────────────────────────────────────────────────

  async getAccounts(filters: AccountFilters = {}): Promise<PaginatedResponse<AccountingAccount>> {
    const response = await apiClient.get(`${BASE}/accounts`, { params: buildParams(filters) });
    return {
      data: Array.isArray(response.data?.data) ? response.data.data : [],
      total: response.data?.total || 0,
      page: response.data?.page || filters.page || 1,
      per_page: response.data?.per_page || filters.perPage || 50,
      total_pages: response.data?.total_pages || 0,
      has_next: response.data?.has_next || false,
      has_prev: response.data?.has_prev || false,
    };
  },

  async getAccount(uuid: string): Promise<AccountingAccount> {
    const response = await apiClient.get(`${BASE}/accounts/${uuid}`);
    return response.data;
  },

  async createAccount(data: Partial<AccountingAccount>): Promise<AccountingAccount> {
    const response = await apiClient.post(`${BASE}/accounts`, toFormData(data as Record<string, unknown>));
    return response.data;
  },

  async updateAccount(uuid: string, data: Partial<AccountingAccount>): Promise<AccountingAccount> {
    const response = await apiClient.put(`${BASE}/accounts/${uuid}`, toFormData(data as Record<string, unknown>));
    return response.data;
  },

  async deleteAccount(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/accounts/${uuid}`);
  },

  // ── Journal Entries ────────────────────────────────────────────────────────

  async getJournalEntries(filters: JournalFilters = {}): Promise<PaginatedResponse<JournalEntry>> {
    const response = await apiClient.get(`${BASE}/journal-entries`, { params: buildParams(filters) });
    return {
      data: Array.isArray(response.data?.data) ? response.data.data : [],
      total: response.data?.total || 0,
      page: response.data?.page || filters.page || 1,
      per_page: response.data?.per_page || filters.perPage || 10,
      total_pages: response.data?.total_pages || 0,
      has_next: response.data?.has_next || false,
      has_prev: response.data?.has_prev || false,
    };
  },

  async getJournalEntry(uuid: string): Promise<JournalEntry> {
    const response = await apiClient.get(`${BASE}/journal-entries/${uuid}`);
    return response.data;
  },

  async createJournalEntry(data: { entry_date: string; description: string; reference?: string; lines: Omit<JournalLine, 'id'>[] }): Promise<JournalEntry> {
    const response = await apiClient.post(`${BASE}/journal-entries`, toFormData(data as unknown as Record<string, unknown>));
    return response.data;
  },

  async voidJournalEntry(uuid: string): Promise<{ message: string }> {
    const response = await apiClient.post(`${BASE}/journal-entries/${uuid}/void`);
    return response.data;
  },

  // ── Bank Transactions ──────────────────────────────────────────────────────

  async getBankTransactions(filters: TransactionFilters = {}): Promise<PaginatedResponse<BankTransaction>> {
    const response = await apiClient.get(`${BASE}/bank-transactions`, { params: buildParams(filters) });
    return {
      data: Array.isArray(response.data?.data) ? response.data.data : [],
      total: response.data?.total || 0,
      page: response.data?.page || filters.page || 1,
      per_page: response.data?.per_page || filters.perPage || 10,
      total_pages: response.data?.total_pages || 0,
      has_next: response.data?.has_next || false,
      has_prev: response.data?.has_prev || false,
    };
  },

  async getBankTransaction(uuid: string): Promise<BankTransaction> {
    const response = await apiClient.get(`${BASE}/bank-transactions/${uuid}`);
    return response.data;
  },

  async updateBankTransaction(uuid: string, data: Partial<BankTransaction>): Promise<BankTransaction> {
    const response = await apiClient.put(`${BASE}/bank-transactions/${uuid}`, toFormData(data as Record<string, unknown>));
    return response.data;
  },

  async importBankTransactions(data: { csv_content?: string; transactions?: Partial<BankTransaction>[] }): Promise<{ imported: number; message: string }> {
    const response = await apiClient.post(`${BASE}/bank-transactions/import`, toFormData(data as unknown as Record<string, unknown>));
    return response.data;
  },

  async reconcileTransaction(uuid: string, data: { account_id: number }): Promise<BankTransaction> {
    const response = await apiClient.post(`${BASE}/bank-transactions/${uuid}/reconcile`, toFormData(data as Record<string, unknown>));
    return response.data;
  },

  // ── Expenses ───────────────────────────────────────────────────────────────

  async getExpenses(filters: ExpenseFilters = {}): Promise<PaginatedResponse<Expense>> {
    const response = await apiClient.get(`${BASE}/expenses`, { params: buildParams(filters) });
    return {
      data: Array.isArray(response.data?.data) ? response.data.data : [],
      total: response.data?.total || 0,
      page: response.data?.page || filters.page || 1,
      per_page: response.data?.per_page || filters.perPage || 10,
      total_pages: response.data?.total_pages || 0,
      has_next: response.data?.has_next || false,
      has_prev: response.data?.has_prev || false,
    };
  },

  async getExpense(uuid: string): Promise<Expense> {
    const response = await apiClient.get(`${BASE}/expenses/${uuid}`);
    return response.data;
  },

  async createExpense(data: Partial<Expense>): Promise<Expense> {
    const response = await apiClient.post(`${BASE}/expenses`, toFormData(data as Record<string, unknown>));
    return response.data;
  },

  async updateExpense(uuid: string, data: Partial<Expense>): Promise<Expense> {
    const response = await apiClient.put(`${BASE}/expenses/${uuid}`, toFormData(data as Record<string, unknown>));
    return response.data;
  },

  async deleteExpense(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/expenses/${uuid}`);
  },

  async approveExpense(uuid: string): Promise<Expense> {
    const response = await apiClient.post(`${BASE}/expenses/${uuid}/approve`);
    return response.data;
  },

  async rejectExpense(uuid: string): Promise<Expense> {
    const response = await apiClient.post(`${BASE}/expenses/${uuid}/reject`);
    return response.data;
  },

  // ── VAT Returns ────────────────────────────────────────────────────────────

  async getVatReturns(): Promise<VatReturn[]> {
    const response = await apiClient.get(`${BASE}/vat-returns`);
    return Array.isArray(response.data?.data) ? response.data.data : [];
  },

  async getVatReturn(uuid: string): Promise<VatReturn> {
    const response = await apiClient.get(`${BASE}/vat-returns/${uuid}`);
    return response.data;
  },

  async createVatReturn(data: { period_start: string; period_end: string }): Promise<VatReturn> {
    const response = await apiClient.post(`${BASE}/vat-returns`, toFormData(data as Record<string, unknown>));
    return response.data;
  },

  async submitVatReturn(uuid: string): Promise<VatReturn> {
    const response = await apiClient.post(`${BASE}/vat-returns/${uuid}/submit`);
    return response.data;
  },

  // ── Reports ────────────────────────────────────────────────────────────────

  async getTrialBalance(params?: { date_from?: string; date_to?: string }): Promise<TrialBalance> {
    const qs = params ? buildQueryString(params) : '';
    const response = await apiClient.get(`${BASE}/reports/trial-balance${qs}`);
    return response.data;
  },

  async getBalanceSheet(params?: { as_of_date?: string }): Promise<BalanceSheet> {
    const qs = params ? buildQueryString(params) : '';
    const response = await apiClient.get(`${BASE}/reports/balance-sheet${qs}`);
    return response.data;
  },

  async getProfitAndLoss(params?: { date_from?: string; date_to?: string }): Promise<ProfitAndLoss> {
    const qs = params ? buildQueryString(params) : '';
    const response = await apiClient.get(`${BASE}/reports/profit-and-loss${qs}`);
    return response.data;
  },

  async getExpenseSummary(params?: { date_from?: string; date_to?: string }): Promise<ExpenseSummary> {
    const qs = params ? buildQueryString(params) : '';
    const response = await apiClient.get(`${BASE}/reports/expense-summary${qs}`);
    return response.data;
  },

  async getDashboardStats(): Promise<DashboardStats> {
    const response = await apiClient.get(`${BASE}/reports/dashboard-stats`);
    return response.data;
  },

  // ── AI ─────────────────────────────────────────────────────────────────────

  async aiCategorize(data: { description: string; amount: number }): Promise<AiCategorization> {
    const response = await apiClient.post(`${BASE}/ai/categorize`, toFormData(data as Record<string, unknown>));
    return response.data;
  },

  async aiSuggestVat(data: { description: string; amount: number; category?: string }): Promise<AiVatSuggestion> {
    const response = await apiClient.post(`${BASE}/ai/suggest-vat`, toFormData(data as Record<string, unknown>));
    return response.data;
  },

  async aiQuery(data: { query: string }): Promise<AiQueryResponse> {
    const response = await apiClient.post(`${BASE}/ai/query`, toFormData(data as Record<string, unknown>));
    return response.data;
  },

  async aiStatus(): Promise<AiStatusResponse> {
    const response = await apiClient.get(`${BASE}/ai/status`);
    return response.data;
  },
};

export default accountingService;
