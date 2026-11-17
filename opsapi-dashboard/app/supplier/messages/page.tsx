'use client';

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { MessageSquare } from 'lucide-react';
import { cn } from '@/lib/utils';
import { fmtDateTime } from '@/components/supplier-portal/shared';
import { useSupplierMe } from '@/components/supplier-portal/SupplierPortalContext';
import { portalError, supplierPortalService, type PortalMessage } from '@/services/supplier-portal.service';

/** The latest messages on every purchase order, grouped by PO. Replies are written on the PO's page. */
export default function SupplierMessagesPage() {
  const me = useSupplierMe();
  const [messages, setMessages] = useState<PortalMessage[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setMessages(await supplierPortalService.messages());
      setError(null);
    } catch (err) {
      setError(portalError(err, 'Messages could not be loaded').message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  // Newest first from the API; keep that order for the groups.
  const groups = useMemo(() => {
    const out: { po_id: string; po_number: string; items: PortalMessage[] }[] = [];
    const byPo = new Map<string, (typeof out)[number]>();
    for (const m of messages) {
      const key = m.po_id || 'unknown';
      let g = byPo.get(key);
      if (!g) {
        g = { po_id: key, po_number: m.po_number || '', items: [] };
        byPo.set(key, g);
        out.push(g);
      }
      g.items.push(m);
    }
    return out;
  }, [messages]);

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-secondary-900">Messages</h1>
        <p className="text-sm text-secondary-500">
          Your latest messages with {me?.buyer.name || 'us'}. Open a purchase order to reply.
        </p>
      </div>

      {error && <p className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">{error}</p>}

      {loading ? (
        <div className="space-y-2">
          {[0, 1].map((i) => (
            <div key={i} className="h-24 animate-pulse rounded-xl bg-secondary-100" />
          ))}
        </div>
      ) : groups.length === 0 ? (
        <div className="rounded-xl border border-secondary-200 bg-surface p-8 text-center">
          <MessageSquare className="mx-auto mb-2 h-10 w-10 text-secondary-300" />
          <p className="text-sm text-secondary-600">No messages yet.</p>
        </div>
      ) : (
        groups.map((g) => (
          <section key={g.po_id} className="rounded-xl border border-secondary-200 bg-surface shadow-sm">
            <div className="flex items-center justify-between gap-2 border-b border-secondary-200 px-4 py-3">
              <h2 className="font-medium text-secondary-900">Purchase order {g.po_number}</h2>
              <Link href={`/supplier/purchase-orders/${g.po_id}`} className="text-sm text-primary-700 hover:underline">
                Open and reply
              </Link>
            </div>
            <ul className="space-y-2 p-4">
              {g.items.slice(0, 5).reverse().map((m) => (
                <li key={m.id} className={cn('flex', m.author_kind === 'supplier' ? 'justify-end' : 'justify-start')}>
                  <div
                    className={cn(
                      'max-w-[85%] rounded-xl px-3 py-2 text-sm',
                      m.author_kind === 'supplier' ? 'bg-primary-50' : 'bg-secondary-100'
                    )}
                  >
                    <p className="whitespace-pre-line break-words text-secondary-900">{m.body}</p>
                    <p className="mt-1 text-[11px] text-secondary-500">
                      {m.author || (m.author_kind === 'staff' ? me?.buyer.name : 'You')} · {fmtDateTime(m.created_at)}
                    </p>
                  </div>
                </li>
              ))}
              {g.items.length > 5 && (
                <li className="text-center text-xs text-secondary-500">
                  {g.items.length - 5} older message{g.items.length - 5 === 1 ? '' : 's'} on the purchase order page
                </li>
              )}
            </ul>
          </section>
        ))
      )}
    </div>
  );
}
