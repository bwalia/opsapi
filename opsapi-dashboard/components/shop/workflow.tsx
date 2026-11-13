'use client';

/**
 * Operator workflow pieces shared by the shop quote, Order Authorisation and order pages:
 *   - NextStepPanel: the single next step for the current state, one primary button, the rest under "More"
 *   - StatusTimeline + quoteTimeline / orderTimeline: what has happened so far
 *   - PoNumberField: the customer's PO number, editable inline, with a copy button
 *   - quoteNextStep / orderNextStep: which step comes next (pure, so the pages and lists agree)
 */
import React, { useEffect, useRef, useState } from 'react';
import { Check, CheckCircle2, ChevronDown, Circle, Copy, Pencil, X } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card } from '@/components/ui';
import { formatDateTime } from '@/lib/utils';
import { humanize } from '@/lib/shop';
import type { ShopOrder, ShopOrderPurchaseOrderRef, ShopQuote } from '@/types/shop';

// ---------------------------------------------------------------------------
// next step
// ---------------------------------------------------------------------------

export type QuoteStepKey =
  | 'superseded'
  | 'cancelled'
  | 'send'
  | 'awaiting_customer'
  | 'expired'
  | 'create_order'
  | 'awaiting_payment'
  | 'has_order';

export interface Step<K extends string> {
  key: K;
  title: string;
  description: string;
}

export function quoteNextStep(q: ShopQuote): Step<QuoteStepKey> {
  const isOrder = q.kind === 'order';
  const noun = isOrder ? 'Order Authorisation' : 'quote';
  if (q.superseded_by) {
    return { key: 'superseded', title: `Replaced by ${q.superseded_by.quote_number}`, description: 'Work on the latest revision. This one can no longer be authorised or paid.' };
  }
  if (q.has_order || q.status === 'converted') {
    return { key: 'has_order', title: q.order_number ? `Order ${q.order_number} created` : 'Order created', description: 'The next steps (payment, supplier PO, delivery) happen on the order.' };
  }
  switch (q.status) {
    case 'draft':
      return { key: 'send', title: isOrder ? 'Send for authorisation' : 'Email the quote to the customer', description: `Check the lines, delivery and the customer's PO number, then email the ${noun} with the PDF.` };
    case 'sent':
      return { key: 'awaiting_customer', title: 'Waiting for the customer', description: isOrder ? 'They confirm the order and accept the terms from the link in the email. Resend it if they can’t find it.' : 'They can accept and pay from the link in the email.' };
    case 'expired':
      return { key: 'expired', title: 'Expired', description: 'Revise it to give it a new validity date, or raise a new quote if prices have moved.' };
    case 'accepted':
      return isOrder
        ? { key: 'awaiting_payment', title: 'Awaiting payment', description: `Authorised${q.authorised_by_name ? ` by ${q.authorised_by_name}` : ''}. The customer pays by card or bank transfer from their link; the order appears here when they do.` }
        : { key: 'create_order', title: 'Create the Order Authorisation', description: 'The customer accepted the quote. Turn it into an Order Authorisation for them to confirm and pay.' };
    case 'cancelled':
      return { key: 'cancelled', title: 'Cancelled', description: 'Nothing more to do. Raise a new quote if the customer comes back.' };
    default:
      return { key: 'cancelled', title: humanize(q.status), description: '' };
  }
}

export type OrderStepKey =
  | 'awaiting_bank_transfer'
  | 'awaiting_payment'
  | 'payment_failed'
  | 'raise_po'
  | 'send_po'
  | 'receive'
  | 'ship'
  | 'deliver'
  | 'done'
  | 'closed';

const OPEN_PO = new Set(['draft', 'sent', 'acknowledged', 'partially_received', 'received', 'billed']);

/** The supplier PO that drives the order's next step: the newest one that isn't cancelled. */
export function activePurchaseOrder(o: ShopOrder): ShopOrderPurchaseOrderRef | null {
  return (o.purchase_orders ?? []).find((p) => OPEN_PO.has(p.status)) ?? null;
}

