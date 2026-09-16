'use client';

/**
 * Customer quotation for a job — a pre-work estimate built from the job's
 * quote-sheet lines (labour / materials / hire). Preview or download the PDF,
 * or email it to the customer. This does not touch invoicing; it's the estimate
 * you send to win the work.
 */

import React, { useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Download, Eye, Mail } from 'lucide-react';
import { Button } from '@/components/ui';
import { fieldService, type FsJobDetail } from '@/services/field-service.service';
import { useNamespace } from '@/contexts/NamespaceContext';
import { generateQuotePdf, previewQuotePdfUrl, quotePdfBase64 } from '@/lib/quote-pdf';
import { SectionCard, apiError, money } from './shared';

export function QuotePanel({ job, canManage }: { job: FsJobDetail; canManage: boolean }) {
  const { currentNamespace } = useNamespace();
  const [emailing, setEmailing] = useState(false);
  const company = { name: currentNamespace?.name || 'Your Company' };
  const cur = job.currency || 'GBP';

  const { total, count } = useMemo(() => {
    let subtotal = 0;
    let tax = 0;
    let n = 0;
    for (const it of job.items || []) {
      if (it.is_billable === false) continue;
      const lt = Number(it.line_total) || (Number(it.quantity) || 0) * (Number(it.unit_price) || 0);
      subtotal += lt;
      tax += lt * ((Number(it.tax_rate) || 0) / 100);
      n += 1;
    }
    return { total: subtotal + tax, count: n };
  }, [job.items]);

  const download = () => {
    try {
      generateQuotePdf(job, company);
    } catch {
      toast.error('Could not build the quote PDF');
    }
  };

  const preview = () => {
    try {
      const url = previewQuotePdfUrl(job, company);
      window.open(url, '_blank', 'noopener,noreferrer');
      // The tab loads the blob immediately; revoke well after to avoid a leak.
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
    } catch {
      toast.error('Could not preview the quote');
    }
  };

  const email = async () => {
    const to = job.customer_email?.trim();
    if (!to) {
      toast.error('Add a customer email to this job before sending.');
      return;
    }
    if (count === 0 && !window.confirm('This quote has no priced lines yet. Send it anyway?')) return;
    if (!window.confirm(`Email quotation for ${job.job_number} to ${to}?`)) return;
    setEmailing(true);
    try {
      const { base64, filename } = quotePdfBase64(job, company);
      await fieldService.emailQuote(job.uuid, { pdf_base64: base64, filename });
      toast.success(`Quotation emailed to ${to}`);
    } catch (err) {
      toast.error(apiError(err, 'Could not email the quote'));
    } finally {
      setEmailing(false);
    }
  };

  return (
    <SectionCard
      title="Quotation"
      actions={
        <div className="flex items-center gap-2">
          <Button size="sm" variant="ghost" onClick={preview}>
            <Eye className="w-4 h-4 mr-1" /> Preview
          </Button>
          <Button size="sm" variant="secondary" onClick={download}>
            <Download className="w-4 h-4 mr-1" /> PDF
          </Button>
          {canManage && (
            <Button size="sm" onClick={email} isLoading={emailing}>
              <Mail className="w-4 h-4 mr-1" /> Email
            </Button>
          )}
        </div>
      }
    >
      <p className="text-sm text-secondary-600">
        A customer-facing estimate from this job&apos;s labour, materials and hire lines
        {count > 0 ? (
          <>
            {' — '}
            <span className="font-semibold text-secondary-900">{money(total, cur)}</span> across {count} line(s).
          </>
        ) : (
          '. Add lines below to price it.'
        )}
      </p>
    </SectionCard>
  );
}

export default QuotePanel;
