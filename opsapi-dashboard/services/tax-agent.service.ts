// Typed client for the conversational tax-filing agent (backend: routes/tax-agent).
// Goes through the shared apiClient, which injects the JWT + namespace headers.
import apiClient from '@/lib/api-client';

const BASE = '/api/v2/tax/agent';

export interface TaxEstimate {
  gross_income: number;
  total_expenses: number;
  trading_profit: number;
  personal_allowance: number;
  taxable_income: number;
  income_tax: { total: number; basic: { amount: number; rate: number }; higher: { amount: number; rate: number }; additional: { amount: number; rate: number } };
  national_insurance: { class4: number; class2: number; total: number };
  total_tax_due: number;
  effective_rate: number;
  tax_year: string;
  unreviewed_count?: number;
  nic_applied?: boolean;
  is_estimate?: boolean;
}

export interface ReviewItem {
  uuid: string;
  description: string;
  amount: number;
  transaction_type: string;
  category?: string;
  hmrc_category?: string;
  confidence_score?: number;
  classification_status?: string;
  transaction_date?: string;
}

export interface UploadPrompt {
  kind: string;
  button_label: string;
  caption?: string;
}

export interface AgentMessage {
  role: 'user' | 'assistant';
  text: string;
  confirm_card?: { summary: string } | null;
  upload_prompt?: UploadPrompt | null;
  quick_replies?: string[] | null;
  created_at?: string | null;
}

export interface AgentProgress {
  tax_year: string;
  income_types: string[];
  profile_set?: boolean;
}

export interface AgentTurn {
  session_id: string;
  message: string;
  upload_prompt?: UploadPrompt | null;
  estimate?: TaxEstimate | null;
  review?: ReviewItem[] | null;
  quick_replies?: string[] | null;
  confirm_card?: { summary: string } | null;
  awaiting_confirm?: boolean;
  progress: AgentProgress;
  status: string;
}

export interface TaxAgentSession {
  id: string;
  tax_year: string;
  status: string;
  income_types: string[];
  profile: Record<string, unknown>;
  progress: AgentProgress;
  pending?: { summary: string } | null;
  messages: AgentMessage[];
}

export interface SessionSummary {
  id: string;
  tax_year: string;
  status: string;
  income_types: string[];
  updated_at?: string | null;
  created_at?: string | null;
}

function data<T>(r: { data: { data: T } }): T {
  return r.data.data;
}

export const taxAgentService = {
  async createSession(opts?: { tax_year?: string; income_types?: string[]; force_new?: boolean }): Promise<TaxAgentSession> {
    const r = await apiClient.post(`${BASE}/sessions`, opts ?? {});
    return data<TaxAgentSession>(r);
  },

  async listSessions(): Promise<SessionSummary[]> {
    const r = await apiClient.get(`${BASE}/sessions`);
    return data<SessionSummary[]>(r);
  },

  async getSession(id: string): Promise<TaxAgentSession> {
    const r = await apiClient.get(`${BASE}/sessions/${id}`);
    return data<TaxAgentSession>(r);
  },

  async sendMessage(id: string, text: string): Promise<AgentTurn> {
    // The model turn can take tens of seconds on a local model — allow 5 minutes.
    const r = await apiClient.post(`${BASE}/sessions/${id}/message`, { text }, { timeout: 300000 });
    return data<AgentTurn>(r);
  },

  async confirm(id: string, approve: boolean): Promise<AgentTurn> {
    const r = await apiClient.post(`${BASE}/sessions/${id}/confirm`, { approve }, { timeout: 300000 });
    return data<AgentTurn>(r);
  },

  async archive(id: string): Promise<void> {
    await apiClient.post(`${BASE}/sessions/${id}/archive`, {});
  },

  // Best-effort: read the bank name (and account details) from an uploaded statement.
  async detectBankDetails(
    statementId: string | number,
  ): Promise<{ bank_name?: string; account_number?: string; sort_code?: string } | null> {
    try {
      const params = new URLSearchParams();
      params.append('statement_id', String(statementId));
      const r = await apiClient.post('/api/v2/tax/extract/bank-details', params.toString());
      return (r.data?.data ?? r.data) || null;
    } catch {
      return null;
    }
  },
};

export default taxAgentService;