export function orderNextStep(o: ShopOrder): Step<OrderStepKey> {
  const po = activePurchaseOrder(o);
  switch (o.status) {
    case 'pending_payment':
      return o.payment_method === 'bank_transfer'
        ? { key: 'awaiting_bank_transfer', title: 'Awaiting bank transfer', description: `Check the bank for a payment with reference ${o.order_number}, then mark the order paid.` }
        : { key: 'awaiting_payment', title: 'Awaiting payment', description: 'The customer is paying by card. Stripe confirms the payment automatically.' };
    case 'payment_failed':
      return { key: 'payment_failed', title: 'Payment failed', description: 'Contact the customer. Cancel the order if they don’t want to try again.' };
    case 'paid':
    case 'processing':
      if (!po) return { key: 'raise_po', title: 'Raise the supplier PO', description: 'Order the goods from the supplier, delivered directly to the customer.' };
      if (po.status === 'draft') return { key: 'send_po', title: `Send supplier PO ${po.po_number}`, description: 'Check the costs on the PO, then email it to the supplier.' };
      if (po.status === 'sent' || po.status === 'acknowledged' || po.status === 'partially_received') {
        return { key: 'receive', title: 'Mark the goods received', description: `When ${po.supplier_name} confirms dispatch or delivery of PO ${po.po_number}.` };
      }
      return { key: 'ship', title: 'Mark shipped', description: 'Add the carrier and tracking number for the customer.' };
    case 'shipped':
      return { key: 'deliver', title: 'Mark delivered', description: 'Once the customer has the goods.' };
    case 'delivered':
      return { key: 'done', title: 'Delivered', description: 'All done. Invoice the customer if they need one.' };
    default:
      return { key: 'closed', title: humanize(o.status), description: 'Nothing more to do on this order.' };
  }
}

// ---------------------------------------------------------------------------
// NextStepPanel
// ---------------------------------------------------------------------------

export interface PanelAction {
  label: string;
  onClick?: () => void;
  href?: string;
  icon?: React.ReactNode;
  loading?: boolean;
  disabled?: boolean;
  danger?: boolean;
  title?: string;
}

