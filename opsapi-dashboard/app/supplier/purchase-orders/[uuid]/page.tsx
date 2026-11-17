'use client';

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import {
  ArrowLeft,
  CheckCircle2,
  Download,
  ExternalLink,
  FileText,
  PackageCheck,
  Truck,
  Upload,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { Modal, promptDialog } from '@/components/ui';
import {
  BalanceSummary,
  FileField,
  InvoiceFields,
  MessageThread,
  SectionCard,
  StageBadge,
  StageSteps,
  Timeline,
  btnPrimary,
  btnSecondary,
  btnSmall,
  emptyInvoice,
  fmtDate,
  fmtDateTime,
  fmtMoney,
  fmtSize,
  inputClass,
  invoiceProblem,
  labelClass,
  tidyInvoice,
} from '@/components/supplier-portal/shared';
import { useSupplierMe } from '@/components/supplier-portal/SupplierPortalContext';
import { DeliveredModal, DispatchModal } from '@/components/supplier-portal/forms';
import { generatePurchaseOrderPdf } from '@/lib/purchase-order-pdf';
import type { PurchaseOrder } from '@/services/purchase-orders.service';
import {
  DOC_INVOICE_KIND,
  DOC_TYPE_LABELS,
  INVOICE_KIND_LABELS,
  SUPPLIER_DOC_TYPES,
  checkUploadFile,
  openDownload,
  portalError,
  supplierPortalService,
  type DeliveredInput,
  type DispatchInput,
  type PortalDocType,
  type SupplierCan,
  type SupplierPoDetail,
  type SupplierPurchaseOrder,
} from '@/services/supplier-portal.service';

const num = (v: unknown) => Number(v ?? 0) || 0;

/** The supplier's view of the PO, shaped for the shared PDF builder. */
function toPdfPo(po: SupplierPurchaseOrder, supplierName: string): PurchaseOrder {
  return {
    uuid: po.id,
    po_number: po.po_number,
    status: 'sent',
    supplier_name: supplierName,
    reference: po.reference ?? null,
    issue_date: po.issue_date,
    expected_date: po.expected_date ?? null,
    delivery_address: po.delivery_address ?? null,
    currency: po.currency || 'GBP',
    notes: po.notes ?? null,
    terms: po.terms ?? null,
    subtotal: num(po.subtotal),
    tax_total: num(po.tax_total),
    total: num(po.total),
    metadata: {
      receipts: [],
      bills: [],
      deal_code: po.deal_code ?? null,
      drop_ship: po.drop_ship,
      delivery_method: po.delivery_method ?? null,
      supplier_account_number: po.supplier_account_number ?? null,
      end_customer_po: po.end_customer_po ?? null,
      bill_to: po.buyer?.bill_to ? { line1: po.buyer.bill_to } : null,
    },
    items: po.items.map((it, i) => ({
      uuid: `line-${i}`,
      description: it.description,
      quantity: num(it.quantity),
      unit_price: num(it.unit_price),
      tax_rate: num(it.tax_rate),
      tax_amount: num(it.tax_amount),
      line_total: num(it.line_total),
      received_quantity: 0,
      billed_quantity: 0,
      billed_net: 0,
      billed_tax: 0,
    })),
    created_at: po.issue_date,
    updated_at: po.issue_date,
  };
}

/** The document types this supplier may upload right now. */
function allowedTypes(can: SupplierCan): PortalDocType[] {
  return SUPPLIER_DOC_TYPES.filter((t) => {
    if (t === 'proforma') return can.upload_proforma;
    if (t === 'vat_invoice' || t === 'credit_note') return can.upload_invoice;
    return can.upload;
  });
}

// ============================================
// Upload a document
// ============================================

function UploadModal({
  isOpen,
  onClose,
  poUuid,
  types,
  initialType,
  onDone,
}: {
  isOpen: boolean;
  onClose: () => void;
  poUuid: string;
  types: PortalDocType[];
  initialType?: PortalDocType;
  onDone: () => void;
}) {
  const [docType, setDocType] = useState<PortalDocType>(types[0] ?? 'other');
  const [file, setFile] = useState<File | null>(null);
  const [note, setNote] = useState('');
  const [invoice, setInvoice] = useState(emptyInvoice());
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setDocType(initialType && types.includes(initialType) ? initialType : types[0] ?? 'other');
    setFile(null);
    setNote('');
    setInvoice(emptyInvoice());
  }, [isOpen, initialType, types]);

  const kind = DOC_INVOICE_KIND[docType];
  const kindLabel = kind ? INVOICE_KIND_LABELS[kind] : '';

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const fileProblem = checkUploadFile(file);
    if (fileProblem) return void toast.error(fileProblem);
    if (kind) {
      const p = invoiceProblem(invoice, kindLabel);
      if (p) return void toast.error(p);
    }
    setSaving(true);
    try {
      await supplierPortalService.uploadDocument(poUuid, {
        file: file as File,
        doc_type: docType,
        note,
        invoice: kind ? tidyInvoice(invoice) : undefined,
      });
      toast.success(`${DOC_TYPE_LABELS[docType]} uploaded`);
      onDone();
      onClose();
    } catch (err) {
      toast.error(portalError(err, 'The document could not be uploaded').message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Upload a document" size="lg">
      <form onSubmit={submit} className="space-y-4">
        <div>
          <label className={labelClass}>What is it? *</label>
          <select className={inputClass} value={docType} onChange={(e) => setDocType(e.target.value as PortalDocType)}>
            {types.map((t) => (
              <option key={t} value={t}>
                {DOC_TYPE_LABELS[t]}
              </option>
            ))}
          </select>
        </div>
        <FileField label="File" file={file} onChange={setFile} required />
        {kind && (
          <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3">
            <p className="mb-3 text-sm text-secondary-700">Type in the main details from the {kindLabel.toLowerCase()}:</p>
            <InvoiceFields value={invoice} onChange={setInvoice} label={kindLabel} />
          </div>
        )}
        <div>
          <label className={labelClass}>Note (optional)</label>
          <textarea className={inputClass} value={note} maxLength={1000} onChange={(e) => setNote(e.target.value)} />
        </div>
        <div className="flex justify-end gap-2">
          <button type="button" className={btnSecondary} onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className={btnPrimary} disabled={saving}>
            <Upload className="h-4 w-4" />
            {saving ? 'Uploading…' : 'Upload'}
          </button>
        </div>
      </form>
    </Modal>
  );
}

