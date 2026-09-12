'use client';

/**
 * Job billing summary + "Create invoice" flow. The preview lists every
 * uninvoiced billable labour line (completed visits) and item; creating the
 * invoice stamps them so re-running only bills new work.
 */

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { AlertTriangle, ExternalLink, Receipt } from 'lucide-react';
import { Modal, Button, Input } from '@/components/ui';
import { fieldService, type FsJobDetail, type FsInvoicePreview } from '@/services/field-service.service';
import { SectionCard, apiError, hours, money, optional, optionalNumber } from './shared';

export function BillingPanel({ job, canInvoice, onChanged }: { job: FsJobDetail; canInvoice: boolean; onChanged: () => void }) {
  const [open, setOpen] = useState(false);
  const t = job.totals;
  const cur = job.currency || 'GBP';

  return (
    <SectionCard
      title="Billing"
      actions={
        canInvoice &&
        job.status !== 'draft' &&
        job.status !== 'cancelled' && (
          <Button size="sm" onClick={() => setOpen(true)} disabled={t.uninvoiced_value <= 0 && !t.missing_rate}>
            <Receipt className="w-4 h-4 mr-1" /> Create invoice
          </Button>
        )
      }
    >
      <dl className="grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
        <dt className="text-secondary-500">Labour logged</dt>
        <dd className="text-right text-secondary-900">
          {hours(t.labour_hours)}
          {t.billable_hours !== t.labour_hours && <span className="text-secondary-500"> ({hours(t.billable_hours)} billable)</span>}
        </dd>
        <dt className="text-secondary-500">Labour value</dt>
        <dd className="text-right text-secondary-900">{money(t.labour_value, cur)}</dd>
        <dt className="text-secondary-500">Parts & materials</dt>
        <dd className="text-right text-secondary-900">{money(t.items_value, cur)}</dd>
        <dt className="text-secondary-700 font-medium border-t border-secondary-100 pt-2">Not yet invoiced (net)</dt>
        <dd className="text-right font-semibold text-secondary-900 border-t border-secondary-100 pt-2">{money(t.uninvoiced_value, cur)}</dd>
      </dl>
      {t.missing_rate && (
        <p className="mt-3 flex items-start gap-2 text-xs text-amber-700 bg-amber-50 rounded-lg p-2.5">
          <AlertTriangle className="w-4 h-4 shrink-0" />
          Some billable labour has no hourly rate. Set a rate on the job, its job type or the visit — or enter a fallback rate when invoicing.
        </p>
      )}
      {t.open_visits > 0 && <p className="mt-2 text-xs text-secondary-500">{t.open_visits} visit(s) still open — their time is billed once completed.</p>}
      {job.invoice_uuid && (
        <Link
          href={`/dashboard/invoices/${job.invoice_uuid}`}
          className="mt-3 inline-flex items-center gap-1.5 text-sm text-primary-600 hover:underline"
        >
          <ExternalLink className="w-4 h-4" />
          Latest invoice {job.invoice_number}
          {job.invoice_status ? ` (${job.invoice_status})` : ''}
          {job.invoice_total != null ? ` · ${money(job.invoice_total, cur)}` : ''}
        </Link>
      )}

      <Modal isOpen={open} onClose={() => setOpen(false)} title={`Invoice ${job.job_number}`} size="xl">
        {open && <InvoiceForm job={job} onClose={() => setOpen(false)} onDone={onChanged} />}
      </Modal>
    </SectionCard>
  );
}