/** A "More" menu of secondary actions. */
export function MoreMenu({ actions, label = 'More' }: { actions: PanelAction[]; label?: string }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    document.addEventListener('mousedown', close);
    document.addEventListener('keydown', esc);
    return () => {
      document.removeEventListener('mousedown', close);
      document.removeEventListener('keydown', esc);
    };
  }, [open]);
  const visible = actions.filter(Boolean);
  if (!visible.length) return null;
  return (
    <div className="relative" ref={ref}>
      <Button variant="outline" rightIcon={<ChevronDown className="h-4 w-4" />} onClick={() => setOpen((v) => !v)} aria-haspopup="menu" aria-expanded={open}>
        {label}
      </Button>
      {open && (
        <div role="menu" className="absolute right-0 z-30 mt-1 min-w-[14rem] overflow-hidden rounded-lg border border-secondary-200 bg-white py-1 shadow-lg">
          {visible.map((a) => {
            const cls = `flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-secondary-50 disabled:cursor-not-allowed disabled:opacity-50 ${a.danger ? 'text-error-700' : 'text-secondary-700'}`;
            return a.href ? (
              <a key={a.label} role="menuitem" href={a.href} target={a.href.startsWith('http') ? '_blank' : undefined} rel="noopener noreferrer" className={cls} onClick={() => setOpen(false)}>
                {a.icon}
                {a.label}
              </a>
            ) : (
              <button
                key={a.label}
                role="menuitem"
                type="button"
                className={cls}
                disabled={a.disabled || a.loading}
                title={a.title}
                onClick={() => {
                  setOpen(false);
                  a.onClick?.();
                }}
              >
                {a.icon}
                {a.loading ? `${a.label}…` : a.label}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

/**
 * The single next step: what to do now, one primary button, secondary actions under "More".
 * `slot` renders extra buttons next to the primary one (e.g. payment actions such as "Mark paid").
 */
export function NextStepPanel({
  step,
  primary,
  more = [],
  slot,
  tone = 'action',
}: {
  step: { title: string; description: string };
  primary?: PanelAction | null;
  more?: PanelAction[];
  slot?: React.ReactNode;
  tone?: 'action' | 'waiting' | 'done';
}) {
  const border = tone === 'action' ? 'border-l-primary-500' : tone === 'waiting' ? 'border-l-warning-500' : 'border-l-success-500';
  return (
    <Card padding="md" className={`border-l-4 ${border} print:hidden`}>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0">
          <p className="text-xs font-semibold uppercase tracking-wider text-secondary-500">Next step</p>
          <p className="text-base font-semibold text-secondary-900">{step.title}</p>
          {step.description && <p className="mt-0.5 text-sm text-secondary-600">{step.description}</p>}
        </div>
        <div className="flex shrink-0 flex-wrap items-center gap-2">
          {slot}
          {primary &&
            (primary.href ? (
              <a href={primary.href}>
                <Button leftIcon={primary.icon}>{primary.label}</Button>
              </a>
            ) : (
              <Button leftIcon={primary.icon} isLoading={primary.loading} disabled={primary.disabled} onClick={primary.onClick} title={primary.title}>
                {primary.label}
              </Button>
            ))}
          <MoreMenu actions={more} />
        </div>
      </div>
    </Card>
  );
}

// ---------------------------------------------------------------------------
// timeline
// ---------------------------------------------------------------------------

export interface TimelineItem {
  label: string;
  at?: string | null;
  detail?: React.ReactNode;
  done: boolean;
}

export function StatusTimeline({ items }: { items: TimelineItem[] }) {
  return (
    <ol className="space-y-3">
      {items.map((it, i) => (
        <li key={`${it.label}-${i}`} className="flex gap-3">
          {it.done ? <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success-600" aria-hidden="true" /> : <Circle className="mt-0.5 h-4 w-4 shrink-0 text-secondary-300" aria-hidden="true" />}
          <div className="min-w-0 text-sm">
            <p className={it.done ? 'font-medium text-secondary-900' : 'text-secondary-500'}>
              {it.label}
              {it.at && <span className="ml-2 font-normal text-secondary-500">{formatDateTime(it.at)}</span>}
            </p>
            {it.detail && <div className="text-xs text-secondary-600">{it.detail}</div>}
          </div>
          <span className="sr-only">{it.done ? 'done' : 'not yet'}</span>
        </li>
      ))}
    </ol>
  );
}

export function quoteTimeline(q: ShopQuote): TimelineItem[] {
  const items: TimelineItem[] = [
    { label: q.revision_no ? `Revision ${q.revision_no} created` : 'Created', at: q.created_at, done: true, detail: q.revision_of ? `Revises ${q.revision_of.quote_number}` : undefined },
    { label: 'Sent to the customer', at: q.sent_at, done: !!q.sent_at },
    { label: 'Viewed by the customer', at: q.viewed_at, done: !!q.viewed_at },
    {
      label: 'Authorised',
      at: q.authorised_at,
      done: !!q.authorised_at,
      detail: q.authorised_at ? [q.authorised_by_name && `by ${q.authorised_by_name}`, q.customer_po_number && `their PO ${q.customer_po_number}`].filter(Boolean).join(', ') : undefined,
    },
    { label: 'Paid', at: q.order_paid_at, done: !!q.order_paid_at, detail: q.order_number ? `Order ${q.order_number}` : undefined },
  ];
  if (q.superseded_by) items.push({ label: `Replaced by ${q.superseded_by.quote_number}`, done: true });
  return items;
}

/** Order timeline. `invoicedAt` comes from the payment-methods feature when it ships. */
export function orderTimeline(o: ShopOrder, extra: { invoicedAt?: string | null; invoiceNumber?: string | null } = {}): TimelineItem[] {
  const po = activePurchaseOrder(o);
  const method = o.payment_method ? humanize(o.payment_method) : o.stripe_payment_intent_id || o.stripe_session_id ? 'Card (Stripe)' : null;
  const shippedAt = (o.tracking?.shipped_at as string | undefined) ?? null;
  return [
    { label: 'Order placed', at: o.created_at, done: true, detail: o.quote_number ? `From ${o.quote_number}` : undefined },
    { label: 'Paid', at: o.paid_at, done: !!o.paid_at, detail: o.paid_at && method ? method : undefined },
    { label: 'Supplier PO raised', at: po?.created_at, done: !!po, detail: po ? `${po.po_number} · ${po.supplier_name}` : undefined },
    { label: 'Supplier PO sent', at: po?.sent_at, done: !!po?.sent_at },
    { label: 'Goods received', at: po?.received_at, done: !!po && ['received', 'billed'].includes(po.status), detail: po?.status === 'partially_received' ? 'Part received' : undefined },
    { label: 'Shipped', at: shippedAt, done: ['shipped', 'delivered'].includes(o.status), detail: o.tracking?.tracking_number ? `${o.tracking?.carrier ?? ''} ${o.tracking.tracking_number}`.trim() : undefined },
    { label: 'Delivered', done: o.status === 'delivered' },
    { label: 'Invoiced', at: extra.invoicedAt, done: !!(extra.invoicedAt || o.invoice_uuid), detail: extra.invoiceNumber ?? undefined },
  ];
}

// ---------------------------------------------------------------------------
// customer PO number
// ---------------------------------------------------------------------------

export const PO_NUMBER_MAX = 64;

/** The customer's PO number: shown with a copy button, edited inline (Enter saves, Escape cancels). */
export function PoNumberField({
  value,
  editable,
  onSave,
  lockedReason,
}: {
  value?: string | null;
  editable: boolean;
  onSave: (v: string | null) => Promise<boolean>;
  /** Why it can't be edited here (shown as a tooltip). */
  lockedReason?: string;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value ?? '');
  const [saving, setSaving] = useState(false);
  const tooLong = draft.trim().length > PO_NUMBER_MAX;

  const save = async () => {
    if (tooLong) return;
    setSaving(true);
    const ok = await onSave(draft.trim() || null);
    setSaving(false);
    if (ok) setEditing(false);
  };
  const copy = async () => {
    if (!value) return;
    try {
      await navigator.clipboard.writeText(value);
      toast.success('PO number copied');
    } catch {
      toast.error('Could not copy');
    }
  };

  if (editing) {
    return (
      <div className="flex items-center gap-1">
        <input
          autoFocus
          aria-label="Customer PO number"
          className={`w-44 rounded-md border px-2 py-1 font-mono text-sm ${tooLong ? 'border-error-500' : 'border-secondary-300'}`}
          value={draft}
          maxLength={PO_NUMBER_MAX + 10}
          placeholder="e.g. PO-45001234"
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') save();
            if (e.key === 'Escape') setEditing(false);
          }}
        />
        <button type="button" className="rounded p-1 text-success-700 hover:bg-success-50 disabled:opacity-50" disabled={saving || tooLong} onClick={save} aria-label="Save PO number">
          <Check className="h-4 w-4" />
        </button>
        <button type="button" className="rounded p-1 text-secondary-500 hover:bg-secondary-100" onClick={() => setEditing(false)} aria-label="Cancel">
          <X className="h-4 w-4" />
        </button>
        {tooLong && <span className="text-xs text-error-600">{PO_NUMBER_MAX} characters at most</span>}
      </div>
    );
  }
  return (
    <span className="inline-flex items-center gap-1">
      {value ? <span className="font-mono text-sm text-secondary-900">{value}</span> : <span className="text-sm text-secondary-400">None given</span>}
      {value && (
        <button type="button" className="rounded p-1 text-secondary-500 hover:bg-secondary-100 print:hidden" onClick={copy} aria-label="Copy PO number">
          <Copy className="h-3.5 w-3.5" />
        </button>
      )}
      {editable ? (
        <button
          type="button"
          className="rounded p-1 text-secondary-500 hover:bg-secondary-100 print:hidden"
          onClick={() => {
            setDraft(value ?? '');
            setEditing(true);
          }}
          aria-label={value ? 'Edit PO number' : 'Add PO number'}
        >
          <Pencil className="h-3.5 w-3.5" />
        </button>
      ) : (
        lockedReason && <span className="sr-only">{lockedReason}</span>
      )}
    </span>
  );
}
