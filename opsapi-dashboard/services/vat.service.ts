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
  sales_from?: 'auto' | 'invoices' | 'bank';
  business_address?: string | null;
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

export interface VatInvoiceCheckResult {
  ok: boolean; missing: string[]; simplified_allowed: boolean; reverse_charge_text?: string | null;
  breakdown: Array<{ vat_code: string; label: string; net: number; vat: number }>;
  net: number; vat: number; gross: number; supplier_vrn?: string | null;
}

export interface VatAgentClient {
  uuid: string; client_vrn: string; status: 'pending' | 'accepted' | 'active' | 'rejected' | 'expired' | 'cancelled' | 'revoked';
  client_action_url?: string | null; expires_on?: string | null; last_checked_at?: string | null;
  business_name?: string | null;
}

export interface VatAccountant {
  uuid: string; arn: string; status: 'pending' | 'accepted' | 'active'; created_at?: string;
  first_name?: string | null; last_name?: string | null; email?: string | null;
}

export interface VatObligation { periodKey: string; start: string; end: string; due: string; status: 'O' | 'F';
  received?: string }

export interface VatAnnualAdjustment {
  annual_pct: number; de_minimis: boolean; should_recover: number; claimed: number; adjustment: number;
  direction: 'claim' | 'repay' | 'none'; taxable_supplies: number; exempt_supplies: number; note: string;
  warnings: string[]; returns_counted: number;
}

export type CapitalKind = 'land' | 'building' | 'civil_engineering' | 'refurbishment' | 'ship' | 'aircraft';
export interface VatCapitalItem {
  uuid: string; description: string; kind: CapitalKind; kind_label?: string; cost_ex_vat: number; input_vat: number;
  original_use_pct: number; intervals: number; first_used_on?: string | null; disposed_on?: string | null;
  adjustments: Array<{ uuid: string; period_start: string; period_end: string; interval_no?: number | null;
    vat: number; description?: string }>;
}

export interface VatGroupInfo {
  members: Array<{ uuid: string; member_name: string; status: 'pending' | 'active'; joined: boolean;
    invite_code?: string | null; joined_at?: string | null }>;
  member_of?: { member_name: string; group_name?: string; group_vrn?: string } | null;
}

export interface VatEcSalesList {
  rows: Array<{ country: string; vat_number: string; value: number; indicator: number }>;
  total: number; missing: Array<{ customer_name?: string; net: number; invoice?: string }>;
  frequency_hint: 'monthly' | 'quarterly'; notes: string[];
}

export interface EinvoiceCheck {
  valid: boolean; errors: Array<{ rule: string; message: string }>; warnings: string[];
}
export interface EinvoiceImport {
  check: EinvoiceCheck; document: string; duplicate: boolean; recorded?: string[]; note?: string;
  data: { invoice_number?: string; issue_date?: string; currency?: string;
    supplier: { name?: string; vat_id?: string }; totals: { tax_exclusive?: number; tax?: number; payable?: number } };
  purchases?: Array<{ vat_code: string; net: number; vat: number; gross: number }> | null;
}
export interface EinvoiceDocument {
  uuid: string; direction: 'in' | 'out'; invoice_number?: string; issue_date?: string; party_name?: string;
  party_vat_id?: string; total?: number; vat_total?: number; valid: boolean; status: string; updated_at: string;
}

const data = <T,>(r: { data?: { data?: T } }) => r.data?.data as T;

