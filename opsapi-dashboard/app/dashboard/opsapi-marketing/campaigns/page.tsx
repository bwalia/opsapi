'use client';

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { Send, Plus, RefreshCw, Search } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  type AttributionRow,
  type Campaign,
  INPUT_CLASS,
  Notice,
  STARTER,
  STATUS_LABELS,
  StatusBadge,
  apiErrorMessage,
  fmtDateTime,
  fmtInt,
  fmtMoney,
  fmtPct,
  unwrap,
  unwrapArray,
} from './_components/shared';
import { HelpLink } from '@/components/opsapi-marketing/GettingStarted';
import { TestModeBanner, useTestMode } from '@/components/opsapi-marketing/TestMode';


export default function MarketingCampaignsPage() {
  const router = useRouter();
  const [items, setItems] = useState<Campaign[]>([]);
  const [metrics, setMetrics] = useState<Record<string, AttributionRow>>({});
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const testMode = useTestMode();
  const [creating, setCreating] = useState(false);
  const [newName, setNewName] = useState('');
  const [status, setStatus] = useState('');
  const [query, setQuery] = useState('');
  const [debouncedQuery, setDebouncedQuery] = useState('');

  useEffect(() => {
    const t = window.setTimeout(() => setDebouncedQuery(query.trim()), 300);
    return () => window.clearTimeout(t);
  }, [query]);

  const load = useCallback(async () => {
    try {
      const params: Record<string, unknown> = { per_page: 100, sort: 'created_at', order: 'desc' };
      if (status) params.status = status;
      if (debouncedQuery) params.q = debouncedQuery;
      const [cRes, aRes] = await Promise.all([
        marketingService.listCampaigns(params),
        marketingService.attribution({ days: 365 }).catch(() => null),
      ]);
      setItems(unwrapArray<Campaign>(cRes));
      if (aRes) {
        const rows = unwrap<{ campaigns?: AttributionRow[] }>(aRes)?.campaigns ?? [];
        setMetrics(Object.fromEntries(rows.map((r) => [r.uuid, r])));
      }
      setError(null);
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Failed to load campaigns'));
    } finally {
      setLoading(false);
    }
  }, [status, debouncedQuery]);

  useEffect(() => {
    void load();
  }, [load]);

  const refresh = () => {
    setLoading(true);
    void load();
  };

  const createDraft = async (e?: React.FormEvent) => {
    e?.preventDefault();
    setCreating(true);
    setError(null);
    try {
      const res = await marketingService.createCampaign({
        name: newName.trim() || 'Untitled campaign',
        ...STARTER,
      });
      const row = unwrap<Campaign>(res);
      router.push(`/dashboard/opsapi-marketing/campaigns/${row.uuid}?tab=content`);
    } catch (err: unknown) {
      setError(apiErrorMessage(err, 'Could not create campaign'));
      setCreating(false);
    }
  };

  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Campaigns"
        description="Consent-gated email and SMS sends with open, click and conversion tracking."
        icon={<Send className="h-6 w-6" />}
        actions={
          <>
            <HelpLink topic="write-email">How do I write and send an email?</HelpLink>
            <Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={refresh} isLoading={loading}>
              Refresh
            </Button>
          </>
        }
      />

      <TestModeBanner on={testMode} />

      <form onSubmit={(e) => void createDraft(e)} className="flex flex-wrap items-end gap-2 rounded-lg border border-secondary-200 p-4">
        <label className="block min-w-64 flex-1 text-sm">
          <span className="font-medium">New campaign</span>
          <input
            className={`${INPUT_CLASS} mt-1 block w-full`}
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder="Untitled campaign"
            maxLength={255}
          />
        </label>
        <Button type="submit" leftIcon={<Plus className="h-4 w-4" />} isLoading={creating}>
          Create draft
        </Button>
        <p className="basis-full text-xs text-secondary-500">
          Starts an email draft with sample content and opens the editor.
        </p>
      </form>

      <div className="flex flex-wrap items-end gap-2">
        <label className="relative block min-w-56 flex-1 text-sm">
          <span className="sr-only">Search campaigns</span>
          <Search
            className="pointer-events-none absolute left-2 top-1/2 h-4 w-4 -translate-y-1/2 text-secondary-500"
            aria-hidden="true"
          />
          <input
            type="search"
            className={`${INPUT_CLASS} w-full pl-8`}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search by name, subject…"
          />
        </label>
        <label className="block text-sm">
          <span className="sr-only">Status</span>
          <select className={INPUT_CLASS} value={status} onChange={(e) => setStatus(e.target.value)} aria-label="Status">
            <option value="">All statuses</option>
            {Object.entries(STATUS_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </select>
        </label>
      </div>

      {error && <Notice tone="error">{error}</Notice>}

      {loading && items.length === 0 ? (
        <p className="text-sm text-secondary-500">Loading…</p>
      ) : items.length === 0 ? (
        <p className="text-sm text-secondary-500">
          {status || debouncedQuery ? 'No campaigns match these filters.' : 'No campaigns yet. Create a draft to get started.'}
        </p>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-secondary-200">
          <table className="w-full text-sm">
            <thead className="bg-secondary-100/60 text-left">
              <tr>
                <th className="p-3 font-medium">Name</th>
                <th className="p-3 font-medium">Status</th>
                <th className="hidden p-3 font-medium md:table-cell">Channel</th>
                <th className="hidden p-3 text-right font-medium sm:table-cell">Sent</th>
                <th className="hidden p-3 text-right font-medium lg:table-cell" title="Estimated, bots excluded">
                  Open rate
                </th>
                <th className="hidden p-3 text-right font-medium lg:table-cell">Click rate</th>
                <th className="hidden p-3 text-right font-medium xl:table-cell">Conversions</th>
                <th className="hidden p-3 text-right font-medium xl:table-cell">Revenue</th>
                <th className="hidden p-3 font-medium xl:table-cell">Scheduled / started</th>
              </tr>
            </thead>
            <tbody>
              {items.map((c) => {
                const m = metrics[c.uuid];
                const when = c.started_at ?? c.scheduled_at;
                return (
                  <tr key={c.uuid} className="border-t border-secondary-200 hover:bg-secondary-50">
                    <td className="p-3">
                      <Link
                        href={`/dashboard/opsapi-marketing/campaigns/${c.uuid}`}
                        className="font-medium underline-offset-2 hover:underline"
                      >
                        {c.name}
                      </Link>
                      {c.subject && <div className="max-w-44 truncate text-xs text-secondary-500 sm:max-w-xs">{c.subject}</div>}
                      {m && (
                        <div className="text-xs text-secondary-500 sm:hidden">
                          {fmtInt(m.sent)} sent
                        </div>
                      )}
                    </td>
                    <td className="p-3">
                      <StatusBadge status={c.status} />
                    </td>
                    <td className="hidden p-3 uppercase md:table-cell">{c.channel}</td>
                    <td className="hidden p-3 text-right tabular-nums sm:table-cell">{m ? fmtInt(m.sent) : '—'}</td>
                    <td className="hidden p-3 text-right tabular-nums lg:table-cell">{m && m.sent ? fmtPct(m.open_rate) : '—'}</td>
                    <td className="hidden p-3 text-right tabular-nums lg:table-cell">{m && m.sent ? fmtPct(m.click_rate) : '—'}</td>
                    <td className="hidden p-3 text-right tabular-nums xl:table-cell">{m ? fmtInt(m.conversions ?? m.converted) : '—'}</td>
                    <td className="hidden p-3 text-right tabular-nums xl:table-cell">{m ? fmtMoney(m.revenue) : '—'}</td>
                    <td className="hidden whitespace-nowrap p-3 text-secondary-500 xl:table-cell">
                      {when ? `${c.started_at ? 'Started' : 'Scheduled'} ${fmtDateTime(when)}` : '—'}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <p className="text-xs text-secondary-500">
        Metrics cover the last 365 days. Open rates are estimates with known bots excluded; revenue is last-click
        attributed via the website pixel.
      </p>
    </div>
  );
}
