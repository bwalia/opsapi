'use client';

import React, { useState } from 'react';
import { ArrowRight, Check, Truck, X } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card, Modal, Textarea } from '@/components/ui';
import { SectionTitle } from '@/components/shop/shared';
import { shopService } from '@/services/shop.service';
import { extractApiError, formatDateTime } from '@/lib/utils';
import type { ShopDeliveryAddress, ShopDeliveryChangeRequest, ShopDeliveryWindow, ShopOrder } from '@/types/shop';

export const DELIVERY_WINDOW_LABEL: Record<ShopDeliveryWindow, string> = {
  all_day: 'Any time',
  am: 'Morning',
  pm: 'Afternoon',
};

/** "Tue 18 Nov 2026" from YYYY-MM-DD (no time zone shift). */
export function formatDeliveryDate(d: string | null | undefined): string {
  if (!d) return 'Not set';
  const [y, m, day] = d.split('-').map(Number);
  if (!y || !m || !day) return d;
  return new Date(Date.UTC(y, m - 1, day)).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
}

export function deliveryAddressLine(a: ShopDeliveryAddress | null | undefined): string {
  if (!a) return 'Not set';
  const s = [a.name, a.company, a.line1, a.line2, a.city, a.county, a.postcode, a.country && a.country !== 'GB' ? a.country : null]
    .filter(Boolean)
    .join(', ');
  return s || 'Not set';
}

const STATUS_STYLE: Record<ShopDeliveryChangeRequest['status'], string> = {
  pending: 'bg-warning-50 text-warning-800',
  approved: 'bg-success-50 text-success-700',
  declined: 'bg-error-50 text-error-700',
  cancelled: 'bg-secondary-100 text-secondary-600',
};

const STATUS_LABEL: Record<ShopDeliveryChangeRequest['status'], string> = {
  pending: 'Waiting for you',
  approved: 'Approved',
  declined: 'Declined',
  cancelled: 'Cancelled by the customer',
};

const CLOSED_ORDER = ['shipped', 'delivered', 'cancelled', 'refunded', 'payment_failed'];

function Change({ label, from, to }: { label: string; from: string; to: string | null }) {
  const changed = to !== null && to !== from;
  return (
    <div className="grid grid-cols-1 gap-1 py-1.5 text-sm sm:grid-cols-[7rem_1fr]">
      <dt className="text-xs font-semibold uppercase tracking-wider text-secondary-500 sm:pt-0.5">{label}</dt>
      <dd className="min-w-0">
        {changed ? (
          <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span className="text-secondary-500 line-through decoration-secondary-300">{from}</span>
            <ArrowRight className="h-3.5 w-3.5 shrink-0 text-secondary-400" aria-label="changes to" />
            <span className="font-medium text-secondary-900">{to}</span>
          </span>
        ) : (
          <span className="text-secondary-700">{from} <span className="text-xs text-secondary-400">(no change)</span></span>
        )}
      </dd>
    </div>
  );
}

/**
 * "Delivery change requests" on the order page: what the customer asked for (old → new) and Approve /
 * Decline. Approving applies the address, date and time window to the order; the customer is only
 * emailed while Shop settings → "Customer emails from the shop" is on.
 */