// An accountant working on a client's VAT: every call carries ?client=<link uuid>
// (lapis/routes/vat.lua resolve()). null = your own VAT.
let vatClient: string | null = null;
export function setVatClient(uuid: string | null) { vatClient = uuid; }
// The workspace's own VAT (accounting: the workspace is the business) instead of yours.
let vatScope: 'namespace' | null = null;
export function setVatScope(scope: 'namespace' | null) { vatScope = scope; }
const withClient = (params?: Record<string, unknown>) => {
  const p: Record<string, unknown> = { ...(params || {}) };
  if (vatClient) p.client = vatClient;
  else if (vatScope) p.scope = vatScope;
  return Object.keys(p).length ? p : undefined;
};
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
  async checkInvoice(uuid: string): Promise<VatInvoiceCheckResult> {
    return data(await apiClient.get(`${BASE}/invoices/${uuid}/check`));
  },
  // Less common schemes (phase 10)
  async peAnnual(year_start: string, year_end: string): Promise<VatAnnualAdjustment> {
    return data(await get(`${BASE}/partial-exemption/annual`, { year_start, year_end }));
  },
  async peAnnualApply(body: { year_start: string; year_end: string; period_start: string; period_end: string }) {
    return data(await post(`${BASE}/partial-exemption/annual`, body));
  },
  async capitalItems(): Promise<VatCapitalItem[]> {
    return data(await get(`${BASE}/capital-items`)) || [];
  },
  async addCapitalItem(body: { description: string; kind: CapitalKind; cost_ex_vat: number; input_vat: number;
    original_use_pct: number; short_lease?: boolean; first_used_on?: string }): Promise<VatCapitalItem> {
    return data(await post(`${BASE}/capital-items`, body));
  },
  async deleteCapitalItem(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/capital-items/${uuid}`, { params: withClient() });
  },
  async adjustCapitalItem(uuid: string, body: { interval_no: number; use_pct: number; period_start: string;
    period_end: string }) {
    return data(await post(`${BASE}/capital-items/${uuid}/adjust`, body));
  },
  async disposeCapitalItem(uuid: string, body: { disposed_on: string; intervals_used: number; sale_taxable: boolean;
    sale_output_vat?: number; period_start: string; period_end: string }) {
    return data<{ adjustment: number; remaining_intervals: number; capped: boolean }>(
      await post(`${BASE}/capital-items/${uuid}/dispose`, body));
  },
  async group(): Promise<VatGroupInfo> {
    return data(await get(`${BASE}/group`));
  },
  async inviteGroupMember(member_name: string) {
    return data<{ uuid: string; member_name: string; invite_code: string }>(
      await post(`${BASE}/group/members`, { member_name }));
  },
  async removeGroupMember(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/group/members/${uuid}`, { params: withClient() });
  },
  async joinGroup(code: string) {
    return data<{ member_name: string; status: string }>(await apiClient.post(`${BASE}/group/join`, { code }));
  },
  async leaveGroup(): Promise<void> {
    await apiClient.post(`${BASE}/group/leave`, {});
  },
  // The accountants linked to your VAT (you can stop them acting for you here)
  async accountants(): Promise<VatAccountant[]> {
    return data(await get(`${BASE}/accountants`)) || [];
  },
  async removeAccountant(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/accountants/${uuid}`, { params: withClient() });
  },
  async ecSalesList(period_start: string, period_end: string): Promise<VatEcSalesList> {
    return data(await get(`${BASE}/ec-sales-list`, { period_start, period_end }));
  },
  async downloadEcSalesList(period_start: string, period_end: string): Promise<void> {
    const r = await get(`${BASE}/ec-sales-list`, { period_start, period_end, format: 'csv' }, { responseType: 'blob' });
    const url = URL.createObjectURL(r.data as Blob);
    const a = document.createElement('a');
    a.href = url; a.download = `ec-sales-list-${period_end}.csv`; a.click();
    URL.revokeObjectURL(url);
  },
  async setInvoiceVatDetails(uuid: string, body: { customer_vat_number?: string; tax_point?: string }) {
    return data(await apiClient.put(`${BASE}/invoices/${uuid}/vat-details`, body));
  },
  // E-invoicing (phase 11)
  async einvoiceCheckInvoice(uuid: string): Promise<{ check: EinvoiceCheck; filename: string }> {
    return data(await apiClient.get(`${BASE}/invoices/${uuid}/einvoice`, { params: { check: 1 } }));
  },
  async downloadEinvoice(uuid: string): Promise<void> {
    const r = await apiClient.get(`${BASE}/invoices/${uuid}/einvoice`, { responseType: 'blob' });
    const name = /filename="([^"]+)"/.exec(String(r.headers['content-disposition'] || ''))?.[1] || 'einvoice.xml';
    const url = URL.createObjectURL(r.data as Blob);
    const a = document.createElement('a');
    a.href = url; a.download = name; a.click();
    URL.revokeObjectURL(url);
  },
  async importEinvoice(xml: string, record = false): Promise<EinvoiceImport> {
    return data(await post(`${BASE}/einvoice/import`, { xml, record }));
  },
  async einvoiceDocuments(direction?: 'in' | 'out'): Promise<EinvoiceDocument[]> {
    return data(await get(`${BASE}/einvoice/documents`, direction ? { direction } : undefined)) || [];
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
