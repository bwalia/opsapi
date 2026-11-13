'use client';

import React, { useState } from 'react';
import { useRouter } from 'next/navigation';
import { AlertTriangle, Info } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Modal, Textarea } from '@/components/ui';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import type { ShopQuote } from '@/types/shop';
import { PO_NUMBER_MAX } from './workflow';

export const REVISION_POLICY =
  'Revisions are for small corrections. For different products, quantities or a different customer, create a new quote instead.';

/**
 * Revise a quote or Order Authorisation: a copy numbered <original>-R<n> with the same lines and prices,
 * starting as a draft; this one is cancelled and points at it. Goes straight to the new revision.
 */
export function ReviseQuoteModal({ quote, open, onClose }: { quote: ShopQuote; open: boolean; onClose: () => void }) {
  const router = useRouter();
  const [reason, setReason] = useState('');
  const [po, setPo] = useState(quote.customer_po_number ?? '');
  const [method, setMethod] = useState(quote.delivery_method ?? '');
  const [saving, setSaving] = useState(false);
  const isOrder = quote.kind === 'order';
  const reasonOk = reason.trim().length >= 3;
  const poOk = po.trim().length <= PO_NUMBER_MAX;

  const submit = async () => {
    if (!reasonOk || !poOk) return;
    setSaving(true);
    try {
      const body: Parameters<typeof shopService.reviseQuote>[1] = { reason: reason.trim() };
      if (po.trim() !== (quote.customer_po_number ?? '')) body.customer_po_number = po.trim() || null;
      if (method.trim() !== (quote.delivery_method ?? '')) body.delivery_method = method.trim();
      const r = await shopService.reviseQuote(quote.uuid, body);
      toast.success(`Revision ${r.quote_number} created as a draft. Check it, then send it to the customer.`);
      onClose();
      router.push(`/dashboard/shop/quotes/${r.uuid}`);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not create the revision'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      isOpen={open}
      onClose={onClose}
      title={`Revise ${quote.quote_number}`}
      description="Creates a draft copy with the same lines and prices. This one is cancelled and links to the new revision."
      size="lg"
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button isLoading={saving} disabled={saving || !reasonOk || !poOk} onClick={submit}>Create revision</Button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="flex gap-2 rounded-lg border border-warning-200 bg-warning-50 p-3 text-sm text-warning-800">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
          <p>{REVISION_POLICY}</p>
        </div>
        {quote.status === 'accepted' && (
          <div className="flex gap-2 rounded-lg border border-primary-200 bg-primary-50 p-3 text-sm text-primary-800">
            <Info className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            <p>The customer has already authorised this order; a revision needs their new authorisation.</p>
          </div>
        )}
        <Textarea
          label="Reason (kept in the internal notes) *"
          id="rev-reason"
          rows={3}
          value={reason}
          placeholder="e.g. Customer asked for delivery to their Leeds office"
          onChange={(e) => setReason(e.target.value)}
          error={reason && !reasonOk ? 'At least 3 characters' : undefined}
        />
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Input
            label="Customer PO number"
            id="rev-po"
            value={po}
            onChange={(e) => setPo(e.target.value)}
            error={!poOk ? `${PO_NUMBER_MAX} characters at most` : undefined}
          />
          <Input label="Delivery method" id="rev-method" value={method} onChange={(e) => setMethod(e.target.value)} />
        </div>
        <p className="text-xs text-secondary-500">
          Change the customer details or delivery address on the new revision before you send it.
          {isOrder ? ' The customer authorises the revision from its own link.' : ''}
        </p>
      </div>
    </Modal>
  );
}

export default ReviseQuoteModal;
