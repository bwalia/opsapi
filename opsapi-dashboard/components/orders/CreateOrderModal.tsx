'use client';

import React, { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { Plus, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Modal, SearchableSelect, Switch, Textarea } from '@/components/ui';
import { storesService } from '@/services/stores.service';
import { posService, type PosProduct } from '@/services/pos.service';
import { ordersService } from '@/services/orders.service';
import { extractApiError } from '@/lib/utils';
import type { Store } from '@/types';

type Line = { key: number; product_uuid: string; quantity: string };

const money = (n: number, currency = 'GBP') => {
  try {
    return new Intl.NumberFormat('en-GB', { style: 'currency', currency }).format(n);
  } catch {
    return `${n.toFixed(2)} ${currency}`;
  }
};
const amount = (v: string) => (v.trim() === '' ? 0 : Number(v));
const validAmount = (v: string) => v.trim() === '' || /^\d+(\.\d{1,2})?$/.test(v.trim());

/**
 * Staff create an order for a customer in one of the workspace's stores (Stores & Products). The customer is
 * found by email or added; prices come from the products and stock is checked by the server, which also
 * works out the final totals (the ones shown here are a preview).
 */
export function CreateOrderModal({ open, onClose, onCreated, hasShop }: {
  open: boolean;
  onClose: () => void;
  onCreated: () => void;
  hasShop: boolean;
}) {
  const [stores, setStores] = useState<Store[] | null>(null);
  const [storeUuid, setStoreUuid] = useState('');
  const [products, setProducts] = useState<PosProduct[]>([]);
  const [lines, setLines] = useState<Line[]>([{ key: 1, product_uuid: '', quantity: '1' }]);
  const [email, setEmail] = useState('');
  const [firstName, setFirstName] = useState('');
  const [lastName, setLastName] = useState('');
  const [phone, setPhone] = useState('');
  const [shipping, setShipping] = useState('');
  const [discount, setDiscount] = useState('');
  const [notes, setNotes] = useState('');
  const [internal, setInternal] = useState('');
  const [paid, setPaid] = useState(false);
  const [channel, setChannel] = useState<'phone' | 'in_person' | 'email'>('phone');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per form: a double click or a retry after a lost answer never makes two orders.
  const [idemKey, setIdemKey] = useState(() => crypto.randomUUID());

  useEffect(() => {
    if (!open) return;
    let active = true;
    storesService
      .getStores({ perPage: 100 })
      .then((r) => {
        if (!active) return;
        setStores(r.data);
        if (r.data.length === 1) setStoreUuid(r.data[0].uuid);
      })
      .catch((e) => active && setError(extractApiError(e, 'Could not load your stores')));
    return () => {
      active = false;
    };
  }, [open]);

  useEffect(() => {
    if (!storeUuid) return;
    let active = true;
    // The store's active products (store-scoped, with stock), the same list the till uses.
    posService
      .products(storeUuid)
      .then((r) => active && setProducts(r.products))
      .catch((e) => active && setError(extractApiError(e, 'Could not load the products')));
    return () => {
      active = false;
    };
  }, [storeUuid]);

  const store = stores?.find((s) => s.uuid === storeUuid);
  const currency = (store as (Store & { currency?: string }) | undefined)?.currency || 'GBP';
  const taxRate = Number((store as (Store & { tax_rate?: number | string }) | undefined)?.tax_rate ?? 0) || 0;
  const byUuid = useMemo(() => new Map(products.map((p) => [p.uuid, p])), [products]);
  const options = useMemo(
    () => products.map((p) => ({ value: p.uuid, label: p.name, hint: [p.sku, money(Number(p.price) || 0, currency), p.stock === null ? null : p.stock > 0 ? `${p.stock} in stock` : 'out of stock'].filter(Boolean).join(' · ') })),
    [products, currency]
  );

  const subtotal = lines.reduce((sum, l) => {
    const p = byUuid.get(l.product_uuid);
    const q = Number(l.quantity);
    return p && Number.isInteger(q) && q > 0 ? sum + Math.round((Number(p.price) || 0) * q * 100) / 100 : sum;
  }, 0);
  const tax = Math.round(subtotal * taxRate * 100) / 100;
  const total = subtotal + tax + (validAmount(shipping) ? amount(shipping) : 0) - (validAmount(discount) ? amount(discount) : 0);

  const reset = () => {
    setStoreUuid('');
    setProducts([]);
    setLines([{ key: 1, product_uuid: '', quantity: '1' }]);
    setEmail('');
    setFirstName('');
    setLastName('');
    setPhone('');
    setShipping('');
    setDiscount('');
    setNotes('');
    setInternal('');
    setPaid(false);
    setChannel('phone');
    setError(null);
    setIdemKey(crypto.randomUUID());
  };

  const close = () => {
    if (saving) return;
    reset();
    onClose();
  };

  const submit = async () => {
    setError(null);
    const items = lines.filter((l) => l.product_uuid).map((l) => ({ product_uuid: l.product_uuid, quantity: Number(l.quantity) }));
    if (!storeUuid) return setError('Choose the store');
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim())) return setError('Enter the customer’s email address');
    if (items.length === 0) return setError('Add at least one product');
    if (items.some((i) => !Number.isInteger(i.quantity) || i.quantity < 1)) return setError('Quantities must be whole numbers from 1');
    if (!validAmount(shipping) || !validAmount(discount)) return setError('Shipping and discount are amounts like 12.50');
    setSaving(true);
    try {
      const order = await ordersService.createOrder(
        {
          store_uuid: storeUuid,
          customer: { email: email.trim(), first_name: firstName.trim() || undefined, last_name: lastName.trim() || undefined, phone: phone.trim() || undefined },
          items,
          shipping_amount: shipping.trim() || undefined,
          discount_amount: discount.trim() || undefined,
          customer_notes: notes.trim() || undefined,
          internal_notes: internal.trim() || undefined,
          paid,
          channel,
        },
        idemKey
      );
      toast.success(`Order ${order.order_number} created`);
      reset();
      onCreated();
      onClose();
    } catch (e) {
      setError(extractApiError(e, 'The order could not be created'));
    } finally {
      setSaving(false);
    }
  };

  const noStores = stores !== null && stores.length === 0;

  return (
    <Modal
      isOpen={open}
      onClose={close}
      title="Create an order"
      description="An order taken by phone, by email or in person at the counter. Prices come from your products."
      size="2xl"
      footer={
        noStores ? (
          <Button variant="ghost" onClick={close}>Close</Button>
        ) : (
          <>
            <Button variant="ghost" onClick={close} disabled={saving}>Cancel</Button>
            <Button onClick={submit} isLoading={saving}>Create order</Button>
          </>
        )
      }
    >
      {stores === null && !error && <p className="text-sm text-secondary-500">Loading…</p>}
      {noStores && (
        <div className="space-y-2 text-sm text-secondary-700">
          <p>You need a store with products before you can take an order here.</p>
          <Link href="/dashboard/stores" className="font-medium text-primary-600 hover:underline">Set up a store</Link>
          {hasShop && (
            <p>
              Selling through your shop? Create the order there instead:{' '}
              <Link href="/dashboard/shop/quotes/new" className="font-medium text-primary-600 hover:underline">Shop → Create order</Link>.
            </p>
          )}
        </div>
      )}
      {stores && stores.length > 0 && (
        <div className="space-y-5">
          {hasShop && (
            <p className="rounded-lg bg-secondary-50 px-3 py-2 text-xs text-secondary-600">
              This is for your online stores. For a shop order the customer confirms and pays online, use{' '}
              <Link href="/dashboard/shop/quotes/new" className="font-medium text-primary-600 hover:underline">Shop → Create order</Link>.
            </p>
          )}
          <div>
            <label className="mb-1 block text-sm font-medium text-secondary-700">Store</label>
            <SearchableSelect
              options={stores.map((s) => ({ value: s.uuid, label: s.name }))}
              value={storeUuid}
              onChange={(v) => {
                setStoreUuid(v);
                setLines([{ key: Date.now(), product_uuid: '', quantity: '1' }]);
              }}
              placeholder="Choose the store"
            />
          </div>

          {storeUuid && (
            <fieldset className="space-y-2">
              <legend className="mb-1 text-sm font-medium text-secondary-700">Products</legend>
              {products.length === 0 && <p className="text-sm text-secondary-500">This store has no active products yet.</p>}
              {lines.map((l, i) => {
                const p = byUuid.get(l.product_uuid);
                return (
                  <div key={l.key} className="flex flex-wrap items-end gap-2">
                    <div className="min-w-[220px] flex-1">
                      <SearchableSelect
                        options={options}
                        value={l.product_uuid}
                        onChange={(v) => setLines((ls) => ls.map((x) => (x.key === l.key ? { ...x, product_uuid: v } : x)))}
                        placeholder={`Product ${i + 1}`}
                        searchPlaceholder="Name or SKU"
                      />
                    </div>
                    <div className="w-24">
                      <Input
                        aria-label={`Quantity for line ${i + 1}`}
                        type="number"
                        min={1}
                        step={1}
                        value={l.quantity}
                        onChange={(e) => setLines((ls) => ls.map((x) => (x.key === l.key ? { ...x, quantity: e.target.value } : x)))}
                      />
                    </div>
                    <span className="w-24 pb-2 text-right text-sm tabular-nums text-secondary-700">
                      {p ? money((Number(p.price) || 0) * (Number(l.quantity) || 0), currency) : '—'}
                    </span>
                    <Button
                      variant="ghost"
                      size="sm"
                      aria-label={`Remove line ${i + 1}`}
                      disabled={lines.length === 1}
                      onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))}
                      leftIcon={<Trash2 className="h-4 w-4" />}
                    />
                  </div>
                );
              })}
              <Button
                variant="outline"
                size="sm"
                leftIcon={<Plus className="h-4 w-4" />}
                onClick={() => setLines((ls) => [...ls, { key: Date.now(), product_uuid: '', quantity: '1' }])}
                disabled={lines.length >= 100}
              >
                Add a product
              </Button>
            </fieldset>
          )}

          <fieldset>
            <legend className="mb-1 text-sm font-medium text-secondary-700">How did they order?</legend>
            <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="How did they order?">
              {([['phone', 'Phone'], ['in_person', 'In person'], ['email', 'Email']] as const).map(([v, l]) => (
                <button key={v} type="button" role="radio" aria-checked={channel === v} onClick={() => setChannel(v)}
                  className={`rounded-full border px-3 py-1 text-sm ${channel === v ? 'border-primary-500 bg-primary-50 text-primary-700' : 'border-secondary-200 text-secondary-700 hover:bg-secondary-50'}`}>
                  {l}
                </button>
              ))}
            </div>
          </fieldset>

          <fieldset className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <legend className="mb-1 text-sm font-medium text-secondary-700">Customer</legend>
            <Input label="Email" id="co-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="off" />
            <Input label="Phone (optional)" id="co-phone" type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
            <Input label="First name (optional)" id="co-first" value={firstName} onChange={(e) => setFirstName(e.target.value)} />
            <Input label="Last name (optional)" id="co-last" value={lastName} onChange={(e) => setLastName(e.target.value)} />
          </fieldset>

          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <Input label="Shipping (optional)" id="co-ship" inputMode="decimal" placeholder="0.00" value={shipping} onChange={(e) => setShipping(e.target.value)}
              error={validAmount(shipping) ? undefined : 'An amount like 12.50'} />
            <Input label="Discount (optional)" id="co-disc" inputMode="decimal" placeholder="0.00" value={discount} onChange={(e) => setDiscount(e.target.value)}
              error={validAmount(discount) ? undefined : 'An amount like 5.00'} />
          </div>
          <Textarea label="Note for the customer (optional)" id="co-notes" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={2000} />
          <Textarea label="Internal note (optional)" id="co-internal" rows={2} value={internal} onChange={(e) => setInternal(e.target.value)} maxLength={2000} />
          <label className="flex items-center justify-between gap-3 text-sm text-secondary-700">
            <span>The customer has already paid</span>
            <Switch checked={paid} onChange={setPaid} aria-label="The customer has already paid" />
          </label>

          <div className="rounded-lg border border-secondary-200 p-3 text-sm tabular-nums">
            <div className="flex justify-between"><span>Subtotal</span><span>{money(subtotal, currency)}</span></div>
            {tax > 0 && <div className="flex justify-between text-secondary-600"><span>Tax</span><span>{money(tax, currency)}</span></div>}
            <div className="mt-1 flex justify-between border-t border-secondary-100 pt-1 font-semibold"><span>Total</span><span>{money(Math.max(0, total), currency)}</span></div>
          </div>
        </div>
      )}
      {error && <p className="mt-3 text-sm text-error-700" role="alert">{error}</p>}
    </Modal>
  );
}
