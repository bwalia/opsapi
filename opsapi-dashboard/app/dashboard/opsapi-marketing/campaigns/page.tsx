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

const STARTER = {
  channel: 'email',
  message_type: 'marketing',
  subject: 'Hello {{contact.first_name}}',
  preview_text: 'A quick update we think you will find useful — take a look inside.',
  body_html: [
    '<div style="font-family:Arial,Helvetica,sans-serif;max-width:600px;margin:0 auto;padding:24px;color:#1f2937">',
    '  <h1 style="font-size:22px;margin:0 0 16px">Hi {{contact.first_name}},</h1>',
    '  <p style="font-size:15px;line-height:1.6">We have something new to share with you.</p>',
    '  <p style="margin:24px 0">',
    '    <a href="https://www.example.com/" style="background:#111827;color:#ffffff;padding:12px 20px;border-radius:6px;text-decoration:none;display:inline-block">Find out more</a>',
    '  </p>',
    '  <p style="font-size:12px;color:#6b7280">Don’t want these emails? <a href="{{unsubscribe_url}}" style="color:#6b7280">Unsubscribe</a>.</p>',
    '</div>',
  ].join('\n'),
  body_text:
    'Hi {{contact.first_name}},\n\nWe have something new to share with you.\n\nFind out more: https://www.example.com/\n\nUnsubscribe: {{unsubscribe_url}}',
};

export default function MarketingCampaignsPage() {
  const router = useRouter();
  const [items, setItems] = useState<Campaign[]>([]);
  const [metrics, setMetrics] = useState<Record<string, AttributionRow>>({});
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
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
          <Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={refresh} isLoading={loading}>
            Refresh
          </Button>
        }
      />

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
                <th className="p-3 font-medium">Channel</th>
                <th className="p-3 text-right font-medium">Sent</th>
                <th className="p-3 text-right font-medium" title="Estimated, bots excluded">
                  Open rate
                </th>
                <th className="p-3 text-right font-medium">Click rate</th>
                <th className="p-3 text-right font-medium">Conversions</th>
                <th className="p-3 text-right font-medium">Revenue</th>
                <th className="p-3 font-medium">Scheduled / started</th>
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
                      {c.subject && <div className="max-w-xs truncate text-xs text-secondary-500">{c.subject}</div>}
                    </td>
                    <td className="p-3">
                      <StatusBadge status={c.status} />
                    </td>
                    <td className="p-3 uppercase">{c.channel}</td>
                    <td className="p-3 text-right tabular-nums">{m ? fmtInt(m.sent) : '—'}</td>
                    <td className="p-3 text-right tabular-nums">{m && m.sent ? fmtPct(m.open_rate) : '—'}</td>
                    <td className="p-3 text-right tabular-nums">{m && m.sent ? fmtPct(m.click_rate) : '—'}</td>
                    <td className="p-3 text-right tabular-nums">{m ? fmtInt(m.conversions ?? m.converted) : '—'}</td>
                    <td className="p-3 text-right tabular-nums">{m ? fmtMoney(m.revenue) : '—'}</td>
                    <td className="whitespace-nowrap p-3 text-secondary-500">
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