function InvoiceForm({ job, onClose, onDone }: { job: FsJobDetail; onClose: () => void; onDone: () => void }) {
  const [taxRate, setTaxRate] = useState('20');
  const [fallbackRate, setFallbackRate] = useState('');
  const [dueDate, setDueDate] = useState('');
  const [notes, setNotes] = useState('');
  const [preview, setPreview] = useState<FsInvoicePreview | null>(null);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);
  const cur = job.currency || 'GBP';

  const loadPreview = useCallback(async () => {
    setLoading(true);
    try {
      setPreview(
        await fieldService.getInvoicePreview(job.uuid, {
          labour_tax_rate: optionalNumber(taxRate),
          hourly_rate: optionalNumber(fallbackRate),
        })
      );
    } catch (err) {
      toast.error(apiError(err, 'Could not load invoice preview'));
    } finally {
      setLoading(false);
    }
  }, [job.uuid, taxRate, fallbackRate]);

  useEffect(() => {
    const t = setTimeout(loadPreview, 300);
    return () => clearTimeout(t);
  }, [loadPreview]);

  const create = async () => {
    setCreating(true);
    try {
      const result = await fieldService.createInvoice(job.uuid, {
        labour_tax_rate: optionalNumber(taxRate),
        hourly_rate: optionalNumber(fallbackRate),
        due_date: optional(dueDate),
        notes: optional(notes),
      });
      toast.success(
        (tt) => (
          <span>
            Invoice {result.invoice_number} created ({money(result.total_amount, result.currency || cur)}).{' '}
            <Link href={`/dashboard/invoices/${result.invoice_uuid}`} className="underline" onClick={() => toast.dismiss(tt.id)}>
              Open
            </Link>
          </span>
        ),
        { duration: 8000 }
      );
      onDone();
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Could not create invoice'));
    } finally {
      setCreating(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-1 sm:grid-cols-4 gap-4">
        <Input label="Labour VAT %" value={taxRate} onChange={(e) => setTaxRate(e.target.value)} inputMode="decimal" />
        <Input
          label="Fallback hourly rate"
          value={fallbackRate}
          onChange={(e) => setFallbackRate(e.target.value)}
          inputMode="decimal"
          placeholder="Only if missing"
        />
        <Input label="Due date" type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
        <Input label="Invoice notes" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder={`Job ${job.job_number}`} />
      </div>

      <div className="overflow-x-auto rounded-lg border border-secondary-200">
        <table className="w-full text-sm">
          <thead className="bg-secondary-50">
            <tr className="text-left text-xs uppercase tracking-wide text-secondary-500">
              <th className="px-3 py-2 font-medium">Line</th>
              <th className="px-3 py-2 font-medium text-right">Qty</th>
              <th className="px-3 py-2 font-medium text-right">Unit</th>
              <th className="px-3 py-2 font-medium text-right">VAT</th>
              <th className="px-3 py-2 font-medium text-right">Total</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-secondary-100">
            {loading && !preview && (
              <tr>
                <td colSpan={5} className="px-3 py-6 text-center text-secondary-500">
                  Loading…
                </td>
              </tr>
            )}
            {preview && preview.lines.length === 0 && (
              <tr>
                <td colSpan={5} className="px-3 py-6 text-center text-secondary-500">
                  Nothing to invoice — no uninvoiced billable labour or items.
                </td>
              </tr>
            )}
            {preview?.lines.map((l) => (
              <tr key={`${l.source}-${l.source_uuid}`} className={l.missing_rate ? 'bg-amber-50' : undefined}>
                <td className="px-3 py-2">
                  <p className="text-secondary-900">{l.description}</p>
                  <p className="text-xs text-secondary-500">
                    {l.source === 'visit' ? 'Labour' : 'Item'}
                    {l.missing_rate && ' · no hourly rate'}
                  </p>
                </td>
                <td className="px-3 py-2 text-right">{l.quantity}</td>
                <td className="px-3 py-2 text-right">{money(l.unit_price, cur)}</td>
                <td className="px-3 py-2 text-right">{l.tax_rate}%</td>
                <td className="px-3 py-2 text-right font-medium">{money(l.total, cur)}</td>
              </tr>
            ))}
          </tbody>
          {preview && preview.lines.length > 0 && (
            <tfoot className="bg-secondary-50 text-sm">
              <tr>
                <td colSpan={4} className="px-3 py-1.5 text-right text-secondary-600">
                  Subtotal
                </td>
                <td className="px-3 py-1.5 text-right">{money(preview.subtotal, cur)}</td>
              </tr>
              <tr>
                <td colSpan={4} className="px-3 py-1.5 text-right text-secondary-600">
                  VAT
                </td>
                <td className="px-3 py-1.5 text-right">{money(preview.tax_amount, cur)}</td>
              </tr>
              <tr>
                <td colSpan={4} className="px-3 py-2 text-right font-semibold text-secondary-900">
                  Total
                </td>
                <td className="px-3 py-2 text-right font-semibold text-secondary-900">{money(preview.total, cur)}</td>
              </tr>
            </tfoot>
          )}
        </table>
      </div>

      {preview?.missing_rate && (
        <p className="flex items-start gap-2 text-sm text-amber-700">
          <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
          Enter a fallback hourly rate (or set one on the job) to price the highlighted labour.
        </p>
      )}

      <div className="flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button onClick={create} isLoading={creating} disabled={loading || !preview?.can_invoice}>
          Create draft invoice
        </Button>
      </div>
    </div>
  );
}

export default BillingPanel;
