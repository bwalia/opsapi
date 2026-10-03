'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { AlertTriangle, CheckCircle2, ExternalLink, LineChart, Pencil, Plus, Trash2, X } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, ConfirmDialog, Input, Modal, Select, Switch } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { SHOP_MODULE, ShopError, ShopLoading } from '@/components/shop/shared';
import { cn, extractApiError, formatDateTime, formatRelativeTime } from '@/lib/utils';
import { formatMoney, humanize, minorToPounds, poundsToMinor } from '@/lib/shop';
import type {
  ShopMarketApplyStrategy,
  ShopMarketAvailability,
  ShopMarketObservation,
  ShopMarketProductDetail,
  ShopMarketSource,
  ShopMarketSourceInput,
  ShopMarketStatus,
} from '@/types/shop';

type BadgeVariant = 'default' | 'success' | 'warning' | 'error' | 'info' | 'secondary';

/** Timestamps arrive as "2026-10-03 07:37:42+00"; never let a bad value throw during render. */
export function safeDateTime(ts: string | null | undefined): string {
  if (!ts) return '—';
  try {
    return formatDateTime(ts);
  } catch {
    return ts;
  }
}

export function safeRelative(ts: string | null | undefined): string {
  if (!ts) return 'never';
  try {
    return formatRelativeTime(ts);
  } catch {
    return ts;
  }
}

export function sourceStatusVariant(s: ShopMarketStatus | null | undefined): BadgeVariant {
  switch (s) {
    case 'ok':
      return 'success';
    case 'anomaly':
      return 'warning';
    case 'no_price':
    case 'mismatch':
    case 'blocked':
      return 'secondary';
    case 'http_error':
    case 'rejected':
      return 'error';
    default:
      return 'default';
  }
}

export function availabilityVariant(a: ShopMarketAvailability | null | undefined): BadgeVariant {
  switch (a) {
    case 'in_stock':
      return 'success';
    case 'limited':
      return 'info';
    case 'out_of_stock':
      return 'error';
    case 'preorder':
    case 'backorder':
      return 'warning';
    default:
      return 'secondary';
  }
}

const METHOD_LABEL: Record<string, string> = { json_ld: 'JSON-LD', meta: 'Meta tag', microdata: 'Microdata', llm: 'LLM' };

// ============================================================
// Source form
// ============================================================

interface SourceFormState {
  name: string;
  url: string;
  fetch_mode: 'direct' | 'firecrawl';
  prices_include_vat: boolean;
  currency: string;
  is_active: boolean;
  mpn: string;
  gtin: string;
  title_must_include: string;
  variant_hint: string;
}

const emptyForm: SourceFormState = {
  name: '',
  url: '',
  fetch_mode: 'direct',
  prices_include_vat: true,
  currency: 'GBP',
  is_active: true,
  mpn: '',
  gtin: '',
  title_must_include: '',
  variant_hint: '',
};

function formFromSource(s: ShopMarketSource): SourceFormState {
  return {
    name: s.name,
    url: s.url,
    fetch_mode: s.fetch_mode,
    prices_include_vat: s.prices_include_vat,
    currency: s.currency || 'GBP',
    is_active: s.is_active,
    mpn: s.match?.mpn ?? '',
    gtin: s.match?.gtin ?? '',
    title_must_include: (s.match?.title_must_include ?? []).join(', '),
    variant_hint: s.match?.variant_hint ?? '',
  };
}

