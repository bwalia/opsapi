'use client';

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { AlertTriangle, ArrowLeft, Copy, ExternalLink, FileText, Lock, Mail, Pencil, Plus, Trash2, Truck } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input, Modal, Select, Textarea, confirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { OrderStatusBadge, QuoteStatusBadge, SHOP_MODULE, SectionTitle, ShopError, ShopLoading } from '@/components/shop/shared';
import { copyText } from '@/components/shop/DealCode';
import { extractApiError, formatDateTime } from '@/lib/utils';
import { formatMoney, humanize, minorToPounds, poundsToMinor } from '@/lib/shop';
import type { ShopDeal, ShopSupplier, ShopSupplierRequest, ShopSupplierRequestDraft, ShopSupplierRequestInput } from '@/types/shop';

const AUDIT_LABEL: Record<string, string> = {
  viewed: 'Viewed the deal',
  linked: 'Linked to this deal',
  unlinked: 'Moved to another deal',
  'purchase_order.created': 'Purchase order drafted',
  'drop_ship.confirmed': 'Drop-ship confirmed (supplier sees the customer’s address)',
  legacy_drop_ship: 'Older drop-ship purchase order (before deal codes)',
  'supplier_request.created': 'Supplier request added',
  'supplier_request.updated': 'Supplier request changed',
  'supplier_request.deleted': 'Supplier request deleted',
  'supplier_request.email_drafted': 'Supplier email drafted',
  'supplier_request.sent': 'Price request sent to the supplier (email, WhatsApp or text)',
  'supplier_intro.sent': 'Customer introduced to the supplier, with their agreement',
};

interface LineDraft {
  line_uuid?: string | null;
  description: string;
  qty: string;
  price: string; // pounds ex VAT
}

interface RequestDraft {
  supplier_uuid: string;
  supplier_name: string;
  contact_name: string;
  contact_email: string;
  sent_at: string;
  supplier_quote_ref: string;
  lead_time: string;
  valid_until: string;
  spec: string;
  notes: string;
  lines: LineDraft[];
}

const OTHER = '__other__';

function draftOf(deal: ShopDeal, r?: ShopSupplierRequest): RequestDraft {
  if (r) {
    return {
      supplier_uuid: r.supplier_uuid ?? OTHER,
      supplier_name: r.supplier_name ?? '',
      contact_name: r.contact_name ?? '',
      contact_email: r.contact_email ?? '',
      sent_at: r.sent_at ?? '',
      supplier_quote_ref: r.supplier_quote_ref ?? '',
      lead_time: r.lead_time ?? '',
      valid_until: r.valid_until ?? '',
      spec: r.spec ?? '',
      notes: r.notes ?? '',
      lines: r.lines.map((l) => ({ line_uuid: l.line_uuid, description: l.description, qty: String(l.qty ?? 1), price: minorToPounds(l.unit_price_minor ?? null) })),
    };
  }
  return {
    supplier_uuid: OTHER,
    supplier_name: '',
    contact_name: '',
    contact_email: '',
    sent_at: new Date().toISOString().slice(0, 10),
    supplier_quote_ref: '',
    lead_time: '',
    valid_until: '',
    spec: '',
    notes: '',
    lines: deal.lines.map((l) => ({ line_uuid: l.uuid, description: l.description, qty: String(l.qty), price: '' })),
  };
}

