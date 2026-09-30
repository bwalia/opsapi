import apiClient, { buildQueryString } from '@/lib/api-client';

/**
 * Workspace activity — who signed in and what they did in the current
 * workspace. Backend: lapis/routes/namespace-activity.lua (RBAC `activity.read`,
 * owners/admins by default). All timestamps are ISO-8601 UTC.
 */

export interface ActivityDay {
  day: string; // YYYY-MM-DD (UTC)
  active_members: number;
  changes: number;
  requests: number;
  errors: number;
}

export interface ActivitySummary {
  days: number;
  totals: {
    members: number;
    active_members: number;
    active_today: number;
    changes: number;
    requests: number;
    errors: number;
  };
  series: ActivityDay[];
  areas: { area: string; changes: number; requests: number }[];
  top_members: {
    user_uuid: string;
    email?: string;
    name?: string;
    changes: number;
    requests: number;
    last_active_at?: string;
  }[];
}

export interface ActivityMember {
  user_uuid: string;
  email: string;
  name?: string;
  active: boolean;
  status: string;
  is_owner: boolean;
  joined_at?: string;
  last_login_at?: string;
  last_login_method?: string;
  login_count: number;
  failed_login_count: number;
  last_seen_at?: string;
  last_active_at?: string;
  changes_30d: number;
  requests_30d: number;
}

export interface ActivityEntry {
  cursor: string;
  occurred_at: string;
  user_uuid: string;
  email?: string;
  name?: string;
  via: 'jwt' | 'api_key';
  method: string;
  route: string;
  action: string;
  entity_id?: string;
  status: number;
  hits: number;
  duration_ms?: number;
  ip?: string;
  user_agent?: string;
}

export interface MemberPageMeta {
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
}

export interface ActivityLogParams {
  days?: number;
  user_uuid?: string;
  area?: string;
  kind?: 'changes' | 'errors';
  cursor?: string;
  limit?: number;
}

const BASE = '/api/v2/namespace/activity';

type Envelope<T, M = undefined> = { data: T; meta: M };

export const activityService = {
  async summary(days: number): Promise<ActivitySummary> {
    const res = await apiClient.get<Envelope<ActivitySummary>>(
      `${BASE}/summary${buildQueryString({ days })}`
    );
    return res.data.data;
  },

  async members(params: {
    search?: string;
    sort?: 'last_login' | 'name';
    page?: number;
    per_page?: number;
  }): Promise<{ data: ActivityMember[]; meta: MemberPageMeta }> {
    const res = await apiClient.get<Envelope<ActivityMember[], MemberPageMeta>>(
      `${BASE}/members${buildQueryString(params)}`
    );
    return { data: res.data.data ?? [], meta: res.data.meta };
  },

  async log(params: ActivityLogParams): Promise<{ data: ActivityEntry[]; nextCursor?: string }> {
    const res = await apiClient.get<Envelope<ActivityEntry[], { next_cursor?: string }>>(
      `${BASE}${buildQueryString({ ...params })}`
    );
    return {
      data: res.data.data ?? [],
      nextCursor: res.data.meta?.next_cursor,
    };
  },
};