function SourceFormModal({
  productUuid,
  source,
  open,
  onClose,
  onSaved,
}: {
  productUuid: string;
  source: ShopMarketSource | null;
  open: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [f, setF] = useState<SourceFormState>(emptyForm);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (open) setF(source ? formFromSource(source) : emptyForm);
  }, [open, source]);

  const set = <K extends keyof SourceFormState>(k: K, v: SourceFormState[K]) => setF((p) => ({ ...p, [k]: v }));
  const urlValid = /^https?:\/\/\S+$/i.test(f.url.trim());
  const valid = f.name.trim() !== '' && urlValid && /^[A-Za-z]{3}$/.test(f.currency.trim());

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!valid) return;
    const tokens = f.title_must_include
      .split(',')
      .map((t) => t.trim())
      .filter(Boolean);
    const input: ShopMarketSourceInput = {
      product_uuid: productUuid,
      name: f.name.trim(),
      url: f.url.trim(),
      fetch_mode: f.fetch_mode,
      prices_include_vat: f.prices_include_vat,
      currency: f.currency.trim().toUpperCase(),
      is_active: f.is_active,
      match: {
        ...(f.mpn.trim() ? { mpn: f.mpn.trim() } : {}),
        ...(f.gtin.trim() ? { gtin: f.gtin.trim() } : {}),
        ...(tokens.length ? { title_must_include: tokens } : {}),
        ...(f.variant_hint.trim() ? { variant_hint: f.variant_hint.trim() } : {}),
      },
    };
    setSaving(true);
    try {
      if (source) await shopService.updateMarketSource(source.uuid, input);
      else await shopService.createMarketSource(input);
      toast.success(source ? 'Source updated' : 'Source added');
      onSaved();
      onClose();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to save source'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={open} onClose={onClose} title={source ? 'Edit market source' : 'Add market source'} size="lg">
      <form onSubmit={submit} className="space-y-4">
        <div className="grid gap-4 sm:grid-cols-2">
          <Input label="Retailer" value={f.name} onChange={(e) => set('name', e.target.value)} placeholder="e.g. Apple UK" required />
          <Input
            label="Currency"
            value={f.currency}
            onChange={(e) => set('currency', e.target.value.toUpperCase().slice(0, 3))}
            placeholder="GBP"
          />
        </div>
        <Input
          label="Product page URL"
          value={f.url}
          onChange={(e) => set('url', e.target.value)}
          placeholder="https://…"
          error={f.url && !urlValid ? 'Must be an http(s) URL' : undefined}
          required
        />
        <div className="grid gap-4 sm:grid-cols-2">
          <Select label="Fetch mode" value={f.fetch_mode} onChange={(e) => set('fetch_mode', e.target.value as 'direct' | 'firecrawl')}>
            <option value="direct">Direct</option>
            <option value="firecrawl">Firecrawl</option>
          </Select>
          <div className="flex flex-col justify-end gap-3 pb-1">
            <label className="flex items-center justify-between gap-3 text-sm text-secondary-700">
              Prices include VAT
              <Switch checked={f.prices_include_vat} onChange={(v) => set('prices_include_vat', v)} aria-label="Prices include VAT" />
            </label>
            <label className="flex items-center justify-between gap-3 text-sm text-secondary-700">
              Active
              <Switch checked={f.is_active} onChange={(v) => set('is_active', v)} aria-label="Source active" />
            </label>
          </div>
        </div>
        <fieldset className="space-y-3 rounded-lg border border-secondary-200 p-4">
          <legend className="px-1 text-sm font-medium text-secondary-700">Identity check</legend>
          <div className="grid gap-4 sm:grid-cols-2">
            <Input label="MPN" value={f.mpn} onChange={(e) => set('mpn', e.target.value)} placeholder="Manufacturer part number" />
            <Input label="GTIN / EAN" value={f.gtin} onChange={(e) => set('gtin', e.target.value)} />
          </div>
          <Input
            label="Title must include"
            value={f.title_must_include}
            onChange={(e) => set('title_must_include', e.target.value)}
            placeholder="Comma-separated tokens, e.g. Mac Studio, M5 Ultra"
          />
          <Input
            label="Variant hint"
            value={f.variant_hint}
            onChange={(e) => set('variant_hint', e.target.value)}
            placeholder="e.g. M5 Ultra, 256GB, 2TB"
          />
        </fieldset>
        <div className="flex justify-end gap-2 border-t border-secondary-200 pt-4">
          <Button type="button" variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving} disabled={!valid}>
            {source ? 'Save' : 'Add source'}
          </Button>
        </div>
      </form>
    </Modal>
  );
}

