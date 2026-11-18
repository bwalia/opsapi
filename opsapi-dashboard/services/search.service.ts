/**
 * The dashboard's ⌘K search across records (lapis/lib/global-search.lua, GET /api/v2/search).
 * Each group is one kind of record the person may see; `open` is set when the query is a whole deal code.
 */
import apiClient, { buildQueryString } from '@/lib/api-client';

export interface SearchHit {
  title: string;
  subtitle?: string | null;
  path: string;
}

export interface SearchGroup {
  key: string;
  label: string;
  items: SearchHit[];
}

export interface SearchResult {
  query: string;
  groups: SearchGroup[];
  open?: string | null;
}

export const searchService = {
  async search(q: string, signal?: AbortSignal): Promise<SearchResult> {
    const res = await apiClient.get(`/api/v2/search${buildQueryString({ q })}`, { signal });
    const data = (res.data?.data ?? {}) as Partial<SearchResult>;
    return { query: data.query ?? q, groups: Array.isArray(data.groups) ? data.groups : [], open: data.open ?? null };
  },
};
