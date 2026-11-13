// Typed client for "My Income" (backend: lapis/routes/tax-my-income.lua).
// Income types are data (Tax → Income types): each carries a field schema the
// dashboard renders as a form, so a new type needs no frontend change.
import apiClient from '@/lib/api-client';

export type FieldType = 'currency' | 'number' | 'percentage' | 'boolean' | 'text' | 'date' | 'select';
export type FieldRole = 'income' | 'expense' | 'tax_paid' | 'relief' | 'info';
export type IncomeStatus = 'not_started' | 'in_progress' | 'done' | 'not_applicable';
export type ValueSource = 'statements' | 'manual';

export interface IncomeField {
  key: string;
  label: string;
  type: FieldType;
  required?: boolean;
  help?: string;
  placeholder?: string;
  min?: number;
  max?: number;
  default?: string | number | boolean;
  role?: FieldRole;
  hmrc_box?: string;
  options?: Array<{ value: string; label: string }>;
  show_if?: { field: string; equals?: string | number | boolean };
  prefill?: { categories: string[]; direction: 'credit' | 'debit' };
}

export interface IncomeSection {
  key: string;
  title: string;
  help?: string;
  fields: IncomeField[];
}

export interface FieldSchema {
  sections: IncomeSection[];
}

export interface EstimatorMapping {
  field: string;
  input: string;
  scale_by?: string;
  sign?: 1 | -1;
}

export interface Totals {
  income: number;
  expense: number;
  tax_paid: number;
  relief: number;
}

export interface IncomeType {
  key: string;
  name: string;
  description?: string | null;
  help_text?: string | null;
  icon?: string | null;
  display_order: number;
  is_active: boolean;
  origin: 'system' | 'custom';
  overridden: Record<string, boolean>;
  entity_type: string | null;
  entity_label?: string | null;
  schedule?: string | null;
  schedule_description?: string | null;
  schedule_link?: string | null;
  estimate_note?: string | null;
  field_schema: FieldSchema;
  estimator_mapping: EstimatorMapping[];
  in_estimate: boolean;
  has_form: boolean;
  usage_count?: number;
}

export interface OverviewCard extends Omit<IncomeType, 'field_schema' | 'estimator_mapping'> {
  status: IncomeStatus;
  totals: Totals;
  entity_count: number;
  done_count: number;
}

export interface IncomeOverview {
  tax_year: string;
  types: OverviewCard[];
  progress: { reviewed: number; total: number; started: number };
  estimate_inputs: Record<string, number>;
}

export type Values = Record<string, string | number | boolean | null>;

export interface IncomeRecord {
  uuid: string;
  entity_uuid?: string | null;
  values: Values;
  sources: Record<string, ValueSource>;
  status: 'in_progress' | 'done';
  updated_at?: string;
  totals: Totals;
}

export interface IncomeEntity {
  uuid: string;
  label: string;
  created_at?: string;
  record: IncomeRecord | null;
}

export interface Suggestion {
  amount: number;
  count: number;
  categories: string[];
}

export interface IncomeTypePage {
  tax_year: string;
  type: IncomeType;
  status: IncomeStatus;
  not_applicable: boolean;
  record: IncomeRecord | null;
  entities: IncomeEntity[];
  suggestions: Record<string, Suggestion>;
}

export interface AdminList {
  types: IncomeType[];
  can_edit: boolean;
  can_create: boolean;
  can_edit_global: boolean;
}

export interface BuilderMeta {
  field_types: FieldType[];
  roles: FieldRole[];
  estimator_inputs: Array<{ key: string; description: string }>;
  categories: Array<{ key: string; label: string; type: string }>;
  entity_types: string[];
}

export interface TypeDraft {
  key?: string;
  display_name?: string;
  description?: string | null;
  help_text?: string | null;
  icon?: string | null;
  entity_type?: string | null;
  entity_label?: string | null;
  estimate_note?: string | null;
  linked_form_title?: string | null;
  linked_form_description?: string | null;
  linked_form_weblink?: string | null;
  display_order?: number;
  is_active?: boolean;
  field_schema?: FieldSchema;
  estimator_mapping?: EstimatorMapping[];
  scope?: 'namespace' | 'global';
}

type Envelope<T> = { success: boolean; data: T };

// The year people file now: the last COMPLETED tax year (years start 6 April).
export function currentFilingYear(now = new Date()): string {
  const afterApr6 = now.getMonth() > 3 || (now.getMonth() === 3 && now.getDate() >= 6);
  const start = (afterApr6 ? now.getFullYear() : now.getFullYear() - 1) - 1;
  return `${start}-${String((start + 1) % 100).padStart(2, '0')}`;
}

