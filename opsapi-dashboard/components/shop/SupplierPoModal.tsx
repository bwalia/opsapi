'use client';

import React, { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { AlertTriangle } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Modal, Select, Textarea } from '@/components/ui';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import { formatMoney, poundsToMinor } from '@/lib/shop';
import type { ShopOrder, ShopPurchaseOrderPreview, ShopSupplier } from '@/types/shop';

const LAST_SUPPLIER_KEY = 'opsapi.shop.lastSupplierUuid';
const OTHER = '__other__';

function readLast(): string | null {
  try {
    return window.localStorage.getItem(LAST_SUPPLIER_KEY);
  } catch {
    return null;
  }
}
function writeLast(v: string) {
  try {
    window.localStorage.setItem(LAST_SUPPLIER_KEY, v);
  } catch {
    /* private window: nothing to remember */
  }
}

function Block({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="rounded-lg border border-secondary-200 p-3">
      <p className="mb-1 text-xs font-semibold uppercase tracking-wider text-secondary-500">{title}</p>
      <div className="whitespace-pre-line text-sm text-secondary-800">{children}</div>
    </div>
  );
}

/**
 * Raise a supplier purchase order for a paid shop order, in one dialog: pick the supplier (remembers the
 * last one), costs come from the supplier's price file, Bill to (Shop → Settings) and Deliver directly to
 * (the order's delivery address) are shown before it is drafted, lines without a cost are highlighted.
 */
