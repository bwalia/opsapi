'use client';

/**
 * Filing requests — the accountant's queue.
 *
 * Customers who chose "our accountant files it" land here with the figures they
 * approved (frozen). The accountant downloads the tax sheet, files it with
 * HMRC-recognised software (e.g. My Tax Digital), then records HMRC's reference.
 * They can also ask the customer a question or return the request.
 *
 * Gated on the `tax_filing_requests` module (read = see + download, update = change
 * status). Only this workspace's requests. Backend: routes/tax-filing.
 */

import React, { useCallback, useEffect, useState } from 'react';
import {
  AlertTriangle,
  CheckCircle2,
  Download,
  FileCheck2,
  Inbox,
  Loader2,
  MessageSquare,
  RefreshCw,
  Undo2,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { Card, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  taxFilingService,
  type FilingStatus,
  type QueueDetail,
  type QueueItem,
} from '@/services/tax-filing.service';
import { formatCurrency, extractApiError } from '@/lib/utils';

const gbp = (n?: number | null) => (n == null ? '—' : formatCurrency(n, 'GBP', 'en-GB'));

function fmtWhen(s?: string | null): string {
  if (!s) return '';
  const iso = s.includes('T') ? s : `${s.replace(' ', 'T')}Z`;
  const d = new Date(iso);
  return Number.isNaN(d.getTime())
    ? s
    : d.toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}

const STATUS: Record<FilingStatus, { label: string; cls: string }> = {
  submitted: { label: 'New', cls: 'bg-blue-50 text-blue-700 border-blue-200' },
  reviewing: { label: 'Reviewing', cls: 'bg-primary-50 text-primary-700 border-primary-200' },
  needs_info: { label: 'Waiting on customer', cls: 'bg-amber-50 text-amber-800 border-amber-200' },
  filing: { label: 'Filing', cls: 'bg-violet-50 text-violet-700 border-violet-200' },
  filed: { label: 'Filed', cls: 'bg-green-50 text-green-700 border-green-200' },
  rejected: { label: 'Returned', cls: 'bg-red-50 text-red-700 border-red-200' },
  cancelled: { label: 'Cancelled', cls: 'bg-secondary-100 text-secondary-600 border-secondary-200' },
};

const TABS: Array<{ key: string; label: string; statuses: FilingStatus[] }> = [
  { key: 'open', label: 'Open', statuses: ['submitted', 'reviewing', 'needs_info', 'filing'] },
  { key: 'submitted', label: 'New', statuses: ['submitted'] },
  { key: 'needs_info', label: 'Waiting on customer', statuses: ['needs_info'] },
  { key: 'filed', label: 'Filed', statuses: ['filed'] },
  { key: 'rejected', label: 'Returned', statuses: ['rejected'] },
  { key: 'all', label: 'All', statuses: [] },
];

function Badge({ status }: { status: FilingStatus }) {
  const s = STATUS[status];
  return <span className={`rounded-full border px-2 py-0.5 text-xs font-medium ${s.cls}`}>{s.label}</span>;
}

function QueueContent() {
  const [tab, setTab] = useState('open');
  const [items, setItems] = useState<QueueItem[]>([]);
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [openUuid, setOpenUuid] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await taxFilingService.queue(tab);
      setItems(r.items);
      setCounts(r.counts);
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Could not load filing requests'));
    } finally {
      setLoading(false);
    }
  }, [tab]);

  useEffect(() => {
    load();
  }, [load]);

  const countFor = (t: (typeof TABS)[number]) =>
    t.statuses.length === 0
      ? Object.values(counts).reduce((a, b) => a + b, 0)
      : t.statuses.reduce((a, s) => a + (counts[s] || 0), 0);

  return (
    <div className="max-w-6xl space-y-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Filing requests</h1>
          <p className="mt-1 text-sm text-secondary-500">
            Returns customers asked us to file. Download the tax sheet, file it on My Tax Digital (or other
            HMRC-recognised software), then record HMRC&apos;s reference.
          </p>
        </div>
        <button
          onClick={load}
          className="flex items-center gap-2 rounded-lg border border-secondary-300 px-3 py-2 text-sm text-secondary-700 hover:bg-secondary-100"
        >
          <RefreshCw className="h-4 w-4" /> Refresh
        </button>
      </div>

      <div className="flex flex-wrap gap-2">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={`rounded-full border px-3 py-1 text-sm ${
              tab === t.key
                ? 'border-primary-400 bg-primary-50 text-primary-700'
                : 'border-secondary-200 text-secondary-600 hover:border-primary-300'
            }`}
          >
            {t.label}
            <span className="ml-1.5 text-xs text-secondary-400">{countFor(t)}</span>
          </button>
        ))}
      </div>

      <Card padding="none">
        {loading ? (
          <p className="flex items-center gap-2 p-6 text-sm text-secondary-500">
            <Loader2 className="h-4 w-4 animate-spin" /> Loading…
          </p>
        ) : items.length === 0 ? (
          <div className="flex flex-col items-center gap-2 p-10 text-center text-secondary-500">
            <Inbox className="h-8 w-8 text-secondary-300" />
            <p className="text-sm">Nothing here.</p>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-secondary-200 text-left text-xs uppercase tracking-wide text-secondary-500">
                  <th className="px-4 py-3 font-medium">Customer</th>
                  <th className="px-4 py-3 font-medium">Tax year</th>
                  <th className="px-4 py-3 text-right font-medium">Est. tax</th>
                  <th className="px-4 py-3 text-right font-medium">To review</th>
                  <th className="px-4 py-3 font-medium">Status</th>
                  <th className="px-4 py-3 font-medium">Received</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-secondary-100">
                {items.map((r) => (
                  <tr
                    key={r.uuid}
                    onClick={() => setOpenUuid(r.uuid)}
                    className="cursor-pointer hover:bg-secondary-50"
                  >
                    <td className="px-4 py-3">
                      <p className="font-medium text-secondary-900">{r.customer.name || '—'}</p>
                      <p className="text-xs text-secondary-500">{r.customer.email}</p>
                    </td>
                    <td className="px-4 py-3 text-secondary-700">{r.tax_year}</td>
                    <td className="px-4 py-3 text-right tabular-nums text-secondary-900">{gbp(r.our_total_due)}</td>
                    <td className="px-4 py-3 text-right tabular-nums">
                      {r.unreviewed > 0 ? (
                        <span className="text-amber-700">{r.unreviewed}</span>
                      ) : (
                        <span className="text-secondary-400">0</span>
                      )}
                    </td>
                    <td className="px-4 py-3"><Badge status={r.status} /></td>
                    <td className="px-4 py-3 text-secondary-500">{fmtWhen(r.created_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {openUuid && (
        <RequestDetail
          uuid={openUuid}
          onClose={() => setOpenUuid(null)}
          onChanged={load}
        />
      )}
    </div>
  );
}

type Action = 'reviewing' | 'filing' | 'filed' | 'needs_info' | 'rejected';

function RequestDetail({ uuid, onClose, onChanged }: { uuid: string; onClose: () => void; onChanged: () => void }) {
  const [d, setD] = useState<QueueDetail | null>(null);
  const [action, setAction] = useState<Action | null>(null);
  const [message, setMessage] = useState('');
  const [reference, setReference] = useState('');
  const [hmrcTotal, setHmrcTotal] = useState('');
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);
  const [downloading, setDownloading] = useState(false);

  const load = useCallback(async () => {
    try {
      setD(await taxFilingService.queueDetail(uuid));
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Could not load the request'));
      onClose();
    }
  }, [uuid, onClose]);

  useEffect(() => {
    load();
  }, [load]);

  const variance = d && hmrcTotal.trim() !== '' && Number.isFinite(Number(hmrcTotal))
    ? Math.abs(Number(hmrcTotal) - (d.our_total_due ?? 0))
    : 0;

  const submit = async (to: Action) => {
    setSaving(true);
    try {
      await taxFilingService.updateStatus(uuid, {
        status: to,
        message: to === 'needs_info' || to === 'rejected' ? message.trim() : undefined,
        hmrc_reference: to === 'filed' ? reference.trim() : undefined,
        hmrc_total_due: to === 'filed' ? hmrcTotal.trim() : undefined,
        variance_note: to === 'filed' ? note.trim() : undefined,
      });
      toast.success('Request updated — the customer has been notified');
      setAction(null);
      setMessage('');
      await load();
      onChanged();
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Could not update the request'));
    } finally {
      setSaving(false);
    }
  };

  const download = async () => {
    if (!d) return;
    setDownloading(true);
    try {
      await taxFilingService.downloadQueueItem(d.uuid, d.tax_year, d.customer.name);
      load(); // the download is recorded on the timeline
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Could not download the tax sheet'));
    } finally {
      setDownloading(false);
    }
  };

  const s = d?.summary || {};
  const canQuick = (a: Action) => !!d?.next.includes(a);

  return (
    <Modal isOpen onClose={onClose} title={d ? `${d.customer.name || d.customer.email} — ${d.tax_year}` : 'Loading…'} size="3xl">
      {!d ? (
        <p className="flex items-center gap-2 text-sm text-secondary-500">
          <Loader2 className="h-4 w-4 animate-spin" /> Loading…
        </p>
      ) : (
        <div className="space-y-5">
          <div className="flex flex-wrap items-center gap-x-6 gap-y-1 text-sm">
            <Badge status={d.status} />
            <span className="text-secondary-600">{d.customer.email}</span>
            <span className="text-secondary-600">
              NINO ending <span className="font-mono">{d.customer.nino_last4 || '—'}</span>
            </span>
            <span className="text-secondary-500">Approved {fmtWhen(d.declared_at)}</span>
          </div>

          {(d.totals?.unreviewed ?? 0) > 0 && (
            <p className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              {d.totals?.unreviewed} transaction(s) were still flagged for review when the customer sent this — check
              them on the Transactions sheet (or ask the customer).
            </p>
          )}
          {(d.totals?.other_money_in ?? 0) > 0 && (
            <p className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              {gbp(d.totals?.other_money_in)} of money in is unclassified or sits in an expense category — counted as
              income. Confirm before filing.
            </p>
          )}

          <div className="grid gap-4 md:grid-cols-2">
            <div className="rounded-lg border border-secondary-200 p-3">
              <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-secondary-500">Calculation</p>
              {([
                ['Income', s.income],
                ['Allowable expenses', s.expenses],
                ['Profit', s.profit],
                ['Personal allowance', s.personal_allowance],
                ['Income Tax', s.income_tax],
                ['Class 4 NIC', s.class4_nic],
                ['Total tax and NICs', s.total_tax_and_nic],
                ['Due by 31 Jan (incl. POA)', s.total_due_31_jan],
              ] as Array<[string, number | undefined]>).map(([k, v], i) => (
                <div key={k} className={`flex justify-between py-0.5 text-sm ${i === 6 ? 'font-semibold' : ''}`}>
                  <span className="text-secondary-600">{k}</span>
                  <span className="tabular-nums text-secondary-900">{gbp(v)}</span>
                </div>
              ))}
            </div>
            <div className="rounded-lg border border-secondary-200 p-3">
              <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-secondary-500">SA103F boxes</p>
              <div className="max-h-56 space-y-0.5 overflow-y-auto">
                {(d.boxes || []).map((b) => (
                  <div key={b.box} className="flex justify-between gap-2 py-0.5 text-sm">
                    <span className="text-secondary-600">
                      <span className="mr-1 font-mono text-xs text-secondary-400">{b.box}</span>
                      {b.item}
                    </span>
                    <span className="tabular-nums text-secondary-900">{gbp(b.amount)}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>

          <div className="rounded-lg border border-primary-200 bg-primary-50 p-3">
            <p className="mb-2 text-sm font-semibold text-secondary-900">How to file this return</p>
            <ol className="space-y-1 text-sm text-secondary-700">
              <li>1. Download the tax sheet — it holds exactly the figures the customer approved.</li>
              <li>2. File it on My Tax Digital (or other HMRC-recognised software) using the Boxes sheet.</li>
              <li>3. Come back and record HMRC&apos;s reference with “Mark as filed”.</li>
            </ol>
            <button
              onClick={download}
              disabled={downloading}
              className="mt-3 flex items-center gap-2 rounded-lg bg-primary-600 px-3 py-1.5 text-sm text-white hover:bg-primary-700 disabled:opacity-50"
            >
              {downloading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />}
              Download tax sheet (.xlsx)
            </button>
          </div>

          {d.status === 'filed' && (
            <div className="rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-800">
              <p className="flex items-center gap-2 font-semibold">
                <CheckCircle2 className="h-4 w-4" /> Filed {fmtWhen(d.filed_at)} — reference{' '}
                <span className="font-mono">{d.hmrc_reference}</span>
              </p>
              {d.hmrc_total_due != null && <p>HMRC&apos;s total: {gbp(d.hmrc_total_due)}</p>}
              {d.variance_note && <p>Note: {d.variance_note}</p>}
            </div>
          )}

          {d.next.length > 0 && (
            <div className="space-y-3 border-t border-secondary-100 pt-4">
              <div className="flex flex-wrap gap-2">
                {canQuick('reviewing') && (
                  <button
                    onClick={() => submit('reviewing')}
                    disabled={saving}
                    className="rounded-lg border border-secondary-300 px-3 py-1.5 text-sm text-secondary-700 hover:bg-secondary-100 disabled:opacity-50"
                  >
                    {d.status === 'needs_info' ? 'Resume review' : 'Start review'}
                  </button>
                )}
                {canQuick('filing') && (
                  <button
                    onClick={() => submit('filing')}
                    disabled={saving}
                    className="rounded-lg border border-secondary-300 px-3 py-1.5 text-sm text-secondary-700 hover:bg-secondary-100 disabled:opacity-50"
                  >
                    I&apos;m filing it now
                  </button>
                )}
                {canQuick('filed') && (
                  <button
                    onClick={() => setAction('filed')}
                    className="flex items-center gap-1.5 rounded-lg bg-green-600 px-3 py-1.5 text-sm text-white hover:bg-green-700"
                  >
                    <FileCheck2 className="h-4 w-4" /> Mark as filed
                  </button>
                )}
                {canQuick('needs_info') && (
                  <button
                    onClick={() => setAction('needs_info')}
                    className="flex items-center gap-1.5 rounded-lg border border-amber-300 px-3 py-1.5 text-sm text-amber-800 hover:bg-amber-50"
                  >
                    <MessageSquare className="h-4 w-4" /> Ask the customer
                  </button>
                )}
                {canQuick('rejected') && (
                  <button
                    onClick={() => setAction('rejected')}
                    className="flex items-center gap-1.5 rounded-lg border border-red-200 px-3 py-1.5 text-sm text-red-700 hover:bg-red-50"
                  >
                    <Undo2 className="h-4 w-4" /> Return to customer
                  </button>
                )}
              </div>

              {(action === 'needs_info' || action === 'rejected') && (
                <div className="space-y-2">
                  <textarea
                    value={message}
                    onChange={(e) => setMessage(e.target.value)}
                    maxLength={2000}
                    rows={3}
                    placeholder={action === 'needs_info'
                      ? 'What do you need from the customer?'
                      : 'Why is it being returned? What should they fix?'}
                    className="w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm"
                  />
                  <button
                    onClick={() => submit(action)}
                    disabled={saving || message.trim() === ''}
                    className="flex items-center gap-2 rounded-lg bg-primary-600 px-3 py-1.5 text-sm text-white hover:bg-primary-700 disabled:opacity-50"
                  >
                    {saving && <Loader2 className="h-4 w-4 animate-spin" />}
                    {action === 'needs_info' ? 'Send question' : 'Return to customer'}
                  </button>
                </div>
              )}

              {action === 'filed' && (
                <div className="grid gap-2 sm:grid-cols-2">
                  <label className="text-sm text-secondary-700">
                    HMRC submission reference *
                    <input
                      value={reference}
                      onChange={(e) => setReference(e.target.value)}
                      maxLength={100}
                      className="mt-1 w-full rounded-lg border border-secondary-300 bg-surface px-3 py-1.5 font-mono text-sm"
                    />
                  </label>
                  <label className="text-sm text-secondary-700">
                    HMRC&apos;s total tax and NICs (optional)
                    <input
                      value={hmrcTotal}
                      onChange={(e) => setHmrcTotal(e.target.value)}
                      inputMode="decimal"
                      placeholder={d.our_total_due != null ? `ours: ${d.our_total_due.toFixed(2)}` : ''}
                      className="mt-1 w-full rounded-lg border border-secondary-300 bg-surface px-3 py-1.5 text-sm tabular-nums"
                    />
                  </label>
                  {variance > 1 && (
                    <label className="text-sm text-secondary-700 sm:col-span-2">
                      HMRC differs from ours by {gbp(variance)} — explain why *
                      <textarea
                        value={note}
                        onChange={(e) => setNote(e.target.value)}
                        rows={2}
                        className="mt-1 w-full rounded-lg border border-secondary-300 bg-surface px-3 py-1.5 text-sm"
                      />
                    </label>
                  )}
                  <div className="sm:col-span-2">
                    <button
                      onClick={() => submit('filed')}
                      disabled={saving || reference.trim() === '' || (variance > 1 && note.trim() === '')}
                      className="flex items-center gap-2 rounded-lg bg-green-600 px-3 py-1.5 text-sm text-white hover:bg-green-700 disabled:opacity-50"
                    >
                      {saving && <Loader2 className="h-4 w-4 animate-spin" />}
                      Confirm filed
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}

          {d.timeline.length > 0 && (
            <div className="border-t border-secondary-100 pt-3">
              <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-secondary-500">History</p>
              <ul className="space-y-1">
                {[...d.timeline].reverse().map((e, i) => (
                  <li key={`${e.at}-${i}`} className="text-sm">
                    <span className="text-secondary-400">{fmtWhen(e.at)}</span>{' '}
                    <span className="text-secondary-700">
                      {e.type === 'export' ? 'Tax sheet downloaded'
                        : e.type === 'reply' ? 'Customer replied'
                          : `${e.by === 'customer' ? 'Customer' : 'Accountant'} → ${STATUS[e.status as FilingStatus]?.label ?? e.status}`}
                    </span>
                    {e.text && <span className="text-secondary-500"> — “{e.text}”</span>}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </Modal>
  );
}

export default function FilingRequestsPage() {
  return (
    <ProtectedPage module="tax_filing_requests" title="Filing requests">
      <QueueContent />
    </ProtectedPage>
  );
}
