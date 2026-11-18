'use client';

/**
 * Point of Sale: the till for selling in person. Pick (or scan) products from a store, take cash, card or another
 * payment, and give a printed or emailed receipt. A sale is a normal order (channel "Point of sale"): paid,
 * handed over, stock taken, and listed in Sales Orders. Data: /api/v2/pos/* (lapis/queries/PosQueries.lua).
 */
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import { Banknote, CreditCard, Mail, Minus, Plus, Printer, ReceiptText, ScanLine, Search, Store, Trash2, Wallet } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { storesService } from '@/services/stores.service';
import { posService, type PosCatalogue, type PosPaymentMethod, type PosProduct, type PosReceipt, type PosSummary } from '@/services/pos.service';
import { extractApiError } from '@/lib/utils';
import type { Store as StoreType } from '@/types';

const STORE_KEY = 'opsapi:pos:store';

type Line = { product: PosProduct; quantity: number };

function money(v: string | number, currency = 'GBP') {
  try {
    return new Intl.NumberFormat('en-GB', { style: 'currency', currency }).format(Number(v) || 0);
  } catch {
    return `${(Number(v) || 0).toFixed(2)} ${currency}`;
  }
}
const r2 = (n: number) => Math.round(n * 100) / 100;
const isAmount = (v: string) => v.trim() === '' || /^\d+(\.\d{1,2})?$/.test(v.trim());

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string);