export function SupplierPoModal({ order, open, onClose }: { order: ShopOrder; open: boolean; onClose: () => void }) {
  const router = useRouter();
  const [suppliers, setSuppliers] = useState<ShopSupplier[] | null>(null);
  const [supplierUuid, setSupplierUuid] = useState<string>('');
  const [preview, setPreview] = useState<ShopPurchaseOrderPreview | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [expected, setExpected] = useState('');
  const [method, setMethod] = useState(order.delivery_method ?? '');
  const [notes, setNotes] = useState('');
  const [costs, setCosts] = useState<Record<string, string>>({});
  const [includeCustom, setIncludeCustom] = useState(false);
  const [saving, setSaving] = useState(false);

  // Suppliers, then the default: the last one used here, else the last on any shop PO.
  useEffect(() => {
    if (!open) return;
    let active = true;
    Promise.all([shopService.getSuppliers().catch(() => [] as ShopSupplier[]), shopService.previewOrderPurchaseOrder(order.uuid).catch(() => null)]).then(([list, p]) => {
      if (!active) return;
      setSuppliers(list);
      const last = readLast() || p?.last_supplier_uuid || '';
      setSupplierUuid(list.some((s) => s.uuid === last) ? last : list.length ? list[0].uuid : OTHER);
    });
    return () => {
      active = false;
    };
  }, [open, order.uuid]);

  // The PO as it would be for the chosen supplier.
  useEffect(() => {
    if (!open || !supplierUuid) return;
    let active = true;
    setPreviewError(null);
    shopService
      .previewOrderPurchaseOrder(order.uuid, supplierUuid === OTHER ? undefined : supplierUuid)
      .then((p) => {
        if (!active) return;
        setPreview(p);
        setName(supplierUuid === OTHER ? '' : p.supplier.name ?? '');
        setEmail(p.supplier.email ?? '');
        setPhone(p.supplier.phone ?? '');
        const c: Record<string, string> = {};
        for (const l of p.lines) if (l.cost) c[l.uuid] = l.cost;
        setCosts(c);
      })
      .catch((err) => active && setPreviewError(extractApiError(err, 'Could not prepare the purchase order')));
    return () => {
      active = false;
    };
  }, [open, order.uuid, supplierUuid]);

  const lines = useMemo(() => (preview?.lines ?? []).filter((l) => !l.custom || includeCustom), [preview, includeCustom]);
  const costOf = (uuid: string) => (costs[uuid] ?? '').trim();
  const badCost = lines.some((l) => costOf(l.uuid) !== '' && poundsToMinor(costOf(l.uuid)) === null);
  const missing = lines.filter((l) => costOf(l.uuid) === '').length;
  const sold = (uuid: string) => order.lines.find((l) => l.uuid === uuid)?.unit_price_minor;

  const submit = async () => {
    if (supplierUuid === OTHER && !name.trim()) {
      toast.error('Enter the supplier’s name');
      return;
    }
    if (badCost) {
      toast.error('Check the highlighted cost prices');
      return;
    }
    setSaving(true);
    try {
      const clean: Record<string, string> = {};
      for (const l of lines) {
        const m = poundsToMinor(costOf(l.uuid));
        if (m !== null) clean[l.uuid] = (m / 100).toFixed(2);
      }
      const po = await shopService.createOrderPurchaseOrder(order.uuid, {
        supplier_uuid: supplierUuid !== OTHER ? supplierUuid : undefined,
        supplier_name: name.trim() || undefined,
        supplier_email: email.trim() || undefined,
        supplier_phone: phone.trim() || undefined,
        expected_date: expected || undefined,
        delivery_method: method.trim() || undefined,
        notes: notes.trim() || undefined,
        costs: clean,
        include_custom: includeCustom,
      });
      if (supplierUuid !== OTHER) writeLast(supplierUuid);
      toast.success(`Purchase order ${po.po_number ?? ''} drafted. Check it, then email it to the supplier.`);
      router.push(`/dashboard/purchase-orders/${po.uuid}`);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not create the purchase order'));
    } finally {
      setSaving(false);
    }
  };

  const billTo = preview?.bill_to
    ? [preview.bill_to.company, preview.bill_to.line1, preview.bill_to.line2, [preview.bill_to.city, preview.bill_to.county, preview.bill_to.postcode].filter(Boolean).join(' '), preview.bill_to.country, preview.bill_to.phone, preview.bill_to.email, preview.bill_to.vat_number && `VAT ${preview.bill_to.vat_number}`]
        .filter(Boolean)
        .join('\n')
    : null;

  return (
    <Modal
      isOpen={open}
      onClose={onClose}
      title={`Raise supplier PO for order ${order.order_number}`}
      description="Drafted for you to check, then email it to the supplier from the purchase order page."
      size="3xl"
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button isLoading={saving} disabled={saving || !preview || lines.length === 0 || badCost} onClick={submit}>
            {missing > 0 ? `Draft PO (${missing} cost${missing > 1 ? 's' : ''} to fill in)` : 'Draft purchase order'}
          </Button>
        </>
      }
    >
      <div className="space-y-5">
        {suppliers && suppliers.length === 0 && (
          <p className="rounded-lg border border-secondary-200 bg-secondary-50 p-3 text-sm text-secondary-700">
            No suppliers set up yet. Type the supplier below, or{' '}
            <Link href="/dashboard/shop/suppliers" className="text-primary-600 hover:underline">add one under Shop → Suppliers</Link> so their details and costs fill in next time.
          </p>
        )}
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Select label="Supplier" id="spo-supplier" value={supplierUuid} onChange={(e) => setSupplierUuid(e.target.value)}>
            {(suppliers ?? []).map((s) => (
              <option key={s.uuid} value={s.uuid}>{s.name}</option>
            ))}
            <option value={OTHER}>Another supplier (type it)</option>
          </Select>
          {supplierUuid === OTHER ? (
            <Input label="Supplier name *" id="spo-name" value={name} onChange={(e) => setName(e.target.value)} />
          ) : (
            <Input label="Our account number" id="spo-acc" value={preview?.supplier.account_number ?? ''} disabled helperText={preview?.supplier.account_number ? undefined : 'Add it on Shop → Suppliers'} />
          )}
          <Input label="Supplier email" id="spo-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
          <Input label="Supplier phone" id="spo-phone" value={phone} onChange={(e) => setPhone(e.target.value)} />
          <Input label="Required by" id="spo-date" type="date" value={expected} onChange={(e) => setExpected(e.target.value)} />
          <Input label="Delivery method" id="spo-method" value={method} placeholder="e.g. Courier, next working day" onChange={(e) => setMethod(e.target.value)} />
        </div>

        {previewError && (
          <p className="rounded-lg border border-error-200 bg-error-50 p-3 text-sm text-error-700" role="alert">
            {previewError}. Close the dialog and try again; if it keeps failing, check the order is paid.
          </p>
        )}

        {preview && (
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            <Block title="Bill to (us)">
              {billTo || (
                <span className="text-warning-700">
                  Not set. <Link href="/dashboard/shop/settings" className="underline">Add it in Shop → Settings</Link> so suppliers invoice the right company.
                </span>
              )}
            </Block>
            <Block title="Deliver directly to">
              {preview.ship_to_text || <span className="text-warning-700">No delivery address on the order. Add it on the Order Authorisation, or put it in the notes.</span>}
              {preview.customer_po_number && <p className="mt-1 font-medium">End customer PO: {preview.customer_po_number}</p>}
            </Block>
          </div>
        )}

        <div>
          <p className="mb-2 text-sm font-medium text-secondary-700">Lines and supplier cost (£ ex VAT, each)</p>
          {missing > 0 && (
            <p className="mb-2 flex items-center gap-1.5 text-xs text-warning-700">
              <AlertTriangle className="h-3.5 w-3.5" aria-hidden="true" />
              {missing} line{missing > 1 ? 's have' : ' has'} no cost in this supplier’s price file. Enter it now or fill it in on the PO.
            </p>
          )}
          <div className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
            {!preview && !previewError && <p className="px-3 py-4 text-sm text-secondary-500">Preparing the purchase order…</p>}
            {lines.map((l) => {
              const empty = costOf(l.uuid) === '';
              const fromFile = l.cost_source === 'supplier_price_file' && costs[l.uuid] === l.cost;
              return (
                <div key={l.uuid} className={`flex flex-wrap items-center justify-between gap-3 px-3 py-2 ${empty ? 'bg-warning-50' : ''}`}>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium text-secondary-900">{l.qty} × {l.description.split('\n')[0]}</p>
                    <p className="text-xs text-secondary-500">
                      Sold at {formatMoney(sold(l.uuid), order.currency)} ex VAT each
                      {fromFile && ' · cost from the supplier’s price file'}
                      {empty && ' · no cost yet'}
                    </p>
                  </div>
                  <div className="w-32">
                    <Input
                      aria-label={`Supplier cost for ${l.description.split('\n')[0]}`}
                      id={`spo-cost-${l.uuid}`}
                      value={costs[l.uuid] ?? ''}
                      inputMode="decimal"
                      placeholder="0.00"
                      onChange={(e) => setCosts({ ...costs, [l.uuid]: e.target.value })}
                      error={costOf(l.uuid) && poundsToMinor(costOf(l.uuid)) === null ? 'Invalid' : undefined}
                    />
                  </div>
                </div>
              );
            })}
            {preview && lines.length === 0 && <p className="px-3 py-4 text-sm text-secondary-500">No product lines on this order. Tick “Include free-text lines” to order those.</p>}
          </div>
          {order.lines.some((l) => l.custom) && (
            <label className="mt-2 flex items-center gap-2 text-sm text-secondary-700">
              <input type="checkbox" checked={includeCustom} onChange={(e) => setIncludeCustom(e.target.checked)} />
              Include free-text lines (e.g. services) as well
            </label>
          )}
        </div>

        {preview?.notes && (
          <Block title="Printed on the PO">{preview.notes}</Block>
        )}
        <Textarea label="Extra notes for the supplier" id="spo-notes" rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} />
      </div>
    </Modal>
  );
}

export default SupplierPoModal;