// ============================================================
// Apply price
// ============================================================

function ApplyPriceModal({
  detail,
  open,
  onClose,
  onApplied,
}: {
  detail: ShopMarketProductDetail;
  open: boolean;
  onClose: () => void;
  onApplied: () => void;
}) {
  const [strategy, setStrategy] = useState<ShopMarketApplyStrategy>('median');
  const [custom, setCustom] = useState('');
  const [saving, setSaving] = useState(false);
  const { summary, product } = detail;

  useEffect(() => {
    if (open) {
      setStrategy(summary.median_ex_vat_minor !== null ? 'median' : 'value');
      setCustom(minorToPounds(product.base_price_minor));
    }
  }, [open, summary.median_ex_vat_minor, product.base_price_minor]);

  const customMinor = poundsToMinor(custom);
  const target =
    strategy === 'median' ? summary.median_ex_vat_minor : strategy === 'min' ? summary.min_ex_vat_minor : customMinor;
  const valid = target !== null && target > 0;

  const submit = async () => {
    if (!valid) return;
    setSaving(true);
    try {
      const res = await shopService.applyMarketPrice(product.uuid, strategy, strategy === 'value' ? customMinor ?? undefined : undefined);
      toast.success(`Price set to ${formatMoney(res.base_price_minor)} ex VAT`);
      onApplied();
      onClose();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to apply price'));
    } finally {
      setSaving(false);
    }
  };

  const option = (value: ShopMarketApplyStrategy, label: string, amount: number | null) => (
    <label
      className={cn(
        'flex cursor-pointer items-center justify-between gap-3 rounded-lg border px-4 py-3 text-sm',
        strategy === value ? 'border-primary-500 bg-primary-50' : 'border-secondary-200',
        value !== 'value' && amount === null && 'cursor-not-allowed opacity-50'
      )}
    >
      <span className="flex items-center gap-2">
        <input
          type="radio"
          name="strategy"
          value={value}
          checked={strategy === value}
          disabled={value !== 'value' && amount === null}
          onChange={() => setStrategy(value)}
        />
        {label}
      </span>
      {value !== 'value' && <span className="tabular-nums font-medium">{formatMoney(amount)}</span>}
    </label>
  );

  return (
    <Modal
      isOpen={open}
      onClose={onClose}
      title="Apply market price"
      description={`${product.name} — currently ${formatMoney(product.base_price_minor)} ex VAT`}
      size="md"
    >
      <div className="space-y-3">
        {option('median', 'Market median (ex VAT)', summary.median_ex_vat_minor)}
        {option('min', 'Market minimum (ex VAT)', summary.min_ex_vat_minor)}
        {option('value', 'Custom amount (ex VAT)', null)}
        {strategy === 'value' && (
          <Input label="Price ex VAT (£)" value={custom} onChange={(e) => setCustom(e.target.value)} inputMode="decimal" />
        )}
        <p className="text-xs text-secondary-500">
          Sets the catalogue base price (ex VAT) and marks it verified. Market data is reference only — nothing changes
          automatically.
          {valid && ` New inc-VAT price: ${formatMoney(Math.round((target as number) * (1 + product.vat_rate)))}.`}
        </p>
        <div className="flex justify-end gap-2 border-t border-secondary-200 pt-4">
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={submit} isLoading={saving} disabled={!valid}>
            Apply {valid ? formatMoney(target) : ''}
          </Button>
        </div>
      </div>
    </Modal>
  );
}

// ============================================================
// Observation row
// ============================================================

