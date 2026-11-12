'use client';

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import { AlertTriangle, ArrowLeft, CheckCircle2, ClipboardCheck, Copy, Download, ExternalLink, FileText, Pencil, Printer, Save, Send, UserPlus, X } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Select, Textarea, confirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import {
  CustomerBlock,
  KeyValue,
  LinesTable,
  PrintStyles,
  QuoteStatusBadge,
  SHOP_MODULE,
  SectionTitle,
  ShopError,
  ShopLoading,
  TotalsBlock,
} from '@/components/shop/shared';
import { QuoteLinesEditor, draftsToPayload, lineToDraft, type LineDraft } from '@/components/shop/QuoteLinesEditor';
import { CustomerForm, customerToDraft, draftToCustomer, validateCustomer, type CustomerDraft } from '@/components/shop/CustomerForm';
import { OrderTermsFields, draftToOrderFields, orderTermsToDraft, type OrderTermsDraft } from '@/components/shop/OrderTermsFields';
import { extractApiError, formatDateTime } from '@/lib/utils';
import { humanize, minorToPounds, poundsToMinor, quotePdfUrl } from '@/lib/shop';
import { SHOP_QUOTE_STATUSES, type ShopQuote, type ShopQuoteStatus } from '@/types/shop';

interface DetailsDraft {
  status: ShopQuoteStatus;
  valid_until: string; // yyyy-mm-dd
  notes: string;
  internal_notes: string;
  shipping: string; // pounds
}

const toDateInput = (s?: string | null) => (s ? String(s).slice(0, 10) : '');

function detailsOf(q: ShopQuote): DetailsDraft {
  return {
    status: q.status,
    valid_until: toDateInput(q.valid_until),
    notes: q.notes ?? '',
    internal_notes: q.internal_notes ?? '',
    shipping: minorToPounds(q.shipping_minor ?? 0),
  };
}

