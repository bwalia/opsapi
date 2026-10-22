'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { RefreshCw, Trophy, Bot, MessageSquare } from 'lucide-react';
import {
  ResponsiveContainer,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
} from 'recharts';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  type CampaignAnalytics,
  KpiTile,
  Notice,
  apiErrorMessage,
  fmtInt,
  fmtMoney,
  fmtPct,
  unwrap,
} from './shared';

const SERIES = [
  { key: 'opens', label: 'Opens (est.)', color: '#3b82f6' },
  { key: 'clicks', label: 'Clicks', color: '#8b5cf6' },
  { key: 'conversions', label: 'Conversions', color: '#16a34a' },
] as const;

const STAGE_LABELS: Record<string, string> = {
  sent: 'Sent',
  opened: 'Opened',
  clicked: 'Clicked',
  converted: 'Converted',
};

const TOOLTIP_STYLE: React.CSSProperties = {
  background: 'var(--color-surface-elevated)',
  border: '1px solid var(--color-secondary-200)',
  color: 'var(--color-foreground)',
  borderRadius: 6,
  fontSize: 12,
};

function hourLabel(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit' });
}

export default function PerformanceTab({
  campaignUuid,
  refreshKey,
  live,
}: {
  campaignUuid: string;
  /** Bumped by the parent to force a reload (auto-refresh while sending). */
  refreshKey: number;
  live: boolean;
}) {
  const [data, setData] = useState<CampaignAnalytics | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null);

  const load = useCallback(async () => {
    try {
      const res = await marketingService.campaignAnalytics(campaignUuid);
      setData(unwrap<CampaignAnalytics>(res));
      setError(null);
      setUpdatedAt(new Date());
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Could not load campaign analytics'));
    } finally {
      setLoading(false);
    }
  }, [campaignUuid]);

  useEffect(() => {
    void load();
  }, [load, refreshKey]);

  const manualRefresh = () => {
    setLoading(true);
    void load();
  };

  if (!data) {
    return error ? (
      <Notice tone="error">{error}</Notice>
    ) : (
      <p className="text-sm text-secondary-500">Loading performance…</p>
    );
  }

  const d = data.deliveries ?? {};
  const r = data.rates ?? {};
  const conv = data.conversions ?? {};
  const currency = conv.currency ?? undefined;
  const funnel = data.funnel ?? [];
  const funnelMax = Math.max(1, ...funnel.map((f) => Number(f.count) || 0));
  const timeline = (data.timeline ?? []).map((t) => ({
    label: hourLabel(t.hour),
    opens: Number(t.opens ?? 0),
    clicks: Number(t.clicks ?? 0),
    conversions: Number(t.conversions ?? 0),
  }));
  const variants = data.variants ?? [];
  const winner = data.ab_winner ?? null;
  const tracking = data.tracking ?? {};
  const links = data.top_links ?? [];
  const replies = data.reply_classes ?? [];
  const sent = Number(d.sent ?? 0);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-secondary-500">
          {live ? 'Auto-refreshing every 15s while sending. ' : ''}
          {updatedAt ? `Updated ${updatedAt.toLocaleTimeString()}` : ''}
        </p>
        <Button
          size="sm"
          variant="outline"
          leftIcon={<RefreshCw className="h-4 w-4" />}
          onClick={manualRefresh}
          isLoading={loading}
        >
          Refresh
        </Button>
      </div>
      {error && <Notice tone="error">{error}</Notice>}

      <section aria-labelledby="perf-kpis" className="space-y-2">
        <h2 id="perf-kpis" className="sr-only">
          Key metrics
        </h2>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <KpiTile label="Sent" value={fmtInt(sent)} hint={`${fmtInt(d.queued)} queued · ${fmtInt(d.skipped)} skipped`} />
          <KpiTile
            label="Open rate (est.)"
            value={fmtPct(r.open_rate)}
            hint="Estimated, bots excluded"
          />
          <KpiTile label="Click rate" value={fmtPct(r.click_rate)} hint={`${fmtInt(d.clicked)} unique clickers`} />
          <KpiTile label="Click-to-open" value={fmtPct(r.click_to_open_rate)} hint="Clicks ÷ estimated opens" />
          <KpiTile
            label="Conversions"
            value={fmtInt(conv.conversions)}
            hint={`${fmtInt(conv.converters)} converters · ${fmtPct(r.conversion_rate)}`}
            tone={(conv.conversions ?? 0) > 0 ? 'good' : undefined}
          />
          <KpiTile label="Revenue" value={fmtMoney(conv.revenue, currency)} hint="Last-click attributed" />
          <KpiTile label="Revenue / recipient" value={fmtMoney(r.revenue_per_recipient, currency)} />
          <KpiTile
            label="Bounce rate"
            value={fmtPct(r.bounce_rate)}
            hint={`${fmtInt(d.bounced)} bounced · ${fmtInt(d.failed)} failed`}
            tone={(r.bounce_rate ?? 0) >= 5 ? 'bad' : undefined}
          />
        </div>
      </section>

      <div className="grid gap-4 lg:grid-cols-2">
        <section aria-labelledby="perf-funnel" className="rounded-lg border border-secondary-200 p-4">
          <h2 id="perf-funnel" className="mb-3 text-sm font-medium">
            Funnel
          </h2>
          {funnel.length === 0 || sent === 0 ? (
            <p className="text-sm text-secondary-500">No deliveries yet.</p>
          ) : (
            <ol className="space-y-3">
              {funnel.map((f, i) => {
                const count = Number(f.count) || 0;
                const prev = i > 0 ? Number(funnel[i - 1].count) || 0 : 0;
                const drop = i > 0 && prev > 0 ? ((prev - count) / prev) * 100 : null;
                const width = Math.max(2, (count / funnelMax) * 100);
                return (
                  <li key={f.stage}>
                    <div className="mb-1 flex items-baseline justify-between text-sm">
                      <span>
                        {STAGE_LABELS[f.stage] ?? f.stage}
                        {f.estimated && <span className="ml-1 text-xs text-secondary-500">(est.)</span>}
                      </span>
                      <span className="tabular-nums">
                        {fmtInt(count)}
                        {drop !== null && drop > 0 && (
                          <span className="ml-2 text-xs text-secondary-500">{drop.toFixed(1)}% drop-off</span>
                        )}
                      </span>
                    </div>
                    <div
                      className="h-3 w-full overflow-hidden rounded bg-secondary-100"
                      role="meter"
                      aria-label={`${STAGE_LABELS[f.stage] ?? f.stage}: ${count}`}
                      aria-valuemin={0}
                      aria-valuemax={funnelMax}
                      aria-valuenow={count}
                    >
                      <div className="h-full rounded bg-primary-500" style={{ width: `${width}%` }} />
                    </div>
                  </li>
                );
              })}
            </ol>
          )}
        </section>

        <section aria-labelledby="perf-timeline" className="rounded-lg border border-secondary-200 p-4">
          <h2 id="perf-timeline" className="mb-3 text-sm font-medium">
            Engagement over time (hourly)
          </h2>
          {timeline.length === 0 ? (
            <p className="text-sm text-secondary-500">No engagement recorded yet.</p>
          ) : (
            <div className="h-64 text-secondary-500">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={timeline} margin={{ top: 4, right: 8, left: -16, bottom: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="var(--color-secondary-200)" vertical={false} />
                  <XAxis dataKey="label" tick={{ fontSize: 11, fill: 'currentColor' }} minTickGap={24} />
                  <YAxis allowDecimals={false} tick={{ fontSize: 11, fill: 'currentColor' }} />
                  <Tooltip contentStyle={TOOLTIP_STYLE} />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                  {SERIES.map((s) => (
                    <Line
                      key={s.key}
                      type="monotone"
                      dataKey={s.key}
                      name={s.label}
                      stroke={s.color}
                      strokeWidth={2}
                      dot={false}
                    />
                  ))}
                </LineChart>
              </ResponsiveContainer>
            </div>
          )}
        </section>
      </div>

      {variants.length > 0 && (
        <section aria-labelledby="perf-ab" className="rounded-lg border border-secondary-200 p-4">
          <h2 id="perf-ab" className="mb-3 text-sm font-medium">
            A/B variants
          </h2>
          {winner && (
            <div className="mb-3">
              <Notice tone={winner.significant ? 'success' : 'info'}>
                <span className="inline-flex items-center gap-1.5 font-medium">
                  <Trophy className="h-4 w-4" aria-hidden="true" />
                  Variant {winner.variant} leads on {winner.metric === 'converted' ? 'conversion' : 'click'} rate
                </span>{' '}
                ({fmtPct(winner.rate)} vs {fmtPct(winner.runner_up_rate)} for {winner.runner_up ?? 'runner-up'}
                {winner.lift != null ? `, ${winner.lift >= 0 ? '+' : ''}${Number(winner.lift).toFixed(1)}% lift` : ''}).{' '}
                {winner.significant
                  ? `Statistically significant at ${fmtPct(winner.confidence, 0)} confidence.`
                  : `Not yet significant (${fmtPct(winner.confidence, 0)} confidence) — keep sending before declaring a winner.`}
              </Notice>
            </div>
          )}
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="text-left text-secondary-500">
                <tr>
                  <th className="py-2 pr-3 font-medium">Variant</th>
                  <th className="py-2 pr-3 text-right font-medium">Sent</th>
                  <th className="py-2 pr-3 text-right font-medium">Open rate (est.)</th>
                  <th className="py-2 pr-3 text-right font-medium">Click rate</th>
                  <th className="py-2 pr-3 text-right font-medium">Conv. rate</th>
                  <th className="py-2 text-right font-medium">Revenue</th>
                </tr>
              </thead>
              <tbody>
                {variants.map((v) => (
                  <tr key={v.variant} className="border-t border-secondary-200">
                    <td className="py-2 pr-3 font-medium">
                      {v.variant}
                      {winner?.variant === v.variant && (
                        <Trophy className="ml-1 inline h-3.5 w-3.5 text-amber-500" aria-label="Leading variant" />
                      )}
                    </td>
                    <td className="py-2 pr-3 text-right tabular-nums">{fmtInt(v.sent ?? v.total)}</td>
                    <td className="py-2 pr-3 text-right tabular-nums">{fmtPct(v.open_rate)}</td>
                    <td className="py-2 pr-3 text-right tabular-nums">{fmtPct(v.click_rate)}</td>
                    <td className="py-2 pr-3 text-right tabular-nums">{fmtPct(v.conversion_rate)}</td>
                    <td className="py-2 text-right tabular-nums">{fmtMoney(v.revenue, currency)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      <section aria-labelledby="perf-links" className="rounded-lg border border-secondary-200 p-4">
        <h2 id="perf-links" className="mb-3 text-sm font-medium">
          Top links
        </h2>
        {links.length === 0 ? (
          <p className="text-sm text-secondary-500">No tracked clicks yet.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="text-left text-secondary-500">
                <tr>
                  <th className="py-2 pr-3 font-medium">URL</th>
                  <th className="py-2 pr-3 text-right font-medium">Clicks</th>
                  <th className="py-2 text-right font-medium">Unique</th>
                </tr>
              </thead>
              <tbody>
                {links.map((l) => (
                  <tr key={l.url} className="border-t border-secondary-200">
                    <td className="max-w-md truncate py-2 pr-3" title={l.url}>
                      {l.url}
                    </td>
                    <td className="py-2 pr-3 text-right tabular-nums">{fmtInt(l.clicks)}</td>
                    <td className="py-2 text-right tabular-nums">{fmtInt(l.unique_clicks)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <div className="grid gap-4 md:grid-cols-2">
        <section aria-labelledby="perf-bots" className="rounded-lg border border-secondary-200 p-4">
          <h2 id="perf-bots" className="mb-2 flex items-center gap-1.5 text-sm font-medium">
            <Bot className="h-4 w-4 text-secondary-500" aria-hidden="true" /> Bot filtering
          </h2>
          <p className="mb-3 text-xs text-secondary-500">
            Mail scanners and privacy proxies pre-fetch images and links. These events are excluded from the rates above.
          </p>
          <dl className="grid grid-cols-2 gap-2 text-sm">
            <div>
              <dt className="text-secondary-500">Raw opens</dt>
              <dd className="tabular-nums">{fmtInt(tracking.opens_raw)}</dd>
            </div>
            <div>
              <dt className="text-secondary-500">Raw clicks</dt>
              <dd className="tabular-nums">{fmtInt(tracking.clicks_raw)}</dd>
            </div>
            <div>
              <dt className="text-secondary-500">Bot opens filtered</dt>
              <dd className="tabular-nums">{fmtInt(tracking.bot_opens)}</dd>
            </div>
            <div>
              <dt className="text-secondary-500">Bot clicks filtered</dt>
              <dd className="tabular-nums">{fmtInt(tracking.bot_clicks)}</dd>
            </div>
          </dl>
        </section>

        <section aria-labelledby="perf-replies" className="rounded-lg border border-secondary-200 p-4">
          <h2 id="perf-replies" className="mb-2 flex items-center gap-1.5 text-sm font-medium">
            <MessageSquare className="h-4 w-4 text-secondary-500" aria-hidden="true" /> Replies
          </h2>
          {replies.length === 0 ? (
            <p className="text-sm text-secondary-500">No replies classified yet.</p>
          ) : (
            <ul className="space-y-1 text-sm">
              {replies.map((rc) => (
                <li key={rc.classification} className="flex justify-between">
                  <span className="capitalize">{rc.classification.replace(/_/g, ' ')}</span>
                  <span className="tabular-nums">{fmtInt(rc.n)}</span>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </div>
  );
}
