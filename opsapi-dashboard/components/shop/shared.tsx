'use client';

import React, { useEffect, useState } from 'react';
import { Loader2, AlertTriangle, X, History, Minus, Plus } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Input, Modal, Select, Textarea } from '@/components/ui';
import { shopService } from '@/services/shop.service';
import { cn, extractApiError, formatDateTime } from '@/lib/utils';
import {
  formatMoney,
  humanize,
  orderStatusVariant,
  productStatusVariant,
  quoteStatusVariant,
  shopAssetUrl,
} from '@/lib/shop';
import type {
  ShopAddress,
  ShopCustomer,
  ShopLine,
  ShopStockMovement,
  ShopStockReason,
  ShopTotals,
} from '@/types/shop';

export const SHOP_MODULE = 'shop';

/** Product/category thumbnail: resolves storefront-relative paths and falls back to a placeholder. */
export function ShopThumb({ src, className, fallback }: { src?: string | null; className?: string; fallback: React.ReactNode }) {
  const url = shopAssetUrl(src);
  const [failedUrl, setFailedUrl] = useState<string | null>(null);
  if (!url || failedUrl === url) return <>{fallback}</>;
  // eslint-disable-next-line @next/next/no-img-element
  return <img src={url} alt="" className={className} onError={() => setFailedUrl(url)} />;
}

// ============================================================
// Badges
// ============================================================

export function OrderStatusBadge({ status }: { status: string }) {
  return (
    <Badge size="sm" variant={orderStatusVariant(status)}>
      {humanize(status)}
    </Badge>
  );
}

export function QuoteStatusBadge({ status }: { status: string }) {
  return (
    <Badge size="sm" variant={quoteStatusVariant(status)}>
      {humanize(status)}
    </Badge>
  );
}

export function ProductStatusBadge({ status }: { status: string }) {
  return (
    <Badge size="sm" variant={productStatusVariant(status)}>
      {humanize(status)}
    </Badge>
  );
}

export function PriceVerifiedBadge({ verified }: { verified: boolean }) {
  return verified ? (
    <Badge size="sm" variant="success">Verified</Badge>
  ) : (
    <Badge size="sm" variant="warning" title="Indicative price — confirm before quoting">
      Unverified
    </Badge>
  );
}

// ============================================================
// Loading / error
// ============================================================

export function ShopLoading({ label = 'Loading…' }: { label?: string }) {
  return (
    <div className="flex items-center justify-center gap-2 py-16 text-secondary-500" role="status">
      <Loader2 className="h-5 w-5 animate-spin text-primary-500" aria-hidden="true" />
      <span className="text-sm">{label}</span>
    </div>
  );
}

export function ShopError({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 rounded-xl border border-error-200 bg-error-50 px-6 py-12 text-center">
      <AlertTriangle className="h-8 w-8 text-error-500" aria-hidden="true" />
      <p className="text-sm text-error-700">{message}</p>
      {onRetry && (
        <Button variant="ghost" size="sm" onClick={onRetry}>
          Retry
        </Button>
      )}
    </div>
  );
}

// ============================================================
// Money
// ============================================================

/** Ex-VAT amount with an optional inc-VAT secondary line. */
export function Money({
  minor,
  currency = 'GBP',
  vatRate,
  className,
}: {
  minor: number | null | undefined;
  currency?: string;
  /** When given, also shows the inc-VAT figure. */
  vatRate?: number;
  className?: string;
}) {
  return (
    <span className={cn('inline-flex flex-col leading-tight', className)}>
      <span className="font-medium tabular-nums text-secondary-900">{formatMoney(minor, currency)}</span>
      {vatRate !== undefined && minor !== null && minor !== undefined && (
        <span className="text-xs tabular-nums text-secondary-500">
          {formatMoney(Math.round(minor * (1 + vatRate)), currency)} inc VAT
        </span>
      )}
    </span>
  );
}

// ============================================================
// Lines + totals
// ============================================================

