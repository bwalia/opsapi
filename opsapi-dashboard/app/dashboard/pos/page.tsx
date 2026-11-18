'use client';

/**
 * Point of Sale: the till for selling in person. Products come from one of the workspace's stores (Stores &
 * Products: Products page for names, prices, SKUs, barcodes and stock; a product's Variations for sizes,
 * colours…). Tap or scan to add, take cash, card or another payment, give a printed or emailed receipt.
 * A sale is a normal order (channel "Point of sale"): paid, handed over, stock taken, listed in Sales Orders.
 * Data: /api/v2/pos/* (lapis/queries/PosQueries.lua).
 */
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import {
  Banknote, BookOpen, Boxes, CreditCard, Info, Layers, Mail, Minus, PackagePlus, Plus, Printer, ReceiptText,
  ScanLine, Search, ShoppingBag, Store, Tag, Trash2, Wallet, X,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { storesService } from '@/services/stores.service';
import {
  posService, type PosCatalogue, type PosPaymentMethod, type PosProduct, type PosReceipt, type PosSummary, type PosVariant,
} from '@/services/pos.service';
import { cn, extractApiError } from '@/lib/utils';
import type { Store as StoreType } from '@/types';

const STORE_KEY = 'opsapi:pos:store';
const GUIDE_KEY = 'opsapi:pos:guide-hidden';
const LOW_STOCK = 5;

type Line = { key: string; product: PosProduct; variant: PosVariant | null; quantity: number };

function money(v: string | number, currency = 'GBP') {
  try {
    return new Intl.NumberFormat('en-GB', { style: 'currency', currency }).format(Number(v) || 0);
  } catch {
    return `${(Number(v) || 0).toFixed(2)} ${currency}`;
  }
}
const r2 = (n: number) => Math.round(n * 100) / 100;
const isAmount = (v: string) => v.trim() === '' || /^\d+(\.\d{1,2})?$/.test(v.trim());
const lineKey = (p: PosProduct, v: PosVariant | null) => `${p.uuid}:${v?.uuid ?? ''}`;
const priceOf = (l: Line) => Number(l.variant ? l.variant.price : l.product.price);
/** How many can be sold: null = no limit (stock not tracked). */
const stockOf = (p: PosProduct, v: PosVariant | null) => (v ? v.stock : p.variants.length ? null : p.stock);

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string);

/** A soft tile colour from the name, for products without a picture. */
function tileTone(name: string) {
  const tones = ['bg-sky-100 text-sky-700', 'bg-emerald-100 text-emerald-700', 'bg-amber-100 text-amber-700', 'bg-rose-100 text-rose-700',
    'bg-violet-100 text-violet-700', 'bg-teal-100 text-teal-700', 'bg-orange-100 text-orange-700', 'bg-indigo-100 text-indigo-700'];
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
  return tones[h % tones.length];
}
const initials = (name: string) => name.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]?.toUpperCase()).join('');

function StockPill({ stock, tracked, compact }: { stock: number | null; tracked: boolean; compact?: boolean }) {
  if (!tracked || stock === null) return <span className="text-[11px] text-secondary-400">{compact ? '' : 'Stock not tracked'}</span>;
  if (stock <= 0) return <span className="rounded-full bg-secondary-100 px-2 py-0.5 text-[11px] font-medium text-secondary-500">Out of stock</span>;
  if (stock <= LOW_STOCK) return <span className="rounded-full bg-amber-50 px-2 py-0.5 text-[11px] font-medium text-amber-700">Only {stock} left</span>;
  return <span className="rounded-full bg-emerald-50 px-2 py-0.5 text-[11px] font-medium text-emerald-700">{stock} in stock</span>;
}