/** The filing year, the year in progress and three earlier years, newest first. */
export function recentTaxYears(now = new Date()): string[] {
  const filing = Number(currentFilingYear(now).slice(0, 4));
  const out: string[] = [];
  for (let s = filing + 1; s >= filing - 3; s--) out.push(`${s}-${String((s + 1) % 100).padStart(2, '0')}`);
  return out;
}

/** "property" → "properties", "property abroad" → "properties abroad", "business" → "businesses". */
export function pluralNoun(label: string): string {
  const [first, ...rest] = label.split(' ');
  const many = /[^aeiou]y$/.test(first) ? `${first.slice(0, -1)}ies` : /(s|x|ch|sh)$/.test(first) ? `${first}es` : `${first}s`;
  return [many, ...rest].join(' ');
}

/** "1 property", "2 properties". */
export const countOf = (n: number, label: string) => `${n} ${n === 1 ? label : pluralNoun(label)}`;

export const STATUS_LABEL: Record<IncomeStatus, string> = {
  not_started: 'Not started',
  in_progress: 'In progress',
  done: 'Done',
  not_applicable: 'Not for me',
};

export const myIncomeService = {
  async overview(taxYear: string): Promise<IncomeOverview> {
    const r = await apiClient.get<Envelope<IncomeOverview>>('/api/v2/tax/my-income', { params: { tax_year: taxYear } });
    return r.data.data;
  },
  async typePage(key: string, taxYear: string): Promise<IncomeTypePage> {
    const r = await apiClient.get<Envelope<IncomeTypePage>>(`/api/v2/tax/my-income/types/${encodeURIComponent(key)}`, {
      params: { tax_year: taxYear },
    });
    return r.data.data;
  },
  async saveRecord(
    key: string,
    body: { tax_year: string; entity_uuid?: string | null; values: Values; sources: Record<string, ValueSource>; status: 'in_progress' | 'done' },
  ): Promise<IncomeRecord> {
    const r = await apiClient.put<Envelope<IncomeRecord>>(`/api/v2/tax/my-income/types/${encodeURIComponent(key)}/record`, body);
    return r.data.data;
  },
  async setNotApplicable(key: string, taxYear: string, notApplicable: boolean): Promise<void> {
    await apiClient.put(`/api/v2/tax/my-income/types/${encodeURIComponent(key)}/not-applicable`, {
      tax_year: taxYear,
      not_applicable: notApplicable,
    });
  },
  async addEntity(key: string, label: string): Promise<IncomeEntity> {
    const r = await apiClient.post<Envelope<IncomeEntity>>(`/api/v2/tax/my-income/types/${encodeURIComponent(key)}/entities`, { label });
    return r.data.data;
  },
  async renameEntity(uuid: string, label: string): Promise<void> {
    await apiClient.put(`/api/v2/tax/my-income/entities/${encodeURIComponent(uuid)}`, { label });
  },
  async removeEntity(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/tax/my-income/entities/${encodeURIComponent(uuid)}`);
  },

  // ── Administrators (module tax_income_types) ──
  async adminList(includeInactive = true): Promise<AdminList> {
    const r = await apiClient.get<Envelope<AdminList>>('/api/v2/tax/income-types', {
      params: { include_inactive: includeInactive ? 'true' : 'false' },
    });
    return r.data.data;
  },
  async meta(): Promise<BuilderMeta> {
    const r = await apiClient.get<Envelope<BuilderMeta>>('/api/v2/tax/income-types/meta');
    return r.data.data;
  },
  async validate(draft: TypeDraft & { creating?: boolean }): Promise<{ valid: boolean; errors: string[] }> {
    const r = await apiClient.post<Envelope<{ valid: boolean; errors: string[] }>>('/api/v2/tax/income-types/validate', draft);
    return r.data.data;
  },
  async create(draft: TypeDraft): Promise<IncomeType> {
    const r = await apiClient.post<Envelope<IncomeType>>('/api/v2/tax/income-types', draft);
    return r.data.data;
  },
  async update(key: string, draft: TypeDraft): Promise<IncomeType> {
    const r = await apiClient.put<Envelope<IncomeType>>(`/api/v2/tax/income-types/${encodeURIComponent(key)}`, draft);
    return r.data.data;
  },
  async reset(key: string): Promise<IncomeType> {
    const r = await apiClient.post<Envelope<IncomeType>>(`/api/v2/tax/income-types/${encodeURIComponent(key)}/reset`);
    return r.data.data;
  },
  async reorder(keys: string[]): Promise<IncomeType[]> {
    const r = await apiClient.post<Envelope<IncomeType[]>>('/api/v2/tax/income-types/reorder', { keys });
    return r.data.data;
  },
};
