'use client';

/**
 * Workspace activity — who signed in and what they did in this workspace,
 * plus the audit trail of record changes (fields before → after).
 * Visible to roles with `activity.read` (owners and admins by default).
 * Sign-in IPs and login history stay with platform admins (Grafana): a login
 * isn't tied to one workspace. See USER_ACTIVITY.md.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Activity,
  AlertTriangle,
  ArrowRight,
  Coins,
  History,
  KeyRound,
  Loader2,
  PencilLine,
  Search,
  ShieldAlert,
  Sparkles,
  UserCheck,
  Users,
} from 'lucide-react';
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { format, parseISO } from 'date-fns';
import { Badge, Button, Card, Input, Pagination, SearchableSelect, Select, Table } from '@/components/ui';
import { PageHeader } from '@/components/layout/PageHeader';
import { ProtectedPage } from '@/components/permissions';
import { useNamespace } from '@/contexts/NamespaceContext';
import { usePermissions } from '@/contexts/PermissionsContext';
import { activityService, aiUsageService } from '@/services';
import type { AiUsageSummary } from '@/services/ai-usage.service';
import type {
  ActivityEntry,
  ActivityLogParams,
  ActivityMember,
  ActivitySummary,
  AuditChange,
  AuditChangeParams,
  MemberPageMeta,
} from '@/services/activity.service';
import { cn, extractApiError, formatDateTime, formatNumber, formatRelativeTime } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

type Tab = 'overview' | 'members' | 'log' | 'changes' | 'ai';
type MemberRef = { uuid: string; label: string };

const TABS: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'members', label: 'Members' },
  { id: 'log', label: 'Activity log' },
  { id: 'changes', label: 'Audit trail' },
  { id: 'ai', label: 'AI usage' },
];

const VERBS: Record<string, { label: string; variant: 'info' | 'success' | 'warning' | 'error' }> = {
  read: { label: 'Viewed', variant: 'info' },
  create: { label: 'Created', variant: 'success' },
  update: { label: 'Updated', variant: 'warning' },
  delete: { label: 'Deleted', variant: 'error' },
};

const METHODS: Record<string, string> = {
  password: 'Password',
  google: 'Google',
  oauth: 'SSO',
};

// ── helpers ────────────────────────────────────────────────────────────────

const who = (m: { name?: string | null; email?: string | null }) => m.name || m.email || 'Deleted user';

const pretty = (s: string) => s.replace(/[_-]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());

/** "crm_accounts.contacts.update" → { verb: "update", what: "Crm Accounts › Contacts" } */
function describe(action: string) {
  const parts = action.split('.');
  const verb = parts.pop() || '';
  return { verb, what: parts.map(pretty).join(' › ') };
}

/** A short "Browser · OS" from a user agent; API clients show their own name. */
function browser(ua?: string) {
  if (!ua) return '';
  const name = /Edg\//.test(ua)
    ? 'Edge'
    : /OPR\//.test(ua)
      ? 'Opera'
      : /Firefox\//.test(ua)
        ? 'Firefox'
        : /Chrome\//.test(ua)
          ? 'Chrome'
          : /Safari\//.test(ua)
            ? 'Safari'
            : ua.split(/[\s/]/)[0];
  const os = /iPhone|iPad/.test(ua)
    ? 'iOS'
    : /Android/.test(ua)
      ? 'Android'
      : /Mac OS X/.test(ua)
        ? 'macOS'
        : /Windows/.test(ua)
          ? 'Windows'
          : /Linux/.test(ua)
            ? 'Linux'
            : '';
  return os ? `${name} · ${os}` : name;
}

function statusVariant(status: number): 'success' | 'info' | 'warning' | 'error' {
  if (status >= 500) return 'error';
  if (status >= 400) return 'warning';
  if (status >= 300) return 'info';
  return 'success';
}

const dayLabel = (day: string) => format(parseISO(day), 'd MMM');

function Relative({ at, empty = '—' }: { at?: string | null; empty?: string }) {
  if (!at) return <span className="text-secondary-400">{empty}</span>;
  return (
    <time dateTime={at} title={formatDateTime(at)}>
      {formatRelativeTime(at)}
    </time>
  );
}

function useDebounced<T>(value: T, ms = 300): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

// ── page ───────────────────────────────────────────────────────────────────

export default function ActivityPage() {
  return (
    <ProtectedPage module="activity" action="read" title="Activity">
      <ActivityContent />
    </ProtectedPage>
  );
}

