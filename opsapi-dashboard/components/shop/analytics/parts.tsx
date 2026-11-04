'use client';

import React, { memo } from 'react';
import { ArrowDownRight, ArrowUpRight, Minus } from 'lucide-react';
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { cn } from '@/lib/utils';
import type { AnalyticsBucket, AnalyticsPoint } from '@/types/shop-analytics';

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

const gbp0 = new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP', maximumFractionDigits: 0 });
const gbpCompact = new Intl.NumberFormat('en-GB', {
  style: 'currency',
  currency: 'GBP',
  notation: 'compact',
  maximumFractionDigits: 1,
});
const int = new Intl.NumberFormat('en-GB');

/** Whole pounds for headline figures (pence in tooltips and tables). */
export const pounds = (minor: number | null | undefined) =>
  minor === null || minor === undefined ? '—' : gbp0.format(minor / 100);
export const poundsCompact = (minor: number) => gbpCompact.format(minor / 100);
export const count = (n: number | null | undefined) => (n === null || n === undefined ? '—' : int.format(n));
export const pct = (r: number | null | undefined, dp = 1) =>
  r === null || r === undefined ? '—' : `${(r * 100).toFixed(dp).replace(/\.0$/, '')}%`;

const dayFmt = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', timeZone: 'UTC' });
const monthFmt = new Intl.DateTimeFormat('en-GB', { month: 'short', year: 'numeric', timeZone: 'UTC' });
const longFmt = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });

