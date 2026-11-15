/**
 * VAT (docs/plans/VAT_MTD.md): registration, AI VAT coding, the 9-box return and
 * filing with HMRC (MTD). Backend: lapis/routes/vat.lua.
 */

import { apiClient } from '@/lib/api-client';

const BASE = '/api/v2/vat';

export type VatScheme = 'standard' | 'cash' | 'flat_rate' | 'annual';

export interface VatCode { code: string; label: string; rate: number; reclaimable: number }

export interface VatRegistration {
  uuid: string;
  vrn: string;
  business_name?: string | null;
  effective_date?: string | null;
  scheme: VatScheme;
  scheme_label?: string;
  stagger: string;
  flat_rate_pct?: number | null;
  flat_rate_first_year?: boolean;
  limited_cost_trader?: boolean;
  partially_exempt?: boolean;
  recovery_pct?: number | null;
  status: string;
}

export interface VatStatus {
  total: number; uncoded: number; by_rule: number; by_ai: number; by_you: number; to_check: number; running: boolean;
}

export interface VatReviewLine {
  uuid: string;
  transaction_date: string;
  description: string;
  amount: number;
  transaction_type: 'CREDIT' | 'DEBIT';
  vat_code: string | null;
  net_amount: number | null;
  vat_amount: number | null;
  vat_reclaimable_pct: number | null;
  vat_source: string | null;
  vat_confidence: number | null;
  vat_reason: string | null;
  vat_review_reasons: string[];
}

export type Boxes = Record<'box1' | 'box2' | 'box3' | 'box4' | 'box5' | 'box6' | 'box7' | 'box8' | 'box9', number>;

export interface VatReturnPreview {
  boxes: Boxes;
  direction: 'pay' | 'repay' | 'nil';
  warnings: string[];
  notes: string[];
  line_count: number;
  uncoded_count: number;
  valid: boolean;
  period: { start: string; end: string; due_date?: string };
  audit: Record<string, string[]>;
}

export interface VatReturnRow extends Boxes {
  uuid: string;
  period_start: string;
  period_end: string;
  period_key?: string | null;
  due_date?: string | null;
  status: 'draft' | 'submitting' | 'submitted' | 'failed';
  direction?: string;
  line_count: number;
  uncoded_count: number;
  submitted_at?: string | null;
  hmrc_receipt?: Record<string, unknown> | null;
  calculation?: { warnings?: string[]; notes?: string[] } | null;
  lines_by_box?: Record<string, Array<{ ref: string; date?: string; description?: string; amount?: number;
    vat_code?: string; net?: number; vat?: number; adjustment?: string }>>;
}

export interface VatThreshold {
  turnover: number; threshold: number; pct: number; status: 'ok' | 'approaching' | 'over';
  as_of: string; crossed_month?: string; register_by?: string;
}

export interface VatReport {
  from: string; to: string;
  totals: { output_vat: number; input_vat: number; reclaimable: number; blocked: number };
  by_code: Array<{ vat_code: string; label?: string; lines: number; sales_net: number; purchases_net: number;
    output_vat: number; input_vat: number; reclaimable: number; blocked: number }>;
  top_suppliers: Array<{ supplier: string; spend: number; vat: number; lines: number }>;
}

export interface VatAgentClient {
  uuid: string; client_vrn: string; status: 'pending' | 'accepted' | 'active' | 'rejected' | 'expired' | 'cancelled' | 'revoked';
  client_action_url?: string | null; expires_on?: string | null; last_checked_at?: string | null;
  business_name?: string | null;
}

export interface VatObligation { periodKey: string; start: string; end: string; due: string; status: 'O' | 'F';
  received?: string }

const data = <T,>(r: { data?: { data?: T } }) => r.data?.data as T;

// An accountant working on a client's VAT: every call carries ?client=<link uuid>
// (lapis/routes/vat.lua resolve()). null = your own VAT.
let vatClient: string | null = null;
export function setVatClient(uuid: string | null) { vatClient = uuid; }
const withClient = (params?: Record<string, unknown>) => (vatClient ? { ...(params || {}), client: vatClient } : params);
const get = (url: string, params?: Record<string, unknown>, extra?: Record<string, unknown>) =>
  apiClient.get(url, { ...(extra || {}), params: withClient(params) });
const post = (url: string, body?: unknown, extra?: Record<string, unknown>) =>
  apiClient.post(url, body, { ...(extra || {}), params: withClient() });
const put = (url: string, body?: unknown) => apiClient.put(url, body, { params: withClient() });