/** Print the receipt on its own (a hidden frame), sized for a receipt printer or A4. */
function printReceipt(r: PosReceipt) {
  const cur = r.currency;
  const rows = r.items.map((i) => `<tr><td>${i.quantity} × ${esc(i.name)}</td><td class="r">${esc(money(i.total, cur))}</td></tr>`).join('');
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
  Object.assign(frame.style, { position: 'fixed', width: '0', height: '0', border: '0' });
  frame.srcdoc = html;
  frame.onload = () => {
    frame.contentWindow?.focus();
    frame.contentWindow?.print();
    setTimeout(() => frame.remove(), 2000);
  };
  document.body.appendChild(frame);
}

/** How the till works and where its products, stock and variations are managed. */
function Guide({ storeName, onHide }: { storeName?: string; onHide: () => void }) {
  const steps = [
    { icon: PackagePlus, title: 'Add products', text: `The till sells the products of ${storeName ? `“${storeName}”` : 'a store'}. Add them in Products: name, price, SKU and barcode (for scanning).`, href: '/dashboard/products', link: 'Open Products' },
    { icon: Boxes, title: 'Keep stock', text: 'On each product, turn on stock tracking and enter the quantity. The till shows what is left, stops at zero, and every sale takes its items off.', href: '/dashboard/products', link: 'Manage stock' },
    { icon: Layers, title: 'Variations', text: 'Sizes, colours and other options: open a product and add Variations, each with its own SKU, price and stock. The till asks which one is being sold.', href: '/dashboard/products', link: 'Add variations' },
    { icon: ShoppingBag, title: 'Sell', text: 'Tap or scan products, take cash, card or another payment, then print or email the receipt. Every sale is listed in Sales Orders.', href: '/dashboard/orders?stage=delivered', link: 'See sales' },
  ];
  return (
    <Card className="relative">
      <button type="button" onClick={onHide} aria-label="Hide the guide" className="absolute right-3 top-3 rounded-md p-1 text-secondary-400 hover:bg-secondary-100">
        <X className="h-4 w-4" />
      </button>
      <h2 className="flex items-center gap-2 text-sm font-semibold text-secondary-900"><BookOpen className="h-4 w-4 text-primary-600" /> How the till works</h2>
      <ol className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {steps.map((s, i) => (
          <li key={s.title} className="rounded-xl border border-secondary-200 bg-secondary-50/60 p-3">
            <p className="flex items-center gap-2 text-sm font-medium text-secondary-900">
              <span className="flex h-6 w-6 items-center justify-center rounded-full bg-primary-600 text-xs font-bold text-white">{i + 1}</span>
              <s.icon className="h-4 w-4 text-secondary-500" /> {s.title}
            </p>
            <p className="mt-1.5 text-xs leading-relaxed text-secondary-600">{s.text}</p>
            <Link href={s.href} className="mt-2 inline-flex text-xs font-medium text-primary-600 hover:underline">{s.link} →</Link>
          </li>
        ))}
      </ol>
    </Card>
  );
}

