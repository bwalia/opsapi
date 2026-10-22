'use client';

/**
 * "Let our accountant file it for you" — the filing path while we aren't an
 * HMRC-recognised filer. The customer reviews their figures, accepts the declaration
 * and sends them; our accountant files them with HMRC-recognised software (e.g. My Tax
 * Digital) and records HMRC's reference, which shows up here. Backend: routes/tax-filing.
 */

import React, { useState } from 'react';
import Link from 'next/link';
import {
  AlertTriangle,
  CheckCircle2,
  Download,
  Loader2,
  MessageSquare,
  Send,
  UserCheck,
  XCircle,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { Card, Modal } from '@/components/ui';
import {
  taxFilingService,
  type FilingOverview,
  type FilingRequest,
  type FilingStatus,
} from '@/services/tax-filing.service';
import { formatCurrency, extractApiError } from '@/lib/utils';

const STEPS: Array<{ key: string; label: string }> = [
  { key: 'submitted', label: 'Sent' },
  { key: 'reviewing', label: 'Reviewing' },
  { key: 'filing', label: 'Filing with HMRC' },
  { key: 'filed', label: 'Filed' },
];
const RANK: Record<string, number> = { submitted: 0, reviewing: 1, needs_info: 1, filing: 2, filed: 3 };

const STATUS_TEXT: Record<FilingStatus, string> = {
  submitted: 'Sent — waiting for our accountant to pick it up.',
  reviewing: 'Our accountant is reviewing your figures.',
  needs_info: 'Our accountant has a question for you.',
  filing: 'Our accountant is filing your return with HMRC.',
  filed: 'Your return has been filed with HMRC.',
  rejected: 'Our accountant returned this request to you.',
  cancelled: 'You cancelled this request.',
};

const CANCELLABLE: FilingStatus[] = ['submitted', 'reviewing', 'needs_info'];

// Postgres timestamps arrive as "2026-10-22 06:44:00" (UTC, no zone); timeline as ISO "…Z".
function fmtWhen(s?: string | null): string {
  if (!s) return '';
  const iso = s.includes('T') ? s : `${s.replace(' ', 'T')}Z`;
  const d = new Date(iso);
  return Number.isNaN(d.getTime())
    ? s
    : d.toLocaleString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

const gbp = (n?: number | null) => (n == null ? '—' : formatCurrency(n, 'GBP', 'en-GB'));

function timelineLabel(e: FilingRequest['timeline'][number]): string {
  if (e.type === 'reply') return 'You replied';
  if (e.status === 'submitted') return 'You sent your figures';
  if (e.status === 'cancelled') return 'You cancelled the request';
  if (e.status === 'needs_info') return 'Our accountant asked a question';
  if (e.status === 'rejected') return 'Our accountant returned the request';
  if (e.status === 'filed') return 'Filed with HMRC';
  if (e.status === 'filing') return 'Filing started';
  if (e.status === 'reviewing') return 'Review started';
  return 'Update';
}

interface Props {
  overview: FilingOverview;
  taxYear: string;
  hasNino: boolean;
  onChanged: () => void;
}

export default function FileForMe({ overview, taxYear, hasNino, onChanged }: Props) {
  const req = overview.request;
  const tracking = !!req && (req.open || req.status === 'filed');
  return tracking ? (
    <RequestStatus req={req!} onChanged={onChanged} />
  ) : (
    <SendToAccountant overview={overview} taxYear={taxYear} hasNino={hasNino} onChanged={onChanged} />
  );
}

// ── Send ───────────────────────────────────────────────────────────────────────

function SendToAccountant({ overview, taxYear, hasNino, onChanged }: Props) {
  const [accepted, setAccepted] = useState(false);
  const [sending, setSending] = useState(false);
  const est = overview.estimate;
  const last = overview.request; // a closed (rejected / cancelled) one, if any
  const noFigures = (est.transactions ?? 0) === 0;
  const canSend = hasNino && !noFigures && accepted && !sending;

  const send = async () => {
    setSending(true);
    try {
      await taxFilingService.createRequest(taxYear, overview.figures_hash);
      toast.success('Sent to our accountant');
      onChanged();
    } catch (err: unknown) {
      const code = (err as { response?: { data?: { code?: string } } })?.response?.data?.code;
      toast.error(extractApiError(err, 'Could not send your request'));
      if (code === 'FIGURES_CHANGED' || code === 'ALREADY_REQUESTED') onChanged();
    } finally {
      setSending(false);
    }
  };

  return (
    <Card padding="lg">
      <div className="flex items-start gap-3">
        <div className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-primary-100 text-primary-600">
          <UserCheck className="h-4 w-4" />
        </div>
        <div>
          <p className="font-semibold text-secondary-900">Send your return to our accountant</p>
          <p className="text-sm text-secondary-500">
            A qualified accountant checks your figures and files your {taxYear} return with HMRC-recognised software.
          </p>
        </div>
      </div>

      <div className="mt-4 space-y-3 pl-12">
        {last?.status === 'rejected' && (
          <div className="flex items-start gap-2 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            <XCircle className="mt-0.5 h-4 w-4 shrink-0" />
            <span>
              Your last request was returned{last.client_message ? <>: <em>“{last.client_message}”</em></> : '.'} Update
              your figures, then send them again.
            </span>
          </div>
        )}

        <ol className="space-y-1.5 text-sm text-secondary-700">
          {[
            'Our accountant reviews your figures (and may ask you a question here).',
            'They may ask you to authorise them as your agent with HMRC — we’ll guide you.',
            'They file your return with HMRC-recognised software such as My Tax Digital.',
            'You see HMRC’s reference here once it’s filed.',
          ].map((t, i) => (
            <li key={t} className="flex gap-2">
              <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-secondary-100 text-xs font-semibold text-secondary-600">
                {i + 1}
              </span>
              <span>{t}</span>
            </li>
          ))}
        </ol>

        {noFigures && (
          <Warn>
            No figures for {taxYear} yet — upload your bank statements in{' '}
            <Link href="/dashboard/tax/agent" className="font-medium underline">File with AI</Link> first.
          </Warn>
        )}
        {!noFigures && est.unreviewed > 0 && (
          <Warn>
            {est.unreviewed} transaction{est.unreviewed === 1 ? '' : 's'} still need review. Our accountant will check
            them, but reviewing them yourself in{' '}
            <Link href="/dashboard/tax/agent" className="font-medium underline">File with AI</Link> makes your return
            more accurate.
          </Warn>
        )}
        {!hasNino && <Warn>Add your National Insurance number in step 1 first.</Warn>}

        {!noFigures && (
          <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-secondary-200 bg-surface px-3 py-2 text-sm">
            <span className="text-secondary-600">You’re sending figures showing estimated tax of</span>
            <span className="font-semibold tabular-nums text-secondary-900">{gbp(est.total_tax_and_nic)}</span>
          </div>
        )}

        <label className="flex items-start gap-2 text-sm text-secondary-700">
          <input
            type="checkbox"
            checked={accepted}
            onChange={(e) => setAccepted(e.target.checked)}
            disabled={noFigures}
            className="mt-0.5"
          />
          <span>{overview.declaration_text}</span>
        </label>

        <button
          onClick={send}
          disabled={!canSend}
          className="flex items-center gap-2 rounded-lg bg-primary-600 px-4 py-2 text-white hover:bg-primary-700 disabled:opacity-50"
        >
          {sending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
          {sending ? 'Sending…' : 'Send to our accountant'}
        </button>
      </div>
    </Card>
  );
}

// ── Track ──────────────────────────────────────────────────────────────────────

function RequestStatus({ req, onChanged }: { req: FilingRequest; onChanged: () => void }) {
  const [reply, setReply] = useState('');
  const [replying, setReplying] = useState(false);
  const [confirmCancel, setConfirmCancel] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const [downloading, setDownloading] = useState(false);
  const rank = RANK[req.status] ?? 0;

  const sendReply = async () => {
    setReplying(true);
    try {
      await taxFilingService.replyRequest(req.uuid, reply.trim());
      setReply('');
      toast.success('Reply sent to our accountant');
      onChanged();
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Could not send your reply'));
    } finally {
      setReplying(false);
    }
  };

  const cancel = async () => {
    setCancelling(true);
    try {
      await taxFilingService.cancelRequest(req.uuid);
      setConfirmCancel(false);
      toast.success('Request cancelled');
      onChanged();
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Could not cancel the request'));
    } finally {
      setCancelling(false);
    }
  };

  const download = async () => {
    setDownloading(true);
    try {
      await taxFilingService.downloadRequest(req.uuid, req.tax_year);
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Could not download your figures'));
    } finally {
      setDownloading(false);
    }
  };

  return (
    <Card padding="lg">
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-semibold text-secondary-900">Your {req.tax_year} return — with our accountant</p>
          <p className="text-sm text-secondary-500">{STATUS_TEXT[req.status]}</p>
        </div>
        <span className="text-xs text-secondary-400">Sent {fmtWhen(req.declared_at || req.created_at)}</span>
      </div>

      {/* Progress */}
      <div className="mt-5 flex items-center">
        {STEPS.map((s, i) => {
          const done = i < rank || req.status === 'filed';
          const current = i === rank && req.status !== 'filed';
          const question = current && req.status === 'needs_info';
          return (
            <React.Fragment key={s.key}>
              <div className="flex flex-col items-center gap-1 text-center">
                <div
                  className={`flex h-7 w-7 items-center justify-center rounded-full text-xs font-semibold ${
                    done ? 'bg-green-100 text-green-700'
                      : question ? 'bg-amber-100 text-amber-700'
                        : current ? 'bg-primary-100 text-primary-700' : 'bg-secondary-100 text-secondary-400'
                  }`}
                >
                  {done ? <CheckCircle2 className="h-4 w-4" /> : question ? <MessageSquare className="h-3.5 w-3.5" /> : i + 1}
                </div>
                <span className={`text-xs ${done || current ? 'text-secondary-700' : 'text-secondary-400'}`}>
                  {question ? 'Question for you' : s.label}
                </span>
              </div>
              {i < STEPS.length - 1 && (
                <div className={`mx-2 mb-5 h-0.5 flex-1 ${i < rank || req.status === 'filed' ? 'bg-green-300' : 'bg-secondary-200'}`} />
              )}
            </React.Fragment>
          );
        })}
      </div>

      <div className="mt-4 space-y-3">
        {req.status === 'needs_info' && (
          <div className="space-y-2 rounded-lg border border-amber-200 bg-amber-50 p-3">
            <p className="flex items-start gap-2 text-sm text-amber-900">
              <MessageSquare className="mt-0.5 h-4 w-4 shrink-0" />
              <span><strong>Our accountant asks:</strong> {req.client_message}</span>
            </p>
            <textarea
              value={reply}
              onChange={(e) => setReply(e.target.value)}
              maxLength={2000}
              rows={3}
              placeholder="Type your answer…"
              className="w-full rounded-lg border border-amber-300 bg-surface px-3 py-2 text-sm"
            />
            <button
              onClick={sendReply}
              disabled={replying || reply.trim() === ''}
              className="flex items-center gap-2 rounded-lg bg-primary-600 px-3 py-1.5 text-sm text-white hover:bg-primary-700 disabled:opacity-50"
            >
              {replying ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
              Send reply
            </button>
          </div>
        )}

        {req.status === 'filed' && (
          <div className="space-y-1 rounded-lg border border-green-200 bg-green-50 p-3">
            <p className="flex items-center gap-2 font-semibold text-green-800">
              <CheckCircle2 className="h-5 w-5" /> Filed with HMRC {fmtWhen(req.filed_at)}
            </p>
            {req.hmrc_reference && (
              <p className="text-sm text-green-700">
                HMRC reference: <span className="font-mono">{req.hmrc_reference}</span>
              </p>
            )}
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2">
          <button
            onClick={download}
            disabled={downloading}
            className="flex items-center gap-2 rounded-lg border border-secondary-300 px-3 py-1.5 text-sm text-secondary-700 hover:bg-secondary-100 disabled:opacity-50"
          >
            {downloading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />}
            Download the figures you approved
          </button>
          {CANCELLABLE.includes(req.status) && (
            <button
              onClick={() => setConfirmCancel(true)}
              className="rounded-lg px-3 py-1.5 text-sm text-red-600 hover:bg-red-50"
            >
              Cancel request
            </button>
          )}
        </div>

        {req.timeline.length > 0 && (
          <div className="border-t border-secondary-100 pt-3">
            <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-secondary-500">History</p>
            <ul className="space-y-1.5">
              {[...req.timeline].reverse().map((e, i) => (
                <li key={`${e.at}-${i}`} className="text-sm">
                  <span className="text-secondary-400">{fmtWhen(e.at)}</span>{' '}
                  <span className="text-secondary-700">{timelineLabel(e)}</span>
                  {e.text && <span className="text-secondary-500"> — “{e.text}”</span>}
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>

      <Modal
        isOpen={confirmCancel}
        onClose={() => setConfirmCancel(false)}
        title="Cancel this filing request?"
        size="sm"
        footer={(
          <div className="flex justify-end gap-2">
            <button
              type="button"
              onClick={() => setConfirmCancel(false)}
              className="rounded-lg border border-secondary-300 px-4 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-50"
            >
              Keep it
            </button>
            <button
              type="button"
              onClick={cancel}
              disabled={cancelling}
              className="flex items-center gap-2 rounded-lg bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
            >
              {cancelling && <Loader2 className="h-4 w-4 animate-spin" />}
              Cancel request
            </button>
          </div>
        )}
      >
        <p className="text-sm text-secondary-600">
          Our accountant will stop working on your {req.tax_year} return. You can send your figures again later.
        </p>
      </Modal>
    </Card>
  );
}

function Warn({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
      <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
      <span>{children}</span>
    </div>
  );
}
