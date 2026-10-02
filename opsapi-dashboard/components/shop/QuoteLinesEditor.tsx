'use client';

import React, { useEffect, useMemo, useState } from 'react';
import { Plus, SlidersHorizontal, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Input, Modal, SearchableSelect } from '@/components/ui';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import { formatMoney, humanize, minorToPounds, poundsToMinor } from '@/lib/shop';
import type { ShopLine, ShopLineInput, ShopProduct, ShopProductListItem, ShopSelections } from '@/types/shop';
import { IconButton, ReorderButtons, moveItem, newKey } from './editor-fields';
import { ShopLoading } from './shared';

export interface LineDraft {
  key: string;
  uuid?: string;
  product_uuid?: string;
  product_slug: string;
  product_name: string;
  qty: string;
  selections: ShopSelections;
  /** Pounds ex VAT; '' = use the computed price. */
  override: string;
  /** Last server-priced snapshot (display only). */
  snapshot?: ShopLine;
}

export function lineToDraft(l: ShopLine): LineDraft {
  return {
    key: newKey(),
    uuid: l.uuid,
    product_uuid: l.product_uuid,
    product_slug: l.product_slug,
    product_name: l.product_name || l.label,
    qty: String(l.qty ?? 1),
    selections: l.selections ?? {},
    override: l.price_override_minor === null || l.price_override_minor === undefined ? '' : minorToPounds(l.price_override_minor),
    snapshot: l,
  };
}

/** Validate drafts → API payload. */
export function draftsToPayload(drafts: LineDraft[]): { lines: ShopLineInput[]; errors: string[] } {
  const errors: string[] = [];
  const lines = drafts.map((d, i) => {
    const qty = parseInt(d.qty, 10);
    if (!d.product_slug) errors.push(`Line ${i + 1}: choose a product`);
    if (!Number.isInteger(qty) || qty < 1) errors.push(`Line ${i + 1}: quantity must be ≥ 1`);
    let override: number | null = null;
    if (d.override.trim() !== '') {
      override = poundsToMinor(d.override);
      if (override === null || override < 0) errors.push(`Line ${i + 1}: invalid price override`);
    }
    return {
      ...(d.uuid ? { uuid: d.uuid } : {}),
      product_slug: d.product_slug,
      qty: Number.isInteger(qty) ? qty : 1,
      selections: d.selections,
      price_override_minor: override,
    };
  });
  return { lines, errors };
}

function selectionSummary(sel: ShopSelections): string {
  const parts = Object.entries(sel ?? {}).flatMap(([g, opts]) =>
    (opts ?? []).map((o) => `${humanize(g)}: ${o.option}${o.qty > 1 ? ` ×${o.qty}` : ''}`)
  );
  return parts.join(' · ');
}