function Till() {
  const [stores, setStores] = useState<StoreType[] | null>(null);
  const [storeUuid, setStoreUuid] = useState('');
  const [catalogue, setCatalogue] = useState<PosCatalogue | null>(null);
  const [search, setSearch] = useState('');
  const [category, setCategory] = useState('');
  const [inStockOnly, setInStockOnly] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [picking, setPicking] = useState<PosProduct | null>(null);
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
  const [showGuide, setShowGuide] = useState(true);
  const [saleKey, setSaleKey] = useState(() => crypto.randomUUID());
  const searchRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    try {
      if (localStorage.getItem(GUIDE_KEY) === '1') setShowGuide(false);
    } catch {
      /* private mode */
    }
  }, []);
  const toggleGuide = (show: boolean) => {
    setShowGuide(show);
    try {
      if (show) localStorage.removeItem(GUIDE_KEY);
      else localStorage.setItem(GUIDE_KEY, '1');
    } catch {
      /* fine */
    }
  };

  // The workspace's stores; the last one used on this device is picked again.
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
          /* private mode */
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
  const loadCatalogue = useCallback((uuid: string) => {
    posService
      .products(uuid)
      .then(setCatalogue)
      .catch((e) => setError(extractApiError(e, 'Could not load the products')));
  }, []);

  useEffect(() => {
    if (!storeUuid) return;
    try {
      localStorage.setItem(STORE_KEY, storeUuid);
    } catch {
      /* fine */
    }
    loadCatalogue(storeUuid);
    loadSummary(storeUuid);
  }, [storeUuid, loadCatalogue, loadSummary]);

  const currency = catalogue?.store.currency ?? 'GBP';
  const products = useMemo(() => catalogue?.products ?? [], [catalogue]);
  const term = search.trim().toLowerCase();
  const shown = useMemo(
    () =>
      products.filter((p) => {
        if (category && p.category !== category) return false;
        if (inStockOnly && !p.available) return false;
        if (!term) return true;
        return (
          p.name.toLowerCase().includes(term) || p.sku?.toLowerCase().includes(term) || p.barcode?.toLowerCase().includes(term) ||
          p.variants.some((v) => v.sku?.toLowerCase().includes(term) || v.title.toLowerCase().includes(term))
        );
      }),
    [products, category, inStockOnly, term]
  );

  const qtyIn = (key: string) => lines.find((l) => l.key === key)?.quantity ?? 0;
  const qtyOfProduct = (uuid: string) => lines.filter((l) => l.product.uuid === uuid).reduce((s, l) => s + l.quantity, 0);
  /** Can one more of this be added? (stock not tracked = always) */
  const canAdd = (p: PosProduct, v: PosVariant | null) => {
    const max = stockOf(p, v);
    return max === null || qtyIn(lineKey(p, v)) < max;
  };

  const addLine = useCallback((p: PosProduct, v: PosVariant | null) => {
    const key = lineKey(p, v);
    const max = stockOf(p, v);
    setLines((ls) => {
      const have = ls.find((l) => l.key === key);
      if (max !== null && (have?.quantity ?? 0) >= max) return ls;
      return have ? ls.map((l) => (l.key === key ? { ...l, quantity: l.quantity + 1 } : l)) : [...ls, { key, product: p, variant: v, quantity: 1 }];
    });
    setNotice(null);
  }, []);

  const setQty = (key: string, q: number) =>
    setLines((ls) => (q <= 0 ? ls.filter((l) => l.key !== key) : ls.map((l) => (l.key === key ? { ...l, quantity: q } : l))));

  /** A tap on a product: one more, or choose a variation first. */
  const pick = (p: PosProduct) => {
    if (!p.available) return;
    if (p.variants.length > 0) {
      setPicking(p);
      return;
    }
    if (canAdd(p, null)) addLine(p, null);
  };

  // A scanner types the code and presses Enter: an exact barcode or SKU (of a product or a variation) is added.
  const onSearchKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Escape') {
      setSearch('');
      setNotice(null);
    }
    if (e.key !== 'Enter') return;
    const code = search.trim().toLowerCase();
    if (!code) return;
    for (const p of products) {
      const v = p.variants.find((x) => x.sku?.toLowerCase() === code) ?? null;
      if (v || (p.variants.length === 0 && (p.barcode?.toLowerCase() === code || p.sku?.toLowerCase() === code))) {
        const max = stockOf(p, v);
        const name = v ? `${p.name} — ${v.title}` : p.name;
        if (max !== null && max <= 0) setNotice(`${name} is out of stock.`);
        else if (!canAdd(p, v)) setNotice(`All ${max} of ${name} in stock are already in this sale.`);
        else {
          addLine(p, v);
          setSearch('');
        }
        return;
      }
    }
    if (shown.length === 1) {
      pick(shown[0]);
      setSearch('');
    } else {
      setNotice(`No product has the barcode or SKU “${search.trim()}”.`);
    }
  };

  const subtotal = r2(lines.reduce((s, l) => s + r2(priceOf(l) * l.quantity), 0));
  const tax = r2(subtotal * (catalogue?.store.tax_rate ?? 0));
  const disc = isAmount(discount) ? Number(discount || 0) : 0;
  const total = r2(subtotal + tax - disc);
  const cash = isAmount(tendered) && tendered.trim() !== '' ? Number(tendered) : total;
  const change = r2(cash - total);
  const itemsCount = lines.reduce((s, l) => s + l.quantity, 0);
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

  const resetSale = () => {
    setLines([]);
    setDiscount('');
    setEmail('');
    setTendered('');
    setReference('');
    setMethod('cash');
  };

  const complete = async () => {
    if (problem || !storeUuid) return;
    setSaving(true);
    setError(null);
    try {
      const r = await posService.sale(
        {
          store_uuid: storeUuid,
          items: lines.map((l) => ({ product_uuid: l.product.uuid, variant_uuid: l.variant?.uuid, quantity: l.quantity })),
          discount_amount: discount.trim() || undefined,
          customer: email.trim() ? { email: email.trim() } : undefined,
          payment: { method, tendered: method === 'cash' ? (tendered.trim() || undefined) : undefined, reference: reference.trim() || undefined },
        },
        saleKey
      );
      setReceipt(r);
      setReceiptEmail(r.customer_email ?? '');
      resetSale();
      setSaleKey(crypto.randomUUID());
      loadSummary(storeUuid);
      loadCatalogue(storeUuid);
    } catch (e) {
      setError(extractApiError(e, 'The sale could not be completed'));
      loadCatalogue(storeUuid); // stock may have changed at another till
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

  const reprint = async (uuid: string) => {
    try {
      const r = await posService.receipt(uuid);
      setReceipt(r);
      setReceiptEmail(r.customer_email ?? '');
    } catch (e) {
      toast.error(extractApiError(e, 'Could not open the receipt'));
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
        <Card className="mx-auto max-w-xl text-center">
          <Store className="mx-auto h-10 w-10 text-secondary-300" />
          <h2 className="mt-3 text-lg font-semibold text-secondary-900">Set up a store to start selling</h2>
          <p className="mt-1 text-sm text-secondary-600">
            The till sells the products of one of your stores. Create a store, add its products (price, SKU, barcode, stock and
            any variations such as sizes), then come back here.
          </p>
          <div className="mt-4 flex justify-center gap-2">
            <Link href="/dashboard/stores"><Button>Set up a store</Button></Link>
            <Link href="/dashboard/products"><Button variant="outline">Products</Button></Link>
          </div>
        </Card>
      </div>
    );
  }

  const storeName = catalogue?.store.name ?? stores?.find((s) => s.uuid === storeUuid)?.name;

  return (
    <div className="space-y-4">
      <PageHeader
        title="Point of Sale"
        description="Sell in person: tap or scan products, take payment and give a receipt."
        icon={<Store className="h-5 w-5" />}
        actions={
          <div className="flex flex-wrap items-center gap-2">
            {!showGuide && (
              <Button variant="ghost" size="sm" leftIcon={<Info className="h-4 w-4" />} onClick={() => toggleGuide(true)}>How it works</Button>
            )}
            <Link href="/dashboard/orders" className="text-sm font-medium text-primary-600 hover:underline">Sales Orders</Link>
          </div>
        }
      />

      {/* Where the products come from */}
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-xl border border-secondary-200 bg-surface px-4 py-3 text-sm">
        <span className="flex items-center gap-2 text-secondary-700">
          <Store className="h-4 w-4 text-secondary-400" /> Selling from
          {stores && stores.length > 1 ? (
            <select
              aria-label="Store"
              className="rounded-lg border border-secondary-300 bg-surface px-2 py-1 text-sm font-medium"
              value={storeUuid}
              onChange={(e) => {
                setStoreUuid(e.target.value);
                setLines([]);
                setCategory('');
              }}
            >
              <option value="">Choose a store</option>
              {stores.map((s) => <option key={s.uuid} value={s.uuid}>{s.name}</option>)}
            </select>
          ) : (
            <strong className="text-secondary-900">{storeName ?? '…'}</strong>
          )}
        </span>
        {catalogue && (
          <span className="text-secondary-500">
            {`${catalogue.products.length} product${catalogue.products.length === 1 ? '' : 's'} from Stores & Products`}
            {(catalogue.store.tax_rate ?? 0) > 0 && ` · prices plus ${r2(catalogue.store.tax_rate * 100)}% tax`}
          </span>
        )}
        <Link href="/dashboard/products" className="font-medium text-primary-600 hover:underline">Manage products, stock &amp; variations</Link>
        {summary && (
          <span className="ml-auto rounded-full bg-secondary-100 px-3 py-1 text-xs text-secondary-700" title={`${summary.date} (${summary.timezone})`}>
            Today: {summary.sales} sale{summary.sales === 1 ? '' : 's'} · {money(summary.total, summary.currency)}
            {summary.by_method.length > 0 && ` (${summary.by_method.map((m) => `${m.label} ${money(m.total, summary.currency)}`).join(', ')})`}
          </span>
        )}
      </div>

      {showGuide && <Guide storeName={storeName} onHide={() => toggleGuide(false)} />}
      {error && <p className="rounded-lg bg-error-50 px-3 py-2 text-sm text-error-700" role="alert">{error}</p>}
      {stores === null && <p className="text-sm text-secondary-500">Loading…</p>}
      {stores && !storeUuid && <Card><p className="text-sm text-secondary-700">Choose the store you are selling from (above).</p></Card>}

      {storeUuid && (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-12">
          <div className="space-y-3 lg:col-span-8">
            <Card padding="md" className="space-y-3">
              <Input
                ref={searchRef}
                autoFocus
                aria-label="Find or scan a product"
                placeholder="Find a product by name or SKU, or scan its barcode"
                leftIcon={search ? <Search className="h-4 w-4" /> : <ScanLine className="h-4 w-4" />}
                value={search}
                onChange={(e) => {
                  setSearch(e.target.value);
                  setNotice(null);
                }}
                onKeyDown={onSearchKey}
              />
              <div className="flex flex-wrap items-center gap-2">
                {[{ name: '' }, ...(catalogue?.categories ?? [])].map((c) => (
                  <button
                    key={c.name || 'all'}
                    type="button"
                    aria-pressed={category === c.name}
                    onClick={() => setCategory(c.name)}
                    className={cn('flex items-center gap-1 rounded-full border px-3 py-1 text-sm',
                      category === c.name ? 'border-primary-500 bg-primary-50 text-primary-700' : 'border-secondary-200 text-secondary-700 hover:bg-secondary-50')}
                  >
                    {c.name ? <><Tag className="h-3 w-3" /> {c.name}</> : 'All products'}
                  </button>
                ))}
                <label className="ml-auto flex items-center gap-2 text-sm text-secondary-600">
                  <input type="checkbox" className="h-4 w-4 rounded border-secondary-300" checked={inStockOnly} onChange={(e) => setInStockOnly(e.target.checked)} />
                  In stock only
                </label>
              </div>
              {notice && (
                <p className="flex items-center gap-2 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-800" role="status">
                  <Info className="h-4 w-4 shrink-0" /> {notice}
                </p>
              )}
            </Card>

            {catalogue === null ? (
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4">
                {Array.from({ length: 8 }).map((_, i) => <div key={i} className="h-44 animate-pulse rounded-2xl bg-secondary-100" />)}
              </div>
            ) : products.length === 0 ? (
              <Card className="text-center">
                <PackagePlus className="mx-auto h-10 w-10 text-secondary-300" />
                <h3 className="mt-2 font-semibold text-secondary-900">No products in this store yet</h3>
                <p className="mt-1 text-sm text-secondary-600">Add products with a price (and a barcode to scan them). Turn on stock tracking to sell only what you have.</p>
                <Link href="/dashboard/products" className="mt-3 inline-flex"><Button>Add products</Button></Link>
              </Card>
            ) : shown.length === 0 ? (
              <Card><p className="text-sm text-secondary-500">Nothing matches. Clear the search or pick another category.</p></Card>
            ) : (
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4">
                {shown.map((p) => {
                  const hasVariants = p.variants.length > 0;
                  const key = lineKey(p, null);
                  const n = hasVariants ? qtyOfProduct(p.uuid) : qtyIn(key);
                  const left = p.stock === null ? null : Math.max(0, p.stock - n);
                  const atMax = !hasVariants && p.stock !== null && n >= p.stock;
                  return (
                    <div
                      key={p.uuid}
                      className={cn('group relative flex flex-col overflow-hidden rounded-2xl border bg-surface transition',
                        !p.available ? 'border-secondary-200 opacity-60' : n > 0 ? 'border-primary-400 ring-1 ring-primary-200' : 'border-secondary-200 hover:border-primary-300 hover:shadow-md')}
                    >
                      <button
                        type="button"
                        onClick={() => pick(p)}
                        disabled={!p.available || atMax}
                        aria-label={`${p.name}, ${money(p.price, currency)}${!p.available ? ', out of stock' : ''}`}
                        className="flex flex-1 flex-col text-left disabled:cursor-not-allowed"
                      >
                        <div className="relative h-24 w-full">
                          {p.image ? (
                            // eslint-disable-next-line @next/next/no-img-element
                            <img src={p.image} alt="" className="h-full w-full object-cover" />
                          ) : (
                            <div className={cn('flex h-full w-full items-center justify-center text-2xl font-bold', tileTone(p.name))}>{initials(p.name)}</div>
                          )}
                          {n > 0 && (
                            <span className="absolute right-2 top-2 rounded-full bg-primary-600 px-2 py-0.5 text-xs font-bold text-white shadow" aria-label={`${n} in this sale`}>{n}</span>
                          )}
                          {!p.available && (
                            <span className="absolute inset-x-0 bottom-0 bg-secondary-900/70 py-1 text-center text-xs font-medium text-white">Out of stock</span>
                          )}
                        </div>
                        <div className="flex flex-1 flex-col gap-1 p-3">
                          <span className="line-clamp-2 text-sm font-medium leading-snug text-secondary-900">{p.name}</span>
                          <span className="text-[11px] text-secondary-400">
                            {[p.sku, p.category].filter(Boolean).join(' · ') || ' '}
                          </span>
                          <span className="mt-auto flex items-end justify-between gap-2">
                            <span className="font-semibold tabular-nums text-secondary-900">
                              {hasVariants && new Set(p.variants.map((v) => v.price)).size > 1 ? 'from ' : ''}
                              {money(hasVariants ? Math.min(...p.variants.map((v) => Number(v.price))) : p.price, currency)}
                            </span>
                            {hasVariants ? (
                              <span className="rounded-full bg-violet-50 px-2 py-0.5 text-[11px] font-medium text-violet-700">{p.variants.length} options</span>
                            ) : (
                              n > 0 && left === 0 ? null : <StockPill stock={left} tracked={p.tracked} compact />
                            )}
                          </span>
                        </div>
                      </button>
                      {/* In the sale: change the quantity here, or take it out. */}
                      {n > 0 && !hasVariants && (
                        <div className="flex items-center justify-between border-t border-primary-100 bg-primary-50/60 px-2 py-1.5">
                          <button type="button" aria-label={`One fewer ${p.name}`} onClick={() => setQty(key, n - 1)}
                            className="rounded-md p-1.5 text-primary-700 hover:bg-primary-100">{n === 1 ? <Trash2 className="h-4 w-4" /> : <Minus className="h-4 w-4" />}</button>
                          <span className="text-xs font-medium text-primary-800">{atMax ? `All ${p.stock} in this sale` : `${n} in this sale`}</span>
                          <button type="button" aria-label={`One more ${p.name}`} onClick={() => addLine(p, null)} disabled={atMax}
                            className="rounded-md p-1.5 text-primary-700 hover:bg-primary-100 disabled:cursor-not-allowed disabled:opacity-40"><Plus className="h-4 w-4" /></button>
                        </div>
                      )}
                      {n > 0 && hasVariants && (
                        <button type="button" onClick={() => setPicking(p)} className="border-t border-primary-100 bg-primary-50/60 px-2 py-2 text-xs font-medium text-primary-800 hover:bg-primary-100">
                          {n} in this sale · change
                        </button>
                      )}
                    </div>
                  );
                })}
              </div>
            )}

            {summary && summary.recent.length > 0 && (
              <Card padding="md">
                <h3 className="text-sm font-semibold text-secondary-900">Today at this till</h3>
                <ul className="mt-2 divide-y divide-secondary-100">
                  {summary.recent.map((s) => (
                    <li key={s.uuid} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                      <span className="min-w-0">
                        <span className="font-mono text-secondary-900">{s.order_number}</span>
                        <span className="ml-2 text-xs text-secondary-500">
                          {new Date(s.sold_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })} · {s.items} item{s.items === 1 ? '' : 's'}
                          {s.method ? ` · ${s.method}` : ''}
                        </span>
                      </span>
                      <span className="flex items-center gap-3">
                        <span className="font-medium tabular-nums">{money(s.total, currency)}</span>
                        <Button variant="ghost" size="sm" leftIcon={<ReceiptText className="h-3.5 w-3.5" />} onClick={() => reprint(s.uuid)}>Receipt</Button>
                      </span>
                    </li>
                  ))}
                </ul>
              </Card>
            )}
          </div>

          <Card className="h-fit space-y-4 lg:sticky lg:top-4 lg:col-span-4">
            <div className="flex items-center justify-between">
              <h2 className="flex items-center gap-2 text-base font-semibold text-secondary-900">
                <ReceiptText className="h-4 w-4" /> This sale {itemsCount > 0 && <span className="text-sm font-normal text-secondary-500">({itemsCount} item{itemsCount === 1 ? '' : 's'})</span>}
              </h2>
              {lines.length > 0 && <Button variant="ghost" size="sm" onClick={resetSale}>Clear</Button>}
            </div>
            {lines.length === 0 ? (
              <div className="rounded-xl border border-dashed border-secondary-200 p-6 text-center text-sm text-secondary-500">
                <ShoppingBag className="mx-auto mb-2 h-6 w-6 text-secondary-300" />
                Tap a product or scan a barcode to start a sale.
              </div>
            ) : (
              <ul className="divide-y divide-secondary-100">
                {lines.map((l) => {
                  const max = stockOf(l.product, l.variant);
                  const atMax = max !== null && l.quantity >= max;
                  return (
                    <li key={l.key} className="py-2">
                      <div className="flex items-center gap-2">
                        <div className="min-w-0 flex-1">
                          <p className="truncate text-sm text-secondary-900">{l.product.name}</p>
                          <p className="text-xs tabular-nums text-secondary-500">
                            {l.variant ? `${l.variant.title} · ` : ''}{money(priceOf(l), currency)} each
                          </p>
                        </div>
                        <div className="flex items-center gap-1">
                          <button type="button" aria-label={`One fewer ${l.product.name}`} className="rounded-md border border-secondary-200 p-1.5 hover:bg-secondary-50"
                            onClick={() => setQty(l.key, l.quantity - 1)}><Minus className="h-3.5 w-3.5" /></button>
                          <span className="w-7 text-center text-sm tabular-nums">{l.quantity}</span>
                          <button type="button" aria-label={`One more ${l.product.name}`} disabled={atMax}
                            className="rounded-md border border-secondary-200 p-1.5 hover:bg-secondary-50 disabled:cursor-not-allowed disabled:opacity-40"
                            onClick={() => addLine(l.product, l.variant)}><Plus className="h-3.5 w-3.5" /></button>
                        </div>
                        <span className="w-20 text-right text-sm tabular-nums">{money(r2(priceOf(l) * l.quantity), currency)}</span>
                        <button type="button" aria-label={`Remove ${l.product.name}`} className="p-1 text-secondary-400 hover:text-error-600"
                          onClick={() => setQty(l.key, 0)}><Trash2 className="h-4 w-4" /></button>
                      </div>
                      {atMax && <p className="mt-1 text-[11px] text-amber-700">That’s all {max} in stock.</p>}
                    </li>
                  );
                })}
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
                    className={cn('flex flex-col items-center gap-1 rounded-lg border py-2 text-sm', method === v ? 'border-primary-500 bg-primary-50 text-primary-700' : 'border-secondary-200 hover:bg-secondary-50')}>
                    <Icon className="h-4 w-4" /> {l}
                  </button>
                ))}
              </div>
              {method === 'cash' ? (
                <div className="mt-3 space-y-2">
                  <Input label="Cash given" id="pos-cash" inputMode="decimal" placeholder={total > 0 ? total.toFixed(2) : '0.00'} value={tendered} onChange={(e) => setTendered(e.target.value)} />
                  <div className="flex flex-wrap gap-1.5">
                    {quick.map((v) => (
                      <button key={v} type="button" onClick={() => setTendered(v.toFixed(2))} className="rounded-full border border-secondary-200 px-2.5 py-1 text-xs tabular-nums hover:bg-secondary-50">
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

            {problem && lines.length > 0 && <p className="text-xs text-amber-700">{problem}</p>}
            <Button className="w-full" size="lg" onClick={complete} isLoading={saving} disabled={!!problem}>
              Complete sale · {money(Math.max(0, total), currency)}
            </Button>
          </Card>
        </div>
      )}

      {/* Choose a variation (size, colour, …) */}
      {picking && (
        <Modal isOpen={!!picking} onClose={() => setPicking(null)} title={`Which ${picking.name}?`} description="Choose the option being sold." size="md"
          footer={<Button onClick={() => setPicking(null)}>Done</Button>}>
          <ul className="space-y-2">
            {picking.variants.map((v) => {
              const key = lineKey(picking, v);
              const n = qtyIn(key);
              const out = v.stock !== null && v.stock <= 0;
              const atMax = v.stock !== null && n >= v.stock;
              return (
                <li key={v.uuid} className={cn('flex items-center gap-3 rounded-xl border p-3', n > 0 ? 'border-primary-300 bg-primary-50/50' : 'border-secondary-200', out && 'opacity-60')}>
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium text-secondary-900">{v.title}</p>
                    <p className="text-xs text-secondary-500">{[v.sku, money(v.price, currency)].filter(Boolean).join(' · ')}</p>
                  </div>
                  {atMax && n > 0 ? (
                    <span className="text-[11px] font-medium text-primary-700">All {v.stock} in this sale</span>
                  ) : (
                    <StockPill stock={v.stock === null ? null : Math.max(0, v.stock - n)} tracked={v.stock !== null} />
                  )}
                  {n > 0 ? (
                    <div className="flex items-center gap-1">
                      <button type="button" aria-label={`One fewer ${v.title}`} className="rounded-md border border-secondary-200 p-1.5 hover:bg-secondary-50" onClick={() => setQty(key, n - 1)}><Minus className="h-3.5 w-3.5" /></button>
                      <span className="w-6 text-center text-sm tabular-nums">{n}</span>
                      <button type="button" aria-label={`One more ${v.title}`} disabled={atMax} className="rounded-md border border-secondary-200 p-1.5 hover:bg-secondary-50 disabled:opacity-40" onClick={() => addLine(picking, v)}><Plus className="h-3.5 w-3.5" /></button>
                    </div>
                  ) : (
                    <Button size="sm" variant="outline" disabled={out} onClick={() => addLine(picking, v)}>{out ? 'Out of stock' : 'Add'}</Button>
                  )}
                </li>
              );
            })}
          </ul>
        </Modal>
      )}

      {receipt && (
        <Modal
          isOpen={!!receipt}
          onClose={newSale}
          title={`Sale ${receipt.order_number}`}
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