function QuoteDetail() {
  const params = useParams();
  const uuid = String(params?.uuid ?? '');
  const router = useRouter();
  const { canUpdate, canCreate, hasPermission } = usePermissions();
  const editable = canUpdate(SHOP_MODULE);
  const mayCreate = canCreate(SHOP_MODULE);
  const mayCrm = hasPermission('crm_accounts', 'create') && hasPermission('crm_contacts', 'create');

  const [quote, setQuote] = useState<ShopQuote | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const [details, setDetails] = useState<DetailsDraft | null>(null);
  const [customer, setCustomer] = useState<CustomerDraft | null>(null);
  const [editCustomer, setEditCustomer] = useState(false);
  const [drafts, setDrafts] = useState<LineDraft[] | null>(null);
  const [saving, setSaving] = useState<string | null>(null);
  const [lineErrors, setLineErrors] = useState<string[]>([]);
  const [terms, setTerms] = useState<OrderTermsDraft | null>(null);

  const reload = useCallback(() => setVersion((v) => v + 1), []);

  const apply = (q: ShopQuote) => {
    setQuote(q);
    setDetails(detailsOf(q));
    setCustomer(customerToDraft(q.customer));
  };

  useEffect(() => {
    let active = true;
    shopService
      .getQuote(uuid)
      .then((q) => {
        if (!active) return;
        setQuote(q);
        setDetails(detailsOf(q));
        setCustomer(customerToDraft(q.customer));
        setError(null);
      })
      .catch((err) => active && setError(extractApiError(err, 'Failed to load quote')));
    return () => {
      active = false;
    };
  }, [uuid, version]);

  if (error) return <ShopError message={error} onRetry={reload} />;
  if (!quote || !details || !customer) return <ShopLoading label="Loading quote…" />;

  const cur = quote.currency || 'GBP';
  const pdfUrl = quotePdfUrl(quote.public_url);
  const locked = quote.status === 'converted';
  const orderUuid = quote.order?.uuid ?? quote.order_uuid;

  const save = async (label: string, body: Parameters<typeof shopService.updateQuote>[1], msg: string): Promise<boolean> => {
    setSaving(label);
    try {
      const updated = await shopService.updateQuote(quote.uuid, body);
      toast.success(msg);
      if (updated?.uuid) apply(updated);
      else reload();
      return true;
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to update quote'));
      return false;
    } finally {
      setSaving(null);
    }
  };

  const saveDetails = () => {
    const shipping = poundsToMinor(details.shipping);
    if (shipping === null || shipping < 0) {
      toast.error('Shipping must be a valid amount');
      return;
    }
    save(
      'details',
      {
        status: details.status,
        valid_until: details.valid_until || undefined,
        notes: details.notes,
        internal_notes: details.internal_notes,
        shipping_minor: shipping,
      },
      'Quote saved'
    );
  };

  const isOrder = quote.kind === 'order';
  const docTitle = quote.document_title || (isOrder ? 'Order Authorisation' : 'Quote');
  const noun = isOrder ? 'order' : 'quote';

  const saveTerms = async () => {
    if (!terms) return;
    const { fields, errors } = draftToOrderFields(terms, (quote.trade_discount_minor ?? 0) > 0);
    if (errors.length) {
      toast.error(errors[0]);
      return;
    }
    if (await save('terms', fields, 'Order terms saved')) setTerms(null);
  };

  const createOrder = async () => {
    const ok = await confirmDialog({
      title: `Create an Order Authorisation from ${quote.quote_number}?`,
      message: 'A new order with the same lines and prices, the VIP Trade discount if the customer is a member, and their address as the delivery address. This quote stays as it is.',
      confirmText: 'Create order',
    });
    if (!ok) return;
    setSaving('order');
    try {
      const o = await shopService.createOrderFromQuote(quote.uuid);
      toast.success(`Order Authorisation ${o.quote_number} created`);
      router.push(`/dashboard/shop/quotes/${o.uuid}`);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not create the order'));
    } finally {
      setSaving(null);
    }
  };

  const saveToCrm = async () => {
    setSaving('crm');
    try {
      const r = await shopService.saveQuoteCustomerToCrm(quote.uuid);
      const what = [r.account_created ? 'company account created' : r.account_uuid ? 'company account updated' : '', r.contact_created ? 'contact created' : r.contact_uuid ? 'contact linked' : '']
        .filter(Boolean)
        .join(', ');
      toast.success(`Saved to the CRM${what ? `: ${what}` : ''}`);
      if (r.account_uuid) router.push(`/dashboard/crm/${r.account_uuid}`);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not save the customer to the CRM'));
    } finally {
      setSaving(null);
    }
  };

  const sendToCustomer = async () => {
    const to = quote.customer?.email;
    if (!to) {
      toast.error('Add the customer’s email first');
      return;
    }
    const ok = await confirmDialog({
      title: `Email ${docTitle} ${quote.quote_number} to ${to}?`,
      message: isOrder
        ? 'They get the PDF and a link to confirm the order, accept the terms and pay online.'
        : 'They get the PDF and a link to view and pay the quote.',
      confirmText: 'Send',
    });
    if (!ok) return;
    setSaving('send');
    try {
      const res = await shopService.sendQuote(quote.uuid);
      toast.success(res.attached ? `Sent to ${res.to} with the PDF attached` : `Sent to ${res.to} (link only: the PDF could not be attached)`);
      if (res.quote?.uuid) apply(res.quote);
      else reload();
    } catch (err) {
      toast.error(extractApiError(err, `Could not send the ${noun}`));
    } finally {
      setSaving(null);
    }
  };

  const saveCustomer = async () => {
    const errs = validateCustomer(customer);
    if (errs.length) {
      toast.error(errs[0]);
      return;
    }
    if (await save('customer', { customer: draftToCustomer(customer) }, 'Customer updated')) setEditCustomer(false);
  };

  const saveLines = async () => {
    if (!drafts) return;
    const { lines, errors } = draftsToPayload(drafts);
    setLineErrors(errors);
    if (errors.length) return;
    if (!lines.length) {
      setLineErrors(['A quote needs at least one line']);
      return;
    }
    if (await save('lines', { lines }, 'Lines re-priced and saved')) setDrafts(null);
  };

  const copyLink = async () => {
    if (!quote.public_url) return;
    try {
      await navigator.clipboard.writeText(quote.public_url);
      toast.success('Customer link copied');
    } catch {
      toast.error('Could not copy link');
    }
  };

  return (
    <div className="space-y-6">
      <PrintStyles />
      <PageHeader
        title={`${docTitle} ${quote.quote_number}`}
        description={`Created ${formatDateTime(quote.created_at)}${quote.source ? ` · from ${humanize(quote.source)}` : ''}`}
        icon={<FileText className="h-5 w-5" />}
        actions={
          <div className="flex flex-wrap items-center gap-2 print:hidden">
            <Link href="/dashboard/shop/quotes">
              <Button variant="ghost" leftIcon={<ArrowLeft className="h-4 w-4" />}>Quotes</Button>
            </Link>
            <Button variant="ghost" leftIcon={<Printer className="h-4 w-4" />} onClick={() => window.print()}>
              Print
            </Button>
            {quote.public_url && (
              <a href={quote.public_url} target="_blank" rel="noopener noreferrer">
                <Button variant="outline" leftIcon={<ExternalLink className="h-4 w-4" />}>Open customer link</Button>
              </a>
            )}
            {pdfUrl && (
              <a href={pdfUrl} target="_blank" rel="noopener noreferrer">
                <Button variant="outline" leftIcon={<Download className="h-4 w-4" />}>Download PDF</Button>
              </a>
            )}
            {mayCreate && !isOrder && quote.status !== 'cancelled' && (
              <Button variant="outline" leftIcon={<ClipboardCheck className="h-4 w-4" />} isLoading={saving === 'order'} disabled={!!saving} onClick={createOrder}>
                Create Order Authorisation
              </Button>
            )}
            {editable && !locked && quote.status !== 'cancelled' && quote.status !== 'expired' && (
              <Button leftIcon={<Send className="h-4 w-4" />} isLoading={saving === 'send'} disabled={!!saving} onClick={sendToCustomer}>
                {quote.sent_at ? 'Send again' : isOrder ? 'Send for authorisation' : 'Email to customer'}
              </Button>
            )}
          </div>
        }
      />

      <div className="flex flex-wrap items-center gap-3">
        <QuoteStatusBadge status={quote.status} />
        {quote.sent_at && <span className="text-sm text-secondary-500">Sent {formatDateTime(quote.sent_at)}</span>}
        {quote.viewed_at && <span className="text-sm text-secondary-500">Viewed by customer {formatDateTime(quote.viewed_at)}</span>}
        {quote.authorised_at && (
          <span className="inline-flex items-center gap-1 text-sm font-medium text-success-700">
            <CheckCircle2 className="h-4 w-4" aria-hidden="true" />
            Confirmed by {quote.authorised_by_name || 'the customer'} {formatDateTime(quote.authorised_at)}
          </span>
        )}
        {orderUuid && (
          <Link href={`/dashboard/shop/orders/${orderUuid}`} className="text-sm text-primary-600 hover:underline">
            Order {quote.order?.order_number ?? quote.order?.number ?? ''} →
          </Link>
        )}
      </div>

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
        <div className="space-y-6 xl:col-span-2">
          <Card>
            <SectionTitle
              actions={
                editable &&
                !locked &&
                (drafts ? (
                  <>
                    <Button size="sm" variant="ghost" leftIcon={<X className="h-4 w-4" />} onClick={() => { setDrafts(null); setLineErrors([]); }}>
                      Discard
                    </Button>
                    <Button size="sm" leftIcon={<Save className="h-4 w-4" />} isLoading={saving === 'lines'} onClick={saveLines}>
                      Save &amp; re-price
                    </Button>
                  </>
                ) : (
                  <Button size="sm" variant="ghost" className="print:hidden" leftIcon={<Pencil className="h-4 w-4" />} onClick={() => setDrafts(quote.lines.map(lineToDraft))}>
                    Edit lines
                  </Button>
                ))
              }
            >
              Lines
            </SectionTitle>
            {drafts ? (
              <>
                {lineErrors.length > 0 && (
                  <div className="mb-3 rounded-lg border border-error-200 bg-error-50 p-3 text-sm text-error-700" role="alert">
                    {lineErrors.map((e, i) => (
                      <p key={i}>{e}</p>
                    ))}
                  </div>
                )}
                <QuoteLinesEditor drafts={drafts} onChange={setDrafts} currency={cur} />
                <p className="mt-3 text-xs text-secondary-500">
                  Saving re-prices every line through the pricing engine. A unit price override replaces the computed unit price (ex VAT); VAT is recalculated.
                </p>
              </>
            ) : (
              <LinesTable lines={quote.lines} currency={cur} />
            )}
            <div className="mt-4 border-t border-secondary-200 pt-4">
              <TotalsBlock totals={quote} />
            </div>
          </Card>

          <Card className="print:hidden">
            <SectionTitle
              actions={
                editable &&
                !locked &&
                (terms ? (
                  <>
                    <Button size="sm" variant="ghost" leftIcon={<X className="h-4 w-4" />} onClick={() => setTerms(null)}>Discard</Button>
                    <Button size="sm" leftIcon={<Save className="h-4 w-4" />} isLoading={saving === 'terms'} onClick={saveTerms}>Save</Button>
                  </>
                ) : (
                  <Button size="sm" variant="ghost" leftIcon={<Pencil className="h-4 w-4" />} onClick={() => setTerms(orderTermsToDraft(quote))}>Edit</Button>
                ))
              }
            >
              Order terms: discounts and delivery
            </SectionTitle>
            {terms ? (
              <OrderTermsFields value={terms} onChange={setTerms} customer={customer} idPrefix="qt" tradeDiscountMinor={quote.trade_discount_minor} />
            ) : (
              <dl className="divide-y divide-secondary-100">
                <KeyValue label="Document">{docTitle}</KeyValue>
                <KeyValue label="VIP Trade discount">{(quote.trade_discount_minor ?? 0) > 0 ? `£${minorToPounds(quote.trade_discount_minor ?? 0)} ex VAT` : 'None'}</KeyValue>
                <KeyValue label="Extra discount">{(quote.discount_minor ?? 0) > 0 ? `£${minorToPounds(quote.discount_minor ?? 0)} ex VAT${quote.discount_label ? ` (${quote.discount_label})` : ''}` : 'None'}</KeyValue>
                <KeyValue label="Delivery method">{quote.delivery_method || '—'}</KeyValue>
                <KeyValue label="Deliver to">
                  {quote.delivery_address
                    ? [quote.delivery_address.name, quote.delivery_address.company, quote.delivery_address.line1, quote.delivery_address.line2, quote.delivery_address.city, quote.delivery_address.postcode, quote.delivery_address.country, quote.delivery_address.email, quote.delivery_address.vat_number && `VAT ${quote.delivery_address.vat_number}`].filter(Boolean).join(', ')
                    : '—'}
                </KeyValue>
              </dl>
            )}
          </Card>

          <Card className="print:hidden">
            <SectionTitle
              actions={
                editable && (
                  <Button size="sm" leftIcon={<Save className="h-4 w-4" />} isLoading={saving === 'details'} onClick={saveDetails}>
                    Save
                  </Button>
                )
              }
            >
              Status, validity & notes
            </SectionTitle>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
              <Select label="Status" id="q-status" value={details.status} disabled={!editable} onChange={(e) => setDetails({ ...details, status: e.target.value as ShopQuoteStatus })}>
                {SHOP_QUOTE_STATUSES.map((s) => (
                  <option key={s} value={s}>{humanize(s)}</option>
                ))}
              </Select>
              <Input label="Valid until" id="q-valid" type="date" value={details.valid_until} disabled={!editable} onChange={(e) => setDetails({ ...details, valid_until: e.target.value })} />
              <Input
                label="Shipping (£ ex VAT)"
                id="q-ship"
                value={details.shipping}
                inputMode="decimal"
                disabled={!editable || locked}
                onChange={(e) => setDetails({ ...details, shipping: e.target.value })}
                error={poundsToMinor(details.shipping) === null ? 'Invalid' : undefined}
              />
            </div>
            <div className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
              <Textarea label="Notes (shown to customer)" id="q-notes" rows={4} value={details.notes} disabled={!editable} onChange={(e) => setDetails({ ...details, notes: e.target.value })} />
              <Textarea label="Internal notes" id="q-inotes" rows={4} value={details.internal_notes} disabled={!editable} onChange={(e) => setDetails({ ...details, internal_notes: e.target.value })} />
            </div>
          </Card>
        </div>

        <div className="space-y-6">
          <Card>
            <SectionTitle
              actions={
                editable &&
                (editCustomer ? (
                  <>
                    <Button size="sm" variant="ghost" onClick={() => { setEditCustomer(false); setCustomer(customerToDraft(quote.customer)); }}>
                      Cancel
                    </Button>
                    <Button size="sm" isLoading={saving === 'customer'} onClick={saveCustomer}>Save</Button>
                  </>
                ) : (
                  <>
                    {mayCrm && (
                      <Button size="sm" variant="ghost" className="print:hidden" leftIcon={<UserPlus className="h-4 w-4" />} isLoading={saving === 'crm'} disabled={!!saving} onClick={saveToCrm}>
                        Save to CRM
                      </Button>
                    )}
                    <Button size="sm" variant="ghost" className="print:hidden" leftIcon={<Pencil className="h-4 w-4" />} onClick={() => setEditCustomer(true)}>
                      Edit
                    </Button>
                  </>
                ))
              }
            >
              Customer
            </SectionTitle>
            {editCustomer ? <CustomerForm value={customer} onChange={setCustomer} /> : <CustomerBlock customer={quote.customer} />}
          </Card>

          <Card className="print:hidden">
            <SectionTitle>Customer link</SectionTitle>
            {quote.public_url ? (
              <div className="space-y-3">
                <div className="flex items-center gap-2">
                  <code className="min-w-0 flex-1 truncate rounded bg-secondary-50 px-2 py-1.5 text-xs text-secondary-700">{quote.public_url}</code>
                  <button onClick={copyLink} className="rounded-lg p-1.5 text-secondary-500 hover:bg-secondary-100" aria-label="Copy customer link">
                    <Copy className="h-4 w-4" />
                  </button>
                </div>
                <p className="flex items-start gap-1.5 text-xs text-secondary-500">
                  <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-warning-500" />
                  Anyone with this link can view and pay the {noun}. Share it only with the customer.
                </p>
              </div>
            ) : (
              <p className="text-sm text-secondary-500">No public URL returned (SHOP_PUBLIC_URL not configured?).</p>
            )}
          </Card>

          <Card>
            <SectionTitle>Details</SectionTitle>
            <dl className="divide-y divide-secondary-100">
              <KeyValue label={isOrder ? 'Order number' : 'Quote number'}>{quote.quote_number}</KeyValue>
              <KeyValue label="Valid until">{quote.valid_until ? toDateInput(quote.valid_until) : '—'}</KeyValue>
              {quote.chat_session_uuid && (
                <KeyValue label="Chat">
                  <Link href={`/dashboard/shop/chats/${quote.chat_session_uuid}`} className="text-primary-600 hover:underline">
                    View transcript
                  </Link>
                </KeyValue>
              )}
              {quote.crm_lead_id && <KeyValue label="CRM lead">#{quote.crm_lead_id}</KeyValue>}
              {quote.updated_at && <KeyValue label="Updated">{formatDateTime(quote.updated_at)}</KeyValue>}
            </dl>
          </Card>
        </div>
      </div>
    </div>
  );
}

export default function ShopQuotePage() {
  return (
    <ProtectedPage module="shop" title="Shop Quote">
      <QuoteDetail />
    </ProtectedPage>
  );
}