/** Print the receipt on its own (a hidden frame), sized for a receipt printer or A4. */
function printReceipt(r: PosReceipt) {
  const cur = r.currency;
  const rows = r.items
    .map((i) => `<tr><td>${i.quantity} × ${esc(i.name)}</td><td class="r">${esc(money(i.total, cur))}</td></tr>`)
    .join('');
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>Receipt ${esc(r.order_number)}</title>
<style>body{font-family:system-ui,sans-serif;font-size:13px;max-width:320px;margin:16px auto;color:#111}
h1{font-size:16px;margin:0}p{margin:2px 0}table{width:100%;border-collapse:collapse;margin:10px 0}
td{padding:3px 0;vertical-align:top}.r{text-align:right}.t td{border-top:1px solid #000;font-weight:700;padding-top:6px}
.m{color:#555;font-size:12px}</style></head><body>
<h1>${esc(r.store.name)}</h1>${r.store.address ? `<p class="m">${esc(r.store.address)}</p>` : ''}${r.store.contact ? `<p class="m">${esc(r.store.contact)}</p>` : ''}
<p class="m">${esc(r.order_number)} · ${esc(new Date(r.sold_at).toLocaleString('en-GB'))}</p>
<table>${rows}
<tr><td>Subtotal</td><td class="r">${esc(money(r.subtotal, cur))}</td></tr>
${Number(r.discount) > 0 ? `<tr><td>Discount</td><td class="r">−${esc(money(r.discount, cur))}</td></tr>` : ''}
${Number(r.tax) > 0 ? `<tr><td>Tax</td><td class="r">${esc(money(r.tax, cur))}</td></tr>` : ''}
<tr class="t"><td>Total</td><td class="r">${esc(money(r.total, cur))}</td></tr></table>
<p>Paid by ${esc(r.payment.label ?? '—')}${r.payment.reference ? ` (${esc(r.payment.reference)})` : ''}</p>
${r.payment.tendered ? `<p>Cash ${esc(money(r.payment.tendered, cur))} · Change ${esc(money(r.payment.change ?? 0, cur))}</p>` : ''}
<p class="m" style="margin-top:12px">Thank you for your purchase.</p></body></html>`;
  const frame = document.createElement('iframe');
  frame.style.position = 'fixed';
  frame.style.width = '0';
  frame.style.height = '0';
  frame.style.border = '0';
  frame.srcdoc = html;
  frame.onload = () => {
    frame.contentWindow?.focus();
    frame.contentWindow?.print();
    setTimeout(() => frame.remove(), 2000);
  };
  document.body.appendChild(frame);
}

function Till() {
  const [stores, setStores] = useState<StoreType[] | null>(null);
  const [storeUuid, setStoreUuid] = useState('');
  const [catalogue, setCatalogue] = useState<PosCatalogue | null>(null);
  const [search, setSearch] = useState('');
  const [lines, setLines] = useState<Line[]>([]);
  const [discount, setDiscount] = useState('');
  const [email, setEmail] = useState('');
  const [method, setMethod] = useState<PosPaymentMethod>('cash');
  const [tendered, setTendered] = useState('');
  const [reference, setReference] = useState('');
  const [saving, setSaving] = useState(false);
  const [receipt, setReceipt] = useState<PosReceipt | null>(null);
  const [receiptEmail, setReceiptEmail] = useState('');
  const [emailing, setEmailing] = useState(false);
  const [summary, setSummary] = useState<PosSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saleKey, setSaleKey] = useState(() => crypto.randomUUID());
  const searchRef = useRef<HTMLInputElement>(null);

  // Stores of this workspace; the last one used on this device is picked again.
  useEffect(() => {
    let active = true;
    storesService
      .getStores({ perPage: 100 })
      .then((r) => {
        if (!active) return;
        setStores(r.data);
        let saved = '';
        try {
          saved = localStorage.getItem(STORE_KEY) ?? '';
        } catch {
          /* private mode: no memory */
        }
        const pick = r.data.find((s) => s.uuid === saved)?.uuid ?? (r.data.length === 1 ? r.data[0].uuid : '');
        if (pick) setStoreUuid(pick);
      })
      .catch((e) => active && setError(extractApiError(e, 'Could not load your stores')));
    return () => {
      active = false;
    };
  }, []);

  const loadSummary = useCallback((uuid: string) => {
    posService.summary(uuid).then(setSummary).catch(() => setSummary(null));
  }, []);

  useEffect(() => {
    if (!storeUuid) return;
    try {
      localStorage.setItem(STORE_KEY, storeUuid);
    } catch {
      /* fine */
    }
    let active = true;
    posService
      .products(storeUuid)
      .then((c) => active && setCatalogue(c))
      .catch((e) => active && setError(extractApiError(e, 'Could not load the products')));
    loadSummary(storeUuid);
    return () => {
      active = false;
    };
  }, [storeUuid, loadSummary]);

  const currency = catalogue?.store.currency ?? 'GBP';
  const products = useMemo(() => catalogue?.products ?? [], [catalogue]);
  const term = search.trim().toLowerCase();
  const shown = useMemo(
    () =>
      term
        ? products.filter((p) => p.name.toLowerCase().includes(term) || p.sku?.toLowerCase().includes(term) || p.barcode?.toLowerCase().includes(term))
        : products,
    [products, term]
  );

  const inCart = (uuid: string) => lines.find((l) => l.product.uuid === uuid)?.quantity ?? 0;

  const add = useCallback((p: PosProduct) => {
    if (!p.available) {
      toast.error(`${p.name} is out of stock`);
      return;
    }
    setLines((ls) => {
      const have = ls.find((l) => l.product.uuid === p.uuid);
      if (have && p.stock !== null && have.quantity >= p.stock) {
        toast.error(`Only ${p.stock} of ${p.name} in stock`);
        return ls;
      }
      return have ? ls.map((l) => (l.product.uuid === p.uuid ? { ...l, quantity: l.quantity + 1 } : l)) : [...ls, { product: p, quantity: 1 }];
    });
  }, []);

  const setQty = (uuid: string, q: number) =>
    setLines((ls) => (q <= 0 ? ls.filter((l) => l.product.uuid !== uuid) : ls.map((l) => (l.product.uuid === uuid ? { ...l, quantity: q } : l))));

  // A scanner types the code and presses Enter: an exact barcode or SKU goes straight into the sale.
  const onSearchKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Escape') setSearch('');
    if (e.key !== 'Enter') return;
    const code = search.trim().toLowerCase();
    if (!code) return;
    const exact = products.find((p) => p.barcode?.toLowerCase() === code || p.sku?.toLowerCase() === code);
    const pick = exact ?? (shown.length === 1 ? shown[0] : undefined);
    if (pick) {
      add(pick);
      setSearch('');
    } else {
      toast.error(`Nothing matches “${search.trim()}”`);
    }
  };

  const subtotal = r2(lines.reduce((s, l) => s + r2(Number(l.product.price) * l.quantity), 0));
  const tax = r2(subtotal * (catalogue?.store.tax_rate ?? 0));
  const disc = isAmount(discount) ? Number(discount || 0) : 0;
  const total = r2(subtotal + tax - disc);
  const cash = isAmount(tendered) && tendered.trim() !== '' ? Number(tendered) : total;
  const change = r2(cash - total);
  const quick = useMemo(() => {
    const set = new Set<number>([total]);
    for (const step of [5, 10, 20, 50]) set.add(Math.ceil(total / step) * step);
    return [...set].filter((v) => v >= total && v > 0).sort((a, b) => a - b).slice(0, 5);
  }, [total]);

  const problem =
    lines.length === 0 ? 'Add something to the sale' :
    !isAmount(discount) ? 'The discount must be an amount like 5.00' :
    total < 0 ? 'The discount is more than the sale' :
    method === 'cash' && (!isAmount(tendered) || change < 0) ? 'The cash given is less than the total' :
    email.trim() && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim()) ? 'Check the email address' : null;

  const complete = async () => {
    if (problem || !storeUuid) return;
    setSaving(true);
    setError(null);
    try {
      const r = await posService.sale(
        {
          store_uuid: storeUuid,
          items: lines.map((l) => ({ product_uuid: l.product.uuid, quantity: l.quantity })),
          discount_amount: discount.trim() || undefined,
          customer: email.trim() ? { email: email.trim() } : undefined,
          payment: { method, tendered: method === 'cash' ? (tendered.trim() || undefined) : undefined, reference: reference.trim() || undefined },
        },
        saleKey
      );
      setReceipt(r);
      setReceiptEmail(r.customer_email ?? '');
      setLines([]);
      setDiscount('');
      setEmail('');
      setTendered('');
      setReference('');
      setMethod('cash');
      setSaleKey(crypto.randomUUID());
      loadSummary(storeUuid);
      posService.products(storeUuid).then(setCatalogue).catch(() => undefined);
    } catch (e) {
      setError(extractApiError(e, 'The sale could not be completed'));
    } finally {
      setSaving(false);
    }
  };

  const sendReceipt = async () => {
    if (!receipt) return;
    setEmailing(true);
    try {
      const res = await posService.emailReceipt(receipt.uuid, receiptEmail.trim());
      toast.success(`Receipt sent to ${res.to}`);
    } catch (e) {
      toast.error(extractApiError(e, 'The receipt could not be sent'));
    } finally {
      setEmailing(false);
    }
  };

  const newSale = () => {
    setReceipt(null);
    setTimeout(() => searchRef.current?.focus(), 50);
  };

  if (stores && stores.length === 0) {
    return (
      <div className="space-y-6">
        <PageHeader title="Point of Sale" description="Sell in person and give a receipt." icon={<Store className="h-5 w-5" />} />
        <Card>
          <p className="text-sm text-secondary-700">The till sells the products of one of your stores. Add a store and its products first.</p>
          <Link href="/dashboard/stores" className="mt-2 inline-flex text-sm font-medium text-primary-600 hover:underline">Set up a store</Link>
        </Card>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title="Point of Sale"
        description="Sell in person: pick or scan products, take payment and give a receipt. Sales show in Sales Orders."
        icon={<Store className="h-5 w-5" />}
        actions={
          <div className="flex flex-wrap items-center gap-2">
            {summary && (
              <span className="rounded-full bg-secondary-100 px-3 py-1 text-xs text-secondary-700" title={`${summary.date} (${summary.timezone})`}>
                Today: {summary.sales} sale{summary.sales === 1 ? '' : 's'} · {money(summary.total, summary.currency)}
                {summary.by_method.length > 0 && ` (${summary.by_method.map((m) => `${m.label} ${money(m.total, summary.currency)}`).join(', ')})`}
              </span>
            )}
            {stores && stores.length > 1 && (
              <select
                aria-label="Store"
                className="rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm"
                value={storeUuid}
                onChange={(e) => {
                  setStoreUuid(e.target.value);
                  setLines([]);
                }}
              >
                <option value="">Choose the store</option>
                {stores.map((s) => <option key={s.uuid} value={s.uuid}>{s.name}</option>)}
              </select>
            )}
            <Link href="/dashboard/orders?stage=delivered" className="text-sm font-medium text-primary-600 hover:underline">Sales Orders</Link>
          </div>
        }
      />

      {error && <p className="rounded-lg bg-error-50 px-3 py-2 text-sm text-error-700" role="alert">{error}</p>}
      {stores === null && <p className="text-sm text-secondary-500">Loading…</p>}
      {stores && !storeUuid && <Card><p className="text-sm text-secondary-700">Choose the store you are selling from (top right).</p></Card>}

      {storeUuid && (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
          <div className="space-y-3 lg:col-span-2">
            <Input
              ref={searchRef}
              autoFocus
              aria-label="Find or scan a product"
              placeholder="Find a product, or scan its barcode"
              leftIcon={search ? <Search className="h-4 w-4" /> : <ScanLine className="h-4 w-4" />}
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              onKeyDown={onSearchKey}
            />
            {catalogue === null ? (
              <p className="text-sm text-secondary-500">Loading products…</p>
            ) : shown.length === 0 ? (
              <p className="text-sm text-secondary-500">{products.length === 0 ? 'This store has no active products yet.' : 'Nothing matches.'}</p>
            ) : (
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4">
                {shown.map((p) => {
                  const n = inCart(p.uuid);
                  return (
                    <button
                      key={p.uuid}
                      type="button"
                      onClick={() => add(p)}
                      disabled={!p.available}
                      className={`relative flex min-h-[96px] flex-col justify-between rounded-xl border p-3 text-left transition ${
                        n > 0 ? 'border-primary-400 bg-primary-50' : 'border-secondary-200 bg-surface hover:border-primary-300'
                      } disabled:cursor-not-allowed disabled:opacity-50`}
                    >
                      <span className="line-clamp-2 text-sm font-medium text-secondary-900">{p.name}</span>
                      <span className="mt-2 flex items-end justify-between gap-2">
                        <span className="font-semibold tabular-nums text-secondary-900">{money(p.price, currency)}</span>
                        <span className="text-xs text-secondary-500">{p.stock === null ? '' : p.stock > 0 ? `${p.stock} left` : 'Out of stock'}</span>
                      </span>
                      {n > 0 && (
                        <span className="absolute right-2 top-2 rounded-full bg-primary-600 px-2 text-xs font-bold text-white" aria-label={`${n} in this sale`}>{n}</span>
                      )}
                    </button>
                  );
                })}
              </div>
            )}
          </div>

          <Card className="h-fit space-y-4 lg:sticky lg:top-4">
            <h2 className="flex items-center gap-2 text-base font-semibold text-secondary-900"><ReceiptText className="h-4 w-4" /> This sale</h2>
            {lines.length === 0 ? (
              <p className="text-sm text-secondary-500">Tap a product to add it.</p>
            ) : (
              <ul className="divide-y divide-secondary-100">
                {lines.map((l) => (
                  <li key={l.product.uuid} className="flex items-center gap-2 py-2">
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm text-secondary-900">{l.product.name}</p>
                      <p className="text-xs tabular-nums text-secondary-500">{money(l.product.price, currency)} each</p>
                    </div>
                    <div className="flex items-center gap-1">
                      <button type="button" aria-label={`One fewer ${l.product.name}`} className="rounded-md border border-secondary-200 p-1.5 hover:bg-secondary-50"
                        onClick={() => setQty(l.product.uuid, l.quantity - 1)}><Minus className="h-3.5 w-3.5" /></button>
                      <span className="w-7 text-center text-sm tabular-nums">{l.quantity}</span>
                      <button type="button" aria-label={`One more ${l.product.name}`} className="rounded-md border border-secondary-200 p-1.5 hover:bg-secondary-50"
                        onClick={() => add(l.product)}><Plus className="h-3.5 w-3.5" /></button>
                    </div>
                    <span className="w-20 text-right text-sm tabular-nums">{money(r2(Number(l.product.price) * l.quantity), currency)}</span>
                    <button type="button" aria-label={`Remove ${l.product.name}`} className="p-1 text-secondary-400 hover:text-error-600"
                      onClick={() => setQty(l.product.uuid, 0)}><Trash2 className="h-4 w-4" /></button>
                  </li>
                ))}
              </ul>
            )}

            <div className="grid grid-cols-2 gap-2">
              <Input label="Discount" id="pos-discount" inputMode="decimal" placeholder="0.00" value={discount} onChange={(e) => setDiscount(e.target.value)} />
              <Input label="Email for receipt" id="pos-email" type="email" placeholder="Optional" value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>

            <div className="space-y-1 rounded-lg bg-secondary-50 p-3 text-sm tabular-nums">
              <div className="flex justify-between"><span>Subtotal</span><span>{money(subtotal, currency)}</span></div>
              {tax > 0 && <div className="flex justify-between text-secondary-600"><span>Tax</span><span>{money(tax, currency)}</span></div>}
              {disc > 0 && <div className="flex justify-between text-secondary-600"><span>Discount</span><span>−{money(disc, currency)}</span></div>}
              <div className="flex justify-between border-t border-secondary-200 pt-1 text-lg font-bold"><span>Total</span><span>{money(Math.max(0, total), currency)}</span></div>
            </div>

            <div>
              <p className="mb-2 text-sm font-medium text-secondary-700">Payment</p>
              <div className="grid grid-cols-3 gap-2" role="radiogroup" aria-label="Payment">
                {([['cash', 'Cash', Banknote], ['card', 'Card', CreditCard], ['other', 'Other', Wallet]] as const).map(([v, l, Icon]) => (
                  <button key={v} type="button" role="radio" aria-checked={method === v} onClick={() => setMethod(v)}
                    className={`flex flex-col items-center gap-1 rounded-lg border py-2 text-sm ${method === v ? 'border-primary-500 bg-primary-50 text-primary-700' : 'border-secondary-200 hover:bg-secondary-50'}`}>
                    <Icon className="h-4 w-4" /> {l}
                  </button>
                ))}
              </div>
              {method === 'cash' ? (
                <div className="mt-3 space-y-2">
                  <Input label="Cash given" id="pos-cash" inputMode="decimal" placeholder={total > 0 ? total.toFixed(2) : '0.00'} value={tendered} onChange={(e) => setTendered(e.target.value)} />
                  <div className="flex flex-wrap gap-1.5">
                    {quick.map((v) => (
                      <button key={v} type="button" onClick={() => setTendered(v.toFixed(2))}
                        className="rounded-full border border-secondary-200 px-2.5 py-1 text-xs tabular-nums hover:bg-secondary-50">
                        {v === total ? 'Exact' : money(v, currency)}
                      </button>
                    ))}
                  </div>
                  {lines.length > 0 && change >= 0 && <p className="text-sm font-semibold text-success-700">Change: {money(change, currency)}</p>}
                </div>
              ) : (
                <div className="mt-3">
                  <Input label={method === 'card' ? 'Card terminal reference (optional)' : 'How they paid (optional)'} id="pos-ref" value={reference}
                    onChange={(e) => setReference(e.target.value)} maxLength={100} />
                </div>
              )}
            </div>

            {problem && lines.length > 0 && <p className="text-xs text-warning-700">{problem}</p>}
            <Button className="w-full" size="lg" onClick={complete} isLoading={saving} disabled={!!problem}>
              Complete sale · {money(Math.max(0, total), currency)}
            </Button>
          </Card>
        </div>
      )}

      {receipt && (
        <Modal
          isOpen={!!receipt}
          onClose={newSale}
          title={`Sale complete: ${receipt.order_number}`}
          size="md"
          footer={
            <>
              <Button variant="outline" leftIcon={<Printer className="h-4 w-4" />} onClick={() => printReceipt(receipt)}>Print receipt</Button>
              <Button onClick={newSale}>New sale</Button>
            </>
          }
        >
          <div className="space-y-3 text-sm">
            <ul className="divide-y divide-secondary-100">
              {receipt.items.map((i, k) => (
                <li key={k} className="flex justify-between py-1.5"><span>{i.quantity} × {i.name}</span><span className="tabular-nums">{money(i.total, receipt.currency)}</span></li>
              ))}
            </ul>
            <div className="flex justify-between text-base font-bold"><span>Total</span><span>{money(receipt.total, receipt.currency)}</span></div>
            <p className="text-secondary-600">
              Paid by {receipt.payment.label}
              {receipt.payment.change && Number(receipt.payment.change) > 0 && (
                <span className="ml-1 font-semibold text-success-700">· give {money(receipt.payment.change, receipt.currency)} change</span>
              )}
            </p>
            <div className="flex items-end gap-2">
              <div className="flex-1">
                <Input label="Email the receipt" id="pos-receipt-email" type="email" placeholder="customer@example.com" value={receiptEmail} onChange={(e) => setReceiptEmail(e.target.value)} />
              </div>
              <Button variant="outline" leftIcon={<Mail className="h-4 w-4" />} isLoading={emailing}
                disabled={!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(receiptEmail.trim())} onClick={sendReceipt}>Send</Button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}

export default function PosPage() {
  return (
    <ProtectedPage module="orders" action="create" title="Point of Sale">
      <Till />
    </ProtectedPage>
  );
}
