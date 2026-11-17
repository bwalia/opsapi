'use client';

import React, { useState } from 'react';
import { Eye, Mail, MapPin, MessageSquare, RefreshCw, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card, Textarea } from '@/components/ui';
import { SectionTitle } from '@/components/shop/shared';
import { shopService } from '@/services/shop.service';
import { extractApiError, formatDateTime } from '@/lib/utils';
import { humanize } from '@/lib/shop';
import type { ShopCustomerUpdate, ShopOrder } from '@/types/shop';

const MAX = 2000;

const KIND: Record<ShopCustomerUpdate['kind'], { label: string; icon: React.ReactNode }> = {
  comment: { label: 'Update', icon: <MessageSquare className="h-4 w-4" /> },
  status: { label: 'Status', icon: <RefreshCw className="h-4 w-4" /> },
  delivery_address: { label: 'Delivery address changed', icon: <MapPin className="h-4 w-4" /> },
  delivery_change: { label: 'Delivery change approved', icon: <MapPin className="h-4 w-4" /> },
  email: { label: 'Emailed the customer', icon: <Mail className="h-4 w-4" /> },
};

/**
 * "Customer updates": the log the customer sees on their order page (shop /orders/:uuid). Staff post an
 * update (plain text) and can remove their own posts or logged events; emails and approved delivery
 * changes are listed for context.
 */
export function CustomerUpdates({ order, editable, onChanged }: { order: ShopOrder; editable: boolean; onChanged: () => void }) {
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const updates = order.customer_updates ?? [];
  const tooLong = message.trim().length > MAX;

  const post = async () => {
    if (!message.trim() || tooLong) return;
    setBusy('post');
    try {
      await shopService.addCustomerUpdate(order.uuid, message.trim());
      setMessage('');
      toast.success('Posted: the customer sees it on their order page');
      onChanged();
    } catch (err) {
      toast.error(extractApiError(err, 'Could not post the update'));
    } finally {
      setBusy(null);
    }
  };

  const remove = async (u: ShopCustomerUpdate) => {
    if (!u.uuid || !window.confirm('Hide this from the customer’s order page?')) return;
    setBusy(u.uuid);
    try {
      await shopService.removeCustomerUpdate(order.uuid, u.uuid);
      toast.success('Hidden from the customer');
      onChanged();
    } catch (err) {
      toast.error(extractApiError(err, 'Could not remove it'));
    } finally {
      setBusy(null);
    }
  };

  return (
    <Card className="print:hidden">
      <SectionTitle>Customer updates</SectionTitle>
      <p className="-mt-2 mb-3 flex items-center gap-1.5 text-xs text-secondary-500">
        <Eye className="h-3.5 w-3.5" /> The customer sees these on their order page, with the order’s progress. They aren’t emailed.
      </p>
      {editable && (
        <div className="mb-4">
          <Textarea
            id="customer-update"
            aria-label="Update for the customer"
            rows={3}
            value={message}
            onChange={(e) => setMessage(e.target.value)}
            placeholder="e.g. Your order has arrived with us. We can deliver today between 6 and 7pm."
            error={tooLong ? `Keep it under ${MAX} characters` : undefined}
          />
          <div className="mt-2 flex justify-end">
            <Button size="sm" isLoading={busy === 'post'} disabled={!message.trim() || tooLong} onClick={post}>
              Post update
            </Button>
          </div>
        </div>
      )}
      {updates.length === 0 ? (
        <p className="text-sm text-secondary-500">Nothing yet.</p>
      ) : (
        <ul className="space-y-3">
          {updates.map((u) => {
            const k = KIND[u.kind] ?? KIND.comment;
            return (
              <li key={`${u.kind}-${u.uuid ?? u.at}`} className="flex gap-3 text-sm">
                <span className="mt-0.5 text-secondary-400">{k.icon}</span>
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-baseline justify-between gap-x-3">
                    <span className="font-medium text-secondary-900">
                      {u.kind === 'status' && u.status ? `Status: ${humanize(u.status)}` : u.kind === 'email' && u.title ? `Emailed: ${u.title}` : k.label}
                    </span>
                    <span className="text-xs text-secondary-500">{formatDateTime(u.at)}</span>
                  </div>
                  {u.message && u.kind !== 'email' && <p className="whitespace-pre-line break-words text-secondary-700">{u.message}</p>}
                  {u.author && <p className="text-xs text-secondary-400">by {u.author}</p>}
                </div>
                {editable && u.removable && u.uuid && (
                  <button
                    type="button"
                    aria-label="Hide from the customer"
                    title="Hide from the customer"
                    className="self-start rounded p-1 text-secondary-400 hover:bg-secondary-100 hover:text-error-600 disabled:opacity-50"
                    disabled={busy === u.uuid}
                    onClick={() => remove(u)}
                  >
                    <Trash2 className="h-4 w-4" />
                  </button>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </Card>
  );
}