export const vatService = {
  async codes(): Promise<{ codes: VatCode[]; schemes: Array<{ key: VatScheme; label: string }> }> {
    return data(await get(`${BASE}/codes`));
  },
  async registration(): Promise<VatRegistration | null> {
    return data(await get(`${BASE}/registration`)) || null;
  },
  async saveRegistration(r: Partial<VatRegistration>): Promise<VatRegistration> {
    return data(await put(`${BASE}/registration`, r));
  },
  async status(taxYear?: string): Promise<VatStatus> {
    return data(await get(`${BASE}/transactions/classify-status`, { tax_year: taxYear }));
  },
  async classify(opts: { tax_year?: string; period_start?: string; period_end?: string; recode?: boolean }) {
    return data<{ started: boolean; pending: number; already_running?: boolean }>(
      await post(`${BASE}/transactions/classify`, opts));
  },
  async applyRules(taxYear?: string) {
    return data<{ matched: number; unmatched: number }>(
      await post(`${BASE}/transactions/apply-rules`, { tax_year: taxYear }));
  },
  async reviewQueue(): Promise<VatReviewLine[]> {
    return data(await get(`${BASE}/review`)) || [];
  },
  async setLineVat(uuid: string, body: { vat_code: string; vat_amount?: number; reclaimable_pct?: number;
    reason?: string }) {
    return data<{ learned_rule?: { match_value: string; vat_code: string } | null }>(
      await put(`${BASE}/transactions/${uuid}`, body));
  },
  async readReceipt(uuid: string, file: File) {
    const b64 = await new Promise<string>((resolve, reject) => {
      const fr = new FileReader();
      fr.onload = () => resolve(String(fr.result).split(',')[1] || '');
      fr.onerror = () => reject(fr.error);
      fr.readAsDataURL(file);
    });
    return data(await post(`${BASE}/transactions/${uuid}/receipt`, { mime: file.type, data: b64 },
      { timeout: 180000 }));
  },
  async preview(period_start: string, period_end: string): Promise<VatReturnPreview> {
    return data(await post(`${BASE}/returns/preview`, { period_start, period_end }));
  },
  async saveDraft(period_start: string, period_end: string): Promise<VatReturnRow> {
    return data(await post(`${BASE}/returns`, { period_start, period_end }));
  },
  async returns(): Promise<VatReturnRow[]> {
    return data(await get(`${BASE}/returns`)) || [];
  },
  async getReturn(uuid: string, lines = false): Promise<VatReturnRow> {
    return data(await get(`${BASE}/returns/${uuid}`, lines ? { lines: 1 } : undefined));
  },
  async obligations(params: { from?: string; to?: string; status?: 'O' | 'F' } = {}): Promise<VatObligation[]> {
    return data(await get(`${BASE}/hmrc/obligations`, params)) || [];
  },
  async submit(uuid: string, period_key: string): Promise<VatReturnRow> {
    return data(await post(`${BASE}/returns/${uuid}/submit`,
      { period_key, declaration_accepted: true }, { timeout: 120000 }));
  },
  async hmrcReturn(period_key: string): Promise<Record<string, number | string>> {
    return data(await get(`${BASE}/hmrc/returns/${encodeURIComponent(period_key)}`));
  },
  async threshold(): Promise<VatThreshold> {
    return data(await get(`${BASE}/threshold`));
  },
  async report(from: string, to: string): Promise<VatReport> {
    return data(await get(`${BASE}/reports`, { from, to }));
  },
  async penalties(): Promise<Record<string, unknown>> {
    return data(await get(`${BASE}/hmrc/penalties`));
  },
  async exportReturn(uuid: string): Promise<void> {
    const r = await get(`${BASE}/returns/${uuid}/export`, undefined, { responseType: 'blob' });
    const name = /filename="([^"]+)"/.exec(String(r.headers['content-disposition'] || ''))?.[1] || 'vat-return.csv';
    const url = URL.createObjectURL(r.data as Blob);
    const a = document.createElement('a');
    a.href = url; a.download = name; a.click();
    URL.revokeObjectURL(url);
  },
  async connectUrl(redirectUrl: string, purpose: 'vat' | 'vat_agent' = 'vat'): Promise<string> {
    const r = await apiClient.get('/auth/hmrc/initiate',
      { params: { source: 'vat', purpose, redirect_url: redirectUrl } });
    return r.data?.auth_url;
  },
  // Accountants (agents)
  async agentProfile(): Promise<{ arn: string } | null> {
    return data(await apiClient.get(`${BASE}/agent/profile`)) || null;
  },
  async saveAgentProfile(arn: string): Promise<{ arn: string }> {
    return data(await apiClient.put(`${BASE}/agent/profile`, { arn }));
  },
  async agentClients(): Promise<VatAgentClient[]> {
    return data(await apiClient.get(`${BASE}/agent/clients`)) || [];
  },
  async inviteClient(vrn: string, vat_registration_date?: string): Promise<VatAgentClient> {
    return data(await apiClient.post(`${BASE}/agent/clients`, { vrn, vat_registration_date }));
  },
  async refreshClient(uuid: string): Promise<VatAgentClient> {
    return data(await apiClient.post(`${BASE}/agent/clients/${uuid}/refresh`, {}));
  },
  async cancelClient(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/agent/clients/${uuid}`);
  },
};

/** The nine boxes in plain English (HMRC's numbering kept for accountants). */
export const BOX_LABELS: Array<{ key: keyof Boxes; n: number; label: string; whole?: boolean }> = [
  { key: 'box1', n: 1, label: 'VAT due on sales and other outputs' },
  { key: 'box2', n: 2, label: 'VAT due on goods from the EU (Northern Ireland only)' },
  { key: 'box3', n: 3, label: 'Total VAT due (Box 1 + Box 2)' },
  { key: 'box4', n: 4, label: 'VAT reclaimed on purchases' },
  { key: 'box5', n: 5, label: 'Net VAT to pay HMRC or reclaim' },
  { key: 'box6', n: 6, label: 'Total sales, excluding VAT', whole: true },
  { key: 'box7', n: 7, label: 'Total purchases, excluding VAT', whole: true },
  { key: 'box8', n: 8, label: 'Goods supplied to the EU, excluding VAT (NI only)', whole: true },
  { key: 'box9', n: 9, label: 'Goods acquired from the EU, excluding VAT (NI only)', whole: true },
];

export default vatService;
