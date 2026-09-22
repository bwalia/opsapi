'use client';

import React, { useEffect, useMemo, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  RefreshCw,
  Loader2,
  ListChecks,
  CheckCircle2,
  Timer,
  AlertTriangle,
  Ban,
  Target,
  Clock,
  Users,
} from 'lucide-react';
import {
  ResponsiveContainer,
  PieChart,
  Pie,
  Cell,
  BarChart,
  Bar,
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
} from 'recharts';
import Button from '@/components/ui/Button';
import Card from '@/components/ui/Card';
import { useKanbanStore } from '@/store/kanban.store';
import { analyticsService, formatPercentage } from '@/services/analytics.service';
import type {
  ProjectAnalyticsStats,
  CompletionTrendResponse,
  PriorityDistribution,
  TeamWorkloadMember,
  CycleTimeResponse,
  KanbanTaskPriority,
} from '@/types';

const n = (v: unknown): number => Number(v) || 0;

const STATUS_COLORS: Record<string, string> = {
  open: '#94a3b8',
  in_progress: '#3b82f6',
  blocked: '#ef4444',
  review: '#a855f7',
  completed: '#22c55e',
  cancelled: '#9ca3af',
};

const PRIORITY_COLORS: Record<KanbanTaskPriority, string> = {
  critical: '#ef4444',
  high: '#f97316',
  medium: '#eab308',
  low: '#3b82f6',
  none: '#9ca3af',
};

// ============================================
// Small presentational pieces
// ============================================

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
  tone?: 'default' | 'success' | 'warning' | 'danger';
}) {
  const toneClasses = {
    default: 'text-secondary-600 bg-secondary-100',
    success: 'text-green-600 bg-green-100',
    warning: 'text-yellow-600 bg-yellow-100',
    danger: 'text-red-600 bg-red-100',
  }[tone];
  return (
    <Card className="p-4">
      <div className="flex items-center gap-3">
        <div className={`w-10 h-10 rounded-lg flex items-center justify-center shrink-0 ${toneClasses}`}>
          {icon}
        </div>
        <div className="min-w-0">
          <p className="text-2xl font-bold text-secondary-900 leading-tight">{value}</p>
          <p className="text-xs text-secondary-500 truncate">{label}</p>
          {sub && <p className="text-[11px] text-secondary-400 truncate">{sub}</p>}
        </div>
      </div>
    </Card>
  );
}

function ChartCard({
  title,
  children,
  empty,
}: {
  title: string;
  children: React.ReactNode;
  empty?: boolean;
}) {
  return (
    <Card className="p-4">
      <h3 className="text-sm font-semibold text-secondary-700 mb-3">{title}</h3>
      {empty ? (
        <div className="h-[260px] flex items-center justify-center text-sm text-secondary-400">
          No data yet
        </div>
      ) : (
        <div className="h-[260px]">{children}</div>
      )}
    </Card>
  );
}

const prettyDate = (iso: string) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime())
    ? iso
    : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
};

// ============================================
// Page
// ============================================