function ObservationItem({
  o,
  canAccept,
  onAccept,
  accepting,
}: {
  o: ShopMarketObservation;
  canAccept: boolean;
  onAccept: (o: ShopMarketObservation) => void;
  accepting: boolean;
}) {
  const anomaly = !o.accepted && o.flags?.anomaly;
  return (
    <li className={cn('space-y-1 py-3', anomaly && 'rounded-lg bg-warning-50 px-3')}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-sm font-medium text-secondary-900">{o.source_name ?? 'Source'}</span>
          <Badge size="sm" variant={availabilityVariant(o.availability)}>
            {humanize(o.availability)}
            {o.stock_qty !== null ? ` (${o.stock_qty})` : ''}
          </Badge>
          <Badge size="sm" variant="secondary">{METHOD_LABEL[o.method] ?? o.method}</Badge>
          {o.confidence !== null && (
            <span className="text-xs text-secondary-500" title="Extraction confidence">
              {Math.round(o.confidence * 100)}%
            </span>
          )}
          {anomaly && (
            <Badge size="sm" variant="warning">
              Anomaly{o.flags.change_pct !== undefined ? ` ${o.flags.change_pct > 0 ? '+' : ''}${o.flags.change_pct}%` : ''}
            </Badge>
          )}
          {o.flags?.anomaly_accepted && <Badge size="sm" variant="info">Anomaly accepted</Badge>}
          {!o.accepted && !anomaly && <Badge size="sm" variant="error">Not accepted</Badge>}
        </div>
        <div className="text-right">
          <span className="font-semibold tabular-nums text-secondary-900">
            {formatMoney(o.price_ex_vat_minor, o.currency)}
          </span>
          <span className="ml-1 text-xs text-secondary-500">ex VAT</span>
          {o.price_inc_vat_minor !== null && (
            <span className="block text-xs tabular-nums text-secondary-500">
              {formatMoney(o.price_inc_vat_minor, o.currency)} inc VAT
            </span>
          )}
        </div>
      </div>
      {o.title && <p className="text-xs text-secondary-600">{o.title}</p>}
      {o.evidence && (
        <blockquote className="border-l-2 border-secondary-300 pl-2 text-xs italic text-secondary-600" title="Evidence quoted from the page">
          “{o.evidence}”
        </blockquote>
      )}
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-secondary-400">
          {safeDateTime(o.fetched_at)}
          {anomaly && o.flags.previous_price_minor !== undefined
            ? ` · previous accepted ${formatMoney(o.flags.previous_price_minor, o.currency)}`
            : ''}
        </p>
        {anomaly && canAccept && (
          <Button size="sm" variant="outline" isLoading={accepting} leftIcon={<CheckCircle2 className="h-4 w-4" />} onClick={() => onAccept(o)}>
            Accept
          </Button>
        )}
      </div>
    </li>
  );
}

// ============================================================
// Drawer
// ============================================================