function ActivityContent() {
  const { currentNamespace } = useNamespace();
  const [tab, setTab] = useState<Tab>('overview');
  const [logMember, setLogMember] = useState<MemberRef | null>(null);
  const nsKey = currentNamespace?.uuid ?? 'none';

  const openLog = useCallback((m: MemberRef) => {
    setLogMember(m);
    setTab('log');
  }, []);

  return (
    <div className="space-y-6">
      <PageHeader
        icon={<Activity className="w-5 h-5" />}
        title="Activity"
        description={`Who signed in and what they did in ${currentNamespace?.name ?? 'this workspace'}.`}
      />

      <div role="tablist" aria-label="Activity views" className="flex gap-1 border-b border-secondary-200">
        {TABS.map((t) => (
          <button
            key={t.id}
            role="tab"
            aria-selected={tab === t.id}
            onClick={() => setTab(t.id)}
            className={cn(
              'px-4 py-2.5 -mb-px text-sm font-medium border-b-2 transition-colors cursor-pointer',
              'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 rounded-t-md',
              tab === t.id
                ? 'border-primary-500 text-primary-600'
                : 'border-transparent text-secondary-500 hover:text-secondary-800'
            )}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div role="tabpanel">
        {tab === 'overview' && <Overview key={nsKey} onMember={openLog} />}
        {tab === 'members' && <Members key={nsKey} onMember={openLog} />}
        {tab === 'log' && <Log key={nsKey} member={logMember} onMemberChange={setLogMember} />}
        {tab === 'changes' && <Changes key={nsKey} />}
        {tab === 'ai' && <AiUsage key={nsKey} />}
      </div>
    </div>
  );
}

// ── overview ───────────────────────────────────────────────────────────────

function StatCard({
  icon,
  label,
  value,
  sub,
  tone = 'default',
}: {
  icon: React.ReactNode;
  label: string;
  value: React.ReactNode;
  sub?: string;
  tone?: 'default' | 'primary' | 'success' | 'warning';
}) {
  const toneClasses = {
    default: 'text-secondary-600 bg-secondary-100',
    primary: 'text-primary-600 bg-primary-500/10',
    success: 'text-success-600 bg-success-500/10',
    warning: 'text-warning-600 bg-warning-500/10',
  }[tone];
  return (
    <Card className="p-4">
      <div className="flex items-center gap-3">
        <div className={cn('w-10 h-10 rounded-lg flex items-center justify-center shrink-0', toneClasses)}>
          {icon}
        </div>
        <div className="min-w-0">
          <p className="text-2xl font-bold text-secondary-900 leading-tight tabular-nums">{value}</p>
          <p className="text-xs text-secondary-500 truncate">{label}</p>
          {sub && <p className="text-[11px] text-secondary-400 truncate">{sub}</p>}
        </div>
      </div>
    </Card>
  );
}

function ChartCard({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <Card className="p-4">
      <h3 className="text-sm font-semibold text-secondary-700 mb-3">{title}</h3>
      <div className="h-[240px]">{children}</div>
    </Card>
  );
}

function Overview({ onMember }: { onMember: (m: MemberRef) => void }) {
  const [days, setDays] = useState(30);
  const [res, setRes] = useState<{
    days: number;
    data?: ActivitySummary;
    error?: string;
  } | null>(null);

  useEffect(() => {
    let live = true;
    activityService
      .summary(days)
      .then((data) => {
        if (live) setRes({ days, data });
      })
      .catch((e) => {
        if (live)
          setRes({
            days,
            error: extractApiError(e, 'Could not load activity'),
          });
      });
    return () => {
      live = false;
    };
  }, [days]);
  const current = res?.days === days ? res : null;
  const data = current?.data;
  const error = current?.error;

  const series = useMemo(() => (data?.series ?? []).map((d) => ({ ...d, label: dayLabel(d.day) })), [data]);
  const maxArea = Math.max(1, ...(data?.areas ?? []).map((a) => a.requests));

  const rangePicker = (
    <div className="w-44">
      <Select aria-label="Time range" value={String(days)} onChange={(e) => setDays(Number(e.target.value))}>
        <option value="7">Last 7 days</option>
        <option value="30">Last 30 days</option>
        <option value="90">Last 90 days</option>
      </Select>
    </div>
  );

  if (error || !data) {
    return (
      <div className="space-y-6">
        <div className="flex justify-end">{rangePicker}</div>
        {error ? <ErrorCard message={error} /> : <LoadingCard />}
      </div>
    );
  }

  const t = data.totals;
  const errorRate = t.requests > 0 ? (t.errors / t.requests) * 100 : 0;

  return (
    <div className="space-y-6">
      <div className="flex justify-end">{rangePicker}</div>

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <StatCard
          icon={<Users size={18} />}
          label="Active members"
          value={formatNumber(t.active_members)}
          sub={`of ${formatNumber(t.members)} members · ${days} days`}
          tone="primary"
        />
        <StatCard
          icon={<UserCheck size={18} />}
          label="Active today"
          value={formatNumber(t.active_today)}
          sub="since midnight UTC"
          tone="success"
        />
        <StatCard
          icon={<PencilLine size={18} />}
          label="Changes"
          value={formatNumber(t.changes)}
          sub="records created, updated or deleted"
        />
        <StatCard
          icon={<AlertTriangle size={18} />}
          label="Failed requests"
          value={formatNumber(t.errors)}
          sub={`${errorRate.toFixed(1)}% of ${formatNumber(t.requests)} requests`}
          tone={errorRate > 5 ? 'warning' : 'default'}
        />
      </div>

      {t.requests === 0 ? (
        <Card className="p-10 text-center">
          <Activity className="w-8 h-8 mx-auto text-secondary-300" aria-hidden="true" />
          <p className="mt-3 font-medium text-secondary-700">No activity in the last {days} days</p>
          <p className="mt-1 text-sm text-secondary-500">
            Activity shows up here a few seconds after members use the workspace.
          </p>
        </Card>
      ) : (
        <>
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <ChartCard title="Active members per day">
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart data={series} margin={{ top: 8, right: 8, left: -18, bottom: 0 }}>
                  <defs>
                    <linearGradient id="gActive" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor="#3b82f6" stopOpacity={0.35} />
                      <stop offset="95%" stopColor="#3b82f6" stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
                  <XAxis dataKey="label" tick={{ fontSize: 11 }} stroke="#94a3b8" minTickGap={16} />
                  <YAxis allowDecimals={false} tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <Tooltip />
                  <Area
                    type="monotone"
                    dataKey="active_members"
                    name="Active members"
                    stroke="#3b82f6"
                    fill="url(#gActive)"
                    strokeWidth={2}
                  />
                </AreaChart>
              </ResponsiveContainer>
            </ChartCard>
            <ChartCard title="Changes and failed requests per day">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={series} margin={{ top: 8, right: 8, left: -18, bottom: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
                  <XAxis dataKey="label" tick={{ fontSize: 11 }} stroke="#94a3b8" minTickGap={16} />
                  <YAxis allowDecimals={false} tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <Tooltip cursor={{ fill: '#f1f5f9' }} />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                  <Bar dataKey="changes" name="Changes" fill="#8b5cf6" radius={[3, 3, 0, 0]} />
                  <Bar dataKey="errors" name="Failed" fill="#f59e0b" radius={[3, 3, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            </ChartCard>
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <Card className="p-4">
              <h3 className="text-sm font-semibold text-secondary-700 mb-3">Most used areas</h3>
              <ul className="space-y-2.5">
                {data.areas.slice(0, 8).map((a) => (
                  <li key={a.area}>
                    <div className="flex items-baseline justify-between gap-3 text-sm">
                      <span className="font-medium text-secondary-800 truncate">{pretty(a.area)}</span>
                      <span className="text-xs text-secondary-500 tabular-nums shrink-0">
                        {formatNumber(a.requests)} requests · {formatNumber(a.changes)} changes
                      </span>
                    </div>
                    <div className="mt-1 h-1.5 rounded-full bg-secondary-100 overflow-hidden">
                      <div
                        className="h-full rounded-full bg-primary-500"
                        style={{
                          width: `${Math.max(2, (a.requests / maxArea) * 100)}%`,
                        }}
                      />
                    </div>
                  </li>
                ))}
              </ul>
            </Card>

            <Card className="p-4">
              <h3 className="text-sm font-semibold text-secondary-700 mb-3">Most active members</h3>
              <ul className="divide-y divide-secondary-100">
                {data.top_members.map((m) => (
                  <li key={m.user_uuid}>
                    <button
                      onClick={() => onMember({ uuid: m.user_uuid, label: who(m) })}
                      className="w-full flex items-center justify-between gap-3 py-2.5 text-left rounded-md hover:bg-secondary-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 cursor-pointer"
                    >
                      <span className="min-w-0">
                        <span className="block text-sm font-medium text-secondary-800 truncate">
                          {who(m)}
                        </span>
                        <span className="block text-xs text-secondary-500">
                          Last active <Relative at={m.last_active_at} />
                        </span>
                      </span>
                      <span className="flex items-center gap-2 shrink-0 text-xs text-secondary-500 tabular-nums">
                        {formatNumber(m.requests)} requests · {formatNumber(m.changes)} changes
                        <ArrowRight className="w-3.5 h-3.5" aria-hidden="true" />
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            </Card>
          </div>
        </>
      )}
    </div>
  );
}

// ── members ────────────────────────────────────────────────────────────────

function Members({ onMember }: { onMember: (m: MemberRef) => void }) {
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<'last_login' | 'name'>('last_login');
  const [page, setPage] = useState(1);
  const [res, setRes] = useState<{
    key: string;
    rows: ActivityMember[];
    meta?: MemberPageMeta;
    error?: string;
  } | null>(null);
  const q = useDebounced(search.trim());
  const key = `${q}|${sort}|${page}`;

  useEffect(() => {
    let live = true;
    activityService
      .members({ search: q || undefined, sort, page, per_page: 25 })
      .then((r) => {
        if (live) setRes({ key, rows: r.data, meta: r.meta });
      })
      .catch((e) => {
        if (live)
          setRes({
            key,
            rows: [],
            error: extractApiError(e, 'Could not load members'),
          });
      });
    return () => {
      live = false;
    };
  }, [key, q, sort, page]);
  const loading = res?.key !== key;
  const rows = res?.rows ?? [];
  const meta = res?.meta;
  const error = loading ? null : res?.error;

  const columns: TableColumn<ActivityMember>[] = [
    {
      key: 'member',
      header: 'Member',
      render: (m) => (
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-medium text-secondary-900 truncate">{who(m)}</span>
            {m.is_owner && (
              <Badge size="sm" variant="info">
                Owner
              </Badge>
            )}
            {!m.active && (
              <Badge size="sm" variant="error">
                Deactivated
              </Badge>
            )}
            {m.active && m.status !== 'active' && <Badge size="sm">{pretty(m.status)}</Badge>}
          </div>
          {m.name && <div className="text-xs text-secondary-500 truncate">{m.email}</div>}
        </div>
      ),
    },
    {
      key: 'last_login_at',
      header: 'Last sign-in',
      render: (m) => (
        <div className="text-sm">
          <Relative at={m.last_login_at} empty="Never" />
          {m.last_login_method && (
            <div className="text-xs text-secondary-500">
              {METHODS[m.last_login_method] ?? pretty(m.last_login_method)} · {formatNumber(m.login_count)}{' '}
              total
            </div>
          )}
        </div>
      ),
    },
    {
      key: 'last_active_at',
      header: 'Last active here',
      render: (m) => (
        <span className="text-sm">
          <Relative at={m.last_active_at} empty="No activity" />
        </span>
      ),
    },
    {
      key: 'usage',
      header: 'Last 30 days',
      render: (m) => (
        <span className="text-sm text-secondary-600 tabular-nums">
          {formatNumber(m.requests_30d)} requests · {formatNumber(m.changes_30d)} changes
        </span>
      ),
    },
    {
      key: 'security',
      header: 'Sign-in health',
      render: (m) =>
        m.failed_login_count > 0 ? (
          <Badge size="sm" variant="warning" title="Failed sign-ins since the last successful one">
            <ShieldAlert className="w-3 h-3 mr-1 inline" aria-hidden="true" />
            {m.failed_login_count} failed
          </Badge>
        ) : (
          <span className="text-sm text-secondary-400">OK</span>
        ),
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row gap-3">
        <div className="flex-1">
          <Input
            aria-label="Search members"
            placeholder="Search by name or email"
            leftIcon={<Search className="w-4 h-4" />}
            value={search}
            onChange={(e) => {
              setSearch(e.target.value);
              setPage(1);
            }}
          />
        </div>
        <div className="sm:w-52 shrink-0">
          <Select
            aria-label="Sort members"
            value={sort}
            onChange={(e) => {
              setSort(e.target.value as 'last_login' | 'name');
              setPage(1);
            }}
          >
            <option value="last_login">Recently signed in</option>
            <option value="name">Name</option>
          </Select>
        </div>
      </div>

      {error ? (
        <ErrorCard message={error} />
      ) : (
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(m) => m.user_uuid}
          onRowClick={(m) => onMember({ uuid: m.user_uuid, label: who(m) })}
          isLoading={loading && rows.length === 0}
          emptyMessage={q ? 'No members match your search' : 'No members yet'}
          caption="Workspace members with their last sign-in and activity"
        />
      )}

      {meta && meta.total_pages > 1 && (
        <Pagination
          currentPage={meta.page}
          totalPages={meta.total_pages}
          totalItems={meta.total}
          perPage={meta.per_page}
          onPageChange={setPage}
        />
      )}
    </div>
  );
}

// ── activity log ───────────────────────────────────────────────────────────

type Kind = 'all' | 'changes' | 'errors';
const KINDS: { id: Kind; label: string }[] = [
  { id: 'all', label: 'Everything' },
  { id: 'changes', label: 'Changes' },
  { id: 'errors', label: 'Failed' },
];

function Log({
  member,
  onMemberChange,
}: {
  member: MemberRef | null;
  onMemberChange: (m: MemberRef | null) => void;
}) {
  const [days, setDays] = useState(7);
  const [kind, setKind] = useState<Kind>('all');
  const [area, setArea] = useState('');
  const [res, setRes] = useState<{
    key: string;
    rows: ActivityEntry[];
    cursor?: string;
    error?: string;
  } | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);
  const [areas, setAreas] = useState<string[]>([]);
  const memberOptions = useMemberOptions(member);

  // Filter options: areas seen in the window.
  useEffect(() => {
    activityService
      .summary(days)
      .then((s) => setAreas(s.areas.map((a) => a.area)))
      .catch(() => {});
  }, [days]);

  const params = useMemo<ActivityLogParams>(
    () => ({
      days,
      kind: kind === 'all' ? undefined : kind,
      area: area || undefined,
      user_uuid: member?.uuid,
      limit: 50,
    }),
    [days, kind, area, member]
  );

  const key = JSON.stringify(params);

  useEffect(() => {
    let live = true;
    activityService
      .log(params)
      .then((r) => {
        if (live) setRes({ key, rows: r.data, cursor: r.nextCursor });
      })
      .catch((e) => {
        if (live)
          setRes({
            key,
            rows: [],
            error: extractApiError(e, 'Could not load the activity log'),
          });
      });
    return () => {
      live = false;
    };
  }, [key, params]);
  const loading = res?.key !== key;
  const rows = loading ? [] : (res?.rows ?? []);
  const cursor = loading ? undefined : res?.cursor;
  const error = loading ? null : res?.error;

  const loadMore = async () => {
    if (!cursor) return;
    setLoadingMore(true);
    try {
      const r = await activityService.log({ ...params, cursor });
      setRes((prev) =>
        prev && prev.key === key ? { ...prev, rows: [...prev.rows, ...r.data], cursor: r.nextCursor } : prev
      );
    } catch (e) {
      toast.error(extractApiError(e, 'Could not load more activity'));
    } finally {
      setLoadingMore(false);
    }
  };

  const columns: TableColumn<ActivityEntry>[] = [
    {
      key: 'occurred_at',
      header: 'When',
      render: (r) => (
        <div className="text-sm whitespace-nowrap">
          <Relative at={r.occurred_at} />
          <div className="text-xs text-secondary-500">
            {format(parseISO(r.occurred_at), 'd MMM, HH:mm:ss')}
          </div>
        </div>
      ),
    },
    {
      key: 'member',
      header: 'Member',
      render: (r) => (
        <div className="min-w-0 max-w-[15rem]">
          <div className="text-sm font-medium text-secondary-900 truncate" title={r.email}>
            {who(r)}
          </div>
          <div className="text-xs text-secondary-500 truncate">
            {r.via === 'api_key' && <KeyRound className="w-3 h-3 mr-1 inline" aria-hidden="true" />}
            {[r.via === 'api_key' ? 'API key' : browser(r.user_agent), r.ip].filter(Boolean).join(' · ') ||
              '—'}
          </div>
        </div>
      ),
    },
    {
      key: 'action',
      header: 'Action',
      render: (r) => {
        const { verb, what } = describe(r.action);
        const v = VERBS[verb];
        return (
          <div className="min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <Badge size="sm" variant={v?.variant ?? 'default'}>
                {v?.label ?? pretty(verb)}
              </Badge>
              <span className="text-sm text-secondary-800">{what}</span>
              {r.hits > 1 && (
                <span
                  className="text-xs text-secondary-500 tabular-nums"
                  title={`${r.hits} identical requests within the same minute`}
                >
                  ×{r.hits}
                </span>
              )}
            </div>
            <div className="mt-0.5 text-xs text-secondary-500 font-mono truncate max-w-[20rem]">
              {r.method} {r.route}
              {r.entity_id && <span className="text-secondary-400"> · {r.entity_id}</span>}
            </div>
          </div>
        );
      },
    },
    {
      key: 'status',
      header: 'Result',
      render: (r) => (
        <div className="whitespace-nowrap">
          <Badge size="sm" variant={statusVariant(r.status)}>
            {r.status}
          </Badge>
          {r.duration_ms != null && (
            <span className="ml-2 text-xs text-secondary-500 tabular-nums">
              {formatNumber(r.duration_ms)} ms
            </span>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-4">
      <Card className="p-3">
        <div className="flex flex-col lg:flex-row lg:flex-wrap lg:items-center gap-3">
          <div role="group" aria-label="What to show" className="inline-flex rounded-lg bg-secondary-100 p-1">
            {KINDS.map((k) => (
              <button
                key={k.id}
                onClick={() => setKind(k.id)}
                aria-pressed={kind === k.id}
                className={cn(
                  'px-3 py-1.5 text-sm rounded-md transition-colors cursor-pointer',
                  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500',
                  kind === k.id
                    ? 'bg-surface text-secondary-900 shadow-sm font-medium'
                    : 'text-secondary-600 hover:text-secondary-900'
                )}
              >
                {k.label}
              </button>
            ))}
          </div>
          <div className="lg:w-64 shrink-0">
            <SearchableSelect
              options={memberOptions}
              value={member?.uuid ?? ''}
              onChange={(uuid) => {
                const found = memberOptions.find((o) => o.value === uuid);
                onMemberChange(found ? { uuid: found.value, label: found.label } : null);
              }}
              placeholder="All members"
              searchPlaceholder="Find a member"
              clearable
            />
          </div>
          <div className="lg:w-48 shrink-0">
            <Select aria-label="Area" value={area} onChange={(e) => setArea(e.target.value)}>
              <option value="">All areas</option>
              {areas.map((a) => (
                <option key={a} value={a}>
                  {pretty(a)}
                </option>
              ))}
            </Select>
          </div>
          <div className="lg:w-40 shrink-0">
            <Select
              aria-label="Time range"
              value={String(days)}
              onChange={(e) => setDays(Number(e.target.value))}
            >
              <option value="1">Last 24 hours</option>
              <option value="7">Last 7 days</option>
              <option value="30">Last 30 days</option>
              <option value="90">Last 90 days</option>
            </Select>
          </div>
        </div>
      </Card>

      {error ? (
        <ErrorCard message={error} />
      ) : (
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(r) => r.cursor}
          isLoading={loading}
          emptyMessage="No activity matches these filters"
          caption="Activity log, newest first"
        />
      )}

      {cursor && !loading && (
        <div className="flex justify-center">
          <Button variant="outline" onClick={loadMore} disabled={loadingMore}>
            {loadingMore && <Loader2 className="w-4 h-4 mr-2 animate-spin" aria-hidden="true" />}
            Load more
          </Button>
        </div>
      )}
    </div>
  );
}

/** "All members" + the workspace's members, for a member filter. */
function useMemberOptions(member: MemberRef | null) {
  const [people, setPeople] = useState<MemberRef[]>([]);
  useEffect(() => {
    activityService
      .members({ sort: 'name', per_page: 100 })
      .then((r) => setPeople(r.data.map((m) => ({ uuid: m.user_uuid, label: who(m) }))))
      .catch(() => {});
  }, []);
  return useMemo(() => {
    const list = member && !people.some((p) => p.uuid === member.uuid) ? [member, ...people] : people;
    return [{ value: '', label: 'All members' }, ...list.map((p) => ({ value: p.uuid, label: p.label }))];
  }, [people, member]);
}

// ── audit trail ────────────────────────────────────────────────────────────

type ChangeAction = 'all' | 'created' | 'updated' | 'deleted';
const CHANGE_ACTIONS: { id: ChangeAction; label: string }[] = [
  { id: 'all', label: 'All' },
  { id: 'created', label: 'Created' },
  { id: 'updated', label: 'Updated' },
  { id: 'deleted', label: 'Deleted' },
];

const CHANGE_VERBS: Record<string, { label: string; variant: 'success' | 'warning' | 'error' }> = {
  created: { label: 'Created', variant: 'success' },
  updated: { label: 'Updated', variant: 'warning' },
  deleted: { label: 'Deleted', variant: 'error' },
};

// Bookkeeping columns that say nothing on their own in a create/delete.
const NOISE = new Set(['id', 'namespace_id', 'created_at', 'updated_at']);
const FIELDS_SHOWN = 4;

const entityLabel = (entity: string) => entity.split('.').map(pretty).join(' › ');

function actor(r: AuditChange) {
  if (r.user_uuid) return who(r);
  return r.via === 'anonymous' ? 'Public (signed out)' : 'System';
}

function show(v: unknown) {
  if (v === null || v === undefined || v === '') return '—';
  return typeof v === 'string' ? v : JSON.stringify(v);
}

function Value({ v, className }: { v: unknown; className?: string }) {
  const text = show(v);
  return (
    <span className={cn('truncate max-w-[14rem]', className)} title={text}>
      {text}
    </span>
  );
}

/** Field-level diff: "status: open → pending" for updates; values for creates/deletes. */
function FieldChanges({ r, expanded, onToggle }: { r: AuditChange; expanded: boolean; onToggle: () => void }) {
  const isUpdate = !!r.old_values && !!r.new_values;
  const values = r.new_values ?? r.old_values ?? {};
  const keys = isUpdate
    ? Array.from(new Set([...Object.keys(r.old_values ?? {}), ...Object.keys(r.new_values ?? {})]))
    : Object.keys(values).filter((k) => !NOISE.has(k) && show(values[k]) !== '—');
  if (keys.length === 0) return <span className="text-sm text-secondary-400">—</span>;
  const shown = expanded ? keys : keys.slice(0, FIELDS_SHOWN);

  return (
    <div className="text-xs min-w-0">
      <dl className="space-y-0.5">
        {shown.map((k) => (
          <div key={k} className="flex items-baseline gap-1.5 min-w-0">
            <dt className="text-secondary-500 shrink-0">{pretty(k)}:</dt>
            <dd className="flex items-baseline gap-1.5 min-w-0 text-secondary-800">
              {isUpdate ? (
                <>
                  <Value v={r.old_values?.[k]} className="text-secondary-500 line-through" />
                  <ArrowRight className="w-3 h-3 shrink-0 self-center text-secondary-400" aria-label="changed to" />
                  <Value v={r.new_values?.[k]} className="font-medium" />
                </>
              ) : (
                <Value v={values[k]} />
              )}
            </dd>
          </div>
        ))}
      </dl>
      {keys.length > FIELDS_SHOWN && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onToggle();
          }}
          aria-expanded={expanded}
          className="mt-1 text-primary-600 hover:underline cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 rounded"
        >
          {expanded ? 'Show less' : `Show all ${keys.length} fields`}
        </button>
      )}
    </div>
  );
}

function Changes() {
  const [days, setDays] = useState(30);
  const [action, setAction] = useState<ChangeAction>('all');
  const [entity, setEntity] = useState('');
  const [record, setRecord] = useState<{ entity: string; id: string } | null>(null);
  const [member, setMember] = useState<MemberRef | null>(null);
  const [entities, setEntities] = useState<string[]>([]);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [loadingMore, setLoadingMore] = useState(false);
  const [res, setRes] = useState<{
    key: string;
    rows: AuditChange[];
    cursor?: string;
    error?: string;
  } | null>(null);
  const memberOptions = useMemberOptions(member);

  const params = useMemo<AuditChangeParams>(
    () => ({
      days,
      action: action === 'all' ? undefined : action,
      entity: record?.entity ?? (entity || undefined),
      entity_id: record?.id,
      user_uuid: member?.uuid,
      limit: 50,
    }),
    [days, action, entity, record, member]
  );
  const key = JSON.stringify(params);

  useEffect(() => {
    let live = true;
    activityService
      .changes(params)
      .then((r) => {
        if (!live) return;
        setRes({ key, rows: r.data, cursor: r.nextCursor });
        if (r.entities) setEntities(r.entities);
      })
      .catch((e) => {
        if (live) setRes({ key, rows: [], error: extractApiError(e, 'Could not load the audit trail') });
      });
    return () => {
      live = false;
    };
  }, [key, params]);
  const loading = res?.key !== key;
  const rows = loading ? [] : (res?.rows ?? []);
  const cursor = loading ? undefined : res?.cursor;
  const error = loading ? null : res?.error;

  const loadMore = async () => {
    if (!cursor) return;
    setLoadingMore(true);
    try {
      const r = await activityService.changes({ ...params, cursor });
      setRes((prev) =>
        prev && prev.key === key ? { ...prev, rows: [...prev.rows, ...r.data], cursor: r.nextCursor } : prev
      );
    } catch (e) {
      toast.error(extractApiError(e, 'Could not load more changes'));
    } finally {
      setLoadingMore(false);
    }
  };

  const toggle = (c: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (!next.delete(c)) next.add(c);
      return next;
    });

  const columns: TableColumn<AuditChange>[] = [
    {
      key: 'occurred_at',
      header: 'When',
      render: (r) => (
        <div className="text-sm whitespace-nowrap">
          <Relative at={r.occurred_at} />
          <div className="text-xs text-secondary-500">{format(parseISO(r.occurred_at), 'd MMM, HH:mm:ss')}</div>
        </div>
      ),
    },
    {
      key: 'member',
      header: 'Who',
      render: (r) => (
        <div className="min-w-0 max-w-[13rem]">
          <div
            className={cn('text-sm truncate', r.user_uuid ? 'font-medium text-secondary-900' : 'text-secondary-500')}
            title={r.email}
          >
            {actor(r)}
          </div>
          <div className="text-xs text-secondary-500 truncate">
            {r.via === 'api_key' && <KeyRound className="w-3 h-3 mr-1 inline" aria-hidden="true" />}
            {[r.via === 'api_key' ? 'API key' : null, r.ip].filter(Boolean).join(' · ') || '\u00a0'}
          </div>
        </div>
      ),
    },
    {
      key: 'record',
      header: 'Record',
      render: (r) => {
        const verb = r.event.startsWith(r.entity + '.') ? r.event.slice(r.entity.length + 1) : r.event;
        const v = CHANGE_VERBS[verb];
        return (
          <div className="min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <Badge size="sm" variant={v?.variant ?? 'info'}>
                {v?.label ?? pretty(verb)}
              </Badge>
              <span className="text-sm text-secondary-800">{entityLabel(r.entity)}</span>
            </div>
            {r.entity_id && (
              <button
                onClick={() => setRecord({ entity: r.entity, id: r.entity_id! })}
                title="Show this record's full history"
                className="mt-0.5 inline-flex items-center gap-1 text-xs font-mono text-secondary-500 hover:text-primary-600 max-w-[16rem] cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 rounded"
              >
                <History className="w-3 h-3 shrink-0" aria-hidden="true" />
                <span className="truncate">{r.entity_id}</span>
              </button>
            )}
          </div>
        );
      },
    },
    {
      key: 'changes',
      header: 'Changes',
      render: (r) => (
        <FieldChanges r={r} expanded={expanded.has(r.cursor)} onToggle={() => toggle(r.cursor)} />
      ),
    },
  ];

  return (
    <div className="space-y-4">
      <Card className="p-3">
        <div className="flex flex-col lg:flex-row lg:flex-wrap lg:items-center gap-3">
          <div role="group" aria-label="Kind of change" className="inline-flex rounded-lg bg-secondary-100 p-1">
            {CHANGE_ACTIONS.map((a) => (
              <button
                key={a.id}
                onClick={() => setAction(a.id)}
                aria-pressed={action === a.id}
                className={cn(
                  'px-3 py-1.5 text-sm rounded-md transition-colors cursor-pointer',
                  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500',
                  action === a.id
                    ? 'bg-surface text-secondary-900 shadow-sm font-medium'
                    : 'text-secondary-600 hover:text-secondary-900'
                )}
              >
                {a.label}
              </button>
            ))}
          </div>
          <div className="lg:w-64 shrink-0">
            <SearchableSelect
              options={memberOptions}
              value={member?.uuid ?? ''}
              onChange={(uuid) => {
                const found = memberOptions.find((o) => o.value === uuid && o.value);
                setMember(found ? { uuid: found.value, label: found.label } : null);
              }}
              placeholder="All members"
              searchPlaceholder="Find a member"
              clearable
            />
          </div>
          <div className="lg:w-52 shrink-0">
            <Select
              aria-label="Record type"
              value={record?.entity ?? entity}
              disabled={!!record}
              onChange={(e) => setEntity(e.target.value)}
            >
              <option value="">All record types</option>
              {entities.map((e) => (
                <option key={e} value={e}>
                  {entityLabel(e)}
                </option>
              ))}
            </Select>
          </div>
          <div className="lg:w-40 shrink-0">
            <Select aria-label="Time range" value={String(days)} onChange={(e) => setDays(Number(e.target.value))}>
              <option value="1">Last 24 hours</option>
              <option value="7">Last 7 days</option>
              <option value="30">Last 30 days</option>
              <option value="90">Last 90 days</option>
              <option value="365">Last 12 months</option>
            </Select>
          </div>
        </div>
        {record && (
          <div className="mt-3 flex items-center gap-2 text-sm text-secondary-700">
            <History className="w-4 h-4 text-primary-600 shrink-0" aria-hidden="true" />
            <span className="min-w-0 truncate">
              History of {entityLabel(record.entity)} <span className="font-mono text-xs">{record.id}</span>
            </span>
            <Button size="sm" variant="ghost" onClick={() => setRecord(null)}>
              Show all records
            </Button>
          </div>
        )}
      </Card>

      {error ? (
        <ErrorCard message={error} />
      ) : (
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(r) => r.cursor}
          isLoading={loading}
          emptyMessage="No record changes match these filters"
          caption="Record changes, newest first"
        />
      )}

      {cursor && !loading && (
        <div className="flex justify-center">
          <Button variant="outline" onClick={loadMore} disabled={loadingMore}>
            {loadingMore && <Loader2 className="w-4 h-4 mr-2 animate-spin" aria-hidden="true" />}
            Load more
          </Button>
        </div>
      )}
    </div>
  );
}

// ── AI usage ───────────────────────────────────────────────────────────────

const FEATURES: Record<string, string> = {
  assistant: 'AI assistant',
  tax_classify: 'Transaction classification',
  statement_extract: 'Statement reading',
  bookkeeping: 'Bookkeeping AI',
  tax_chat: 'Tax AI chat',
  health_check: 'Model health checks',
  other: 'Other',
};

const compact = (n: number) =>
  new Intl.NumberFormat('en-GB', { notation: 'compact', maximumFractionDigits: 1 }).format(n);

type AiMember = AiUsageSummary['members'][number];
type AiWorkspace = NonNullable<AiUsageSummary['workspaces']>[number];

const tokenCells = <T extends { input_tokens: number; output_tokens: number }>(): TableColumn<T>[] => [
  { key: 'input_tokens', header: 'Tokens in', render: (r) => formatNumber(r.input_tokens) },
  { key: 'output_tokens', header: 'Tokens out', render: (r) => formatNumber(r.output_tokens) },
  {
    key: 'total',
    header: 'Total tokens',
    render: (r) => <span className="font-medium">{formatNumber(r.input_tokens + r.output_tokens)}</span>,
  },
];

const MEMBER_COLUMNS: TableColumn<AiMember>[] = [
  {
    key: 'member',
    header: 'Member',
    render: (m) => (
      <span className="min-w-0">
        <span className="block font-medium text-secondary-800 truncate">{who(m)}</span>
        {m.name && m.email && <span className="block text-xs text-secondary-500 truncate">{m.email}</span>}
      </span>
    ),
  },
  { key: 'requests', header: 'Requests', render: (m) => formatNumber(m.requests) },
  { key: 'model_calls', header: 'Model calls', render: (m) => formatNumber(m.model_calls) },
  ...tokenCells<AiMember>(),
  { key: 'last_used_at', header: 'Last used', render: (m) => <Relative at={m.last_used_at} /> },
];

const WORKSPACE_COLUMNS: TableColumn<AiWorkspace>[] = [
  {
    key: 'workspace',
    header: 'Workspace',
    render: (w) => <span className="font-medium text-secondary-800">{w.name || 'No workspace'}</span>,
  },
  { key: 'users', header: 'Members using AI', render: (w) => formatNumber(w.users) },
  { key: 'requests', header: 'Requests', render: (w) => formatNumber(w.requests) },
  ...tokenCells<AiWorkspace>(),
];

function AiUsage() {
  const { isAdmin } = usePermissions();
  const [days, setDays] = useState(30);
  const [all, setAll] = useState(false);
  const [res, setRes] = useState<{ key: string; data?: AiUsageSummary; error?: string } | null>(null);
  const key = `${days}:${all}`;

  useEffect(() => {
    let live = true;
    const k = `${days}:${all}`;
    (all ? aiUsageService.platform(days) : aiUsageService.workspace(days))
      .then((data) => {
        if (live) setRes({ key: k, data });
      })
      .catch((e) => {
        if (live) setRes({ key: k, error: extractApiError(e, 'Could not load AI usage') });
      });
    return () => {
      live = false;
    };
  }, [days, all]);
  const current = res?.key === key ? res : null;
  const data = current?.data;

  const series = useMemo(() => (data?.series ?? []).map((d) => ({ ...d, label: dayLabel(d.day) })), [data]);
  const maxFeature = Math.max(1, ...(data?.features ?? []).map((f) => f.input_tokens + f.output_tokens));

  const controls = (
    <div className="flex flex-wrap justify-end gap-2">
      {isAdmin && (
        <div className="w-48">
          <Select aria-label="Scope" value={all ? 'all' : 'ws'} onChange={(e) => setAll(e.target.value === 'all')}>
            <option value="ws">This workspace</option>
            <option value="all">All workspaces</option>
          </Select>
        </div>
      )}
      <div className="w-44">
        <Select aria-label="Time range" value={String(days)} onChange={(e) => setDays(Number(e.target.value))}>
          <option value="7">Last 7 days</option>
          <option value="30">Last 30 days</option>
          <option value="90">Last 90 days</option>
          <option value="365">Last 12 months</option>
        </Select>
      </div>
    </div>
  );

  if (!data) {
    return (
      <div className="space-y-6">
        {controls}
        {current?.error ? <ErrorCard message={current.error} /> : <LoadingCard />}
      </div>
    );
  }

  const t = data.totals;
  const tokens = t.input_tokens + t.output_tokens;
  const failRate = t.model_calls > 0 ? (t.failed / t.model_calls) * 100 : 0;

  return (
    <div className="space-y-6">
      {controls}

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <StatCard
          icon={<Sparkles size={18} />}
          label="AI requests"
          value={formatNumber(t.requests)}
          sub={`${formatNumber(t.model_calls)} model calls`}
          tone="primary"
        />
        <StatCard
          icon={<Coins size={18} />}
          label="Tokens used"
          value={compact(tokens)}
          sub={`${compact(t.input_tokens)} in · ${compact(t.output_tokens)} out${
            t.cached_input_tokens ? ` · ${compact(t.cached_input_tokens)} cached` : ''
          }`}
          tone="success"
        />
        <StatCard
          icon={<Users size={18} />}
          label="Members using AI"
          value={formatNumber(t.users)}
          sub={`last ${days} days`}
        />
        <StatCard
          icon={<AlertTriangle size={18} />}
          label="Failed model calls"
          value={formatNumber(t.failed)}
          sub={`${failRate.toFixed(1)}% · avg ${(t.avg_latency_ms / 1000).toFixed(1)}s per call`}
          tone={failRate > 5 ? 'warning' : 'default'}
        />
      </div>

      {t.model_calls === 0 ? (
        <Card className="p-10 text-center">
          <Sparkles className="w-8 h-8 mx-auto text-secondary-300" aria-hidden="true" />
          <p className="mt-3 font-medium text-secondary-700">No AI usage in the last {days} days</p>
          <p className="mt-1 text-sm text-secondary-500">
            Every request to the AI assistant and the other AI features shows up here.
          </p>
        </Card>
      ) : (
        <>
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <ChartCard title="Tokens per day">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={series} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
                  <XAxis dataKey="label" tick={{ fontSize: 11 }} stroke="#94a3b8" minTickGap={16} />
                  <YAxis tick={{ fontSize: 11 }} stroke="#94a3b8" tickFormatter={compact} />
                  <Tooltip cursor={{ fill: '#f1f5f9' }} formatter={(v) => formatNumber(Number(v))} />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                  <Bar dataKey="input_tokens" name="Tokens in" stackId="t" fill="#3b82f6" />
                  <Bar dataKey="output_tokens" name="Tokens out" stackId="t" fill="#8b5cf6" radius={[3, 3, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            </ChartCard>
            <ChartCard title="Requests per day">
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart data={series} margin={{ top: 8, right: 8, left: -18, bottom: 0 }}>
                  <defs>
                    <linearGradient id="gAiRequests" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor="#3b82f6" stopOpacity={0.35} />
                      <stop offset="95%" stopColor="#3b82f6" stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
                  <XAxis dataKey="label" tick={{ fontSize: 11 }} stroke="#94a3b8" minTickGap={16} />
                  <YAxis allowDecimals={false} tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <Tooltip />
                  <Area
                    type="monotone"
                    dataKey="requests"
                    name="Requests"
                    stroke="#3b82f6"
                    fill="url(#gAiRequests)"
                    strokeWidth={2}
                  />
                </AreaChart>
              </ResponsiveContainer>
            </ChartCard>
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <Card className="p-4">
              <h3 className="text-sm font-semibold text-secondary-700 mb-3">By feature</h3>
              <ul className="space-y-2.5">
                {data.features.map((f) => (
                  <li key={f.feature}>
                    <div className="flex items-baseline justify-between gap-3 text-sm">
                      <span className="font-medium text-secondary-800 truncate">
                        {FEATURES[f.feature] ?? pretty(f.feature)}
                      </span>
                      <span className="text-xs text-secondary-500 tabular-nums shrink-0">
                        {formatNumber(f.requests)} requests · {compact(f.input_tokens + f.output_tokens)} tokens
                      </span>
                    </div>
                    <div className="mt-1 h-1.5 rounded-full bg-secondary-100 overflow-hidden">
                      <div
                        className="h-full rounded-full bg-primary-500"
                        style={{ width: `${Math.max(2, ((f.input_tokens + f.output_tokens) / maxFeature) * 100)}%` }}
                      />
                    </div>
                  </li>
                ))}
              </ul>
            </Card>
            <Card className="p-4">
              <h3 className="text-sm font-semibold text-secondary-700 mb-3">By model</h3>
              <ul className="divide-y divide-secondary-100">
                {data.models.map((m) => (
                  <li key={`${m.provider}/${m.model}`} className="flex items-center justify-between gap-3 py-2.5">
                    <span className="min-w-0">
                      <span className="block text-sm font-medium text-secondary-800 truncate">{m.model}</span>
                      <span className="block text-xs text-secondary-500">{pretty(m.provider)}</span>
                    </span>
                    <span className="text-xs text-secondary-500 tabular-nums shrink-0">
                      {formatNumber(m.model_calls)} calls · {compact(m.input_tokens)} in
                      {m.cached_input_tokens ? ` (${compact(m.cached_input_tokens)} cached)` : ''} ·{' '}
                      {compact(m.output_tokens)} out
                    </span>
                  </li>
                ))}
              </ul>
            </Card>
          </div>

          {data.workspaces && (
            <Card className="p-4">
              <h3 className="text-sm font-semibold text-secondary-700 mb-3">By workspace</h3>
              <Table
                columns={WORKSPACE_COLUMNS}
                data={data.workspaces}
                keyExtractor={(w) => w.namespace_uuid ?? 'none'}
                caption="AI usage by workspace"
              />
            </Card>
          )}

          <Card className="p-4">
            <h3 className="text-sm font-semibold text-secondary-700 mb-3">By member</h3>
            <Table
              columns={MEMBER_COLUMNS}
              data={data.members}
              keyExtractor={(m) => m.user_uuid}
              emptyMessage="Only system calls (health checks) in this period."
              caption="AI usage by member"
            />
          </Card>
        </>
      )}
    </div>
  );
}

// ── states ─────────────────────────────────────────────────────────────────

function LoadingCard() {
  return (
    <Card className="p-12">
      <div className="flex items-center justify-center gap-3 text-secondary-500" role="status">
        <Loader2 className="w-5 h-5 animate-spin" aria-hidden="true" />
        Loading activity…
      </div>
    </Card>
  );
}

function ErrorCard({ message }: { message: string }) {
  return (
    <Card className="p-6">
      <div className="flex items-center gap-3 text-error-600" role="alert">
        <AlertTriangle className="w-5 h-5 shrink-0" aria-hidden="true" />
        <p className="text-sm">{message}</p>
      </div>
    </Card>
  );
}