export default function ProjectAnalyticsPage() {
  const { uuid } = useParams<{ uuid: string }>();
  const router = useRouter();
  const { currentProject } = useKanbanStore();

  const [stats, setStats] = useState<ProjectAnalyticsStats | null>(null);
  const [trend, setTrend] = useState<CompletionTrendResponse | null>(null);
  const [priority, setPriority] = useState<PriorityDistribution[]>([]);
  const [workload, setWorkload] = useState<TeamWorkloadMember[]>([]);
  const [cycle, setCycle] = useState<CycleTimeResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    if (!uuid) return;
    let cancelled = false;
    const load = async () => {
      setLoading(true);
      setError(null);
      // Each endpoint is independent — render whatever succeeds rather than
      // blanking the whole page if one call fails.
      const [s, t, p, w, c] = await Promise.allSettled([
        analyticsService.getProjectStats(uuid),
        analyticsService.getCompletionTrend(uuid, 30),
        analyticsService.getPriorityDistribution(uuid),
        analyticsService.getTeamWorkload(uuid),
        analyticsService.getCycleTime(uuid),
      ]);
      if (cancelled) return;
      if (s.status === 'fulfilled') setStats(s.value);
      else setError('Some analytics could not be loaded.');
      setTrend(t.status === 'fulfilled' ? t.value : null);
      setPriority(p.status === 'fulfilled' ? p.value : []);
      setWorkload(w.status === 'fulfilled' ? w.value : []);
      setCycle(c.status === 'fulfilled' ? c.value : null);
      setLoading(false);
    };
    load();
    return () => {
      cancelled = true;
    };
  }, [uuid, reloadKey]);

  const statusData = useMemo(() => {
    if (!stats) return [];
    const t = stats.tasks;
    return [
      { key: 'open', name: 'Open', value: n(t.open_tasks) },
      { key: 'in_progress', name: 'In progress', value: n(t.in_progress_tasks) },
      { key: 'blocked', name: 'Blocked', value: n(t.blocked_tasks) },
      { key: 'review', name: 'Review', value: n(t.review_tasks) },
      { key: 'completed', name: 'Completed', value: n(t.completed_tasks) },
      { key: 'cancelled', name: 'Cancelled', value: n(t.cancelled_tasks) },
    ].filter((d) => d.value > 0);
  }, [stats]);

  const priorityData = useMemo(
    () =>
      priority.map((p) => ({
        name: p.priority,
        Total: n(p.count),
        Active: n(p.active_count),
        fill: PRIORITY_COLORS[p.priority] ?? PRIORITY_COLORS.none,
      })),
    [priority]
  );

  const trendData = useMemo(
    () =>
      (trend?.trend ?? []).map((pt) => ({
        date: prettyDate(pt.date),
        Created: n(pt.created_count),
        Completed: n(pt.completed_count),
      })),
    [trend]
  );

  const workloadData = useMemo(
    () =>
      workload.map((m) => ({
        name: `${m.first_name ?? ''} ${m.last_name ?? ''}`.trim() || m.email || 'Unknown',
        Active: n(m.active_tasks),
        Completed: n(m.completed_tasks),
        Overdue: n(m.overdue_tasks),
      })),
    [workload]
  );

  const cycleData = useMemo(
    () =>
      (cycle?.by_priority ?? []).map((c) => ({
        name: c.priority,
        hours: Math.round(n(c.avg_hours) * 10) / 10,
        fill: PRIORITY_COLORS[c.priority] ?? PRIORITY_COLORS.none,
      })),
    [cycle]
  );

  const totalHours = stats ? Math.round((n(stats.time?.total_minutes) / 60) * 10) / 10 : 0;
  const billableHours = stats ? Math.round((n(stats.time?.billable_minutes) / 60) * 10) / 10 : 0;

  return (
    <div className="p-4 sm:p-6 max-w-7xl mx-auto space-y-5">
      {/* Header */}
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-3 min-w-0">
          <Button variant="ghost" size="sm" onClick={() => router.push(`/dashboard/projects/${uuid}`)}>
            <ArrowLeft size={18} />
          </Button>
          <div className="min-w-0">
            <h1 className="text-xl font-bold text-secondary-900 truncate">Analytics</h1>
            <p className="text-sm text-secondary-500 truncate">
              {currentProject?.name || 'Project insights'}
            </p>
          </div>
        </div>
        <Button
          variant="outline"
          size="sm"
          onClick={() => setReloadKey((k) => k + 1)}
          disabled={loading}
        >
          <RefreshCw size={16} className={loading ? 'animate-spin' : ''} />
          <span className="ml-2 hidden sm:inline">Refresh</span>
        </Button>
      </div>

      {error && (
        <div className="flex items-center gap-2 text-sm text-yellow-700 bg-yellow-50 border border-yellow-200 rounded-lg px-3 py-2">
          <AlertTriangle size={16} />
          {error}
        </div>
      )}

      {loading && !stats ? (
        <div className="h-[50vh] flex items-center justify-center">
          <Loader2 className="w-6 h-6 text-primary-500 animate-spin" />
        </div>
      ) : (
        <>
          {/* KPI cards */}
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
            <StatCard
              icon={<ListChecks size={18} />}
              label="Total tasks"
              value={n(stats?.tasks?.total_tasks)}
              sub={`${n(stats?.boards?.board_count)} boards · ${n(stats?.members?.member_count)} members`}
            />
            <StatCard
              icon={<CheckCircle2 size={18} />}
              label="Completed"
              value={n(stats?.tasks?.completed_tasks)}
              sub={`${formatPercentage(n(stats?.progress_percentage))} progress`}
              tone="success"
            />
            <StatCard
              icon={<Timer size={18} />}
              label="In progress"
              value={n(stats?.tasks?.in_progress_tasks)}
              sub={`${n(stats?.tasks?.review_tasks)} in review`}
            />
            <StatCard
              icon={<AlertTriangle size={18} />}
              label="Overdue"
              value={n(stats?.tasks?.overdue_tasks)}
              sub={`${n(stats?.tasks?.due_today_tasks)} due today`}
              tone={n(stats?.tasks?.overdue_tasks) > 0 ? 'danger' : 'default'}
            />
            <StatCard
              icon={<Ban size={18} />}
              label="Blocked"
              value={n(stats?.tasks?.blocked_tasks)}
              tone={n(stats?.tasks?.blocked_tasks) > 0 ? 'warning' : 'default'}
            />
            <StatCard
              icon={<Target size={18} />}
              label="Story points"
              value={`${n(stats?.tasks?.completed_points)}/${n(stats?.tasks?.total_points)}`}
              sub="completed / total"
            />
            <StatCard
              icon={<Clock size={18} />}
              label="Time logged"
              value={`${totalHours}h`}
              sub={`${billableHours}h billable`}
            />
            <StatCard
              icon={<Users size={18} />}
              label="Sprints"
              value={n(stats?.sprints?.active_sprints)}
              sub={`${n(stats?.sprints?.completed_sprints)} completed`}
            />
          </div>

          {/* Charts */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            {/* Completion trend */}
            <ChartCard title="Created vs completed (30 days)" empty={trendData.length === 0}>
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart data={trendData} margin={{ top: 8, right: 8, left: -18, bottom: 0 }}>
                  <defs>
                    <linearGradient id="gCreated" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor="#3b82f6" stopOpacity={0.35} />
                      <stop offset="95%" stopColor="#3b82f6" stopOpacity={0} />
                    </linearGradient>
                    <linearGradient id="gCompleted" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor="#22c55e" stopOpacity={0.35} />
                      <stop offset="95%" stopColor="#22c55e" stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" />
                  <XAxis dataKey="date" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <YAxis allowDecimals={false} tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <Tooltip />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                  <Area type="monotone" dataKey="Created" stroke="#3b82f6" fill="url(#gCreated)" strokeWidth={2} />
                  <Area type="monotone" dataKey="Completed" stroke="#22c55e" fill="url(#gCompleted)" strokeWidth={2} />
                </AreaChart>
              </ResponsiveContainer>
            </ChartCard>

            {/* Status distribution */}
            <ChartCard title="Tasks by status" empty={statusData.length === 0}>
              <ResponsiveContainer width="100%" height="100%">
                <PieChart>
                  <Pie
                    data={statusData}
                    dataKey="value"
                    nameKey="name"
                    innerRadius={60}
                    outerRadius={95}
                    paddingAngle={2}
                  >
                    {statusData.map((d) => (
                      <Cell key={d.key} fill={STATUS_COLORS[d.key]} />
                    ))}
                  </Pie>
                  <Tooltip />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                </PieChart>
              </ResponsiveContainer>
            </ChartCard>

            {/* Priority distribution */}
            <ChartCard title="Tasks by priority" empty={priorityData.length === 0}>
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={priorityData} margin={{ top: 8, right: 8, left: -18, bottom: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
                  <XAxis dataKey="name" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <YAxis allowDecimals={false} tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <Tooltip cursor={{ fill: '#f1f5f9' }} />
                  <Bar dataKey="Total" radius={[4, 4, 0, 0]}>
                    {priorityData.map((d, i) => (
                      <Cell key={i} fill={d.fill} />
                    ))}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
            </ChartCard>

            {/* Cycle time by priority */}
            <ChartCard title="Avg lead time by priority (hours)" empty={cycleData.length === 0}>
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={cycleData} margin={{ top: 8, right: 8, left: -18, bottom: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
                  <XAxis dataKey="name" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <YAxis tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <Tooltip cursor={{ fill: '#f1f5f9' }} />
                  <Bar dataKey="hours" radius={[4, 4, 0, 0]}>
                    {cycleData.map((d, i) => (
                      <Cell key={i} fill={d.fill} />
                    ))}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
            </ChartCard>
          </div>

          {/* Team workload — full width */}
          <ChartCard title="Team workload" empty={workloadData.length === 0}>
            <ResponsiveContainer width="100%" height="100%">
              <BarChart
                data={workloadData}
                layout="vertical"
                margin={{ top: 8, right: 8, left: 8, bottom: 0 }}
              >
                <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" horizontal={false} />
                <XAxis type="number" allowDecimals={false} tick={{ fontSize: 11 }} stroke="#94a3b8" />
                <YAxis type="category" dataKey="name" width={110} tick={{ fontSize: 11 }} stroke="#94a3b8" />
                <Tooltip cursor={{ fill: '#f1f5f9' }} />
                <Legend wrapperStyle={{ fontSize: 12 }} />
                <Bar dataKey="Active" stackId="w" fill="#3b82f6" />
                <Bar dataKey="Completed" stackId="w" fill="#22c55e" />
                <Bar dataKey="Overdue" stackId="w" fill="#ef4444" radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </ChartCard>
        </>
      )}
    </div>
  );
}
