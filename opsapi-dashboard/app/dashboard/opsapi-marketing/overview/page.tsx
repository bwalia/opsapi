'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import {
  Megaphone,
  Send,
  Users,
  ShieldOff,
  Radar,
  Palette,
  ArrowRight,
} from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { buttonClass } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import { GettingStarted, HelpLink } from '@/components/opsapi-marketing/GettingStarted';
import {
  type AttributionRow,
  KpiTile,
  Notice,
  StatusBadge,
  apiErrorMessage,
  fmtInt,
  fmtMoney,
  fmtPct,
  unwrap,
  unwrapArray,
} from '../campaigns/_components/shared';

type Overview = {
  campaigns?: { drafts?: number; active?: number; completed?: number; paused?: number };
  deliveries?: {
    queued?: number;
    accepted?: number;
    delivered?: number;
    bounced?: number;
    failed?: number;
    skipped?: number;
    opened_est?: number;
    clicked?: number;
  };
  conversions_30d?: { conversions?: number; revenue?: number; attributed?: number };
  web?: { events_24h?: number; visitors_24h?: number; pixels?: number };
  top_campaigns?: AttributionRow[];
  unsubscribed_30d?: number;
};

type Pixel = { uuid: string; name: string; install_status?: 'waiting' | 'active' | 'stale'; events_24h?: number };

type Attribution = { unattributed?: { conversions?: number; revenue?: number } };

const PIXEL_STATUS: Record<string, { label: string; className: string }> = {
  active: { label: 'Receiving events', className: 'text-green-700 dark:text-green-400' },
  waiting: { label: 'Waiting for first event', className: 'text-amber-700 dark:text-amber-300' },
  stale: { label: 'No events in 24h', className: 'text-red-700 dark:text-red-400' },
};