export function DeliveryChangeRequests({ order, editable, onChanged }: { order: ShopOrder; editable: boolean; onChanged: (o: ShopOrder) => void }) {
  const requests = order.delivery_change_requests ?? [];
  const [acting, setActing] = useState<{ request: ShopDeliveryChangeRequest; action: 'approve' | 'decline' } | null>(null);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [showAll, setShowAll] = useState(false);

  if (requests.length === 0) return null;
  const visible = showAll ? requests : requests.slice(0, 3);
  const orderClosed = CLOSED_ORDER.includes(order.status);

  const open = (request: ShopDeliveryChangeRequest, action: 'approve' | 'decline') => {
    setNote('');
    setActing({ request, action });
  };

  const submit = async () => {
    if (!acting) return;
    if (acting.action === 'decline' && note.trim().length < 3) {
      toast.error('Give the customer a reason');
      return;
    }
    setBusy(true);
    try {
      const res =
        acting.action === 'approve'
          ? await shopService.approveDeliveryChange(order.uuid, acting.request.uuid, note.trim())
          : await shopService.declineDeliveryChange(order.uuid, acting.request.uuid, note.trim());
      const what = acting.action === 'approve' ? 'approved: the order now has the new delivery details' : 'declined';
      toast.success(
        `Delivery change ${what}. ${res.customer_notified ? 'The customer has been emailed.' : 'The customer has not been emailed; they see it on their order page.'}`,
        { duration: 6000 },
      );
      setActing(null);
      if (res.order?.uuid) onChanged(res.order);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not save the decision'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card className="print:hidden">
      <SectionTitle>
        <span className="inline-flex items-center gap-2">
          <Truck className="h-4 w-4 text-secondary-500" /> Delivery change requests
        </span>
      </SectionTitle>
      <ul className="space-y-4">
        {visible.map((r) => {
          const prevAddr = deliveryAddressLine(r.previous_delivery_address);
          const newAddr = deliveryAddressLine(r.requested_address);
          return (
            <li key={r.uuid} className={`rounded-lg border p-3 ${r.status === 'pending' ? 'border-warning-300 bg-warning-50/40' : 'border-secondary-200'}`}>
              <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_STYLE[r.status]}`}>{STATUS_LABEL[r.status]}</span>
                <span className="text-xs text-secondary-500">
                  {formatDateTime(r.created_at)} · {r.requested_by_email}
                </span>
              </div>
              <dl className="divide-y divide-secondary-100">
                <Change label="Address" from={prevAddr} to={newAddr} />
                {r.requested_address.phone && <Change label="Phone" from={r.previous_delivery_address?.phone || 'Not set'} to={r.requested_address.phone} />}
                <Change label="Date" from={formatDeliveryDate(r.previous_delivery_date)} to={r.requested_date ? formatDeliveryDate(r.requested_date) : null} />
                <Change
                  label="Time"
                  from={r.previous_delivery_window ? DELIVERY_WINDOW_LABEL[r.previous_delivery_window] : 'Not set'}
                  to={r.requested_window ? DELIVERY_WINDOW_LABEL[r.requested_window] : null}
                />
              </dl>
              {r.customer_note && (
                <p className="mt-2 whitespace-pre-line rounded bg-secondary-50 p-2 text-sm text-secondary-700">
                  <span className="block text-xs font-semibold uppercase tracking-wider text-secondary-500">Customer note</span>
                  {r.customer_note}
                </p>
              )}
              {r.decided_at && (
                <p className="mt-2 text-xs text-secondary-500">
                  {r.status === 'approved' ? 'Approved' : 'Declined'} by {r.decided_by ?? 'staff'} {formatDateTime(r.decided_at)}
                  {r.customer_notified_at ? ' · customer emailed' : ' · customer not emailed'}
                </p>
              )}
              {r.staff_note && (
                <p className="mt-1 whitespace-pre-line text-sm text-secondary-700">
                  <span className="text-xs font-semibold uppercase tracking-wider text-secondary-500">Note to the customer: </span>
                  {r.staff_note}
                </p>
              )}
              {r.status === 'pending' && editable && (
                <div className="mt-3 flex flex-wrap items-center gap-2">
                  <Button size="sm" leftIcon={<Check className="h-4 w-4" />} disabled={orderClosed} onClick={() => open(r, 'approve')}>
                    Approve
                  </Button>
                  <Button size="sm" variant="ghost" leftIcon={<X className="h-4 w-4" />} onClick={() => open(r, 'decline')}>
                    Decline
                  </Button>
                  {orderClosed && <span className="text-xs text-secondary-500">The order is {order.status.replace('_', ' ')}: decline it and contact the customer.</span>}
                </div>
              )}
            </li>
          );
        })}
      </ul>
      {requests.length > 3 && (
        <button type="button" className="mt-3 text-sm text-primary-600 hover:underline" onClick={() => setShowAll((v) => !v)}>
          {showAll ? 'Show fewer' : `Show all ${requests.length}`}
        </button>
      )}

      <Modal
        isOpen={!!acting}
        onClose={() => !busy && setActing(null)}
        title={acting?.action === 'approve' ? 'Approve this delivery change?' : 'Decline this delivery change?'}
        description={
          acting?.action === 'approve'
            ? 'The order’s delivery address, date and time are replaced with what the customer asked for. Check the courier can do it first.'
            : 'The order keeps its current delivery details.'
        }
        size="md"
        footer={
          <>
            <Button variant="ghost" onClick={() => setActing(null)} disabled={busy}>
              Cancel
            </Button>
            <Button variant={acting?.action === 'approve' ? 'primary' : 'danger'} isLoading={busy} onClick={submit}>
              {acting?.action === 'approve' ? 'Approve' : 'Decline'}
            </Button>
          </>
        }
      >
        {acting && (
          <div className="space-y-3">
            <dl className="divide-y divide-secondary-100 rounded-lg border border-secondary-200 px-3">
              <Change label="Address" from={deliveryAddressLine(acting.request.previous_delivery_address)} to={deliveryAddressLine(acting.request.requested_address)} />
              <Change label="Date" from={formatDeliveryDate(acting.request.previous_delivery_date)} to={acting.request.requested_date ? formatDeliveryDate(acting.request.requested_date) : null} />
              <Change
                label="Time"
                from={acting.request.previous_delivery_window ? DELIVERY_WINDOW_LABEL[acting.request.previous_delivery_window] : 'Not set'}
                to={acting.request.requested_window ? DELIVERY_WINDOW_LABEL[acting.request.requested_window] : null}
              />
            </dl>
            <Textarea
              id="delivery-change-note"
              label={acting.action === 'approve' ? 'Note to the customer (optional)' : 'Reason (shown to the customer)'}
              value={note}
              onChange={(e) => setNote(e.target.value)}
              rows={3}
              maxLength={1000}
              placeholder={acting.action === 'approve' ? 'e.g. Booked with the courier for the morning' : 'e.g. The courier can’t deliver there on that day'}
              helperText="The customer sees this on their order page."
            />
          </div>
        )}
      </Modal>
    </Card>
  );
}
