'use client';

/**
 * Pieces shared by the supplier portal (/supplier) and the staff PO page's supplier panel.
 * Plain words: suppliers are not technical.
 */
import React, { useState } from 'react';
import { Check, Copy, Send } from 'lucide-react';
import toast from 'react-hot-toast';
import { cn } from '@/lib/utils';
import {
  BALANCE_BASIS_LABELS,
  BALANCE_STATE_LABELS,
  DOC_TYPE_LABELS,
  INVOICE_KIND_LABELS,
  PAYMENT_METHOD_LABELS,
  PORTAL_STAGES,
  UPLOAD_ACCEPT,
  stageLabel,
  type InvoiceInput,
  type Money,
  type PortalBalance,
  type PortalMessage,
  type PortalStage,
  type PortalTimelineEntry,
} from '@/services/supplier-portal.service';

// ---------------------------------------------------------------------------
// formatting
// ---------------------------------------------------------------------------

export const inputClass =
  'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface';
export const labelClass = 'block text-sm font-medium text-secondary-700 mb-1';
export const btnSecondary =
  'inline-flex items-center justify-center gap-2 px-3 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors disabled:opacity-50 disabled:cursor-not-allowed';
export const btnPrimary =
  'inline-flex items-center justify-center gap-2 px-3 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50 disabled:cursor-not-allowed';
export const btnDanger =
  'inline-flex items-center justify-center gap-1 px-2.5 py-1.5 text-xs font-medium text-red-700 bg-red-50 border border-red-200 rounded-lg hover:bg-red-100 transition-colors disabled:opacity-50';
export const btnSmall =
  'inline-flex items-center justify-center gap-1 px-2.5 py-1.5 text-xs font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors disabled:opacity-50';

/** Postgres timestamps ("2026-11-17 10:04:05.12+00") and dates ("2026-11-17") → Date. */
export function parseWhen(v: string | null | undefined): Date | null {
  if (!v) return null;
  let t = String(v).trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(t)) {
    const d = new Date(`${t}T00:00:00Z`);
    return isNaN(d.getTime()) ? null : d;
  }
  t = t.replace(' ', 'T');
  if (/[+-]\d\d$/.test(t)) t += ':00';
  if (t.includes('T') && !/([zZ]|[+-]\d\d:?\d\d)$/.test(t)) t += 'Z';
  const d = new Date(t);
  return isNaN(d.getTime()) ? null : d;
}

export function fmtDate(v: string | null | undefined): string {
  const d = parseWhen(v);
  if (!d) return v ? String(v) : '—';
  const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(String(v).trim());
  return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', ...(dateOnly ? { timeZone: 'UTC' } : {}) });
}