/** "2026-10-06" → "6 Oct" (day/week) or "Oct 2026" (month). Dates are UK calendar days. */
export function bucketLabel(bucket: string, kind: AnalyticsBucket): string {
  const d = new Date(`${bucket}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return bucket;
  return kind === 'month' ? monthFmt.format(d) : dayFmt.format(d);
}
export const longDate = (s: string) => {
  const d = new Date(`${s}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? s : longFmt.format(d);
};

// ---------------------------------------------------------------------------
// KPI tile
// ---------------------------------------------------------------------------

export interface KpiTileProps {
  label: string;
  value: string;
  sub?: React.ReactNode;
  /** Relative change vs the previous period (0.25 = +25%); null/undefined = no comparison. */
  change?: number | null;
  /** For costs (abandoned carts): down is good. */
  lowerIsBetter?: boolean;
  icon: React.ReactNode;
  loading?: boolean;
  hint?: string;
}

export const KpiTile = memo(function KpiTile({ label, value, sub, change, lowerIsBetter, icon, loading, hint }: KpiTileProps) {
  const hasChange = change !== null && change !== undefined && Number.isFinite(change);
  const flat = hasChange && Math.abs(change as number) < 0.005;
  const up = hasChange && (change as number) > 0;
  const good = flat ? null : lowerIsBetter ? !up : up;
  const ChangeIcon = flat ? Minus : up ? ArrowUpRight : ArrowDownRight;
  const c = hasChange ? (change as number) : 0;
  // Past +1000% a multiple reads better: +2300% is "24×" the previous period.
  const changeText = !hasChange
    ? null
    : c >= 10
      ? `${Math.round(1 + c)}×`
      : `${up ? '+' : flat ? '' : '−'}${Math.abs(c * 100).toFixed(Math.abs(c) < 0.1 ? 1 : 0)}%`;
  return (
    <div className="rounded-2xl border border-secondary-200/70 bg-surface p-4 shadow-sm sm:p-5" title={hint}>
      <div className="flex items-start justify-between gap-3">
        <p className="text-xs font-medium uppercase leading-tight tracking-wide text-secondary-500">{label}</p>
        <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary-500/10 text-primary-600 [&>svg]:h-4 [&>svg]:w-4">
          {icon}
        </span>
      </div>
      {loading ? (
        <>
          <div className="mt-2 h-8 w-28 animate-pulse rounded-lg bg-secondary-200" />
          <div className="mt-3 h-4 w-36 animate-pulse rounded bg-secondary-100" />
        </>
      ) : (
        <>
          <p className="mt-1 truncate text-2xl font-bold tracking-tight tabular-nums text-secondary-900 sm:text-[1.7rem]">{value}</p>
          <div className="mt-2 flex min-h-5 flex-wrap items-center gap-x-2 gap-y-1 text-xs">
            {changeText && (
              <span
                className={cn(
                  'inline-flex items-center gap-0.5 rounded-full px-1.5 py-0.5 font-semibold tabular-nums',
                  good === null && 'bg-secondary-100 text-secondary-600',
                  good === true && 'bg-success-500/10 text-success-600',
                  good === false && 'bg-error-500/10 text-error-600'
                )}
                aria-label={`${changeText} vs previous period`}
              >
                <ChangeIcon className="h-3.5 w-3.5" aria-hidden="true" />
                {changeText}
              </span>
            )}
            {sub && <span className="text-secondary-500">{sub}</span>}
          </div>
        </>
      )}
    </div>
  );
});

// ---------------------------------------------------------------------------
// Funnel (horizontal steps, each as a share of the first)
// ---------------------------------------------------------------------------

export interface FunnelStep {
  label: string;
  value: number;
  note?: string;
}

export function Funnel({ steps }: { steps: FunnelStep[] }) {
  const top = steps[0]?.value ?? 0;
  return (
    <ol className="space-y-3">
      {steps.map((s, i) => {
        const share = top > 0 ? s.value / top : 0;
        const prev = i > 0 ? steps[i - 1].value : null;
        const stepRate = prev && prev > 0 ? s.value / prev : null;
        return (
          <li key={s.label}>
            <div className="mb-1 flex items-baseline justify-between gap-3 text-sm">
              <span className="font-medium text-secondary-800">{s.label}</span>
              <span className="tabular-nums text-secondary-900">
                <span className="font-semibold">{count(s.value)}</span>
                {stepRate !== null && <span className="ml-2 text-xs text-secondary-500">{pct(stepRate, 0)} of previous</span>}
              </span>
            </div>
            <div className="h-2.5 overflow-hidden rounded-full bg-secondary-100" aria-hidden="true">
              <div
                className="h-full rounded-full bg-primary-500 transition-[width] duration-500"
                style={{ width: `${Math.max(share * 100, s.value > 0 ? 2 : 0)}%`, opacity: 1 - i * 0.18 }}
              />
            </div>
            {s.note && <p className="mt-1 text-xs text-secondary-500">{s.note}</p>}
          </li>
        );
      })}
    </ol>
  );
}

// ---------------------------------------------------------------------------
// Ranked bar list
// ---------------------------------------------------------------------------

export function BarList({
  rows,
  empty,
  format = count,
}: {
  rows: { key: string; label: React.ReactNode; value: number; extra?: React.ReactNode }[];
  empty: string;
  format?: (n: number) => string;
}) {
  if (rows.length === 0) return <p className="py-6 text-center text-sm text-secondary-500">{empty}</p>;
  const max = Math.max(...rows.map((r) => r.value), 1);
  return (
    <ul className="space-y-2">
      {rows.map((r) => (
        <li key={r.key} className="relative overflow-hidden rounded-lg px-3 py-2">
          <div
            className="absolute inset-y-0 left-0 rounded-lg bg-primary-500/10"
            style={{ width: `${(r.value / max) * 100}%` }}
            aria-hidden="true"
          />
          <div className="relative flex items-center justify-between gap-3 text-sm">
            <span className="min-w-0 truncate text-secondary-800">{r.label}</span>
            <span className="shrink-0 tabular-nums">
              <span className="font-semibold text-secondary-900">{format(r.value)}</span>
              {r.extra && <span className="ml-2 text-xs text-secondary-500">{r.extra}</span>}
            </span>
          </div>
        </li>
      ))}
    </ul>
  );
}

// ---------------------------------------------------------------------------
// Trend chart
// ---------------------------------------------------------------------------

export type TrendMetric = 'revenue_minor' | 'orders' | 'checkouts' | 'carts' | 'chats' | 'quotes';

export const TREND_METRICS: { key: TrendMetric; label: string; money?: boolean }[] = [
  { key: 'revenue_minor', label: 'Revenue', money: true },
  { key: 'orders', label: 'Paid orders' },
  { key: 'checkouts', label: 'Checkouts' },
  { key: 'carts', label: 'Carts' },
  { key: 'chats', label: 'AI chats' },
  { key: 'quotes', label: 'Quotes' },
];

const ChartTip = memo(function ChartTip({
  active,
  payload,
  label,
  money,
  metricLabel,
}: {
  active?: boolean;
  payload?: Array<{ value: number }>;
  label?: string;
  money?: boolean;
  metricLabel: string;
}) {
  if (!active || !payload?.length) return null;
  const v = Number(payload[0].value) || 0;
  return (
    <div className="rounded-lg border border-secondary-200 bg-surface px-3 py-2 text-sm shadow-lg">
      <p className="text-xs text-secondary-500">{label}</p>
      <p className="mt-0.5 font-semibold tabular-nums text-secondary-900">
        {money
          ? new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' }).format(v / 100)
          : int.format(v)}{' '}
        <span className="font-normal text-secondary-500">{metricLabel.toLowerCase()}</span>
      </p>
    </div>
  );
});

export function TrendChart({
  series,
  bucket,
  metric,
}: {
  series: AnalyticsPoint[];
  bucket: AnalyticsBucket;
  metric: TrendMetric;
}) {
  const meta = TREND_METRICS.find((m) => m.key === metric) ?? TREND_METRICS[0];
  const data = series.map((p) => ({
    label: (bucket === 'week' ? 'w/c ' : '') + bucketLabel(p.bucket, bucket),
    value: p[metric],
  }));
  const allZero = data.every((d) => !d.value);
  const axis = { fontSize: 11, fill: 'var(--color-secondary-500)' };
  const grid = 'var(--color-secondary-200)';
  const yFmt = (v: number) => (meta.money ? poundsCompact(v) : int.format(v));

  if (allZero) {
    return (
      <div className="flex h-64 items-center justify-center rounded-xl border border-dashed border-secondary-200 text-sm text-secondary-500">
        No {meta.label.toLowerCase()} in this period
      </div>
    );
  }

  return (
    <div className="h-64 w-full" role="img" aria-label={`${meta.label} per ${bucket}`}>
      <ResponsiveContainer width="100%" height="100%">
        {meta.money ? (
          <AreaChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
            <defs>
              <linearGradient id="saFill" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor="var(--color-primary-500)" stopOpacity={0.28} />
                <stop offset="100%" stopColor="var(--color-primary-500)" stopOpacity={0} />
              </linearGradient>
            </defs>
            <CartesianGrid strokeDasharray="3 3" stroke={grid} vertical={false} />
            <XAxis dataKey="label" tick={axis} stroke={grid} minTickGap={18} tickLine={false} />
            <YAxis tick={axis} stroke={grid} tickFormatter={yFmt} width={64} tickLine={false} axisLine={false} />
            <Tooltip content={<ChartTip money metricLabel={meta.label} />} cursor={{ stroke: grid }} />
            <Area type="monotone" dataKey="value" stroke="var(--color-primary-500)" strokeWidth={2} fill="url(#saFill)" />
          </AreaChart>
        ) : (
          <BarChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke={grid} vertical={false} />
            <XAxis dataKey="label" tick={axis} stroke={grid} minTickGap={18} tickLine={false} />
            <YAxis tick={axis} stroke={grid} allowDecimals={false} tickFormatter={yFmt} width={40} tickLine={false} axisLine={false} />
            <Tooltip content={<ChartTip metricLabel={meta.label} />} cursor={{ fill: 'var(--color-secondary-100)' }} />
            <Bar dataKey="value" fill="var(--color-primary-500)" radius={[3, 3, 0, 0]} maxBarSize={28} />
          </BarChart>
        )}
      </ResponsiveContainer>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Small pieces
// ---------------------------------------------------------------------------

export function Stat({ label, value, hint }: { label: string; value: React.ReactNode; hint?: string }) {
  return (
    <div className="rounded-xl bg-secondary-50 px-3 py-2.5" title={hint}>
      <p className="text-xs text-secondary-500">{label}</p>
      <p className="mt-0.5 text-base font-semibold tabular-nums text-secondary-900">{value}</p>
    </div>
  );
}

export function Row({ label, value, strong, muted }: { label: string; value: React.ReactNode; strong?: boolean; muted?: boolean }) {
  return (
    <div className={cn('flex items-center justify-between gap-4 py-1.5 text-sm', strong && 'border-t border-secondary-200 pt-2.5')}>
      <dt className={cn(muted ? 'text-secondary-400' : 'text-secondary-600', strong && 'font-medium text-secondary-900')}>{label}</dt>
      <dd className={cn('tabular-nums text-secondary-900', strong && 'font-semibold')}>{value}</dd>
    </div>
  );
}
