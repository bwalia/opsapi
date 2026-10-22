// Typed client for "download your calculation" and "let our accountant file it for you"
// (backend: routes/tax-filing). Goes through apiClient (JWT + namespace headers).
import apiClient from '@/lib/api-client';

const BASE = '/api/v2/tax/filing';

export type FilingStatus =
  | 'submitted' | 'reviewing' | 'needs_info' | 'filing' | 'filed' | 'rejected' | 'cancelled';

export interface FilingTimelineEntry {
  type: 'status' | 'reply' | 'export';
  status?: FilingStatus;
  text?: string;
  by: 'customer' | 'accountant';
  at: string;
}

export interface FilingRequest {
  uuid: string;
  tax_year: string;
  status: FilingStatus;
  open: boolean;
  our_total_due?: number | null;
  declared_at?: string | null;
  hmrc_reference?: string | null;
  filed_at?: string | null;
  client_message?: string | null;
  created_at?: string;
  updated_at?: string;
  timeline: FilingTimelineEntry[];
}

export interface FilingEstimate {
  income: number;
  expenses: number;
  profit: number;
  total_income: number;
  personal_allowance: number;
  taxable_income: number;
  income_tax: number;
  class4_nic: number;
  class2_nic: number;
  total_tax_and_nic: number;
  tax_already_paid: number;
  balancing_payment: number;
  payment_on_account: number;
  total_due_31_jan: number;
  transactions: number;
  unreviewed: number;
  confirmed: number; // rows the customer has checked and confirmed
  other_money_in: number;
  excluded_money_in: number;
  unmapped_expenses: number;
}

export interface FilingOverview {
  tax_year: string;
  estimate: FilingEstimate;
  figures_hash: string;
  nino: { has: boolean; last4?: string | null };
  direct_filing_enabled: boolean;
  declaration_text: string;
  request: FilingRequest | null;
}

export interface QueueItem {
  uuid: string;
  tax_year: string;
  status: FilingStatus;
  our_total_due?: number | null;
  unreviewed: number;
  hmrc_reference?: string | null;
  filed_at?: string | null;
  created_at?: string;
  updated_at?: string;
  customer: { name: string; email: string };
}

export interface QueueBox {
  box: string;
  item: string;
  mtd_field?: string | null;
  section?: string | null;
  amount: number;
  disallowable: number;
  count: number;
}

export interface QueueDetail {
  uuid: string;
  tax_year: string;
  status: FilingStatus;
  next: FilingStatus[];
  customer: { name: string; email: string; nino_last4?: string | null };
  our_total_due?: number | null;
  hmrc_total_due?: number | null;
  hmrc_reference?: string | null;
  variance_note?: string | null;
  client_message?: string | null;
  declaration_text?: string;
  declared_at?: string;
  filed_at?: string | null;
  created_at?: string;
  updated_at?: string;
  timeline: FilingTimelineEntry[];
  summary?: Partial<FilingEstimate>;
  boxes?: QueueBox[];
  totals?: { transactions: number; unreviewed: number; other_money_in: number; excluded_money_in: number };
  income_types?: string[];
}

export interface StatusUpdate {
  status: FilingStatus;
  message?: string;
  hmrc_reference?: string;
  hmrc_total_due?: string;
  variance_note?: string;
}

function unwrap<T>(r: { data: { data: T } }): T {
  return r.data.data;
}

// Form-encode explicitly: the backend reads form params (and JSON as a fallback).
function form(data: Record<string, string | boolean | undefined | null>): string {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(data)) if (v !== undefined && v !== null && v !== '') p.append(k, String(v));
  return p.toString();
}

async function download(url: string, filename: string): Promise<void> {
  const res = await apiClient.get(url, { responseType: 'blob' });
  const href = URL.createObjectURL(res.data as Blob);
  const a = document.createElement('a');
  a.href = href;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(href), 1000);
}

const safe = (s: string) => s.replace(/[^\w]+/g, '-').replace(/^-+|-+$/g, '');

export const taxFilingService = {
  async overview(taxYear: string): Promise<FilingOverview> {
    return unwrap<FilingOverview>(await apiClient.get(`${BASE}/overview`, { params: { tax_year: taxYear } }));
  },

  /** The live calculation as an Excel workbook (Summary, HMRC boxes, Transactions). */
  downloadCalculation(taxYear: string): Promise<void> {
    return download(`${BASE}/export?tax_year=${encodeURIComponent(taxYear)}`, `tax-calculation-${taxYear}.xlsx`);
  },

  async createRequest(taxYear: string, figuresHash: string): Promise<FilingRequest> {
    return unwrap<FilingRequest>(await apiClient.post(`${BASE}/requests`,
      form({ tax_year: taxYear, declaration_accepted: 'true', figures_hash: figuresHash })));
  },

  async cancelRequest(uuid: string): Promise<FilingRequest> {
    return unwrap<FilingRequest>(await apiClient.post(`${BASE}/requests/${uuid}/cancel`, ''));
  },

  async replyRequest(uuid: string, text: string): Promise<FilingRequest> {
    return unwrap<FilingRequest>(await apiClient.post(`${BASE}/requests/${uuid}/reply`, form({ text })));
  },

  /** The figures the customer approved (frozen at request time). */
  downloadRequest(uuid: string, taxYear: string): Promise<void> {
    return download(`${BASE}/requests/${uuid}/export`, `tax-calculation-${taxYear}-approved.xlsx`);
  },

  // ── Accountant queue (module tax_filing_requests) ─────────────────────────────
  async queue(status: string): Promise<{ items: QueueItem[]; counts: Record<string, number> }> {
    const r = await apiClient.get(`${BASE}/queue`, { params: { status } });
    return { items: r.data?.data ?? [], counts: r.data?.meta?.counts ?? {} };
  },

  async queueDetail(uuid: string): Promise<QueueDetail> {
    return unwrap<QueueDetail>(await apiClient.get(`${BASE}/queue/${uuid}`));
  },

  downloadQueueItem(uuid: string, taxYear: string, customerName: string): Promise<void> {
    const who = safe(customerName);
    return download(`${BASE}/queue/${uuid}/export`, `tax-calculation-${taxYear}${who ? `-${who}` : ''}.xlsx`);
  },

  async updateStatus(uuid: string, update: StatusUpdate): Promise<void> {
    await apiClient.post(`${BASE}/queue/${uuid}/status`, form({ ...update }));
  },
};

export default taxFilingService;