export function LinesTable({ lines, currency = 'GBP' }: { lines: ShopLine[]; currency?: string }) {
  if (!lines?.length) {
    return <p className="py-6 text-center text-sm text-secondary-500">No lines.</p>;
  }
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-secondary-200 text-left text-xs font-semibold uppercase tracking-wider text-secondary-600">
            <th className="py-2 pr-4">Item</th>
            <th className="py-2 pr-4 text-right">Qty</th>
            <th className="py-2 pr-4 text-right">Unit (ex VAT)</th>
            <th className="py-2 pr-4 text-right">Subtotal</th>
            <th className="py-2 pr-4 text-right">VAT</th>
            <th className="py-2 text-right">Total</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-secondary-100">
          {lines.map((l, i) => (
            <tr key={l.uuid || i} className="align-top">
              <td className="py-3 pr-4">
                <p className="font-medium text-secondary-900">{l.product_name || l.label}</p>
                {l.sku && <p className="text-xs text-secondary-500">SKU {l.sku}</p>}
                {l.label && l.label !== l.product_name && (
                  <p className="text-xs text-secondary-500">{l.label}</p>
                )}
                {l.breakdown?.length > 0 && (
                  <ul className="mt-1 space-y-0.5 text-xs text-secondary-600">
                    {l.breakdown.map((b, j) => (
                      <li key={`${b.group}-${b.option}-${j}`}>
                        <span className="text-secondary-400">{humanize(b.group)}:</span> {b.name}
                        {b.qty > 1 ? ` ×${b.qty}` : ''}
                        {b.price_delta_minor ? (
                          <span className="text-secondary-400"> ({b.price_delta_minor > 0 ? '+' : ''}{formatMoney(b.price_delta_minor, currency)})</span>
                        ) : null}
                      </li>
                    ))}
                  </ul>
                )}
                {l.violations?.length > 0 && (
                  <ul className="mt-1 space-y-0.5 text-xs text-error-600">
                    {l.violations.map((v, j) => (
                      <li key={j}>⚠ {v.message}</li>
                    ))}
                  </ul>
                )}
                {l.price_override_minor !== undefined && l.price_override_minor !== null && (
                  <Badge size="sm" variant="info" className="mt-1">Price override</Badge>
                )}
              </td>
              <td className="py-3 pr-4 text-right tabular-nums">{l.qty}</td>
              <td className="py-3 pr-4 text-right tabular-nums">{formatMoney(l.unit_price_minor, currency)}</td>
              <td className="py-3 pr-4 text-right tabular-nums">{formatMoney(l.line_subtotal_minor, currency)}</td>
              <td className="py-3 pr-4 text-right tabular-nums text-secondary-600">{formatMoney(l.line_vat_minor, currency)}</td>
              <td className="py-3 text-right font-medium tabular-nums">{formatMoney(l.line_total_minor, currency)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function TotalsBlock({ totals }: { totals: Partial<ShopTotals> }) {
  const cur = totals.currency || 'GBP';
  const row = (label: string, v: number | undefined, strong = false) => (
    <div className={cn('flex justify-between gap-8', strong && 'border-t border-secondary-200 pt-2 text-base font-semibold')}>
      <dt className={strong ? 'text-secondary-900' : 'text-secondary-600'}>{label}</dt>
      <dd className="tabular-nums text-secondary-900">{formatMoney(v ?? 0, cur)}</dd>
    </div>
  );
  return (
    <dl className="ml-auto w-full max-w-xs space-y-1.5 text-sm">
      {row('Subtotal (ex VAT)', totals.subtotal_minor)}
      {row('VAT', totals.vat_minor)}
      {row('Shipping', totals.shipping_minor)}
      {row('Total', totals.total_minor, true)}
    </dl>
  );
}

// ============================================================
// Customer / address
// ============================================================

export function formatAddress(a: ShopAddress | string | null | undefined): string {
  if (!a) return '';
  if (typeof a === 'string') return a;
  // Orders store Stripe's shape: { name, address: { line1, city, … } }.
  const inner = a.address && typeof a.address === 'object' ? (a.address as ShopAddress) : null;
  if (inner) {
    const rest = formatAddress(inner);
    return [typeof a.name === 'string' ? a.name : '', rest].filter(Boolean).join(', ');
  }
  return [a.line1, a.line2, a.city, a.state, a.postal_code, a.country].filter(Boolean).join(', ');
}

export function CustomerBlock({ customer, email }: { customer?: ShopCustomer | null; email?: string | null }) {
  const c = customer ?? {};
  const mail = c.email || email;
  const addr = formatAddress(c.address as ShopAddress | string | null | undefined);
  if (!c.name && !mail && !c.company) {
    return <p className="text-sm text-secondary-500">No customer details.</p>;
  }
  return (
    <dl className="space-y-1 text-sm">
      {c.name && <dd className="font-medium text-secondary-900">{c.name}</dd>}
      {c.company && <dd className="text-secondary-700">{c.company}</dd>}
      {mail && (
        <dd>
          <a href={`mailto:${mail}`} className="text-primary-600 hover:underline">{mail}</a>
        </dd>
      )}
      {c.phone && <dd className="text-secondary-700">{c.phone}</dd>}
      {c.vat_number && <dd className="text-secondary-600">VAT: {c.vat_number}</dd>}
      {addr && <dd className="text-secondary-600">{addr}</dd>}
    </dl>
  );
}

// ============================================================
// Stock adjust + movements
// ============================================================

const ADJUST_REASONS: ShopStockReason[] = ['adjustment', 'restock', 'import'];

export interface StockTarget {
  kind: 'product' | 'option';
  uuid: string;
  label: string;
  current: number;
}

export function StockAdjustModal({
  target,
  initialDelta = 1,
  onClose,
  onDone,
}: {
  target: StockTarget | null;
  initialDelta?: number;
  onClose: () => void;
  onDone: () => void;
}) {
  const [delta, setDelta] = useState(String(initialDelta));
  const [reason, setReason] = useState<ShopStockReason>(initialDelta > 0 ? 'restock' : 'adjustment');
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (target) {
      setDelta(String(initialDelta));
      setReason(initialDelta > 0 ? 'restock' : 'adjustment');
      setNote('');
    }
  }, [target, initialDelta]);

  const d = parseInt(delta, 10);
  const valid = Number.isInteger(d) && d !== 0;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!target || !valid) return;
    setSaving(true);
    try {
      const body = { delta: d, reason, note: note.trim() || undefined };
      if (target.kind === 'product') await shopService.adjustProductStock(target.uuid, body);
      else await shopService.adjustOptionStock(target.uuid, body);
      toast.success(`Stock ${d > 0 ? 'increased' : 'decreased'} by ${Math.abs(d)}`);
      onDone();
      onClose();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to adjust stock'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={!!target} onClose={onClose} title="Adjust stock" description={target?.label} size="md">
      {target && (
        <form onSubmit={submit} className="space-y-4">
          <div className="flex items-end gap-2">
            <Button type="button" variant="ghost" aria-label="Decrease" onClick={() => setDelta(String((parseInt(delta, 10) || 0) - 1))}>
              <Minus className="h-4 w-4" />
            </Button>
            <Input label="Change (±)" value={delta} onChange={(e) => setDelta(e.target.value)} inputMode="numeric" className="text-center" />
            <Button type="button" variant="ghost" aria-label="Increase" onClick={() => setDelta(String((parseInt(delta, 10) || 0) + 1))}>
              <Plus className="h-4 w-4" />
            </Button>
          </div>
          <p className="text-sm text-secondary-600">
            Current: <span className="font-medium tabular-nums">{target.current}</span>
            {valid && (
              <>
                {' '}→ New: <span className="font-medium tabular-nums">{target.current + d}</span>
              </>
            )}
          </p>
          <Select label="Reason" value={reason} onChange={(e) => setReason(e.target.value as ShopStockReason)}>
            {ADJUST_REASONS.map((r) => (
              <option key={r} value={r}>{humanize(r)}</option>
            ))}
          </Select>
          <Textarea label="Note" value={note} onChange={(e) => setNote(e.target.value)} rows={2} placeholder="e.g. PO-1234 received, stock count correction" />
          <div className="flex justify-end gap-2 border-t border-secondary-200 pt-4">
            <Button type="button" variant="ghost" onClick={onClose}>Cancel</Button>
            <Button type="submit" isLoading={saving} disabled={!valid}>Apply</Button>
          </div>
        </form>
      )}
    </Modal>
  );
}

function MovementsList({ target }: { target: StockTarget }) {
  const [rows, setRows] = useState<ShopStockMovement[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    shopService
      .getStockMovements(target.kind === 'product' ? { product_uuid: target.uuid } : { option_uuid: target.uuid })
      .then((r) => active && setRows(r))
      .catch((err) => {
        if (!active) return;
        const status = (err as { response?: { status?: number } })?.response?.status;
        setError(status === 404 ? 'Movement history is not available from the API yet.' : extractApiError(err, 'Failed to load movements'));
      });
    return () => {
      active = false;
    };
  }, [target]);

  if (error) return <p className="text-sm text-secondary-500">{error}</p>;
  if (rows === null) return <ShopLoading />;
  if (rows.length === 0) return <p className="text-sm text-secondary-500">No movements recorded.</p>;
  return (
    <ul className="divide-y divide-secondary-100">
      {rows.map((m, i) => (
        <li key={m.uuid || i} className="flex items-start justify-between gap-3 py-3">
          <div className="min-w-0">
            <p className="text-sm font-medium text-secondary-900">{humanize(m.reason)}</p>
            {(m.note || m.ref) && <p className="text-xs text-secondary-600">{m.note || m.ref}</p>}
            <p className="text-xs text-secondary-400">
              {formatDateTime(m.created_at)}
              {m.user_name ? ` · ${m.user_name}` : ''}
            </p>
          </div>
          <span className={cn('shrink-0 font-semibold tabular-nums', m.delta > 0 ? 'text-success-600' : 'text-error-600')}>
            {m.delta > 0 ? `+${m.delta}` : m.delta}
          </span>
        </li>
      ))}
    </ul>
  );
}

/** Right-hand drawer with stock movement history for a product or option. */
export function MovementsDrawer({ target, onClose }: { target: StockTarget | null; onClose: () => void }) {
  useEffect(() => {
    if (!target) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [target, onClose]);

  if (!target) return null;
  return (
    <div className="fixed inset-0 z-50 flex justify-end" role="dialog" aria-modal="true" aria-label="Stock movements">
      <div className="fixed inset-0 bg-secondary-900/40 backdrop-blur-sm" onClick={onClose} />
      <aside className="relative flex h-full w-full max-w-md flex-col border-l border-secondary-200 bg-surface shadow-xl">
        <header className="flex items-start justify-between gap-3 border-b border-secondary-200 px-5 py-4">
          <div className="min-w-0">
            <h2 className="flex items-center gap-2 text-lg font-semibold text-secondary-900">
              <History className="h-5 w-5 text-primary-500" aria-hidden="true" />
              Stock movements
            </h2>
            <p className="truncate text-sm text-secondary-500">{target.label}</p>
          </div>
          <button onClick={onClose} className="rounded-lg p-2 text-secondary-400 hover:bg-secondary-100 hover:text-secondary-600" aria-label="Close">
            <X className="h-5 w-5" />
          </button>
        </header>
        <div className="flex-1 overflow-y-auto px-5 py-4">
          <MovementsList key={`${target.kind}:${target.uuid}`} target={target} />
        </div>
      </aside>
    </div>
  );
}

// ============================================================
// Small layout helpers
// ============================================================

export function SectionTitle({ children, actions }: { children: React.ReactNode; actions?: React.ReactNode }) {
  return (
    <div className="mb-4 flex items-center justify-between gap-3">
      <h2 className="text-base font-semibold text-secondary-900">{children}</h2>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </div>
  );
}

export function KeyValue({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-4 py-1.5 text-sm">
      <dt className="text-secondary-500">{label}</dt>
      <dd className="min-w-0 break-all text-right text-secondary-900">{children}</dd>
    </div>
  );
}

/** Native select styled like the dashboard filter selects. */
export function FilterSelect(props: React.SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select
      {...props}
      className={cn(
        'rounded-lg border border-secondary-300 bg-surface px-4 py-2.5 text-sm text-secondary-900 focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20',
        props.className
      )}
    />
  );
}

/** Hide dashboard chrome (sidebar, header, footer) when printing an order/quote. */
export function PrintStyles() {
  return (
    <style>{`
      @media print {
        aside, header, footer, .print\\:hidden { display: none !important; }
        #main-content { padding: 0 !important; }
        #main-content, #main-content * { box-shadow: none !important; }
        div:has(> #main-content) { margin-left: 0 !important; }
        body { background: #fff !important; }
      }
    `}</style>
  );
}
