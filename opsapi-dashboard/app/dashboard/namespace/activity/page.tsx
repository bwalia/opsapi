'use client';

/**
 * Workspace activity — who signed in and what they did in this workspace.
 * Visible to roles with `activity.read` (owners and admins by default).
 * Sign-in IPs and login history stay with platform admins (Grafana): a login
 * isn't tied to one workspace. See USER_ACTIVITY.md.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Activity,
  AlertTriangle,
  ArrowRight,
  KeyRound,
  Loader2,
  PencilLine,
  Search,
  ShieldAlert,
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
import { activityService } from '@/services';
import type {
  ActivityEntry,
  ActivityLogParams,
  ActivityMember,
  ActivitySummary,
  MemberPageMeta,
} from '@/services/activity.service';
import { cn, extractApiError, formatDateTime, formatNumber, formatRelativeTime } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

type Tab = 'overview' | 'members' | 'log';
type MemberRef = { uuid: string; label: string };

const TABS: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'members', label: 'Members' },
  { id: 'log', label: 'Activity log' },
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
  const [people, setPeople] = useState<MemberRef[]>([]);

  // Filter options: areas seen in the window, and the workspace's members.
  useEffect(() => {
    activityService
      .summary(days)
      .then((s) => setAreas(s.areas.map((a) => a.area)))
      .catch(() => {});
  }, [days]);
  useEffect(() => {
    activityService
      .members({ sort: 'name', per_page: 100 })
      .then((r) => setPeople(r.data.map((m) => ({ uuid: m.user_uuid, label: who(m) }))))
      .catch(() => {});
  }, []);

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

  const memberOptions = useMemo(() => {
    const list = member && !people.some((p) => p.uuid === member.uuid) ? [member, ...people] : people;
    return [{ value: '', label: 'All members' }, ...list.map((p) => ({ value: p.uuid, label: p.label }))];
  }, [people, member]);

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