// ============================================
// Page
// ============================================

export default function SupplierPurchaseOrderPage() {
  const { uuid } = useParams<{ uuid: string }>();
  const me = useSupplierMe();
  const [data, setData] = useState<SupplierPoDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [upload, setUpload] = useState<{ open: boolean; type?: PortalDocType }>({ open: false });
  const [dispatchOpen, setDispatchOpen] = useState(false);
  const [deliveredOpen, setDeliveredOpen] = useState(false);

  const load = useCallback(async () => {
    try {
      setData(await supplierPortalService.getPurchaseOrder(uuid));
      setError(null);
    } catch (err) {
      const e = portalError(err, 'This purchase order could not be loaded');
      setError(e.status === 404 ? 'Purchase order not found.' : e.message);
    } finally {
      setLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    void load();
  }, [load]);

  const download = useCallback(async (docId: string) => {
    try {
      openDownload(await supplierPortalService.documentLink(docId));
    } catch (err) {
      toast.error(portalError(err, 'The download could not be started').message);
    }
  }, []);

  const types = useMemo(() => (data ? allowedTypes(data.can) : []), [data]);

  if (loading) {
    return (
      <div className="space-y-3">
        {[0, 1, 2].map((i) => (
          <div key={i} className="h-24 animate-pulse rounded-xl bg-secondary-100" />
        ))}
      </div>
    );
  }

  if (!data) {
    return (
      <div className="rounded-xl border border-secondary-200 bg-surface p-8 text-center">
        <p className="text-secondary-700">{error || 'Purchase order not found.'}</p>
        <Link href="/supplier" className={`${btnSecondary} mt-4`}>
          <ArrowLeft className="h-4 w-4" />
          Back to purchase orders
        </Link>
      </div>
    );
  }

  const { purchase_order: po, can } = data;
  const cur = po.currency || 'GBP';
  const ourPo = [...data.documents].reverse().find((d) => d.doc_type === 'purchase_order');
  const hasPod = data.documents.some((d) => d.doc_type === 'proof_of_delivery' || d.doc_type === 'delivery_note');
  const buyerName = po.buyer?.name || me?.buyer.name || 'Us';

  const acknowledge = async () => {
    const note = await promptDialog({
      title: `Acknowledge ${po.po_number}?`,
      message: 'This tells us you have received the purchase order and will supply it.',
      label: 'Note (optional)',
      defaultValue: '',
      confirmText: 'Acknowledge',
    });
    if (note === null) return;
    setBusy(true);
    try {
      setData(await supplierPortalService.acknowledge(po.id, note.trim() || undefined));
      toast.success('Purchase order acknowledged');
    } catch (err) {
      toast.error(portalError(err, 'Could not acknowledge').message);
    } finally {
      setBusy(false);
    }
  };

  const downloadOurPo = () => {
    if (ourPo) return void download(ourPo.id);
    generatePurchaseOrderPdf(toPdfPo(po, me?.supplier.name || 'Supplier'), { name: buyerName });
  };

  const saveDispatch = async (input: DispatchInput) => {
    try {
      await supplierPortalService.dispatch(po.id, input);
      toast.success('Dispatch saved');
      await load();
      return true;
    } catch (err) {
      toast.error(portalError(err, 'The dispatch could not be saved').message);
      return false;
    }
  };

  const saveDelivered = async (input: DeliveredInput, file: File | null) => {
    try {
      await supplierPortalService.delivered(po.id, input, file);
      toast.success('Marked as delivered');
      await load();
      return true;
    } catch (err) {
      toast.error(portalError(err, 'Could not mark it delivered').message);
      return false;
    }
  };

  const sendMessage = async (text: string) => {
    try {
      await supplierPortalService.postMessage(po.id, text);
      await load();
      return true;
    } catch (err) {
      toast.error(portalError(err, 'The message could not be sent').message);
      return false;
    }
  };

  return (
    <div className="space-y-5">
      {/* Header */}
      <div className="space-y-3">
        <Link href="/supplier" className="inline-flex items-center gap-1 text-sm text-secondary-600 hover:text-secondary-900">
          <ArrowLeft className="h-4 w-4" />
          Purchase orders
        </Link>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="text-xl font-semibold text-secondary-900 sm:text-2xl">Purchase order {po.po_number}</h1>
              <StageBadge stage={po.stage} label={po.stage_label} />
            </div>
            <p className="mt-1 text-sm text-secondary-500">
              From {buyerName} · {fmtDate(po.issue_date)}
              {po.expected_date ? ` · Needed by ${fmtDate(po.expected_date)}` : ''}
            </p>
          </div>
          <div className="text-left sm:text-right">
            <p className="text-xs text-secondary-500">Total</p>
            <p className="text-xl font-semibold text-secondary-900">{fmtMoney(po.total, cur)}</p>
          </div>
        </div>
        <StageSteps stage={po.stage} />
        <div className="flex flex-wrap gap-2">
          <button type="button" className={btnSecondary} onClick={downloadOurPo}>
            <Download className="h-4 w-4" />
            Download our PO
          </button>
          {can.acknowledge && (
            <button type="button" className={btnPrimary} onClick={acknowledge} disabled={busy}>
              <CheckCircle2 className="h-4 w-4" />
              Acknowledge
            </button>
          )}
          {types.length > 0 && (
            <button type="button" className={btnSecondary} onClick={() => setUpload({ open: true })}>
              <Upload className="h-4 w-4" />
              Upload document
            </button>
          )}
          {can.dispatch && (
            <button type="button" className={btnSecondary} onClick={() => setDispatchOpen(true)}>
              <Truck className="h-4 w-4" />
              Enter dispatch
            </button>
          )}
          {can.mark_delivered && (
            <button type="button" className={btnSecondary} onClick={() => setDeliveredOpen(true)}>
              <PackageCheck className="h-4 w-4" />
              Mark delivered
            </button>
          )}
        </div>
      </div>

      {/* Order */}
      <SectionCard title="What we ordered">
        <div className="mb-4 grid grid-cols-1 gap-4 text-sm sm:grid-cols-2 lg:grid-cols-3">
          <div>
            <p className="text-xs text-secondary-500">Buyer</p>
            <p className="font-medium text-secondary-900">{buyerName}</p>
            {po.buyer?.bill_to && <p className="text-secondary-600">{po.buyer.bill_to}</p>}
          </div>
          {po.deal_code && (
            <div>
              <p className="text-xs text-secondary-500">Deal code (please quote it on your paperwork)</p>
              <p className="font-mono font-medium text-secondary-900">{po.deal_code}</p>
            </div>
          )}
          {po.reference && po.reference !== po.deal_code && (
            <div>
              <p className="text-xs text-secondary-500">Reference</p>
              <p className="text-secondary-900">{po.reference}</p>
            </div>
          )}
          {po.supplier_account_number && (
            <div>
              <p className="text-xs text-secondary-500">Our account number with you</p>
              <p className="text-secondary-900">{po.supplier_account_number}</p>
            </div>
          )}
          {po.delivery_address && (
            <div>
              <p className="text-xs text-secondary-500">{po.drop_ship ? 'Deliver directly to' : 'Deliver to'}</p>
              <p className="whitespace-pre-line text-secondary-900">{po.delivery_address}</p>
              {po.end_customer_po && <p className="text-xs text-secondary-600">Their PO: {po.end_customer_po}</p>}
            </div>
          )}
          {po.delivery_method && (
            <div>
              <p className="text-xs text-secondary-500">Delivery</p>
              <p className="text-secondary-900">{po.delivery_method}</p>
            </div>
          )}
        </div>

        <div className="-mx-4 overflow-x-auto sm:mx-0">
          <table className="w-full min-w-[520px] text-sm">
            <thead className="bg-secondary-50 text-left text-xs uppercase tracking-wide text-secondary-500">
              <tr>
                <th className="px-3 py-2">Item</th>
                <th className="px-3 py-2 text-right">Qty</th>
                <th className="px-3 py-2 text-right">Unit price</th>
                <th className="px-3 py-2 text-right">VAT</th>
                <th className="px-3 py-2 text-right">Line total</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-secondary-100">
              {po.items.map((it, i) => (
                <tr key={i}>
                  <td className="whitespace-pre-line px-3 py-2 text-secondary-900">{it.description}</td>
                  <td className="px-3 py-2 text-right">{num(it.quantity)}</td>
                  <td className="px-3 py-2 text-right">{fmtMoney(it.unit_price, cur)}</td>
                  <td className="px-3 py-2 text-right">{num(it.tax_rate) ? `${num(it.tax_rate)}%` : '—'}</td>
                  <td className="px-3 py-2 text-right font-medium">{fmtMoney(it.line_total, cur)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <dl className="ml-auto mt-3 w-full max-w-xs space-y-1 text-sm">
          <div className="flex justify-between">
            <dt className="text-secondary-500">Net</dt>
            <dd>{fmtMoney(po.subtotal, cur)}</dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-secondary-500">VAT</dt>
            <dd>{fmtMoney(po.tax_total, cur)}</dd>
          </div>
          <div className="flex justify-between border-t border-secondary-200 pt-1 font-semibold">
            <dt>Total</dt>
            <dd>{fmtMoney(po.total, cur)}</dd>
          </div>
        </dl>
        {(po.notes || po.terms) && (
          <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2">
            {po.notes && (
              <div className="rounded-lg bg-amber-50 p-3 text-sm">
                <p className="mb-1 font-medium text-amber-900">Notes</p>
                <p className="whitespace-pre-line text-amber-800">{po.notes}</p>
              </div>
            )}
            {po.terms && (
              <div className="rounded-lg bg-secondary-50 p-3 text-sm">
                <p className="mb-1 font-medium text-secondary-900">Terms</p>
                <p className="whitespace-pre-line text-secondary-700">{po.terms}</p>
              </div>
            )}
          </div>
        )}
      </SectionCard>

      {/* Payments */}
      <SectionCard title="Payments">
        <BalanceSummary balance={data.balance} view="supplier" />
        {data.payments.length > 0 ? (
          <ul className="mt-4 divide-y divide-secondary-100 text-sm">
            {data.payments.map((p) => (
              <li key={p.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5">
                <div>
                  <p className="font-medium text-secondary-900">
                    {fmtMoney(p.amount, p.currency)} · {p.method_label}
                  </p>
                  <p className="text-xs text-secondary-500">
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
        ) : (
          <p className="mt-4 text-sm text-secondary-500">No payments yet.</p>
        )}
      </SectionCard>

      {/* Proforma & invoices */}
      <SectionCard
        title="Your proforma and invoices"
        actions={
          (can.upload_proforma || can.upload_invoice) && (
            <button
              type="button"
              className={btnSmall}
              onClick={() => setUpload({ open: true, type: can.upload_proforma ? 'proforma' : 'vat_invoice' })}
            >
              <Upload className="h-3.5 w-3.5" />
              Upload
            </button>
          )
        }
      >
        {data.invoices.length === 0 ? (
          <p className="text-sm text-secondary-500">
            None yet. Upload your proforma invoice{can.upload_invoice ? ', and your final VAT invoice once delivered' : ''}.
          </p>
        ) : (
          <ul className="divide-y divide-secondary-100 text-sm">
            {data.invoices.map((inv) => (
              <li key={inv.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5">
                <div>
                  <p className="font-medium text-secondary-900">
                    {inv.label || INVOICE_KIND_LABELS[inv.kind]} {inv.number}
                  </p>
                  <p className="text-xs text-secondary-500">
                    {fmtDate(inv.invoice_date)} · Net {fmtMoney(inv.net, inv.currency)} · VAT {fmtMoney(inv.vat, inv.currency)} ·
                    Total {fmtMoney(inv.total, inv.currency)}
                    {inv.due_date ? ` · due ${fmtDate(inv.due_date)}` : ''}
                  </p>
                </div>
                {inv.document_id && (
                  <button type="button" className={btnSmall} onClick={() => download(inv.document_id as string)}>
                    <Download className="h-3.5 w-3.5" />
                    Download
                  </button>
                )}
              </li>
            ))}
          </ul>
        )}
      </SectionCard>

      {/* Deliveries */}
      <SectionCard title="Deliveries">
        {data.shipments.length === 0 ? (
          <p className="text-sm text-secondary-500">
            Nothing dispatched yet.{can.dispatch ? ' Use “Enter dispatch” when the goods leave you.' : ''}
          </p>
        ) : (
          <ul className="divide-y divide-secondary-100 text-sm">
            {data.shipments.map((s) => (
              <li key={s.id} className="space-y-1 py-2.5">
                <p className="font-medium text-secondary-900">
                  {s.carrier}
                  {s.tracking_number ? ` · ${s.tracking_number}` : ''}
                </p>
                <p className="text-xs text-secondary-500">
                  Dispatched {fmtDate(s.dispatched_on)}
                  {s.expected_on ? ` · expected ${fmtDate(s.expected_on)}` : ''}
                  {s.delivered_on ? ` · delivered ${fmtDate(s.delivered_on)}` : ''}
                  {s.received_by ? ` · received by ${s.received_by}` : ''}
                </p>
                <div className="flex flex-wrap gap-2">
                  {s.tracking_url && (
                    <a href={s.tracking_url} target="_blank" rel="noopener noreferrer" className={btnSmall}>
                      <ExternalLink className="h-3.5 w-3.5" />
                      Track
                    </a>
                  )}
                  {s.pod_document_id && (
                    <button type="button" className={btnSmall} onClick={() => download(s.pod_document_id as string)}>
                      <Download className="h-3.5 w-3.5" />
                      Proof of delivery
                    </button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}
      </SectionCard>

      {/* Documents */}
      <SectionCard
        title="Documents"
        actions={
          types.length > 0 && (
            <button type="button" className={btnSmall} onClick={() => setUpload({ open: true })}>
              <Upload className="h-3.5 w-3.5" />
              Upload
            </button>
          )
        }
      >
        {data.documents.length === 0 ? (
          <p className="text-sm text-secondary-500">No documents yet.</p>
        ) : (
          <ul className="divide-y divide-secondary-100 text-sm">
            {data.documents.map((d) => (
              <li key={d.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5">
                <div className="flex min-w-0 items-start gap-2">
                  <FileText className="mt-0.5 h-4 w-4 shrink-0 text-secondary-400" />
                  <div className="min-w-0">
                    <p className="truncate font-medium text-secondary-900">{d.filename}</p>
                    <p className="text-xs text-secondary-500">
                      {d.label} · {d.uploaded_by || (d.uploaded_by_kind === 'staff' ? buyerName : 'You')} · {fmtDateTime(d.created_at)}
                      {d.size ? ` · ${fmtSize(d.size)}` : ''}
                    </p>
                    {d.note && <p className="text-xs text-secondary-600">{d.note}</p>}
                  </div>
                </div>
                <button type="button" className={btnSmall} onClick={() => download(d.id)}>
                  <Download className="h-3.5 w-3.5" />
                  Download
                </button>
              </li>
            ))}
          </ul>
        )}
      </SectionCard>

      {/* Messages */}
      <SectionCard title={`Messages with ${buyerName}`}>
        <MessageThread
          messages={data.messages}
          mine="supplier"
          canSend={can.message}
          onSend={sendMessage}
          placeholder={`Write to ${buyerName} about this order`}
        />
      </SectionCard>

      {/* History */}
      <SectionCard title="History">
        <Timeline entries={data.timeline} view="supplier" />
      </SectionCard>

      <UploadModal
        isOpen={upload.open}
        onClose={() => setUpload({ open: false })}
        poUuid={po.id}
        types={types}
        initialType={upload.type}
        onDone={load}
      />
      <DispatchModal isOpen={dispatchOpen} onClose={() => setDispatchOpen(false)} onSubmit={saveDispatch} />
      <DeliveredModal isOpen={deliveredOpen} onClose={() => setDeliveredOpen(false)} hasPod={hasPod} onSubmit={saveDelivered} />
    </div>
  );
}