export function fmtDateTime(v: string | null | undefined): string {
  const d = parseWhen(v);
  if (!d) return v ? String(v) : '—';
  return d.toLocaleString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

export function fmtMoney(v: Money | null | undefined, currency = 'GBP'): string {
  const n = Number(v ?? 0);
  if (!isFinite(n)) return String(v ?? '');
  try {
    return new Intl.NumberFormat('en-GB', { style: 'currency', currency: currency || 'GBP' }).format(n);
  } catch {
    return `${currency} ${n.toFixed(2)}`;
  }
}

export function fmtSize(bytes: number | null | undefined): string {
  if (!bytes && bytes !== 0) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Today as YYYY-MM-DD (local). */
export function todayIso(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

// ---------------------------------------------------------------------------
// stage
// ---------------------------------------------------------------------------

const STAGE_TONE: Record<string, string> = {
  draft: 'bg-secondary-100 text-secondary-700 border-secondary-200',
  sent: 'bg-blue-50 text-blue-700 border-blue-200',
  acknowledged: 'bg-indigo-50 text-indigo-700 border-indigo-200',
  proforma_received: 'bg-violet-50 text-violet-700 border-violet-200',
  part_paid: 'bg-amber-50 text-amber-800 border-amber-200',
  paid: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  dispatched: 'bg-sky-50 text-sky-700 border-sky-200',
  delivered: 'bg-teal-50 text-teal-700 border-teal-200',
  invoiced: 'bg-cyan-50 text-cyan-800 border-cyan-200',
  closed: 'bg-gray-100 text-gray-700 border-gray-200',
  cancelled: 'bg-red-50 text-red-700 border-red-200',
};

export function StageBadge({ stage, label }: { stage: string; label?: string | null }) {
  return (
    <span
      className={cn(
        'inline-flex items-center whitespace-nowrap rounded-full border px-2.5 py-0.5 text-xs font-medium',
        STAGE_TONE[stage] || STAGE_TONE.draft
      )}
    >
      {label || stageLabel(stage)}
    </span>
  );
}

/** Progress steps. part_paid / paid are folded into one "Paid" step so the row stays short. */
export function StageSteps({ stage }: { stage: PortalStage }) {
  if (stage === 'cancelled') {
    return <p className="text-sm font-medium text-red-700">This purchase order was cancelled.</p>;
  }
  const steps: { key: PortalStage[]; label: string }[] = [
    { key: ['sent'], label: 'Sent' },
    { key: ['acknowledged'], label: 'Acknowledged' },
    { key: ['proforma_received'], label: 'Proforma' },
    { key: ['part_paid', 'paid'], label: stage === 'part_paid' ? 'Part paid' : 'Paid' },
    { key: ['dispatched'], label: 'Dispatched' },
    { key: ['delivered'], label: 'Delivered' },
    { key: ['invoiced'], label: 'Final invoice' },
    { key: ['closed'], label: 'Closed' },
  ];
  const rank = (s: PortalStage) => PORTAL_STAGES.indexOf(s);
  const current = rank(stage);
  return (
    <ol className="flex flex-wrap gap-x-1 gap-y-2 text-xs" aria-label="Progress">
      {steps.map((st, i) => {
        const now = st.key.includes(stage);
        const done = !now && current > Math.max(...st.key.map(rank));
        return (
          <li key={st.label} className="flex items-center gap-1">
            <span
              className={cn(
                'inline-flex items-center gap-1 rounded-full px-2 py-1 font-medium',
                now ? 'bg-primary-600 text-white' : done ? 'bg-primary-50 text-primary-700' : 'bg-secondary-100 text-secondary-500'
              )}
              aria-current={now ? 'step' : undefined}
            >
              {done && <Check className="h-3 w-3" />}
              {st.label}
            </span>
            {i < steps.length - 1 && <span className="text-secondary-300">›</span>}
          </li>
        );
      })}
    </ol>
  );
}

// ---------------------------------------------------------------------------
// balance
// ---------------------------------------------------------------------------

const BALANCE_TONE: Record<string, string> = {
  nothing_due: 'text-secondary-600',
  unpaid: 'text-amber-700',
  part_paid: 'text-amber-700',
  paid: 'text-emerald-700',
  overpaid: 'text-red-700',
};

export function balanceText(b: PortalBalance | null | undefined): string {
  if (!b) return '';
  return BALANCE_STATE_LABELS[b.state] || b.state;
}

export function BalanceSummary({ balance, view }: { balance: PortalBalance; view: 'supplier' | 'staff' }) {
  const cur = balance.currency || 'GBP';
  const owed = Number(balance.balance);
  return (
    <div className="grid grid-cols-3 gap-2 sm:gap-4">
      <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3">
        <p className="text-xs text-secondary-500">{view === 'supplier' ? 'Total due to you' : 'Due to the supplier'}</p>
        <p className="mt-1 text-base font-semibold text-secondary-900 sm:text-lg">{fmtMoney(balance.due, cur)}</p>
      </div>
      <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3">
        <p className="text-xs text-secondary-500">Paid so far</p>
        <p className="mt-1 text-base font-semibold text-secondary-900 sm:text-lg">{fmtMoney(balance.paid, cur)}</p>
      </div>
      <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3">
        <p className="text-xs text-secondary-500">{owed < 0 ? 'Overpaid by' : 'Still to pay'}</p>
        <p className={cn('mt-1 text-base font-semibold sm:text-lg', BALANCE_TONE[balance.state])}>
          {fmtMoney(Math.abs(owed), cur)}
        </p>
      </div>
      <p className={cn('col-span-3 text-xs', BALANCE_TONE[balance.state])}>
        {balanceText(balance)} · based on {BALANCE_BASIS_LABELS[balance.basis] || balance.basis}
      </p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// history
// ---------------------------------------------------------------------------

const str = (v: unknown): string => (v === undefined || v === null ? '' : String(v));

/** One history entry as a readable sentence. */
export function timelineSentence(e: PortalTimelineEntry, view: 'supplier' | 'staff'): string {
  const d = e.detail || {};
  const who = e.by || (e.by_kind === 'system' ? 'The system' : view === 'supplier' ? 'We' : 'Someone');
  const docLabel = DOC_TYPE_LABELS[str(d.doc_type) as keyof typeof DOC_TYPE_LABELS] || 'document';
  const kindLabel = INVOICE_KIND_LABELS[str(d.kind) as keyof typeof INVOICE_KIND_LABELS] || 'Invoice';
  const amount = d.amount !== undefined ? fmtMoney(str(d.amount), str(d.currency) || 'GBP') : '';
  const reason = d.reason ? ` Reason: ${str(d.reason)}.` : '';
  switch (e.action) {
    case 'po.stage_changed': {
      const to = stageLabel(str(d.to));
      if (!d.from) return `${who === 'Someone' ? 'Marked' : `${who} marked it`} ${to.toLowerCase()}.${reason}`;
      const auto = d.auto ? ' (after a payment change)' : '';
      return `${who} moved it from ${stageLabel(str(d.from)).toLowerCase()} to ${to.toLowerCase()}${auto}.${reason}`;
    }
    case 'po.acknowledged':
      return `${who} acknowledged the purchase order.`;
    case 'po.sent':
      return `${who} sent the purchase order.`;
    case 'po.cancelled':
      return `${who} cancelled the purchase order.${reason}`;
    case 'po.closed':
      return `${who} closed the purchase order.${reason}`;
    case 'po.viewed':
      return `${who} looked at the purchase order.`;
    case 'po.supplier_linked':
      return `${who} linked it to the supplier ${str(d.supplier_name) || ''}.`.replace(' .', '.');
    case 'document.uploaded':
      return `${who} added ${docLabel.toLowerCase()}${d.filename ? `: ${str(d.filename)}` : ''}.${
        view === 'staff' && d.visible_to_supplier === false ? ' (not shown to the supplier)' : ''
      }`;
    case 'document.removed':
      return `${who} removed ${docLabel.toLowerCase()}${d.filename ? ` ${str(d.filename)}` : ''}.${reason}`;
    case 'document.downloaded':
      return `${who} downloaded ${docLabel.toLowerCase()}${d.filename ? ` ${str(d.filename)}` : ''}.`;
    case 'invoice.recorded':
      return `${who} recorded ${kindLabel.toLowerCase()} ${str(d.number)}${d.total ? ` for ${fmtMoney(str(d.total), str(d.currency) || 'GBP')}` : ''}.`;
    case 'invoice.removed':
      return `${who} removed ${kindLabel.toLowerCase()} ${str(d.number)}.${reason}`;
    case 'payment.recorded': {
      const method = PAYMENT_METHOD_LABELS[str(d.method) as keyof typeof PAYMENT_METHOD_LABELS];
      const ref = d.payment_reference ? `, reference ${str(d.payment_reference)}` : '';
      return `${who} recorded a payment of ${amount}${method ? ` by ${method}` : ''}${d.sent_on ? ` sent on ${fmtDate(str(d.sent_on))}` : ''}${ref}.`;
    }
    case 'payment.updated':
      return `${who} updated a payment${d.cleared_on ? `: cleared on ${fmtDate(str(d.cleared_on))}` : ''}.`;
    case 'payment.voided':
      return `${who} cancelled (voided) a payment${amount ? ` of ${amount}` : ''}.${reason}`;
    case 'shipment.dispatched':
      return `${who} entered dispatch${d.carrier ? ` with ${str(d.carrier)}` : ''}${
        d.tracking_number ? ` (tracking ${str(d.tracking_number)})` : ''
      }${d.dispatched_on ? ` on ${fmtDate(str(d.dispatched_on))}` : ''}.`;
    case 'shipment.delivered':
      return `${who} marked it delivered${d.delivered_on ? ` on ${fmtDate(str(d.delivered_on))}` : ''}${
        d.received_by ? `, received by ${str(d.received_by)}` : ''
      }.`;
    case 'message.posted':
      return `${who} wrote a message.`;
    case 'notification.sent':
      return `The supplier was emailed${d.event ? ` (${str(d.event).replace(/_/g, ' ')})` : ''}.`;
    case 'notification.suppressed': {
      const why =
        d.reason === 'disabled'
          ? 'supplier emails are off'
          : d.reason === 'no_recipients'
            ? 'the supplier has no portal login to email'
            : d.reason === 'no_supplier'
              ? 'no supplier is linked'
              : str(d.reason);
      return `Nothing was emailed to the supplier${d.event ? ` about ${str(d.event).replace(/_/g, ' ')}` : ''}${why ? `: ${why}` : ''}.`;
    }
    default:
      return `${who}: ${e.action.replace(/[._]/g, ' ')}.`;
  }
}

export function Timeline({ entries, view }: { entries: PortalTimelineEntry[]; view: 'supplier' | 'staff' }) {
  if (entries.length === 0) return <p className="text-sm text-secondary-500">Nothing yet.</p>;
  const list = [...entries].reverse();
  return (
    <ol className="space-y-3">
      {list.map((e, i) => (
        <li key={`${e.at}-${i}`} className="flex gap-3 text-sm">
          <span
            className={cn(
              'mt-1.5 h-2 w-2 shrink-0 rounded-full',
              e.by_kind === 'supplier' ? 'bg-amber-500' : e.by_kind === 'system' ? 'bg-secondary-300' : 'bg-primary-500'
            )}
          />
          <div className="min-w-0">
            <p className="text-secondary-800">{timelineSentence(e, view)}</p>
            <p className="text-xs text-secondary-500">{fmtDateTime(e.at)}</p>
          </div>
        </li>
      ))}
    </ol>
  );
}

// ---------------------------------------------------------------------------
// messages
// ---------------------------------------------------------------------------

export function MessageThread({
  messages,
  mine,
  canSend,
  onSend,
  placeholder,
  sendHint,
}: {
  messages: PortalMessage[];
  /** Whose messages are shown on the right. */
  mine: 'staff' | 'supplier';
  canSend: boolean;
  /** Resolve true when sent (the box is cleared). */
  onSend: (text: string) => Promise<boolean>;
  placeholder?: string;
  sendHint?: React.ReactNode;
}) {
  const [text, setText] = useState('');
  const [sending, setSending] = useState(false);
  const send = async () => {
    const t = text.trim();
    if (!t) return;
    if (t.length > 4000) {
      toast.error('Messages can be at most 4000 characters');
      return;
    }
    setSending(true);
    try {
      if (await onSend(t)) setText('');
    } finally {
      setSending(false);
    }
  };
  return (
    <div className="space-y-3">
      {messages.length === 0 ? (
        <p className="text-sm text-secondary-500">No messages yet.</p>
      ) : (
        <ul className="max-h-96 space-y-2 overflow-y-auto pr-1">
          {messages.map((m) => {
            const own = m.author_kind === mine;
            return (
              <li key={m.id} className={cn('flex', own ? 'justify-end' : 'justify-start')}>
                <div
                  className={cn(
                    'max-w-[85%] rounded-xl px-3 py-2 text-sm',
                    own ? 'bg-primary-50 text-secondary-900' : 'bg-secondary-100 text-secondary-900'
                  )}
                >
                  <p className="whitespace-pre-line break-words">{m.body}</p>
                  <p className="mt-1 text-[11px] text-secondary-500">
                    {m.author || (m.author_kind === 'staff' ? 'Us' : 'Supplier')} · {fmtDateTime(m.created_at)}
                  </p>
                </div>
              </li>
            );
          })}
        </ul>
      )}
      {canSend && (
        <div className="space-y-2">
          <textarea
            className={cn(inputClass, 'min-h-[80px]')}
            value={text}
            maxLength={4000}
            placeholder={placeholder || 'Write a message'}
            onChange={(e) => setText(e.target.value)}
          />
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="text-xs text-secondary-500">{sendHint}</div>
            <button type="button" className={btnPrimary} disabled={sending || !text.trim()} onClick={send}>
              <Send className="h-4 w-4" />
              {sending ? 'Sending…' : 'Send'}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// forms
// ---------------------------------------------------------------------------

export const emptyInvoice = (): InvoiceInput => ({
  number: '',
  invoice_date: todayIso(),
  net: '',
  vat: '',
  total: '',
  supplier_order_ref: '',
  payment_terms: '',
  incoterm: '',
  due_date: '',
  bank_details: '',
});

const AMOUNT = /^\d+(\.\d{1,2})?$/;

/** A message when the invoice details aren't complete, else null. */
export function invoiceProblem(inv: InvoiceInput, label: string): string | null {
  if (!inv.number.trim()) return `Enter the ${label.toLowerCase()} number`;
  if (!inv.invoice_date) return 'Enter the date on it';
  if (!AMOUNT.test(inv.total.trim().replace(/,/g, ''))) return 'Enter the total, for example 5256.65';
  for (const [k, v] of [
    ['Net', inv.net],
    ['VAT', inv.vat],
  ] as const) {
    if (v && v.trim() && !AMOUNT.test(v.trim().replace(/,/g, ''))) return `${k} must be an amount such as 4380.54`;
  }
  return null;
}

/** Strip thousands separators so "5,256.65" is sent as "5256.65". */
export function tidyInvoice(inv: InvoiceInput): InvoiceInput {
  const m = (v?: string) => (v ? v.trim().replace(/,/g, '') : v);
  return { ...inv, net: m(inv.net), vat: m(inv.vat), total: m(inv.total) || '' };
}

export function InvoiceFields({
  value,
  onChange,
  label,
  showBank = true,
}: {
  value: InvoiceInput;
  onChange: (v: InvoiceInput) => void;
  label: string;
  showBank?: boolean;
}) {
  const set = (k: keyof InvoiceInput) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    onChange({ ...value, [k]: e.target.value });
  return (
    <div className="space-y-3">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div>
          <label className={labelClass}>{label} number *</label>
          <input className={inputClass} value={value.number} onChange={set('number')} />
        </div>
        <div>
          <label className={labelClass}>Date on it *</label>
          <input type="date" className={inputClass} value={value.invoice_date} onChange={set('invoice_date')} />
        </div>
      </div>
      <div className="grid grid-cols-3 gap-3">
        <div>
          <label className={labelClass}>Net</label>
          <input inputMode="decimal" className={inputClass} placeholder="0.00" value={value.net ?? ''} onChange={set('net')} />
        </div>
        <div>
          <label className={labelClass}>VAT</label>
          <input inputMode="decimal" className={inputClass} placeholder="0.00" value={value.vat ?? ''} onChange={set('vat')} />
        </div>
        <div>
          <label className={labelClass}>Total *</label>
          <input inputMode="decimal" className={inputClass} placeholder="0.00" value={value.total} onChange={set('total')} />
        </div>
      </div>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div>
          <label className={labelClass}>Your order reference</label>
          <input className={inputClass} value={value.supplier_order_ref ?? ''} onChange={set('supplier_order_ref')} />
        </div>
        <div>
          <label className={labelClass}>Payment due date</label>
          <input type="date" className={inputClass} value={value.due_date ?? ''} onChange={set('due_date')} />
        </div>
        <div>
          <label className={labelClass}>Payment terms</label>
          <input className={inputClass} placeholder="e.g. 100% before dispatch" value={value.payment_terms ?? ''} onChange={set('payment_terms')} />
        </div>
        <div>
          <label className={labelClass}>Incoterm</label>
          <input className={inputClass} placeholder="e.g. DAP" value={value.incoterm ?? ''} onChange={set('incoterm')} />
        </div>
      </div>
      {showBank && (
        <div>
          <label className={labelClass}>Bank details on it</label>
          <textarea
            className={cn(inputClass, 'min-h-[60px]')}
            placeholder="Account name, sort code, account number / IBAN"
            value={value.bank_details ?? ''}
            onChange={set('bank_details')}
          />
        </div>
      )}
    </div>
  );
}

export function FileField({
  label,
  file,
  onChange,
  required,
  hint,
}: {
  label: string;
  file: File | null;
  onChange: (f: File | null) => void;
  required?: boolean;
  hint?: string;
}) {
  return (
    <div>
      <label className={labelClass}>
        {label}
        {required ? ' *' : ''}
      </label>
      <input
        type="file"
        accept={UPLOAD_ACCEPT}
        onChange={(e) => onChange(e.target.files?.[0] ?? null)}
        className="block w-full text-sm text-secondary-700 file:mr-3 file:rounded-lg file:border-0 file:bg-primary-50 file:px-3 file:py-2 file:text-sm file:font-medium file:text-primary-700 hover:file:bg-primary-100"
      />
      <p className="mt-1 text-xs text-secondary-500">
        {file ? `${file.name} (${fmtSize(file.size)})` : hint || 'PDF, PNG or JPG, up to 20 MB'}
      </p>
    </div>
  );
}

/** A link to pass on, with a Copy button. */
export function CopyLink({ url, message }: { url: string; message?: string | null }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      toast.success('Link copied');
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast.error('Could not copy: select the link and copy it yourself');
    }
  };
  return (
    <div className="space-y-2 rounded-lg border border-emerald-200 bg-emerald-50 p-3">
      {message && <p className="text-sm text-emerald-900">{message}</p>}
      <div className="flex flex-col gap-2 sm:flex-row">
        <input readOnly value={url} className={cn(inputClass, 'font-mono text-xs')} onFocus={(e) => e.currentTarget.select()} />
        <button type="button" onClick={copy} className={btnSecondary}>
          {copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
          {copied ? 'Copied' : 'Copy'}
        </button>
      </div>
    </div>
  );
}

export function SectionCard({
  title,
  actions,
  children,
  className,
}: {
  title: React.ReactNode;
  actions?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <section className={cn('rounded-xl border border-secondary-200 bg-surface shadow-sm', className)}>
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-secondary-200 px-4 py-3 sm:px-5">
        <h2 className="font-medium text-secondary-900">{title}</h2>
        {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
      </div>
      <div className="p-4 sm:p-5">{children}</div>
    </section>
  );
}