export default function MarketingOverviewPage() {
  const [stats, setStats] = useState<Overview | null>(null);
  const [pixels, setPixels] = useState<Pixel[] | null>(null);
  const [unattributed, setUnattributed] = useState<Attribution['unattributed'] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    marketingService
      .analyticsOverview()
      .then((res) => {
        if (!cancelled) setStats(unwrap<Overview>(res) ?? null);
      })
      .catch((e: unknown) => {
        if (!cancelled) setError(apiErrorMessage(e, 'Could not load analytics (is the plugin enabled?)'));
      });
    marketingService
      .listPixels()
      .then((res) => {
        if (!cancelled) setPixels(unwrapArray<Pixel>(res));
      })
      .catch(() => {
        if (!cancelled) setPixels([]);
      });
    marketingService
      .attribution({ days: 30 })
      .then((res) => {
        if (!cancelled) setUnattributed(unwrap<Attribution>(res)?.unattributed ?? null);
      })
      .catch(() => {
        /* optional */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const d = stats?.deliveries;
  const c = stats?.campaigns;
  const conv = stats?.conversions_30d;
  const web = stats?.web;
  const top = (stats?.top_campaigns ?? [])
    .slice()
    .sort((a, b) => Number(b.revenue ?? 0) - Number(a.revenue ?? 0))
    .slice(0, 8);
  const attributedShare =
    conv && Number(conv.conversions ?? 0) > 0
      ? (Number(conv.attributed ?? 0) / Number(conv.conversions)) * 100
      : null;
  const activePixels = (pixels ?? []).filter((p) => p.install_status === 'active').length;
  // Website tracking is an advanced option (Settings): its results only show once a pixel exists.
  const hasPixels = (pixels?.length ?? 0) > 0;
  const pixelsNeedInstall = hasPixels && activePixels === 0;

  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Marketing Cloud"
        description="Multi-channel campaigns with consent-first delivery, website attribution and revenue tracking."
        icon={<Megaphone className="h-6 w-6" />}
        actions={<HelpLink topic="top">Getting started guide</HelpLink>}
      />

      <GettingStarted compact />

      {error && <Notice tone="error">{error}</Notice>}

      {stats && (
        <>
          {hasPixels && (
            <section aria-labelledby="ov-results" className="space-y-2">
              <h2 id="ov-results" className="text-sm font-medium">
                Results — last 30 days
              </h2>
              <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
                <KpiTile label="Conversions" value={fmtInt(conv?.conversions)} />
                <KpiTile label="Revenue" value={fmtMoney(conv?.revenue)} tone={Number(conv?.revenue ?? 0) > 0 ? 'good' : undefined} />
                <KpiTile
                  label="Attributed to campaigns"
                  value={attributedShare === null ? '—' : fmtPct(attributedShare, 0)}
                  hint={`${fmtInt(conv?.attributed)} of ${fmtInt(conv?.conversions)} conversions`}
                />
                <KpiTile
                  label="Website visitors (24h)"
                  value={fmtInt(web?.visitors_24h)}
                  hint={`${fmtInt(web?.events_24h)} events · ${fmtInt(web?.pixels)} pixel${web?.pixels === 1 ? '' : 's'}`}
                />
              </div>
              {unattributed && Number(unattributed.conversions ?? 0) > 0 && (
                <p className="text-xs text-secondary-500">
                  {fmtInt(unattributed.conversions)} conversion{unattributed.conversions === 1 ? '' : 's'} worth{' '}
                  {fmtMoney(unattributed.revenue)} had no campaign click in their attribution window (direct, organic or
                  other channels).
                </p>
              )}
            </section>
          )}

          <section aria-labelledby="ov-delivery" className="space-y-2">
            <h2 id="ov-delivery" className="text-sm font-medium">
              Campaigns &amp; delivery
            </h2>
            <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
              <KpiTile label="Active campaigns" value={fmtInt(c?.active)} hint={`${fmtInt(c?.paused)} paused`} />
              <KpiTile label="Drafts" value={fmtInt(c?.drafts)} hint={`${fmtInt(c?.completed)} completed`} />
              <KpiTile label="Accepted" value={fmtInt(d?.accepted)} hint={`${fmtInt(d?.delivered)} confirmed delivered`} />
              <KpiTile label="Opened (estimated)" value={fmtInt(d?.opened_est)} hint="Bots excluded" />
              <KpiTile label="Clicked" value={fmtInt(d?.clicked)} />
              <KpiTile label="Bounced" value={fmtInt(d?.bounced)} hint={`${fmtInt(d?.failed)} failed`} />
              <KpiTile label="Skipped" value={fmtInt(d?.skipped)} hint="Consent, suppression or budget" />
              <KpiTile label="Unsubscribed" value={fmtInt(stats.unsubscribed_30d)} hint="Last 30 days" />
            </div>
            <p className="text-xs text-secondary-500">
              Opens are estimated — scanners and privacy proxies inflate raw counts. Accepted is not delivered.
            </p>
          </section>
        </>
      )}

      <div className="grid gap-4 lg:grid-cols-3">
        <section
          aria-labelledby="ov-top"
          className={`rounded-lg border border-secondary-200 p-4 ${hasPixels ? 'lg:col-span-2' : 'lg:col-span-3'}`}
        >
          <div className="mb-3 flex items-center justify-between">
            <h2 id="ov-top" className="text-sm font-medium">
              {hasPixels ? 'Top campaigns by revenue' : 'Campaign results'}
            </h2>
            <Link href="/dashboard/opsapi-marketing/campaigns" className="text-xs text-secondary-500 underline">
              All campaigns
            </Link>
          </div>
          {top.length === 0 ? (
            <p className="text-sm text-secondary-500">No campaign results yet.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-left text-secondary-500">
                  <tr>
                    <th className="py-2 pr-3 font-medium">Campaign</th>
                    <th className="py-2 pr-3 text-right font-medium">Sent</th>
                    <th className="py-2 pr-3 text-right font-medium">Click rate</th>
                    {hasPixels && <th className="py-2 pr-3 text-right font-medium">Conversions</th>}
                    {hasPixels && <th className="py-2 text-right font-medium">Revenue</th>}
                  </tr>
                </thead>
                <tbody>
                  {top.map((r) => (
                    <tr key={r.uuid} className="border-t border-secondary-200">
                      <td className="py-2 pr-3">
                        <Link
                          href={`/dashboard/opsapi-marketing/campaigns/${r.uuid}`}
                          className="font-medium underline-offset-2 hover:underline"
                        >
                          {r.name}
                        </Link>
                        {r.status && (
                          <span className="ml-2 align-middle">
                            <StatusBadge status={r.status} />
                          </span>
                        )}
                      </td>
                      <td className="py-2 pr-3 text-right tabular-nums">{fmtInt(r.sent)}</td>
                      <td className="py-2 pr-3 text-right tabular-nums">{fmtPct(r.click_rate)}</td>
                      {hasPixels && (
                        <td className="py-2 pr-3 text-right tabular-nums">{fmtInt(r.conversions ?? r.converted)}</td>
                      )}
                      {hasPixels && <td className="py-2 text-right tabular-nums">{fmtMoney(r.revenue)}</td>}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        {hasPixels && (
          <section aria-labelledby="ov-pixel" className="space-y-3 rounded-lg border border-secondary-200 p-4">
            <h2 id="ov-pixel" className="flex items-center gap-1.5 text-sm font-medium">
              <Radar className="h-4 w-4 text-secondary-500" aria-hidden="true" /> Website pixel
            </h2>
            <ul className="space-y-2 text-sm">
              {(pixels ?? []).slice(0, 5).map((p) => {
                const st = PIXEL_STATUS[p.install_status ?? 'waiting'] ?? PIXEL_STATUS.waiting;
                return (
                  <li key={p.uuid} className="flex items-start justify-between gap-2">
                    <span className="min-w-0">
                      <span className="block truncate font-medium">{p.name}</span>
                      <span className={`block text-xs ${st.className}`}>{st.label}</span>
                    </span>
                    <span className="shrink-0 text-xs tabular-nums text-secondary-500">
                      {fmtInt(p.events_24h)} events/24h
                    </span>
                  </li>
                );
              })}
            </ul>
            <Link
              href="/dashboard/opsapi-marketing/pixels"
              className={buttonClass(pixelsNeedInstall ? 'primary' : 'outline', 'sm')}
            >
              {pixelsNeedInstall ? 'Finish installing' : 'Manage pixels'}
              <ArrowRight className="ml-1 h-4 w-4" aria-hidden="true" />
            </Link>
          </section>
        )}
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <NavCard
          href="/dashboard/opsapi-marketing/studio"
          icon={<Palette className="mb-2 h-5 w-5 text-secondary-500" />}
          title="Studio"
          desc="Design email and SMS with merge fields and previews."
        />
        <NavCard
          href="/dashboard/opsapi-marketing/campaigns"
          icon={<Send className="mb-2 h-5 w-5 text-secondary-500" />}
          title="Campaigns"
          desc="Draft, test, schedule and measure email and SMS sends."
        />
        <NavCard
          href="/dashboard/opsapi-marketing/lists"
          icon={<Users className="mb-2 h-5 w-5 text-secondary-500" />}
          title="Lists & segments"
          desc="Build audiences from CRM contacts with consent."
        />
        <NavCard
          href="/dashboard/opsapi-marketing/unsubscribed"
          icon={<ShieldOff className="mb-2 h-5 w-5 text-secondary-500" />}
          title="Unsubscribed"
          desc="Everyone who asked to stop, and addresses you've blocked."
        />
      </div>
    </div>
  );
}

function NavCard({ href, icon, title, desc }: { href: string; icon: React.ReactNode; title: string; desc: string }) {
  return (
    <Link href={href} className="rounded-lg border border-secondary-200 p-5 transition-colors hover:bg-secondary-100/60">
      {icon}
      <h2 className="font-medium">{title}</h2>
      <p className="mt-1 text-sm text-secondary-500">{desc}</p>
    </Link>
  );
}
