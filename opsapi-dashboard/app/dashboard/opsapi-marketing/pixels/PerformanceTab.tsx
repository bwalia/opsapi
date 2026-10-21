'use client';

import React, { useEffect, useState } from 'react';
import { Loader2 } from 'lucide-react';
import {
  CartesianGrid,
  ComposedChart,
  Bar,
  Legend,
  Line,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  apiErrorMessage,
  DEST_LABEL,
  formatMoney,
  FORWARD_STATUS_CLASS,
  toNumber,
  unwrap,
  type Pixel,
  type PixelStats,
} from './shared';

const RANGES = [7, 30, 90] as const;
const AXIS = '#94a3b8';
const COLORS = { page_views: '#3b82f6', visitors: '#a855f7', conversions: '#22c55e' };

function Tile({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="rounded-lg border border-secondary-200 p-4">
      <div className="text-xs text-secondary-500">{label}</div>
      <div className="mt-1 text-2xl font-semibold tabular-nums">{value}</div>
      {hint && <div className="mt-0.5 text-xs text-secondary-500">{hint}</div>}
    </div>
  );
}

function shortDay(day: string): string {
  const d = new Date(`${day.slice(0, 10)}T00:00:00`);
  return Number.isNaN(d.getTime()) ? day : d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

export function PerformanceTab({ pixel }: { pixel: Pixel }) {
  const [days, setDays] = useState<number>(30);
  const reqKey = `${pixel.uuid}:${days}`;
  const [result, setResult] = useState<{ key: string; stats: PixelStats | null; error: string | null } | null>(null);

  useEffect(() => {
    let cancelled = false;
    marketingService
      .pixelStats(pixel.uuid, { days })
      .then((res) => {
        if (!cancelled) setResult({ key: reqKey, stats: unwrap<PixelStats>(res), error: null });
      })
      .catch((e: unknown) => {
        // Keep the previous figures visible on a failed refresh.
        if (!cancelled) {
          setResult((prev) => ({
            key: reqKey,
            stats: prev?.stats ?? null,
            error: apiErrorMessage(e, 'Failed to load stats'),
          }));
        }
      });
    return () => {
      cancelled = true;
    };
  }, [pixel.uuid, days, reqKey]);

  const loading = result?.key !== reqKey;
  const stats = result?.stats ?? null;
  const error = loading ? null : (result?.error ?? null);

  const t = stats?.totals;
  const n = (v: unknown) => toNumber(v).toLocaleString();
  const daily = (stats?.daily || []).map((d) => ({
    ...d,
    label: shortDay(d.day),
    page_views: toNumber(d.page_views),
    visitors: toNumber(d.visitors),
    conversions: toNumber(d.conversions),
  }));
  const forwards = stats?.forwards || [];

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div role="radiogroup" aria-label="Date range" className="flex rounded border border-secondary-200">
          {RANGES.map((r) => (
            <button
              key={r}
              type="button"
              role="radio"
              aria-checked={days === r}
              className={`px-3 py-1 text-xs first:rounded-l last:rounded-r ${
                days === r ? 'bg-secondary-100 font-medium' : 'text-secondary-500 hover:bg-secondary-50'
              }`}
              onClick={() => setDays(r)}
            >
              {r} days
            </button>
          ))}
        </div>
        {loading && (
          <span className="flex items-center gap-1.5 text-xs text-secondary-500" role="status">
            <Loader2 className="h-3.5 w-3.5 animate-spin" /> Loading…
          </span>
        )}
      </div>

      {error && <p className="text-sm text-error-600">{error}</p>}

      {t && (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Tile label="Events" value={n(t.events)} hint={`${n(t.bot_events)} from bots`} />
          <Tile label="Visitors" value={n(t.visitors)} hint={`${n(t.identified)} identified`} />
          <Tile label="Conversions" value={n(t.conversions)} hint={`${n(t.attributed_events)} attributed events`} />
          <Tile label="Revenue" value={formatMoney(t.revenue)} hint="From tracked conversions" />
        </div>
      )}

      {stats && (
        <div className="rounded-lg border border-secondary-200 p-4">
          <h3 className="mb-3 text-sm font-medium">Daily activity</h3>
          {daily.length === 0 ? (
            <p className="text-sm text-secondary-500">No events in this period.</p>
          ) : (
            <div className="h-72" role="img" aria-label={`Daily page views, visitors and conversions over ${days} days`}>
              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={daily} margin={{ top: 4, right: 8, left: -12, bottom: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke={AXIS} strokeOpacity={0.3} vertical={false} />
                  <XAxis dataKey="label" tick={{ fontSize: 11 }} stroke={AXIS} minTickGap={16} />
                  <YAxis yAxisId="left" allowDecimals={false} tick={{ fontSize: 11 }} stroke={AXIS} />
                  <YAxis yAxisId="right" orientation="right" allowDecimals={false} tick={{ fontSize: 11 }} stroke={AXIS} />
                  <Tooltip
                    contentStyle={{
                      background: 'var(--color-background)',
                      border: `1px solid ${AXIS}`,
                      borderRadius: 6,
                      fontSize: 12,
                    }}
                  />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                  <Bar yAxisId="left" dataKey="page_views" name="Page views" fill={COLORS.page_views} radius={[3, 3, 0, 0]} />
                  <Line
                    yAxisId="left"
                    type="monotone"
                    dataKey="visitors"
                    name="Visitors"
                    stroke={COLORS.visitors}
                    strokeWidth={2}
                    dot={false}
                  />
                  <Line
                    yAxisId="right"
                    type="monotone"
                    dataKey="conversions"
                    name="Conversions"
                    stroke={COLORS.conversions}
                    strokeWidth={2}
                    dot={false}
                  />
                </ComposedChart>
              </ResponsiveContainer>
            </div>
          )}
        </div>
      )}

      {stats && (
        <div className="grid gap-4 md:grid-cols-2">
          <div className="rounded-lg border border-secondary-200 p-4">
            <h3 className="mb-2 text-sm font-medium">Top events</h3>
            {stats.top_events.length === 0 ? (
              <p className="text-sm text-secondary-500">None yet.</p>
            ) : (
              <ol className="space-y-1 text-sm">
                {stats.top_events.map((e) => (
                  <li key={e.event_name} className="flex justify-between gap-2">
                    <span className="truncate font-mono">{e.event_name}</span>
                    <span className="tabular-nums text-secondary-500">{n(e.n)}</span>
                  </li>
                ))}
              </ol>
            )}
          </div>
          <div className="rounded-lg border border-secondary-200 p-4">
            <h3 className="mb-2 text-sm font-medium">Top pages</h3>
            {stats.top_pages.length === 0 ? (
              <p className="text-sm text-secondary-500">None yet.</p>
            ) : (
              <ol className="space-y-1 text-sm">
                {stats.top_pages.map((p) => (
                  <li key={p.page} className="flex justify-between gap-2">
                    <span className="truncate" title={p.page}>
                      {p.page || '(unknown)'}
                    </span>
                    <span className="tabular-nums text-secondary-500">{n(p.n)}</span>
                  </li>
                ))}
              </ol>
            )}
          </div>
        </div>
      )}

      {stats && (
        <div className="rounded-lg border border-secondary-200 p-4">
          <h3 className="mb-1 text-sm font-medium">Server-side forwarding</h3>
          <p className="mb-2 text-xs text-secondary-500">
            Conversions relayed to ad platforms in the last {days} days.
          </p>
          {forwards.length === 0 ? (
            <p className="text-sm text-secondary-500">
              Nothing forwarded. Configure Meta Conversions API or GA4 under Marketing → Settings.
            </p>
          ) : (
            <table className="w-full text-sm">
              <thead className="text-left text-xs text-secondary-500">
                <tr>
                  <th className="py-1 font-normal">Destination</th>
                  <th className="py-1 font-normal">Status</th>
                  <th className="py-1 text-right font-normal">Count</th>
                </tr>
              </thead>
              <tbody>
                {forwards.map((f) => (
                  <tr key={`${f.destination}-${f.status}`} className="border-t border-secondary-200">
                    <td className="py-1.5">{DEST_LABEL[f.destination] || f.destination}</td>
                    <td className={`py-1.5 ${FORWARD_STATUS_CLASS[f.status] || ''}`}>{f.status.replace('_', ' ')}</td>
                    <td className="py-1.5 text-right tabular-nums">{n(f.n)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      )}
    </div>
  );
}
