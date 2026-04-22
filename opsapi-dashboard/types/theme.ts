export type ThemeVisibility = 'private' | 'public' | 'platform';

export interface Theme {
  id: number;
  uuid: string;
  namespace_id: number | null;
  project_code: string;
  name: string;
  slug: string;
  description?: string | null;
  visibility: ThemeVisibility;
  is_platform: boolean;
  is_active: boolean;
  parent_uuid?: string | null;
  source_uuid?: string | null;
  version: number;
  created_by?: number | null;
  created_at: string;
  updated_at: string;
  deleted_at?: string | null;
}

export type ThemeTokens = Record<string, Record<string, unknown>>;

export interface ThemeDetail {
  theme: Theme;
  tokens: ThemeTokens;
  custom_css: string;
}

export interface ThemeResolved {
  theme: Theme;
  resolved: ThemeTokens;
}

export interface ThemeRevision {
  id: number;
  uuid: string;
  theme_id: number;
  version: number;
  tokens: ThemeTokens;
  custom_css?: string | null;
  change_note?: string | null;
  created_by?: number | null;
  created_at: string;
}

export type ThemeTokenFieldType =
  | 'color'
  | 'color_scale'
  | 'color_scale_preset'
  | 'size'
  | 'font'
  | 'number'
  | 'string'
  | 'enum'
  | 'boolean'
  | 'shadow'
  | 'asset';

export interface ThemeTokenField {
  type: ThemeTokenFieldType;
  required?: boolean;
  default?: unknown;
  min?: number;
  max?: number;
  values?: string[];
  max_length?: number;
  asset_type?: string;
  ui?: {
    label?: string;
    hint?: string;
    group?: string;
    order?: number;
  };
}

export type ThemeTokenGroup = Record<string, ThemeTokenField>;
export type ThemeSchema = Record<string, ThemeTokenGroup>;

export interface ThemeListMeta {
  total?: number;
  limit?: number;
  offset?: number;
}

export interface ThemeListParams {
  project_code?: string;
  limit?: number;
  offset?: number;
  visibility?: ThemeVisibility;
  q?: string;
}

export interface ThemeCreateInput {
  name: string;
  slug?: string;
  description?: string;
  parent_uuid?: string;
  from_preset_slug?: string;
  tokens?: ThemeTokens;
  custom_css?: string;
  project_code?: string;
}

export interface ThemeUpdateInput {
  name?: string;
  description?: string;
  tokens?: ThemeTokens;
  custom_css?: string;
  change_note?: string;
}

export interface ThemePreset {
  uuid: string;
  slug: string;
  name: string;
  description?: string | null;
  project_code: string;
  tokens?: ThemeTokens;
}
