'use client';

import React, { useCallback, useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Ban, Search, ShieldOff, Trash2 } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, confirmDialog } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import { HelpLink } from '@/components/opsapi-marketing/GettingStarted';
import { INPUT_CLASS, Notice, apiErrorMessage } from '../campaigns/_components/shared';

type Row = {
  uuid: string;
  channel?: string | null;
  address: string;
  reason: string;
  source: string;
  notes?: string | null;
  created_at?: string;
};

// How each person ended up here, in plain words (mkt_suppressions.source, then .reason).
const HOW: Record<string, string> = {
  unsubscribe_page: 'Pressed Unsubscribe in an email',
  list_unsubscribe_post: 'Used their email app’s Unsubscribe button',
  one_click_unsubscribe: 'Opened the unsubscribe link (older emails)',
  preferences_page: 'Turned emails off on the preferences page',
  sms_stop: 'Replied STOP to a text',
  reply_unsubscribe: 'Replied asking to stop',
  reply: 'Complained about an email',
  bounce: 'The address doesn’t exist (bounced)',
  dashboard: 'Your team recorded their request',
  manual: 'Blocked by you',
};
const BY_REASON: Record<string, string> = {
  unsubscribe: 'Unsubscribed',
  stop_keyword: 'Replied STOP to a text',
  hard_bounce: 'The address doesn’t exist (bounced)',
  complaint: 'Complained about an email',
};
const CHANNEL: Record<string, string> = { email: 'Email', sms: 'Text' };
const PER_PAGE = 50;

const when = (s?: string) =>
  s ? new Date(s).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '';

export default function MarketingUnsubscribedPage() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [q, setQ] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [channel, setChannel] = useState<'email' | 'sms'>('email');
  const [address, setAddress] = useState('');
  const [blocking, setBlocking] = useState(false);

  const load = useCallback(async () => {
    try {
      const res = await marketingService.listSuppressions({ page, per_page: PER_PAGE, ...(q ? { q } : {}) });
      setRows(Array.isArray(res.data?.data) ? res.data.data : []);
      setTotal(Number(res.data?.meta?.total ?? 0));
      setError(null);
    } catch (e) {
      setError(apiErrorMessage(e, 'Could not load the list.'));
      setRows([]);
    }
  }, [page, q]);

  useEffect(() => {
    const t = setTimeout(() => void load(), q ? 300 : 0);
    return () => clearTimeout(t);
  }, [load, q]);

  const block = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!address.trim()) return;
    setBlocking(true);
    try {
      const res = await marketingService.blockAddress({ address, channel });
      toast.success(res.status === 201 ? 'Blocked — they won’t get your marketing.' : 'That address is already here.');
      setAddress('');
      void load();
    } catch (err) {
      toast.error(apiErrorMessage(err, 'Could not block that address.'));
    } finally {
      setBlocking(false);
    }
  };

  const unblock = async (r: Row) => {
    const ok = await confirmDialog({
      title: `Unblock ${r.address}?`,
      message: 'They can get your marketing again if they are on a list and have agreed to it.',
      confirmText: 'Unblock',
    });
    if (!ok) return;
    try {
      await marketingService.removeBlock(r.uuid);
      toast.success('Unblocked.');
      void load();
    } catch (err) {
      toast.error(apiErrorMessage(err, 'Could not unblock that address.'));
    }
  };

  const pages = Math.max(1, Math.ceil(total / PER_PAGE));

  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Unsubscribed"
        description="People who asked not to get your marketing, and addresses you’ve blocked. Nothing is ever sent to them."
        icon={<ShieldOff className="h-6 w-6" />}
        actions={<HelpLink topic="unsubscribe">How unsubscribing works</HelpLink>}
      />

      <Notice>
        Only the person can undo their unsubscribe: the unsubscribe page in any of your emails has a{' '}
        <strong>Subscribe again</strong> button. You can block an address yourself, and unblock the ones you blocked.
      </Notice>

      <form onSubmit={block} className="flex flex-wrap items-end gap-2 rounded-lg border border-secondary-200 p-4">
        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium text-secondary-900">Block an address</span>
          <select
            className={INPUT_CLASS}
            value={channel}
            onChange={(e) => setChannel(e.target.value as 'email' | 'sms')}
            aria-label="Email or mobile"
          >
            <option value="email">Email</option>
            <option value="sms">Mobile number</option>
          </select>
        </label>
        <input
          className={`${INPUT_CLASS} min-w-0 flex-1 basis-56`}
          type={channel === 'email' ? 'email' : 'tel'}
          value={address}
          onChange={(e) => setAddress(e.target.value)}
          placeholder={channel === 'email' ? 'name@example.com' : '07700 900123'}
          aria-label={channel === 'email' ? 'Email address to block' : 'Mobile number to block'}
        />
        <Button type="submit" variant="outline" leftIcon={<Ban className="h-4 w-4" />} isLoading={blocking}>
          Block
        </Button>
      </form>

      {error && <Notice tone="error">{error}</Notice>}

      <div className="space-y-3">
        <div className="relative max-w-sm">
          <Search className="pointer-events-none absolute left-2 top-2 h-4 w-4 text-secondary-400" aria-hidden />
          <input
            className={`${INPUT_CLASS} w-full pl-8`}
            value={q}
            onChange={(e) => {
              setQ(e.target.value);
              setPage(1);
            }}
            placeholder="Search by email or number"
            aria-label="Search"
          />
        </div>

        {rows === null ? (
          <p className="text-sm text-secondary-500">Loading…</p>
        ) : rows.length === 0 ? (
          <p className="text-sm text-secondary-500">
            {q ? 'Nobody matches that search.' : 'Nobody has unsubscribed yet.'}
          </p>
        ) : (
          <ul className="divide-y divide-secondary-200 rounded-lg border border-secondary-200">
            {rows.map((r) => (
              <li key={r.uuid} className="flex flex-wrap items-center gap-x-4 gap-y-1 p-3 text-sm">
                <span className="min-w-0 flex-1 basis-56">
                  <span className="block truncate font-medium text-secondary-900">{r.address}</span>
                  <span className="block text-xs text-secondary-500">
                    {HOW[r.source] ?? BY_REASON[r.reason] ?? 'Unsubscribed'}
                    {r.notes ? ` · ${r.notes}` : ''}
                  </span>
                </span>
                <span className="text-xs text-secondary-500">{CHANNEL[r.channel ?? ''] ?? 'Everything'}</span>
                <span className="w-24 text-xs text-secondary-500">{when(r.created_at)}</span>
                <span className="flex w-28 justify-end">
                  {r.source === 'manual' && (
                    <Button
                      size="sm"
                      variant="ghost"
                      leftIcon={<Trash2 className="h-4 w-4" />}
                      onClick={() => void unblock(r)}
                    >
                      Unblock
                    </Button>
                  )}
                </span>
              </li>
            ))}
          </ul>
        )}

        {pages > 1 && (
          <div className="flex items-center gap-3 text-sm">
            <Button size="sm" variant="outline" disabled={page <= 1} onClick={() => setPage(page - 1)}>
              Previous
            </Button>
            <span className="text-secondary-500">
              Page {page} of {pages} · {total.toLocaleString()} in all
            </span>
            <Button size="sm" variant="outline" disabled={page >= pages} onClick={() => setPage(page + 1)}>
              Next
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}
