'use client';

/**
 * "VAT invoice check" on an invoice: what a valid UK VAT invoice must show and this
 * one is missing (VAT Notice 700/21), VAT by rate, and the reverse-charge wording to
 * add. Hidden when the deployment has no VAT feature (the API answers 404).
 * Backend: GET /api/v2/vat/invoices/:uuid/check (lapis/lib/vat-invoice.lua).
 */

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { AlertTriangle, CheckCircle2, FileCode2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { formatCurrency } from '@/lib/utils';
import vatService, { type EinvoiceCheck, type VatInvoiceCheckResult } from '@/services/vat.service';

const gbp = (n: number) => formatCurrency(n, 'GBP', 'en-GB');

export default function VatInvoiceCheck({ invoiceUuid, refreshKey }: { invoiceUuid: string; refreshKey?: unknown }) {
  const [res, setRes] = useState<VatInvoiceCheckResult | null>(null);
  const [einv, setEinv] = useState<EinvoiceCheck | null>(null);
  useEffect(() => {
    let live = true;
    vatService.checkInvoice(invoiceUuid).then((r) => { if (live) setRes(r); }).catch(() => { if (live) setRes(null); });
    return () => { live = false; };
  }, [invoiceUuid, refreshKey]);
  const checkEinvoice = () => vatService.einvoiceCheckInvoice(invoiceUuid).then((r) => setEinv(r.check))
    .catch((e) => toast.error(e?.response?.data?.error || 'Could not build the e-invoice'));
  if (!res) return null;
  const missing = Array.isArray(res.missing) ? res.missing : [];
  const breakdown = Array.isArray(res.breakdown) ? res.breakdown : [];
  return (
    <div className="rounded-xl border border-secondary-200 bg-surface p-5 shadow-sm" data-testid="vat-invoice-check">
      <div className="flex items-center gap-2">
        {res.ok ? <CheckCircle2 className="h-5 w-5 text-green-600" /> : <AlertTriangle className="h-5 w-5 text-amber-600" />}
        <h3 className="font-medium text-secondary-900">
          {res.ok ? 'This is a valid VAT invoice' : 'Before sending this as a VAT invoice'}
        </h3>
      </div>
      {missing.length > 0 && (
        <ul className="mt-2 space-y-1 text-sm text-amber-900">
          {missing.map((m) => <li key={m}>• Add: {m}</li>)}
        </ul>
      )}
      {res.simplified_allowed && !res.ok && (
        <p className="mt-2 text-xs text-secondary-600">Up to £250 including VAT, a simplified invoice is fine (no
          customer details needed).</p>
      )}
      {res.reverse_charge_text && (
        <p className="mt-2 text-sm text-secondary-700">Show this wording on the invoice: <strong>{res.reverse_charge_text}</strong></p>
      )}
      {breakdown.length > 0 && (
        <div className="mt-3 text-sm">
          {breakdown.map((b) => (
            <div key={b.vat_code} className="flex justify-between border-t border-secondary-100 py-1">
              <span className="text-secondary-700">{b.label}</span>
              <span className="tabular-nums">net {gbp(b.net)} · VAT {gbp(b.vat)}</span>
            </div>
          ))}
        </div>
      )}
      <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-secondary-100 pt-3 text-sm">
        <FileCode2 className="h-4 w-4 text-secondary-500" />
        <span className="text-secondary-700">E-invoice (Peppol UBL)</span>
        <button type="button" className="text-primary-700 underline" onClick={checkEinvoice}>Check</button>
        <button type="button" className="text-primary-700 underline" onClick={() => vatService.downloadEinvoice(invoiceUuid)
          .catch((e) => toast.error(e?.response?.status === 409 ? 'Issue the invoice first' : 'Download failed'))}>Download XML</button>
      </div>
      {einv && (
        <div className={`mt-2 rounded-lg p-2 text-xs ${einv.valid ? 'bg-green-50 text-green-900' : 'bg-amber-50 text-amber-900'}`}
          data-testid="vat-einvoice-check">
          {einv.valid ? 'Passes the Peppol BIS 3.0 checks.' : 'Fix these before sending it as an e-invoice:'}
          {(Array.isArray(einv.errors) ? einv.errors : []).map((e) => <p key={e.rule + e.message}>• {e.message} ({e.rule})</p>)}
          {(Array.isArray(einv.warnings) ? einv.warnings : []).map((w) => <p key={w}>{w}</p>)}
        </div>
      )}
      {!res.supplier_vrn && (
        <p className="mt-2 text-xs"><Link href="/dashboard/tax/vat?scope=namespace" className="text-primary-700 underline">
          Add the workspace&apos;s VAT registration</Link></p>
      )}
    </div>
  );
}
