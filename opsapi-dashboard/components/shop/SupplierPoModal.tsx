'use client';

import React, { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { Button, Input, Modal, Textarea } from '@/components/ui';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import { formatMoney, poundsToMinor } from '@/lib/shop';
import type { ShopOrder, ShopSupplier } from '@/types/shop';

/**
 * Draft a supplier purchase order for a paid shop order: Bill to us (Shop → Settings), deliver
 * directly to the customer (the order's delivery address), with the supplier's cost per line.
 */
export function SupplierPoModal({ order, open, onClose }: { order: ShopOrder; open: boolean; onClose: () => void }) {
  const router = useRouter();
  const [suppliers, setSuppliers] = useState<ShopSupplier[]>([]);
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [expected, setExpected] = useState('');
  const [method, setMethod] = useState(order.delivery_method ?? '');
  const [notes, setNotes] = useState('');
  const [costs, setCosts] = useState<Record<string, string>>({});
  const [includeCustom, setIncludeCustom] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    let active = true;
    shopService
      .getSuppliers()
      .then((r) => active && setSuppliers(r))
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [open]);

  const lines = order.lines.filter((l) => includeCustom || !l.custom);
  const badCost = lines.some((l) => (costs[l.uuid] ?? '').trim() !== '' && poundsToMinor(costs[l.uuid]) === null);

  const submit = async () => {
    if (!name.trim()) {
      toast.error('Enter the supplier');
      return;
    }
    if (badCost) {
      toast.error('Check the cost prices');
      return;
    }
    setSaving(true);
    try {
      const clean: Record<string, string> = {};
      for (const l of lines) {
        const m = poundsToMinor(costs[l.uuid] ?? '');
        if (m !== null) clean[l.uuid] = (m / 100).toFixed(2);
      }
      const po = await shopService.createOrderPurchaseOrder(order.uuid, {
        supplier_name: name.trim(),
        supplier_email: email.trim() || undefined,
        supplier_phone: phone.trim() || undefined,
        expected_date: expected || undefined,
        delivery_method: method.trim() || undefined,
        notes: notes.trim() || undefined,
        costs: clean,
        include_custom: includeCustom,
      });
      toast.success(`Purchase order ${po.po_number ?? ''} drafted`);
      router.push(`/dashboard/purchase-orders/${po.uuid}`);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not create the purchase order'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={open} onClose={onClose} title={`Supplier PO for order ${order.order_number}`} description="Drafted for you to check, then send to the supplier from the purchase order page." size="2xl">
      <div className="space-y-5">
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <Input label="Supplier" id="spo-name" value={name} list="spo-suppliers" onChange={(e) => {
              setName(e.target.value);
              const s = suppliers.find((x) => x.name === e.target.value);
              const contact = (s as unknown as { contact_email?: string | null } | undefined)?.contact_email;
              if (contact && !email) setEmail(contact);
            }} />
            <datalist id="spo-suppliers">
              {suppliers.map((s) => (
                <option key={s.uuid} value={s.name} />
              ))}
            </datalist>
          </div>
          <Input label="Supplier email" id="spo-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
          <Input label="Supplier phone" id="spo-phone" value={phone} onChange={(e) => setPhone(e.target.value)} />
          <Input label="Required by" id="spo-date" type="date" value={expected} onChange={(e) => setExpected(e.target.value)} />
          <Input label="Delivery method" id="spo-method" value={method} placeholder="e.g. Courier, next working day" onChange={(e) => setMethod(e.target.value)} />
        </div>

        <div>
          <p className="mb-2 text-sm font-medium text-secondary-700">Lines and supplier cost (£ ex VAT, each)</p>
          <div className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
            {lines.map((l) => (
              <div key={l.uuid} className="flex flex-wrap items-center justify-between gap-3 px-3 py-2">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-secondary-900">{l.qty} × {l.product_name || l.label}</p>
                  <p className="text-xs text-secondary-500">Sold at {formatMoney(l.unit_price_minor, order.currency)} ex VAT each</p>
                </div>
                <div className="w-32">
                  <Input
                    aria-label={`Supplier cost for ${l.product_name || l.label}`}
                    id={`spo-cost-${l.uuid}`}
                    value={costs[l.uuid] ?? ''}
                    inputMode="decimal"
                    placeholder="0.00"
                    onChange={(e) => setCosts({ ...costs, [l.uuid]: e.target.value })}
                    error={(costs[l.uuid] ?? '').trim() && poundsToMinor(costs[l.uuid]) === null ? 'Invalid' : undefined}
                  />
                </div>
              </div>
            ))}
            {lines.length === 0 && <p className="px-3 py-4 text-sm text-secondary-500">No product lines on this order.</p>}
          </div>
          {order.lines.some((l) => l.custom) && (
            <label className="mt-2 flex items-center gap-2 text-sm text-secondary-700">
              <input type="checkbox" checked={includeCustom} onChange={(e) => setIncludeCustom(e.target.checked)} />
              Include free-text lines (e.g. services) as well
            </label>
          )}
          <p className="mt-2 text-xs text-secondary-500">Leave a cost blank to fill it in on the purchase order.</p>
        </div>

        <Textarea label="Notes for the supplier" id="spo-notes" rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} />

        <div className="flex justify-end gap-2 border-t border-secondary-200 pt-4">
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button isLoading={saving} disabled={saving || lines.length === 0} onClick={submit}>Draft purchase order</Button>
        </div>
      </div>
    </Modal>
  );
}

export default SupplierPoModal;
