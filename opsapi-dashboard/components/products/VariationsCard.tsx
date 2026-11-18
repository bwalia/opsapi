'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { Layers, Pencil, Plus, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, Input, Modal, Switch, confirmDialog } from '@/components/ui';
import { catalogVariantsService, type CatalogVariant } from '@/services/catalog-variants.service';
import { extractApiError, formatCurrency } from '@/lib/utils';

type Form = { option1: string; option2: string; title: string; sku: string; price: string; stock: string; is_active: boolean };
const EMPTY: Form = { option1: '', option2: '', title: '', sku: '', price: '', stock: '0', is_active: true };

/**
 * Variations of a product — sizes, colours or any other option — each with its own SKU, price (empty = the
 * product's) and stock. The till (Point of Sale) and staff orders ask which one is being sold.
 */
export function VariationsCard({ productUuid, productPrice, tracked, canEdit }: {
  productUuid: string;
  productPrice: number;
  tracked: boolean;
  canEdit: boolean;
}) {
  const [rows, setRows] = useState<CatalogVariant[] | null>(null);
  const [editing, setEditing] = useState<CatalogVariant | 'new' | null>(null);
  const [form, setForm] = useState<Form>(EMPTY);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setRows((await catalogVariantsService.list(productUuid)).variants);
    } catch (e) {
      setError(extractApiError(e, 'Could not load the variations'));
    }
  }, [productUuid]);

  useEffect(() => {
    load();
  }, [load]);

  const open = (v: CatalogVariant | 'new') => {
    setForm(v === 'new' ? EMPTY : {
      option1: v.option1 ?? '', option2: v.option2 ?? '', title: v.title, sku: v.sku ?? '', price: v.price ?? '',
      stock: String(v.stock), is_active: v.is_active,
    });
    setEditing(v);
  };

  const set = (k: keyof Form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm((f) => ({ ...f, [k]: e.target.value }));

  const save = async () => {
    if (!form.title.trim() && !form.option1.trim()) {
      toast.error('Give the variation a name or an option, e.g. Medium');
      return;
    }
    if (form.price.trim() && !/^\d+(\.\d{1,2})?$/.test(form.price.trim())) {
      toast.error('The price must be an amount like 12.50, or empty to use the product’s price');
      return;
    }
    if (!/^\d+$/.test(form.stock.trim() || '0')) {
      toast.error('Stock must be a whole number');
      return;
    }
    setSaving(true);
    try {
      const body = {
        title: form.title.trim() || undefined,
        option1: form.option1.trim(),
        option2: form.option2.trim(),
        sku: form.sku.trim(),
        price: form.price.trim() || null,
        stock: Number(form.stock.trim() || '0'),
        is_active: form.is_active,
      };
      if (editing === 'new') await catalogVariantsService.create(productUuid, body);
      else if (editing) await catalogVariantsService.update(editing.uuid, body);
      toast.success('Variation saved');
      setEditing(null);
      await load();
    } catch (e) {
      toast.error(extractApiError(e, 'The variation could not be saved'));
    } finally {
      setSaving(false);
    }
  };

  const remove = async (v: CatalogVariant) => {
    const ok = await confirmDialog({
      title: `Delete ${v.title}?`,
      message: 'It can no longer be sold. Past orders keep its name. To stop selling it for now, switch it off instead.',
      confirmText: 'Delete',
      danger: true,
    });
    if (!ok) return;
    try {
      await catalogVariantsService.remove(v.uuid);
      toast.success('Variation deleted');
      await load();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not delete it'));
    }
  };

  return (
    <Card padding="lg">
      <div className="mb-3 flex items-center justify-between gap-2">
        <h2 className="flex items-center gap-2 text-sm font-semibold text-secondary-800"><Layers className="h-4 w-4" /> Variations</h2>
        {canEdit && <Button size="sm" variant="outline" leftIcon={<Plus className="h-4 w-4" />} onClick={() => open('new')}>Add variation</Button>}
      </div>
      <p className="mb-3 text-xs text-secondary-500">
        Sizes, colours or other options, each with its own SKU, price and stock. The till asks which one is being sold.
        {!tracked && ' Stock is only counted when stock tracking is on for this product.'}
      </p>
      {error && <p className="text-sm text-error-700" role="alert">{error}</p>}
      {rows === null && !error && <p className="text-sm text-secondary-500">Loading…</p>}
      {rows && rows.length === 0 && <p className="text-sm text-secondary-500">No variations. This product is sold as it is.</p>}
      {rows && rows.length > 0 && (
        <ul className="divide-y divide-secondary-100">
          {rows.map((v) => (
            <li key={v.uuid} className="flex flex-wrap items-center gap-3 py-2">
              <div className="min-w-0 flex-1">
                <p className="text-sm font-medium text-secondary-900">{v.title} {!v.is_active && <Badge variant="secondary" size="sm">Off</Badge>}</p>
                <p className="text-xs text-secondary-500">{[v.sku && `SKU ${v.sku}`, formatCurrency(Number(v.effective_price)), v.price ? null : 'product price'].filter(Boolean).join(' · ')}</p>
              </div>
              {tracked && <Badge variant={v.stock > 0 ? 'success' : 'secondary'} size="sm">{v.stock} in stock</Badge>}
              {canEdit && (
                <span className="flex gap-1">
                  <Button size="sm" variant="ghost" aria-label={`Edit ${v.title}`} leftIcon={<Pencil className="h-3.5 w-3.5" />} onClick={() => open(v)} />
                  <Button size="sm" variant="ghost" aria-label={`Delete ${v.title}`} leftIcon={<Trash2 className="h-3.5 w-3.5" />} onClick={() => remove(v)} />
                </span>
              )}
            </li>
          ))}
        </ul>
      )}

      {editing && (
        <Modal
          isOpen={!!editing}
          onClose={() => !saving && setEditing(null)}
          title={editing === 'new' ? 'Add a variation' : `Edit ${editing.title}`}
          description="For example a size and a colour. Leave the price empty to use the product's price."
          footer={
            <>
              <Button variant="ghost" onClick={() => setEditing(null)} disabled={saving}>Cancel</Button>
              <Button onClick={save} isLoading={saving}>Save</Button>
            </>
          }
        >
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <Input label="Option 1 (e.g. size)" id="v-o1" value={form.option1} onChange={set('option1')} placeholder="Medium" />
            <Input label="Option 2 (e.g. colour)" id="v-o2" value={form.option2} onChange={set('option2')} placeholder="Blue" />
            <div className="sm:col-span-2">
              <Input label="Name shown at the till (optional)" id="v-title" value={form.title} onChange={set('title')}
                placeholder={[form.option1, form.option2].filter((x) => x.trim()).join(' / ') || 'Medium / Blue'} />
            </div>
            <Input label="SKU" id="v-sku" value={form.sku} onChange={set('sku')} placeholder="TSHIRT-M-BLU" />
            <Input label={`Price (empty = ${formatCurrency(productPrice)})`} id="v-price" inputMode="decimal" value={form.price} onChange={set('price')} />
            <Input label="Stock" id="v-stock" inputMode="numeric" value={form.stock} onChange={set('stock')} />
            <label className="flex items-center justify-between gap-3 self-end pb-2 text-sm text-secondary-700">
              <span>For sale</span>
              <Switch checked={form.is_active} onChange={(v) => setForm((f) => ({ ...f, is_active: v }))} aria-label="For sale" />
            </label>
          </div>
        </Modal>
      )}
    </Card>
  );
}
