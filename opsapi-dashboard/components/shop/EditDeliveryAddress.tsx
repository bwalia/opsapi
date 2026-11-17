'use client';

import React, { useState } from 'react';
import { MapPin } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Modal, Textarea } from '@/components/ui';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import type { ShopDeliveryAddress, ShopOrder, ShopOrderStatus } from '@/types/shop';

/** Statuses where the delivery address can still change (the backend refuses the rest with 409). */
const OPEN: ShopOrderStatus[] = ['pending_payment', 'paid', 'processing'];

type Form = Required<Pick<ShopDeliveryAddress, 'name' | 'company' | 'line1' | 'line2' | 'city' | 'county' | 'postcode' | 'phone' | 'email'>>;

const str = (v: unknown) => (typeof v === 'string' ? v : '');

/** Where the order goes now: the agreed delivery address, else the address the customer gave Stripe. */
function currentAddress(order: ShopOrder): Form {
  const d = order.delivery_address;
  if (d && (d.line1 || d.postcode)) {
    return {
      name: str(d.name), company: str(d.company), line1: str(d.line1), line2: str(d.line2), city: str(d.city),
      county: str(d.county), postcode: str(d.postcode), phone: str(d.phone), email: str(d.email),
    };
  }
  const ship = (order.shipping_address ?? {}) as Record<string, unknown>;
  const a = (ship.address && typeof ship.address === 'object' ? ship.address : ship) as Record<string, unknown>;
  return {
    name: str(ship.name) || str(order.customer?.name), company: '', line1: str(a.line1), line2: str(a.line2),
    city: str(a.city), county: str(a.state), postcode: str(a.postal_code) || str(a.postcode),
    phone: str(ship.phone) || str(order.customer?.phone), email: '',
  };
}

export function canEditDeliveryAddress(order: ShopOrder): boolean {
  return OPEN.includes(order.status);
}

/** "Change delivery address" for staff: updates the order and, by default, its open drop-ship supplier POs. */
export function EditDeliveryAddress({ order, onSaved }: { order: ShopOrder; onSaved: (o: ShopOrder) => void }) {
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<Form>(() => currentAddress(order));
  const [note, setNote] = useState('');
  const [updatePos, setUpdatePos] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const openPos = (order.purchase_orders ?? []).filter((p) => !['received', 'billed', 'cancelled'].includes(p.status));

  const start = () => {
    setForm(currentAddress(order));
    setNote('');
    setUpdatePos(true);
    setError(null);
    setOpen(true);
  };

  const set = (k: keyof Form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm((f) => ({ ...f, [k]: e.target.value }));

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const res = await shopService.setDeliveryAddress(order.uuid, {
        address: form,
        staff_note: note.trim() || undefined,
        update_purchase_orders: updatePos,
      });
      setOpen(false);
      onSaved(res.order);
      const sent = res.purchase_orders.filter((p) => p.already_sent);
      if (sent.length > 0) {
        toast(
          `Delivery address changed. ${sent.map((p) => p.po_number).join(', ')} was already sent to `
            + `${sent.map((p) => p.supplier_name || 'the supplier').join(', ')}: re-send it or tell them the new address.`,
          { icon: '⚠️', duration: 12000 },
        );
      } else {
        toast.success(res.purchase_orders.length > 0 ? 'Delivery address changed on the order and supplier PO' : 'Delivery address changed');
      }
    } catch (err) {
      setError(extractApiError(err, 'Could not change the delivery address'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <Button size="sm" variant="ghost" leftIcon={<MapPin className="h-4 w-4" />} onClick={start}>
        Change delivery address
      </Button>
      <Modal
        isOpen={open}
        onClose={() => setOpen(false)}
        title="Change delivery address"
        description="Where this order is delivered. UK addresses only. The old address is kept in the internal notes."
        size="lg"
        footer={
          <>
            <Button variant="ghost" onClick={() => setOpen(false)}>Cancel</Button>
            <Button isLoading={saving} onClick={save}>Save address</Button>
          </>
        }
      >
        <div className="grid gap-3 sm:grid-cols-2">
          <Input label="Recipient name" id="da-name" value={form.name} onChange={set('name')} required />
          <Input label="Company (leave blank for a home address)" id="da-company" value={form.company} onChange={set('company')} />
          <Input label="Address line 1" id="da-line1" value={form.line1} onChange={set('line1')} required />
          <Input label="Address line 2" id="da-line2" value={form.line2} onChange={set('line2')} />
          <Input label="Town or city" id="da-city" value={form.city} onChange={set('city')} required />
          <Input label="County" id="da-county" value={form.county} onChange={set('county')} />
          <Input label="Postcode" id="da-postcode" value={form.postcode} onChange={set('postcode')} required className="uppercase" />
          <Input label="Phone for the courier" id="da-phone" value={form.phone} onChange={set('phone')} />
          <Input label="Email" id="da-email" type="email" value={form.email} onChange={set('email')} />
        </div>
        <Textarea
          className="mt-3"
          label="Why (internal note, optional)"
          id="da-note"
          rows={2}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="e.g. Customer phoned: deliver to her home instead"
        />
        {openPos.length > 0 && (
          <label className="mt-3 flex items-start gap-2 text-sm text-secondary-700">
            <input type="checkbox" className="mt-0.5" checked={updatePos} onChange={(e) => setUpdatePos(e.target.checked)} />
            <span>
              Also update the delivery address on drop-ship supplier PO{openPos.length > 1 ? 's' : ''}{' '}
              {openPos.map((p) => p.po_number).join(', ')}. A PO that was already sent isn&apos;t re-sent: tell the supplier.
            </span>
          </label>
        )}
        {error && <p className="mt-3 text-sm text-error-600" role="alert">{error}</p>}
      </Modal>
    </>
  );
}