export function QuoteLinesEditor({
  drafts,
  onChange,
  currency = 'GBP',
}: {
  drafts: LineDraft[];
  onChange: (d: LineDraft[]) => void;
  currency?: string;
}) {
  const [products, setProducts] = useState<ShopProductListItem[]>([]);
  const [configuring, setConfiguring] = useState<number | null>(null);

  useEffect(() => {
    let active = true;
    shopService
      .getProducts({ status: 'active', limit: 500 })
      .then((r) => active && setProducts(r.data))
      .catch((err) => active && toast.error(extractApiError(err, 'Failed to load products')));
    return () => {
      active = false;
    };
  }, []);

  const options = useMemo(
    () =>
      products.map((p) => ({
        value: p.slug,
        label: p.name,
        hint: `${p.sku} · ${humanize(p.price_mode)} · from ${formatMoney(p.from_price_minor ?? p.base_price_minor, p.currency)}`,
      })),
    [products]
  );

  const update = (i: number, patch: Partial<LineDraft>) => onChange(drafts.map((d, j) => (j === i ? { ...d, ...patch } : d)));

  const pickProduct = (i: number, slug: string) => {
    const p = products.find((x) => x.slug === slug);
    update(i, {
      product_slug: slug,
      product_uuid: p?.uuid,
      product_name: p?.name ?? slug,
      selections: p?.default_selections ?? {},
      snapshot: undefined,
    });
  };

  const configDraft = configuring !== null ? drafts[configuring] : null;
  const configProductUuid = configDraft?.product_uuid ?? products.find((p) => p.slug === configDraft?.product_slug)?.uuid;

  return (
    <div className="space-y-3">
      {drafts.length === 0 && <p className="rounded-lg border border-dashed border-secondary-300 p-6 text-center text-sm text-secondary-500">No lines yet.</p>}
      {drafts.map((d, i) => {
        const product = products.find((p) => p.slug === d.product_slug);
        const configurable = product ? product.price_mode === 'configurable' : Object.keys(d.selections ?? {}).length > 0;
        const overrideMinor = d.override.trim() ? poundsToMinor(d.override) : null;
        return (
          <div key={d.key} className="rounded-lg border border-secondary-200 p-3">
            <div className="grid grid-cols-1 gap-3 md:grid-cols-12 md:items-end">
              <div className="md:col-span-5">
                <SearchableSelect
                  label="Product"
                  options={options.length ? options : d.product_slug ? [{ value: d.product_slug, label: d.product_name }] : []}
                  value={d.product_slug}
                  onChange={(v) => pickProduct(i, v)}
                  placeholder="Choose a product…"
                  searchPlaceholder="Search catalogue…"
                />
              </div>
              <div className="md:col-span-2">
                <Input label="Qty" id={`ql-${d.key}-qty`} value={d.qty} onChange={(e) => update(i, { qty: e.target.value.replace(/[^\d]/g, '') })} inputMode="numeric" />
              </div>
              <div className="md:col-span-3">
                <Input
                  label="Unit price override (£ ex VAT)"
                  id={`ql-${d.key}-ovr`}
                  value={d.override}
                  onChange={(e) => update(i, { override: e.target.value })}
                  onBlur={() => overrideMinor !== null && update(i, { override: minorToPounds(overrideMinor) })}
                  inputMode="decimal"
                  placeholder={d.snapshot ? minorToPounds(d.snapshot.unit_price_minor) : 'computed'}
                  error={d.override.trim() && overrideMinor === null ? 'Invalid' : undefined}
                />
              </div>
              <div className="flex items-center justify-end gap-0.5 md:col-span-2 md:pb-1.5">
                {configurable && (
                  <IconButton label="Configure options" onClick={() => setConfiguring(i)}>
                    <SlidersHorizontal className="h-4 w-4" />
                  </IconButton>
                )}
                <ReorderButtons index={i} count={drafts.length} onMove={(dir) => onChange(moveItem(drafts, i, dir))} />
                <IconButton label="Remove line" danger onClick={() => onChange(drafts.filter((_, j) => j !== i))}>
                  <Trash2 className="h-4 w-4" />
                </IconButton>
              </div>
            </div>
            <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-secondary-500">
              {Object.keys(d.selections ?? {}).length > 0 && <span>{selectionSummary(d.selections)}</span>}
              {product?.price_mode === 'quote_only' && <Badge size="sm" variant="warning">Quote only</Badge>}
              {d.snapshot && (
                <span className="tabular-nums">
                  Last priced: {formatMoney(d.snapshot.unit_price_minor, currency)} × {d.snapshot.qty} = {formatMoney(d.snapshot.line_subtotal_minor, currency)} ex VAT
                </span>
              )}
              {d.snapshot?.violations?.map((v, j) => (
                <span key={j} className="text-error-600">⚠ {v.message}</span>
              ))}
            </div>
          </div>
        );
      })}
      <Button
        type="button"
        variant="outline"
        size="sm"
        leftIcon={<Plus className="h-4 w-4" />}
        onClick={() => onChange([...drafts, { key: newKey(), product_slug: '', product_name: '', qty: '1', selections: {}, override: '' }])}
      >
        Add line
      </Button>

      <ConfigureModal
        open={configuring !== null}
        productUuid={configProductUuid}
        selections={configDraft?.selections ?? {}}
        onClose={() => setConfiguring(null)}
        onApply={(sel) => {
          if (configuring !== null) update(configuring, { selections: sel, snapshot: undefined });
          setConfiguring(null);
        }}
      />
    </div>
  );
}

/** Pick options for a configurable product. Price + rule validation happen server-side on save. */
function ConfigureModal({
  open,
  productUuid,
  selections,
  onClose,
  onApply,
}: {
  open: boolean;
  productUuid?: string;
  selections: ShopSelections;
  onClose: () => void;
  onApply: (s: ShopSelections) => void;
}) {
  return (
    <Modal isOpen={open} onClose={onClose} title="Configure options" description="Price and compatibility are re-checked by the pricing engine when you save." size="2xl">
      {open && <ConfigureBody key={productUuid ?? 'none'} productUuid={productUuid} initial={selections} onClose={onClose} onApply={onApply} />}
    </Modal>
  );
}

