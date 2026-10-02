'use client';

import React, { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { ArrowLeft, FilePlus2, Save } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { shopService } from '@/services/shop.service';
import { SectionTitle } from '@/components/shop/shared';
import { QuoteLinesEditor, draftsToPayload, type LineDraft } from '@/components/shop/QuoteLinesEditor';
import { CustomerForm, customerToDraft, draftToCustomer, validateCustomer, type CustomerDraft } from '@/components/shop/CustomerForm';
import { newKey } from '@/components/shop/editor-fields';
import { extractApiError } from '@/lib/utils';
import { poundsToMinor } from '@/lib/shop';
import type { ShopQuoteStatus } from '@/types/shop';

function NewQuote() {
  const router = useRouter();
  const [customer, setCustomer] = useState<CustomerDraft>(() => customerToDraft(null));
  const [drafts, setDrafts] = useState<LineDraft[]>(() => [
    { key: newKey(), product_slug: '', product_name: '', qty: '1', selections: {}, override: '' },
  ]);
  const [notes, setNotes] = useState('');
  const [internalNotes, setInternalNotes] = useState('');
  const [validUntil, setValidUntil] = useState('');
  const [shipping, setShipping] = useState('0.00');
  const [errors, setErrors] = useState<string[]>([]);
  const [saving, setSaving] = useState<ShopQuoteStatus | null>(null);

  const submit = async (status: ShopQuoteStatus) => {
    const errs = [...validateCustomer(customer)];
    const { lines, errors: lineErrs } = draftsToPayload(drafts);
    errs.push(...lineErrs);
    if (!lines.length) errs.push('Add at least one line');
    const shippingMinor = poundsToMinor(shipping);
    if (shippingMinor === null || shippingMinor < 0) errs.push('Shipping must be a valid amount');
    setErrors(errs);
    if (errs.length) return;
    setSaving(status);
    try {
      const q = await shopService.createQuote({
        source: 'admin',
        status,
        customer: draftToCustomer(customer),
        lines,
        notes: notes.trim() || undefined,
        internal_notes: internalNotes.trim() || undefined,
        valid_until: validUntil || undefined,
        shipping_minor: shippingMinor ?? 0,
      });
      toast.success(`Quote ${q?.quote_number ?? ''} created`);
      router.push(q?.uuid ? `/dashboard/shop/quotes/${q.uuid}` : '/dashboard/shop/quotes');
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to create quote'));
    } finally {
      setSaving(null);
    }
  };

  return (
    <div className="space-y-6">
      <PageHeader
        title="Create quote"
        description="For phone and email enquiries — lines are priced by the pricing engine"
        icon={<FilePlus2 className="h-5 w-5" />}
        actions={
          <>
            <Link href="/dashboard/shop/quotes">
              <Button variant="ghost" leftIcon={<ArrowLeft className="h-4 w-4" />}>Quotes</Button>
            </Link>
            <Button variant="outline" isLoading={saving === 'draft'} disabled={!!saving} onClick={() => submit('draft')}>
              Save draft
            </Button>
            <Button leftIcon={<Save className="h-4 w-4" />} isLoading={saving === 'sent'} disabled={!!saving} onClick={() => submit('sent')}>
              Create &amp; mark sent
            </Button>
          </>
        }
      />

      {errors.length > 0 && (
        <div className="rounded-xl border border-error-200 bg-error-50 p-4 text-sm text-error-700" role="alert">
          <ul className="list-disc space-y-0.5 pl-5">
            {errors.map((e, i) => (
              <li key={i}>{e}</li>
            ))}
          </ul>
        </div>
      )}

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
        <div className="space-y-6 xl:col-span-2">
          <Card>
            <SectionTitle>Lines</SectionTitle>
            <QuoteLinesEditor drafts={drafts} onChange={setDrafts} />
          </Card>
          <Card>
            <SectionTitle>Notes</SectionTitle>
            <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
              <Textarea label="Notes (shown to customer)" id="nq-notes" rows={4} value={notes} onChange={(e) => setNotes(e.target.value)} />
              <Textarea label="Internal notes" id="nq-inotes" rows={4} value={internalNotes} onChange={(e) => setInternalNotes(e.target.value)} />
            </div>
          </Card>
        </div>
        <div className="space-y-6">
          <Card>
            <SectionTitle>Customer</SectionTitle>
            <CustomerForm value={customer} onChange={setCustomer} />
          </Card>
          <Card>
            <SectionTitle>Terms</SectionTitle>
            <div className="space-y-4">
              <Input label="Valid until" id="nq-valid" type="date" value={validUntil} onChange={(e) => setValidUntil(e.target.value)} helperText="Defaults to 30 days from creation" />
              <Input label="Shipping (£ ex VAT)" id="nq-ship" value={shipping} inputMode="decimal" onChange={(e) => setShipping(e.target.value)} />
            </div>
          </Card>
        </div>
      </div>
    </div>
  );
}

export default function NewShopQuotePage() {
  return (
    <ProtectedPage module="shop" action="create" title="Create Quote">
      <NewQuote />
    </ProtectedPage>
  );
}
