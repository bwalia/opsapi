'use client';

/**
 * Pipeline insights for a date range: the funnel (how many leads reached each
 * stage, the drop between stages, how long it takes), speed to lead against
 * the workspace's target, where leads come from and why they are lost.
 */
import React from 'react';
import { ArrowDown, Clock3, Coins, Target, TrendingUp } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { Funnel } from '@/services/leads.service';
import { minutesText, money, STAGE_STYLE } from './ui';

function Kpi({ icon, label, value, hint, tone = 'default' }: {
  icon: React.ReactNode; label: string; value: string; hint?: string; tone?: 'default' | 'good' | 'warn';
}) {
  return (
    <div className="rounded-xl border border-secondary-200 bg-white p-4">
      <div className="flex items-center gap-2 text-xs font-medium text-secondary-500">{icon}{label}</div>
      <p className={cn('mt-1.5 text-2xl font-bold tabular-nums tracking-tight',
        tone === 'good' ? 'text-emerald-700' : tone === 'warn' ? 'text-amber-700' : 'text-secondary-900')}>{value}</p>
      {hint && <p className="mt-0.5 text-xs text-secondary-500">{hint}</p>}
    </div>
  );
}

export function FunnelPanel({ funnel }: { funnel: Funnel }) {
  const max = Math.max(1, funnel.total);
  const converted = funnel.steps.find((s) => s.key === 'converted')?.reached ?? 0;
  const speed = funnel.speed_to_lead;
  const inTime = speed.within_target_pct;
  return (
    <div className="space-y-5">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Kpi icon={<Clock3 className="h-4 w-4" aria-hidden="true" />} label="Speed to lead"
          value={minutesText(speed.median_minutes)}
          tone={speed.median_minutes !== null && speed.median_minutes <= speed.target_minutes ? 'good' : speed.median_minutes === null ? 'default' : 'warn'}
          hint={inTime === null ? `Target: first call within ${minutesText(speed.target_minutes)}`
            : `${inTime}% called within the ${minutesText(speed.target_minutes)} target`} />
        <Kpi icon={<TrendingUp className="h-4 w-4" aria-hidden="true" />} label="Converted to deals"
          value={funnel.total ? `${Math.round((converted * 1000) / funnel.total) / 10}%` : '—'}
          hint={`${converted} of ${funnel.total} leads`} />
        <Kpi icon={<Target className="h-4 w-4" aria-hidden="true" />} label="Open pipeline"
          value={money(funnel.money.open_value, funnel.currency, true)} hint={`${funnel.open} open leads`} />
        <Kpi icon={<Coins className="h-4 w-4" aria-hidden="true" />} label="Deals won"
          value={money(funnel.money.won_value, funnel.currency, true)}
          hint={`${money(funnel.money.deal_value, funnel.currency, true)} in deals from these leads`} tone="good" />
      </div>

      <div className="grid grid-cols-1 gap-5 xl:grid-cols-5">
        <section className="rounded-xl border border-secondary-200 bg-white p-5 xl:col-span-3" aria-labelledby="funnel-title">
          <h3 id="funnel-title" className="text-sm font-semibold text-secondary-900">Funnel</h3>
          <p className="text-xs text-secondary-500">Leads created {new Date(funnel.from).toLocaleDateString()} – {new Date(funnel.to).toLocaleDateString()}: how far they got</p>
          <ol className="mt-4 space-y-1">
            {funnel.steps.map((s, i) => (
              <li key={s.key}>
                {i > 0 && (
                  <div className="flex items-center gap-2 py-1 pl-2 text-[11px] text-secondary-500">
                    <ArrowDown className="h-3 w-3" aria-hidden="true" />
                    {s.pct_of_previous === null ? '—' : `${s.pct_of_previous}% moved on`}
                    {s.median_minutes_from_created !== null && <span>· typically {minutesText(s.median_minutes_from_created)} after arriving</span>}
                  </div>
                )}
                <div className="flex items-center gap-3">
                  <span className="w-24 shrink-0 text-sm font-medium text-secondary-700">{s.label}</span>
                  <div className="h-8 flex-1 overflow-hidden rounded-md bg-secondary-100" role="img"
                    aria-label={`${s.label}: ${s.reached} leads (${s.pct_of_total}%)`}>
                    <div className={cn('h-full rounded-md transition-all', STAGE_STYLE[s.key].bar)}
                      style={{ width: `${Math.max(s.reached > 0 ? 2 : 0, (s.reached / max) * 100)}%` }} />
                  </div>
                  <span className="w-24 shrink-0 text-right text-sm tabular-nums">
                    <strong className="text-secondary-900">{s.reached}</strong>
                    <span className="ml-1 text-xs text-secondary-500">{s.pct_of_total}%</span>
                  </span>
                </div>
              </li>
            ))}
          </ol>
          <p className="mt-4 text-xs text-secondary-500">
            Parked: {funnel.nurture} in nurture, {funnel.lost} lost.
          </p>
        </section>

        <div className="space-y-5 xl:col-span-2">
          <section className="rounded-xl border border-secondary-200 bg-white p-5" aria-labelledby="sources-title">
            <h3 id="sources-title" className="text-sm font-semibold text-secondary-900">Where leads come from</h3>
            {funnel.by_source.length === 0 ? <p className="mt-3 text-sm text-secondary-500">No leads in this period.</p> : (
              <table className="mt-3 w-full text-sm">
                <thead><tr className="text-left text-xs text-secondary-500">
                  <th className="pb-2 font-medium">Source</th><th className="pb-2 text-right font-medium">Leads</th>
                  <th className="pb-2 text-right font-medium">Converted</th></tr></thead>
                <tbody>
                  {funnel.by_source.map((r) => {
                    const pct = r.leads ? Math.round((r.converted * 100) / r.leads) : 0;
                    return (
                      <tr key={r.source} className="border-t border-secondary-100">
                        <td className="py-2 capitalize text-secondary-800">{r.source.replace(/_/g, ' ')}</td>
                        <td className="py-2 text-right tabular-nums">{r.leads}</td>
                        <td className="py-2 text-right tabular-nums">
                          <span className="inline-flex items-center gap-2">
                            <span className="hidden h-1.5 w-12 overflow-hidden rounded-full bg-secondary-100 sm:inline-block">
                              <span className="block h-full bg-emerald-500" style={{ width: `${pct}%` }} />
                            </span>
                            {pct}%
                          </span>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}
          </section>
          <section className="rounded-xl border border-secondary-200 bg-white p-5" aria-labelledby="lost-title">
            <h3 id="lost-title" className="text-sm font-semibold text-secondary-900">Why leads were lost</h3>
            {funnel.lost_reasons.length === 0 ? <p className="mt-3 text-sm text-secondary-500">None lost in this period.</p> : (
              <ul className="mt-3 space-y-2">
                {funnel.lost_reasons.map((r) => (
                  <li key={r.reason} className="flex items-center justify-between text-sm">
                    <span className="text-secondary-700">{r.reason}</span>
                    <span className="tabular-nums text-secondary-500">{r.leads}</span>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </div>
      </div>
    </div>
  );
}