function RequestForm({ deal, request, suppliers, onClose, onSaved }: { deal: ShopDeal; request?: ShopSupplierRequest; suppliers: ShopSupplier[]; onClose: () => void; onSaved: () => void }) {
  const [d, setD] = useState<RequestDraft>(() => draftOf(deal, request));
  const [saving, setSaving] = useState(false);
  const badPrice = d.lines.some((l) => l.price.trim() !== '' && poundsToMinor(l.price) === null);
  const setLine = (i: number, patch: Partial<LineDraft>) => setD({ ...d, lines: d.lines.map((l, k) => (k === i ? { ...l, ...patch } : l)) });

  const save = async () => {
    if (d.supplier_uuid === OTHER && !d.supplier_name.trim()) {
      toast.error('Choose a supplier or type its name');
      return;
    }
    if (badPrice) {
      toast.error('Check the highlighted prices');
      return;
    }
    const body: ShopSupplierRequestInput = {
      supplier_uuid: d.supplier_uuid !== OTHER ? d.supplier_uuid : undefined,
      supplier_name: d.supplier_uuid === OTHER ? d.supplier_name.trim() : undefined,
      contact_name: d.contact_name.trim() || null,
      contact_email: d.contact_email.trim() || null,
      sent_at: d.sent_at || null,
      supplier_quote_ref: d.supplier_quote_ref.trim() || null,
      lead_time: d.lead_time.trim() || null,
      valid_until: d.valid_until || null,
      spec: d.spec.trim() || null,
      notes: d.notes.trim() || null,
      lines: d.lines
        .filter((l) => l.description.trim())
        .map((l) => ({ line_uuid: l.line_uuid ?? null, description: l.description.trim(), qty: Math.max(1, Math.floor(Number(l.qty) || 1)), unit_price_minor: l.price.trim() ? poundsToMinor(l.price) : null })),
    };
    setSaving(true);
    try {
      if (request) await shopService.updateSupplierRequest(request.uuid, body);
      else await shopService.createSupplierRequest(deal.deal_code, body);
      toast.success(request ? 'Supplier request saved' : 'Supplier request added');
      onSaved();
    } catch (err) {
      toast.error(extractApiError(err, 'Could not save the supplier request'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      isOpen
      onClose={onClose}
      title={request ? `Supplier request: ${request.supplier_name}` : 'New supplier request'}
      description={`Asking a supplier to price this deal. They see ${deal.deal_code} and the spec only, never the customer.`}
      size="3xl"
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button isLoading={saving} disabled={saving || badPrice} onClick={save}>Save</Button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Select label="Supplier" id="sr-supplier" value={d.supplier_uuid} onChange={(e) => setD({ ...d, supplier_uuid: e.target.value })}>
            {suppliers.map((s) => (
              <option key={s.uuid} value={s.uuid}>{s.name}</option>
            ))}
            <option value={OTHER}>Another supplier (type it)</option>
          </Select>
          {d.supplier_uuid === OTHER ? (
            <Input label="Supplier name *" id="sr-name" value={d.supplier_name} onChange={(e) => setD({ ...d, supplier_name: e.target.value })} />
          ) : (
            <div className="hidden sm:block" />
          )}
          <Input label="Contact name" id="sr-contact" value={d.contact_name} onChange={(e) => setD({ ...d, contact_name: e.target.value })} />
          <Input label="Contact email" id="sr-email" type="email" value={d.contact_email} onChange={(e) => setD({ ...d, contact_email: e.target.value })} helperText={d.supplier_uuid !== OTHER && !request ? 'Empty: the supplier’s PO email' : undefined} />
          <Input label="Date sent" id="sr-sent" type="date" value={d.sent_at} onChange={(e) => setD({ ...d, sent_at: e.target.value })} />
          <Input label="Their quote reference" id="sr-ref" value={d.supplier_quote_ref} onChange={(e) => setD({ ...d, supplier_quote_ref: e.target.value })} />
          <Input label="Stock / lead time" id="sr-lead" value={d.lead_time} placeholder="e.g. In stock, 3 days" onChange={(e) => setD({ ...d, lead_time: e.target.value })} />
          <Input label="Price valid until" id="sr-valid" type="date" value={d.valid_until} onChange={(e) => setD({ ...d, valid_until: e.target.value })} />
        </div>
        <Textarea label="Spec (the supplier sees this)" id="sr-spec" rows={3} value={d.spec} onChange={(e) => setD({ ...d, spec: e.target.value })} placeholder="The build: GPUs, CPU, RAM, storage, PSU…" helperText="Never put the customer’s name, email, phone, company or our quote number here." />
        <div>
          <p className="mb-2 text-sm font-medium text-secondary-700">Lines and their price (£ ex VAT, each)</p>
          <div className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
            {d.lines.length === 0 && <p className="px-3 py-3 text-sm text-secondary-500">No lines yet.</p>}
            {d.lines.map((l, i) => {
              const bad = l.price.trim() !== '' && poundsToMinor(l.price) === null;
              return (
                <div key={i} className="grid grid-cols-6 items-end gap-2 px-3 py-2 sm:grid-cols-12">
                  <div className="col-span-6 sm:col-span-7">
                    <Input aria-label={`Line ${i + 1} description`} id={`sr-l-${i}`} value={l.description} onChange={(e) => setLine(i, { description: e.target.value })} />
                  </div>
                  <div className="col-span-2 sm:col-span-1">
                    <Input aria-label={`Line ${i + 1} quantity`} id={`sr-q-${i}`} inputMode="numeric" value={l.qty} onChange={(e) => setLine(i, { qty: e.target.value })} />
                  </div>
                  <div className="col-span-3 sm:col-span-3">
                    <Input aria-label={`Line ${i + 1} price`} id={`sr-p-${i}`} inputMode="decimal" placeholder="0.00" value={l.price} error={bad ? 'Invalid' : undefined} onChange={(e) => setLine(i, { price: e.target.value })} />
                  </div>
                  <div className="col-span-1 flex justify-end pb-1">
                    <button type="button" className="rounded p-1 text-secondary-400 hover:bg-secondary-100 hover:text-error-600" aria-label={`Remove line ${i + 1}`} onClick={() => setD({ ...d, lines: d.lines.filter((_, k) => k !== i) })}>
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
          <Button size="sm" variant="ghost" className="mt-2" leftIcon={<Plus className="h-4 w-4" />} onClick={() => setD({ ...d, lines: [...d.lines, { line_uuid: null, description: '', qty: '1', price: '' }] })}>
            Add a line
          </Button>
        </div>
        <Textarea label="Our notes (not sent to the supplier)" id="sr-notes" rows={2} value={d.notes} onChange={(e) => setD({ ...d, notes: e.target.value })} />
      </div>
    </Modal>
  );
}

function EmailDraftModal({ draft, onClose }: { draft: ShopSupplierRequestDraft; onClose: () => void }) {
  return (
    <Modal
      isOpen
      onClose={onClose}
      title="Email to the supplier (draft)"
      description="Nothing has been sent. Open it in your email app, or copy it, check it and send it yourself."
      size="2xl"
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>Close</Button>
          <Button variant="outline" leftIcon={<Copy className="h-4 w-4" />} onClick={() => copyText(`Subject: ${draft.subject}\n\n${draft.body}`, 'Email copied')}>Copy</Button>
          <a href={draft.mailto} className="inline-flex items-center gap-2 rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white hover:bg-primary-700">
            <Mail className="h-4 w-4" aria-hidden="true" /> Open in email app
          </a>
        </>
      }
    >
      <dl className="space-y-3 text-sm">
        <div>
          <dt className="text-xs font-semibold uppercase tracking-wider text-secondary-500">To</dt>
          <dd className="text-secondary-900">{draft.to || <span className="text-warning-700">No contact email: add one to the request</span>}</dd>
        </div>
        <div>
          <dt className="text-xs font-semibold uppercase tracking-wider text-secondary-500">Subject</dt>
          <dd className="font-medium text-secondary-900">{draft.subject}</dd>
        </div>
        <div>
          <dt className="text-xs font-semibold uppercase tracking-wider text-secondary-500">Message</dt>
          <dd><pre className="whitespace-pre-wrap rounded-lg border border-secondary-200 bg-secondary-50 p-3 font-sans text-sm text-secondary-800">{draft.body}</pre></dd>
        </div>
      </dl>
    </Modal>
  );
}

function DealDetail() {
  const params = useParams();
  const code = decodeURIComponent(String(params?.code ?? ''));
  const { canUpdate, canCreate, canDelete } = usePermissions();
  const [deal, setDeal] = useState<ShopDeal | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [suppliers, setSuppliers] = useState<ShopSupplier[]>([]);
  const [editing, setEditing] = useState<ShopSupplierRequest | 'new' | null>(null);
  const [draft, setDraft] = useState<ShopSupplierRequestDraft | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(() => {
    setError(null);
    shopService
      .getDeal(code)
      .then(setDeal)
      .catch((e) => setError(extractApiError(e, 'Could not load the deal')));
  }, [code]);

  useEffect(() => {
    load();
    shopService.getSuppliers().then(setSuppliers).catch(() => setSuppliers([]));
  }, [load]);

  const emailDraft = async (r: ShopSupplierRequest) => {
    setBusy(r.uuid);
    try {
      setDraft(await shopService.supplierRequestEmailDraft(r.uuid));
    } catch (e) {
      toast.error(extractApiError(e, 'Could not draft the email'));
    } finally {
      setBusy(null);
    }
  };

  const remove = async (r: ShopSupplierRequest) => {
    if (!(await confirmDialog({ title: 'Delete this supplier request?', message: `${r.supplier_name}${r.supplier_quote_ref ? ` (${r.supplier_quote_ref})` : ''}`, confirmText: 'Delete', danger: true }))) return;
    try {
      await shopService.deleteSupplierRequest(r.uuid);
      toast.success('Deleted');
      load();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not delete'));
    }
  };

  const currency = deal?.quotes[0]?.currency ?? deal?.orders[0]?.currency ?? 'GBP';
  const suppliersInCompare = useMemo(() => deal?.compare.rows[0]?.suppliers.map((c) => ({ uuid: c.request_uuid, name: c.supplier_name })) ?? [], [deal]);

  if (error) return <ShopError message={error} onRetry={load} />;
  if (!deal) return <ShopLoading label="Loading the deal…" />;

  return (
    <div className="space-y-6">
      {editing && (
        <RequestForm
          deal={deal}
          request={editing === 'new' ? undefined : editing}
          suppliers={suppliers}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            load();
          }}
        />
      )}
      {draft && <EmailDraftModal draft={draft} onClose={() => setDraft(null)} />}
      <PageHeader
        title={`Deal ${deal.deal_code}`}
        description="Everything on this deal, customer and supplier side. Staff only: suppliers see the code, customers never do."
        icon={<Lock className="h-5 w-5" />}
        actions={
          <div className="flex flex-wrap items-center gap-2">
            <Link href="/dashboard/shop/deals">
              <Button variant="ghost" leftIcon={<ArrowLeft className="h-4 w-4" />}>Deals</Button>
            </Link>
            <Button variant="outline" leftIcon={<Copy className="h-4 w-4" />} onClick={() => copyText(deal.deal_code, 'Deal code copied')}>Copy code</Button>
          </div>
        }
      />

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
        <div className="space-y-6 xl:col-span-2">
          <Card>
            <SectionTitle
              actions={
                canCreate(SHOP_MODULE) && (
                  <Button size="sm" leftIcon={<Plus className="h-4 w-4" />} onClick={() => setEditing('new')}>New request</Button>
                )
              }
            >
              Supplier requests
            </SectionTitle>
            {deal.supplier_requests.length === 0 ? (
              <p className="text-sm text-secondary-500">No supplier has been asked yet. Add a request, then use “Email supplier” to draft the email.</p>
            ) : (
              <ul className="divide-y divide-secondary-100">
                {deal.supplier_requests.map((r) => (
                  <li key={r.uuid} className="flex flex-wrap items-start justify-between gap-3 py-3">
                    <div className="min-w-0">
                      <p className="font-medium text-secondary-900">
                        {r.supplier_name}
                        {r.kind === 'intro' && (
                          <span className="ml-2 rounded-full bg-warning-50 px-2 py-0.5 text-xs font-medium text-warning-800">Customer introduced</span>
                        )}
                        {r.supplier_quote_ref && <span className="ml-2 font-mono text-xs text-secondary-500">{r.supplier_quote_ref}</span>}
                      </p>
                      <p className="text-xs text-secondary-500">
                        {[r.contact_name, r.contact_email].filter(Boolean).join(' · ') || 'No contact'}
                        {r.sent_at && ` · sent ${r.sent_at}`}{r.channel && ` by ${({ email: 'email', whatsapp: 'WhatsApp', sms: 'text' } as const)[r.channel]}`}
                        {r.lead_time && ` · ${r.lead_time}`}
                        {r.valid_until && ` · valid until ${r.valid_until}`}
                      </p>
                      <p className="mt-1 text-xs text-secondary-600">
                        {r.lines.length} line{r.lines.length === 1 ? '' : 's'}
                        {r.lines.some((l) => l.unit_price_minor != null) &&
                          ` · ${formatMoney(r.lines.reduce((t, l) => t + (l.unit_price_minor ?? 0) * (l.qty || 1), 0), currency)} ex VAT`}
                      </p>
                    </div>
                    <div className="flex flex-wrap gap-1">
                      {canUpdate(SHOP_MODULE) && (
                        <Button size="sm" variant="outline" leftIcon={<Mail className="h-4 w-4" />} isLoading={busy === r.uuid} onClick={() => emailDraft(r)}>Email supplier</Button>
                      )}
                      {canUpdate(SHOP_MODULE) && (
                        <Button size="sm" variant="ghost" leftIcon={<Pencil className="h-4 w-4" />} onClick={() => setEditing(r)}>Edit</Button>
                      )}
                      {canDelete(SHOP_MODULE) && (
                        <Button size="sm" variant="ghost" aria-label={`Delete request from ${r.supplier_name}`} onClick={() => remove(r)}>
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      )}
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card>
            <SectionTitle>Our price vs supplier prices</SectionTitle>
            {deal.compare.below_cost_count > 0 && (
              <p className="mb-3 flex items-center gap-1.5 rounded-lg bg-error-50 px-3 py-2 text-sm text-error-700" role="alert">
                <AlertTriangle className="h-4 w-4" aria-hidden="true" />
                {deal.compare.below_cost_count} price{deal.compare.below_cost_count === 1 ? ' is' : 's are'} below a supplier’s cost.
              </p>
            )}
            {deal.compare.rows.length === 0 ? (
              <p className="text-sm text-secondary-500">No quote lines to compare yet.</p>
            ) : (
              <div className="-mx-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
                <table className="w-full min-w-[32rem] text-sm">
                  <thead>
                    <tr className="border-b border-secondary-200 text-left text-xs uppercase tracking-wider text-secondary-500">
                      <th className="py-2 pr-3 font-semibold">Line</th>
                      <th className="py-2 pr-3 text-right font-semibold">Our price</th>
                      {suppliersInCompare.map((s) => (
                        <th key={s.uuid} className="py-2 pr-3 text-right font-semibold">{s.name}</th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {deal.compare.rows.map((row) => (
                      <tr key={row.line_uuid} className="border-b border-secondary-100 align-top">
                        <td className="py-2 pr-3 text-secondary-900">
                          {row.qty} × {row.description}
                        </td>
                        <td className="py-2 pr-3 text-right text-secondary-900">{formatMoney(row.our_unit_minor, currency)}</td>
                        {row.suppliers.map((c) => (
                          <td key={c.request_uuid} className={`py-2 pr-3 text-right ${c.below_cost ? 'bg-error-50' : ''}`}>
                            {c.cost_unit_minor == null ? (
                              <span className="text-secondary-400">—</span>
                            ) : (
                              <>
                                <span className="block text-secondary-900">{formatMoney(c.cost_unit_minor, currency)}</span>
                                <span className={`block text-xs ${c.below_cost ? 'font-semibold text-error-700' : 'text-success-700'}`}>
                                  {c.below_cost ? 'Below cost: ' : 'Profit '}
                                  {formatMoney(c.profit_line_minor ?? 0, currency)}
                                </span>
                              </>
                            )}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
                <p className="mt-2 text-xs text-secondary-500">
                  Each price ex VAT; profit is for the whole line. Our prices from {deal.lines_from ?? 'the quote'}, before whole-quote discounts.
                </p>
              </div>
            )}
          </Card>

          <Card>
            <SectionTitle>Internal notes</SectionTitle>
            {deal.notes.length === 0 ? (
              <p className="text-sm text-secondary-500">No notes yet.</p>
            ) : (
              <ul className="space-y-3">
                {deal.notes.map((n) => (
                  <li key={n.kind + n.uuid}>
                    <Link href={`/dashboard/shop/${n.kind === 'order' ? 'orders' : 'quotes'}/${n.uuid}`} className="text-xs font-semibold text-primary-700 hover:underline">{n.source}</Link>
                    <p className="whitespace-pre-line text-sm text-secondary-800">{n.text}</p>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>

        <div className="space-y-6">
          <Card>
            <SectionTitle>Customer</SectionTitle>
            <dl className="text-sm">
              {[
                ['Name', deal.customer.name],
                ['Company', deal.customer.company],
                ['Email', deal.customer.email],
                ['Phone', deal.customer.phone],
              ].map(([label, value]) => (
                <div key={label} className="flex justify-between gap-4 py-1">
                  <dt className="text-secondary-500">{label}</dt>
                  <dd className="min-w-0 break-all text-right text-secondary-900">{value || '—'}</dd>
                </div>
              ))}
            </dl>
            {deal.leads.length > 0 && (
              <p className="mt-2 text-xs text-secondary-500">
                CRM lead: {deal.leads.map((l) => `${l.name || l.email} (${humanize(l.status)})`).join(', ')}
              </p>
            )}
          </Card>

          <Card>
            <SectionTitle>Customer quotes</SectionTitle>
            {deal.quotes.length === 0 ? (
              <p className="text-sm text-secondary-500">None.</p>
            ) : (
              <ul className="divide-y divide-secondary-100">
                {deal.quotes.map((q) => (
                  <li key={q.uuid} className="flex items-center justify-between gap-2 py-2">
                    <div className="min-w-0">
                      <Link href={`/dashboard/shop/quotes/${q.uuid}`} className="font-mono text-sm text-primary-700 hover:underline">{q.quote_number}</Link>
                      <p className="text-xs text-secondary-500">
                        {q.kind === 'order' ? 'Order Authorisation' : 'Quote'} · {formatMoney(q.total_minor, q.currency)} · {formatDateTime(q.created_at)}
                      </p>
                    </div>
                    <QuoteStatusBadge status={q.superseded ? 'superseded' : q.status} />
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card>
            <SectionTitle>Orders</SectionTitle>
            {deal.orders.length === 0 ? (
              <p className="text-sm text-secondary-500">None yet.</p>
            ) : (
              <ul className="divide-y divide-secondary-100">
                {deal.orders.map((o) => (
                  <li key={o.uuid} className="flex items-center justify-between gap-2 py-2">
                    <div className="min-w-0">
                      <Link href={`/dashboard/shop/orders/${o.uuid}`} className="font-mono text-sm text-primary-700 hover:underline">{o.order_number}</Link>
                      <p className="text-xs text-secondary-500">{formatMoney(o.total_minor, o.currency)}{o.paid_at ? ` · paid ${formatDateTime(o.paid_at)}` : ''}</p>
                    </div>
                    <OrderStatusBadge status={o.status} />
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card>
            <SectionTitle>Purchase orders to suppliers</SectionTitle>
            {deal.purchase_orders.length === 0 ? (
              <p className="text-sm text-secondary-500">None yet. Raise one from the paid order.</p>
            ) : (
              <ul className="divide-y divide-secondary-100">
                {deal.purchase_orders.map((p) => (
                  <li key={p.uuid} className="py-2">
                    <div className="flex items-center justify-between gap-2">
                      <Link href={`/dashboard/purchase-orders/${p.uuid}`} className="inline-flex items-center gap-1 font-mono text-sm text-primary-700 hover:underline">
                        <FileText className="h-3.5 w-3.5" aria-hidden="true" />
                        {p.po_number}
                      </Link>
                      <Badge size="sm">{humanize(p.status)}</Badge>
                    </div>
                    <p className="text-xs text-secondary-500">{p.supplier_name} · {formatMoney(Math.round(Number(p.total) * 100), p.currency)}</p>
                    {p.drop_ship && (
                      <p className={`mt-1 inline-flex items-center gap-1 text-xs ${p.legacy_drop_ship ? 'text-warning-700' : 'text-secondary-600'}`}>
                        <Truck className="h-3.5 w-3.5" aria-hidden="true" />
                        {p.legacy_drop_ship ? 'Drop-ship raised before deal codes (no confirmation recorded)' : 'Drop-ship, confirmed by staff'}
                      </p>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card>
            <SectionTitle>Activity</SectionTitle>
            <p className="mb-2 text-xs text-secondary-500">Who viewed or changed the link between the customer and suppliers.</p>
            <ul className="max-h-80 space-y-2 overflow-y-auto text-sm">
              {deal.audit.map((a, i) => (
                <li key={i}>
                  <p className="text-secondary-800">{AUDIT_LABEL[a.action] ?? humanize(a.action)}{a.detail && typeof a.detail.po_number === 'string' ? ` ${a.detail.po_number}` : ''}{a.detail && typeof a.detail.number === 'string' ? ` (${a.detail.number})` : ''}</p>
                  <p className="text-xs text-secondary-500">{a.by ?? 'System'} · {formatDateTime(a.at)}</p>
                </li>
              ))}
            </ul>
          </Card>
        </div>
      </div>
      <p className="text-xs text-secondary-500">
        <ExternalLink className="mr-1 inline h-3 w-3" aria-hidden="true" />
        Find any deal with search (Ctrl+K): type a deal code, WSQ quote number, order number, a supplier’s quote reference or the customer’s email.
      </p>
    </div>
  );
}

export default function DealPage() {
  return (
    <ProtectedPage module="shop" title="Deal">
      <DealDetail />
    </ProtectedPage>
  );
}