/** Right-hand drawer: market sources (CRUD), observation history, accept anomalies, apply price. */
export function MarketDrawer({
  productUuid,
  onClose,
  onChanged,
}: {
  productUuid: string | null;
  onClose: () => void;
  onChanged: () => void;
}) {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [detail, setDetail] = useState<ShopMarketProductDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const [editing, setEditing] = useState<{ source: ShopMarketSource | null } | null>(null);
  const [deleting, setDeleting] = useState<ShopMarketSource | null>(null);
  const [deleteBusy, setDeleteBusy] = useState(false);
  const [accepting, setAccepting] = useState<string | null>(null);
  const [applyOpen, setApplyOpen] = useState(false);
  const [sourceFilter, setSourceFilter] = useState('');

  const reload = useCallback(() => setVersion((v) => v + 1), []);
  const changed = useCallback(() => {
    reload();
    onChanged();
  }, [reload, onChanged]);

  useEffect(() => {
    if (!productUuid) return;
    let active = true;
    setError(null);
    shopService
      .getMarketProduct(productUuid)
      .then((d) => active && setDetail(d))
      .catch((err) => active && setError(extractApiError(err, 'Failed to load market data')));
    return () => {
      active = false;
    };
  }, [productUuid, version]);

  useEffect(() => {
    setDetail(null);
    setSourceFilter('');
  }, [productUuid]);

  useEffect(() => {
    if (!productUuid) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && !editing && !applyOpen && !deleting && onClose();
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [productUuid, onClose, editing, applyOpen, deleting]);

  if (!productUuid) return null;

  const accept = async (o: ShopMarketObservation) => {
    setAccepting(o.uuid);
    try {
      await shopService.acceptMarketObservation(o.uuid);
      toast.success('Observation accepted');
      changed();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to accept observation'));
    } finally {
      setAccepting(null);
    }
  };

  const confirmDelete = async () => {
    if (!deleting) return;
    setDeleteBusy(true);
    try {
      await shopService.deleteMarketSource(deleting.uuid);
      toast.success('Source deleted');
      setDeleting(null);
      changed();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to delete source'));
    } finally {
      setDeleteBusy(false);
    }
  };

  const s = detail?.summary;
  const ours = detail?.product.base_price_minor ?? 0;
  const diff = s?.median_ex_vat_minor ? ((ours - s.median_ex_vat_minor) / s.median_ex_vat_minor) * 100 : null;
  const history = (detail?.observations ?? []).filter((o) => !sourceFilter || o.source_uuid === sourceFilter);

  return (
    <div className="fixed inset-0 z-50 flex justify-end" role="dialog" aria-modal="true" aria-label="Market prices">
      <div className="fixed inset-0 bg-secondary-900/40 backdrop-blur-sm" onClick={onClose} />
      <aside className="relative flex h-full w-full max-w-2xl flex-col border-l border-secondary-200 bg-surface shadow-xl">
        <header className="flex items-start justify-between gap-3 border-b border-secondary-200 px-5 py-4">
          <div className="min-w-0">
            <h2 className="flex items-center gap-2 text-lg font-semibold text-secondary-900">
              <LineChart className="h-5 w-5 text-primary-500" aria-hidden="true" />
              Market prices
            </h2>
            <p className="truncate text-sm text-secondary-500">
              {detail ? `${detail.product.name} · ${detail.product.sku}` : 'Loading…'}
            </p>
          </div>
          <button onClick={onClose} className="rounded-lg p-2 text-secondary-400 hover:bg-secondary-100 hover:text-secondary-600" aria-label="Close">
            <X className="h-5 w-5" />
          </button>
        </header>

        <div className="flex-1 space-y-6 overflow-y-auto px-5 py-4">
          {error ? (
            <ShopError message={error} onRetry={reload} />
          ) : !detail ? (
            <ShopLoading label="Loading market data…" />
          ) : (
            <>
              {/* Summary */}
              <section aria-label="Summary" className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                <Stat label="Our price (ex VAT)" value={formatMoney(ours)} sub={detail.product.price_verified ? 'Verified' : 'Unverified'} />
                <Stat
                  label="Market median"
                  value={formatMoney(s?.median_ex_vat_minor)}
                  sub={diff !== null ? `Ours ${diff > 0 ? '+' : ''}${diff.toFixed(1)}%` : 'No fresh data'}
                  tone={diff === null ? undefined : Math.abs(diff) > 10 ? 'warn' : 'ok'}
                />
                <Stat label="Range" value={`${formatMoney(s?.min_ex_vat_minor)} – ${formatMoney(s?.max_ex_vat_minor)}`} />
                <Stat
                  label="In stock"
                  value={`${s?.sources_in_stock ?? 0} / ${s?.sources_total ?? 0}`}
                  sub={s?.freshest_at ? `Fresh ${safeRelative(s.freshest_at)}` : `Nothing in last ${s?.fresh_days ?? 7} days`}
                />
              </section>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <p className="text-xs text-secondary-500">
                  Summary uses accepted GBP observations from the last {s?.fresh_days ?? 7} days, latest per active source.
                  Our stock: {detail.product.available} available.
                </p>
                {canUpdate(SHOP_MODULE) && (
                  <Button size="sm" onClick={() => setApplyOpen(true)}>
                    Apply price…
                  </Button>
                )}
              </div>

              {/* Sources */}
              <section aria-label="Sources">
                <div className="mb-3 flex items-center justify-between">
                  <h3 className="text-base font-semibold text-secondary-900">Sources ({detail.sources.length})</h3>
                  {canCreate(SHOP_MODULE) && (
                    <Button size="sm" variant="outline" leftIcon={<Plus className="h-4 w-4" />} onClick={() => setEditing({ source: null })}>
                      Add source
                    </Button>
                  )}
                </div>
                {detail.sources.length === 0 ? (
                  <p className="rounded-lg border border-dashed border-secondary-300 py-6 text-center text-sm text-secondary-500">
                    No sources pinned for this product yet.
                  </p>
                ) : (
                  <ul className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
                    {detail.sources.map((src) => {
                      const lo = src.latest_observation;
                      return (
                        <li key={src.uuid} className={cn('space-y-1 px-4 py-3', !src.is_active && 'opacity-60')}>
                          <div className="flex flex-wrap items-start justify-between gap-2">
                            <div className="min-w-0">
                              <div className="flex flex-wrap items-center gap-2">
                                <span className="font-medium text-secondary-900">{src.name}</span>
                                <Badge size="sm" variant={sourceStatusVariant(src.last_status)}>
                                  {src.last_status ? humanize(src.last_status) : 'Not checked'}
                                </Badge>
                                {!src.is_active && <Badge size="sm" variant="secondary">Inactive</Badge>}
                                {src.fetch_mode === 'firecrawl' && <Badge size="sm" variant="info">Firecrawl</Badge>}
                                <span className="text-xs text-secondary-500">
                                  {src.currency} · {src.prices_include_vat ? 'inc VAT' : 'ex VAT'}
                                </span>
                                {(src.pending_anomalies ?? 0) > 0 && (
                                  <Badge size="sm" variant="warning">{src.pending_anomalies} pending</Badge>
                                )}
                              </div>
                              <a
                                href={src.url}
                                target="_blank"
                                rel="noopener noreferrer"
                                className="inline-flex max-w-full items-center gap-1 truncate text-xs text-primary-600 hover:underline"
                              >
                                <span className="truncate">{src.url}</span>
                                <ExternalLink className="h-3 w-3 shrink-0" aria-hidden="true" />
                              </a>
                              <p className="text-xs text-secondary-400">
                                Checked {safeRelative(src.last_checked_at)}
                                {src.last_error ? ` · ${src.last_error}` : ''}
                              </p>
                              {(src.match?.mpn || src.match?.gtin || src.match?.title_must_include?.length || src.match?.variant_hint) && (
                                <p className="text-xs text-secondary-500">
                                  Match:{' '}
                                  {[
                                    src.match.mpn && `MPN ${src.match.mpn}`,
                                    src.match.gtin && `GTIN ${src.match.gtin}`,
                                    src.match.title_must_include?.length && `title ⊇ ${src.match.title_must_include.join(', ')}`,
                                    src.match.variant_hint && `variant “${src.match.variant_hint}”`,
                                  ]
                                    .filter(Boolean)
                                    .join(' · ')}
                                </p>
                              )}
                            </div>
                            <div className="flex items-start gap-2">
                              <div className="text-right">
                                {lo ? (
                                  <>
                                    <span className={cn('block font-semibold tabular-nums', lo.accepted ? 'text-secondary-900' : 'text-warning-600')}>
                                      {formatMoney(lo.price_ex_vat_minor, lo.currency)}
                                    </span>
                                    <span className="block text-xs text-secondary-500">
                                      {lo.fresh ? safeRelative(lo.fetched_at) : 'stale'}
                                    </span>
                                  </>
                                ) : (
                                  <span className="text-xs text-secondary-400">No data</span>
                                )}
                              </div>
                              {canUpdate(SHOP_MODULE) && (
                                <button
                                  type="button"
                                  onClick={() => setEditing({ source: src })}
                                  className="rounded-lg p-1.5 text-secondary-500 hover:bg-secondary-100 hover:text-secondary-800"
                                  aria-label={`Edit source ${src.name}`}
                                  title="Edit"
                                >
                                  <Pencil className="h-4 w-4" />
                                </button>
                              )}
                              {canDelete(SHOP_MODULE) && (
                                <button
                                  type="button"
                                  onClick={() => setDeleting(src)}
                                  className="rounded-lg p-1.5 text-secondary-500 hover:bg-error-50 hover:text-error-600"
                                  aria-label={`Delete source ${src.name}`}
                                  title="Delete"
                                >
                                  <Trash2 className="h-4 w-4" />
                                </button>
                              )}
                            </div>
                          </div>
                        </li>
                      );
                    })}
                  </ul>
                )}
              </section>

              {/* History */}
              <section aria-label="Observation history">
                <div className="mb-2 flex items-center justify-between gap-3">
                  <h3 className="text-base font-semibold text-secondary-900">Observation history</h3>
                  {detail.sources.length > 1 && (
                    <select
                      value={sourceFilter}
                      onChange={(e) => setSourceFilter(e.target.value)}
                      aria-label="Filter history by source"
                      className="rounded-lg border border-secondary-300 bg-surface px-3 py-1.5 text-sm text-secondary-900"
                    >
                      <option value="">All sources</option>
                      {detail.sources.map((src) => (
                        <option key={src.uuid} value={src.uuid}>
                          {src.name}
                        </option>
                      ))}
                    </select>
                  )}
                </div>
                {history.some((o) => !o.accepted && o.flags?.anomaly) && (
                  <p className="mb-2 flex items-center gap-2 text-xs text-warning-700">
                    <AlertTriangle className="h-4 w-4" aria-hidden="true" />
                    Anomalies (&gt; 40 % change vs the last accepted price) are excluded until accepted.
                  </p>
                )}
                {history.length === 0 ? (
                  <p className="py-6 text-center text-sm text-secondary-500">No observations yet.</p>
                ) : (
                  <ul className="divide-y divide-secondary-100">
                    {history.map((o) => (
                      <ObservationItem
                        key={o.uuid}
                        o={o}
                        canAccept={canUpdate(SHOP_MODULE)}
                        onAccept={accept}
                        accepting={accepting === o.uuid}
                      />
                    ))}
                  </ul>
                )}
              </section>
            </>
          )}
        </div>
      </aside>

      {detail && (
        <>
          <SourceFormModal
            productUuid={detail.product.uuid}
            source={editing?.source ?? null}
            open={!!editing}
            onClose={() => setEditing(null)}
            onSaved={changed}
          />
          <ApplyPriceModal detail={detail} open={applyOpen} onClose={() => setApplyOpen(false)} onApplied={changed} />
        </>
      )}
      <ConfirmDialog
        isOpen={!!deleting}
        onClose={() => setDeleting(null)}
        onConfirm={confirmDelete}
        title="Delete market source?"
        message={`${deleting?.name ?? ''} and all of its observations will be removed.`}
        confirmText="Delete"
        isLoading={deleteBusy}
      />
    </div>
  );
}

function Stat({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: 'ok' | 'warn' }) {
  return (
    <div className="rounded-lg border border-secondary-200 px-3 py-2">
      <p className="text-xs text-secondary-500">{label}</p>
      <p className="break-words font-semibold tabular-nums text-secondary-900">{value}</p>
      {sub && (
        <p className={cn('text-xs', tone === 'warn' ? 'text-warning-600' : tone === 'ok' ? 'text-success-600' : 'text-secondary-500')}>{sub}</p>
      )}
    </div>
  );
}

export default MarketDrawer;
