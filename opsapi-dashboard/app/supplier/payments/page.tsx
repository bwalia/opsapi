'use client';

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { Download } from 'lucide-react';
import toast from 'react-hot-toast';
import { btnSmall, fmtDate, fmtMoney } from '@/components/supplier-portal/shared';
import { useSupplierMe } from '@/components/supplier-portal/SupplierPortalContext';
import { openDownload, portalError, supplierPortalService, type PortalPayment } from '@/services/supplier-portal.service';

export default function SupplierPaymentsPage() {
  const me = useSupplierMe();
  const [payments, setPayments] = useState<PortalPayment[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setPayments(await supplierPortalService.payments());
      setError(null);
    } catch (err) {
      setError(portalError(err, 'Payments could not be loaded').message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const download = async (id: string) => {
    try {
      openDownload(await supplierPortalService.documentLink(id));
    } catch (err) {
      toast.error(portalError(err, 'The download could not be started').message);
    }
  };

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-secondary-900">Payments</h1>
        <p className="text-sm text-secondary-500">
          Payments {me?.buyer.name || 'we'} sent you, newest first. Open a purchase order to see what is still to pay on it.
        </p>
      </div>

      {error && <p className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">{error}</p>}

      <div className="rounded-xl border border-secondary-200 bg-surface shadow-sm">
        {loading ? (
          <div className="space-y-2 p-4">
            {[0, 1, 2].map((i) => (
              <div key={i} className="h-12 animate-pulse rounded bg-secondary-100" />
            ))}
          </div>
        ) : payments.length === 0 ? (
          <p className="p-6 text-center text-sm text-secondary-500">No payments yet.</p>
        ) : (
          <ul className="divide-y divide-secondary-100 text-sm">
            {payments.map((p) => (
              <li key={p.id} className="flex flex-wrap items-center justify-between gap-2 px-4 py-3">
                <div>
                  <p className="font-medium text-secondary-900">
                    {fmtMoney(p.amount, p.currency)} · {p.method_label}
                  </p>
                  <p className="text-xs text-secondary-500">
                    {p.po_id && (
                      <>
                        <Link href={`/supplier/purchase-orders/${p.po_id}`} className="text-primary-700 hover:underline">
                          {p.po_number}
                        </Link>
                        {' · '}
                      </>
                    )}
                    Sent {fmtDate(p.sent_on)}
                    {p.cleared_on ? ` · cleared ${fmtDate(p.cleared_on)}` : ''}
                    {p.payment_reference ? ` · reference ${p.payment_reference}` : ''}
                    {p.against ? ` · against ${p.against.number}` : ''}
                  </p>
                </div>
                {p.proof_document_id && (
                  <button type="button" className={btnSmall} onClick={() => download(p.proof_document_id as string)}>
                    <Download className="h-3.5 w-3.5" />
                    Download payment proof
                  </button>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