function ConfigureBody({
  productUuid,
  initial,
  onClose,
  onApply,
}: {
  productUuid?: string;
  initial: ShopSelections;
  onClose: () => void;
  onApply: (s: ShopSelections) => void;
}) {
  const [product, setProduct] = useState<ShopProduct | null>(null);
  const [failed, setFailed] = useState(!productUuid);
  const [sel, setSel] = useState<ShopSelections>(initial);

  useEffect(() => {
    if (!productUuid) return;
    let active = true;
    shopService
      .getProduct(productUuid)
      .then((p) => {
        if (!active) return;
        setProduct(p);
        // The server fills omitted groups with their default options — show
        // those as selected so the admin edits the configuration actually priced.
        setSel((cur) => {
          const out: ShopSelections = { ...cur };
          for (const g of p.option_groups ?? []) {
            if (out[g.code]?.length) continue;
            const defs = g.options.filter((o) => o.is_active !== false && o.is_default);
            if (defs.length) out[g.code] = defs.map((o) => ({ option: o.code, qty: 1 }));
          }
          return out;
        });
      })
      .catch(() => active && setFailed(true));
    return () => {
      active = false;
    };
  }, [productUuid]);

  if (failed) return <p className="py-6 text-sm text-secondary-500">Could not load the product&apos;s options.</p>;
  if (!product) return <ShopLoading />;

  const groups = [...(product.option_groups ?? [])].sort((a, b) => a.sort_order - b.sort_order);
  const qtyOf = (g: string, o: string) => sel[g]?.find((x) => x.option === o)?.qty ?? 0;
  const setQty = (g: string, o: string, qty: number) => {
    const rest = (sel[g] ?? []).filter((x) => x.option !== o);
    const next = qty > 0 ? [...rest, { option: o, qty }] : rest;
    setSel((s) => {
      const out = { ...s, [g]: next };
      if (!next.length) delete out[g];
      return out;
    });
  };

  return (
    <div className="space-y-5">
      {groups.map((g) => {
        const opts = g.options.filter((o) => o.is_active !== false).sort((a, b) => a.sort_order - b.sort_order);
        return (
          <fieldset key={g.code}>
            <legend className="mb-2 text-sm font-semibold text-secondary-900">
              {g.name} {g.required && <span className="text-error-500">*</span>}
              <span className="ml-2 font-mono text-xs font-normal text-secondary-400">{g.code}</span>
            </legend>
            {g.selection === 'single' ? (
              <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
                {!g.required && (
                  <label className="flex items-center gap-2 rounded-lg border border-secondary-200 px-3 py-2 text-sm">
                    <input type="radio" name={`cfg-${g.code}`} checked={!sel[g.code]?.length} onChange={() => setSel((s) => { const o = { ...s }; delete o[g.code]; return o; })} />
                    None
                  </label>
                )}
                {opts.map((o) => (
                  <label key={o.code} className="flex items-center justify-between gap-2 rounded-lg border border-secondary-200 px-3 py-2 text-sm">
                    <span className="flex items-center gap-2">
                      <input type="radio" name={`cfg-${g.code}`} checked={qtyOf(g.code, o.code) > 0} onChange={() => setSel((s) => ({ ...s, [g.code]: [{ option: o.code, qty: 1 }] }))} />
                      {o.name}
                    </span>
                    <span className="text-xs tabular-nums text-secondary-500">{o.price_delta_minor ? `${o.price_delta_minor > 0 ? '+' : ''}${formatMoney(o.price_delta_minor)}` : ''}</span>
                  </label>
                ))}
              </div>
            ) : (
              <div className="space-y-1.5">
                {opts.map((o) => (
                  <div key={o.code} className="flex items-center justify-between gap-3 rounded-lg border border-secondary-200 px-3 py-2 text-sm">
                    <span>
                      {o.name}
                      <span className="ml-2 text-xs tabular-nums text-secondary-500">{o.price_delta_minor ? `${o.price_delta_minor > 0 ? '+' : ''}${formatMoney(o.price_delta_minor)} each` : ''}</span>
                    </span>
                    <input
                      type="number"
                      min={0}
                      max={o.max_qty || g.max_qty || 99}
                      aria-label={`${o.name} quantity`}
                      value={qtyOf(g.code, o.code)}
                      onChange={(e) => setQty(g.code, o.code, Math.max(0, parseInt(e.target.value, 10) || 0))}
                      className="w-20 rounded-lg border border-secondary-300 bg-surface px-2 py-1 text-right text-sm"
                    />
                  </div>
                ))}
              </div>
            )}
          </fieldset>
        );
      })}
      {product.rules?.length > 0 && (
        <ul className="list-disc space-y-0.5 pl-5 text-xs text-secondary-500">
          {product.rules.filter((r) => r.is_active !== false).map((r, i) => (
            <li key={i}>{r.message}</li>
          ))}
        </ul>
      )}
      <div className="flex justify-end gap-2 border-t border-secondary-200 pt-4">
        <Button type="button" variant="ghost" onClick={onClose}>Cancel</Button>
        <Button type="button" onClick={() => onApply(sel)}>Apply selections</Button>
      </div>
    </div>
  );
}
