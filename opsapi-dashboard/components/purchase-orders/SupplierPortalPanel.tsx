'use client';

/**
 * The supplier portal panel on the staff PO page: stage, documents, proforma / invoices, payments,
 * dispatch and delivery, messages with the supplier and the full history.
 * GET /api/v2/purchase-orders/:uuid/portal; every change answers with the refreshed panel.
 */
import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import {
  AlertTriangle,
  Ban,
  CheckCircle2,
  Download,
  Eye,
  EyeOff,
  FileText,
  Link2,
  Lock,
  PackageCheck,
  PoundSterling,
  Receipt,
  Share2,
  Trash2,
  Truck,
  Undo2,
  Upload,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { Modal, alertDialog, confirmDialog, promptDialog } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { cn } from '@/lib/utils';
import { purchaseOrderPdfBase64 } from '@/lib/purchase-order-pdf';
import type { InvoiceCompany } from '@/lib/invoice-pdf';
import type { PurchaseOrder } from '@/services/purchase-orders.service';
import { shopService } from '@/services/shop.service';
import type { ShopSupplier } from '@/types/shop';
import {
  BalanceSummary,
  FileField,
  InvoiceFields,
  MessageThread,
  SectionCard,
  StageBadge,
  StageSteps,
  Timeline,
  btnDanger,
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
  todayIso,
} from '@/components/supplier-portal/shared';
import { DeliveredModal, DispatchModal } from '@/components/supplier-portal/forms';
import {
  DOC_INVOICE_KIND,
  DOC_TYPE_LABELS,
  INVOICE_KIND_LABELS,
  PAYMENT_METHOD_LABELS,
  STAFF_DOC_TYPES,
  checkUploadFile,
  openDownload,
  portalError,
  purchaseOrderPortalService as api,
  type DeliveredInput,
  type DispatchInput,
  type InvoiceKind,
  type PaymentInput,
  type PaymentMethod,
  type PortalDocType,
  type PortalPayment,
  type StaffPanel,
} from '@/services/supplier-portal.service';

const KIND_DOC_TYPE: Record<InvoiceKind, PortalDocType> = {
  proforma: 'proforma',
  invoice: 'vat_invoice',
  credit_note: 'credit_note',
};

const DISPATCH_STAGES = ['sent', 'acknowledged', 'proforma_received', 'part_paid', 'paid', 'dispatched'];

/** Tell staff what happened to the supplier email after a change. */
function notifyToast(panel: StaffPanel) {
  const n = panel.notification as { sent?: number; suppressed?: string } | undefined;
  if (!n) return;
  if (n.sent && n.sent > 0) toast.success(`The supplier was emailed (${n.sent})`);
  else if (n.suppressed === 'disabled') toast('Nothing was emailed: supplier emails are off. They see it when they sign in.');
  else if (n.suppressed === 'no_recipients') toast('Nothing was emailed: the supplier has no portal login yet.');
}

function pdfFile(po: PurchaseOrder, company: InvoiceCompany): File {
  const { base64, filename } = purchaseOrderPdfBase64(po, company);
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new File([bytes], filename, { type: 'application/pdf' });
}

// ============================================
// Upload a document
// ============================================

function UploadModal({
  isOpen,
  onClose,
  onSubmit,
}: {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (input: {
    file: File;
    doc_type: PortalDocType;
    note: string;
    visible: boolean;
    invoice?: ReturnType<typeof emptyInvoice>;
  }) => Promise<boolean>;
}) {
  const [docType, setDocType] = useState<PortalDocType>('proforma');
  const [file, setFile] = useState<File | null>(null);
  const [note, setNote] = useState('');
  const [visible, setVisible] = useState(true);
  const [invoice, setInvoice] = useState(emptyInvoice());
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    if (!isOpen) return;
    setDocType('proforma');
    setFile(null);
    setNote('');
    setVisible(true);
    setInvoice(emptyInvoice());
  }, [isOpen]);
  const kind = DOC_INVOICE_KIND[docType];
  const kindLabel = kind ? INVOICE_KIND_LABELS[kind] : '';

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const fp = checkUploadFile(file);
    if (fp) return void toast.error(fp);
    if (kind) {
      const p = invoiceProblem(invoice, kindLabel);
      if (p) return void toast.error(p);
    }
    setSaving(true);
    try {
      const ok = await onSubmit({
        file: file as File,
        doc_type: docType,
        note,
        visible,
        invoice: kind ? tidyInvoice(invoice) : undefined,
      });
      if (ok) onClose();
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Upload a document" size="lg">
      <form onSubmit={submit} className="space-y-4">
        <div>
          <label className={labelClass}>Type *</label>
          <select className={inputClass} value={docType} onChange={(e) => setDocType(e.target.value as PortalDocType)}>
            {STAFF_DOC_TYPES.map((t) => (
              <option key={t} value={t}>
                {DOC_TYPE_LABELS[t]}
              </option>
            ))}
          </select>
        </div>
        <FileField label="File" file={file} onChange={setFile} required />
        {kind && (
          <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3">
            <p className="mb-3 text-sm text-secondary-700">The {kindLabel.toLowerCase()}&rsquo;s details:</p>
            <InvoiceFields value={invoice} onChange={setInvoice} label={kindLabel} />
          </div>
        )}
        <div>
          <label className={labelClass}>Note</label>
          <textarea className={inputClass} value={note} maxLength={1000} onChange={(e) => setNote(e.target.value)} />
        </div>
        <label className="flex items-center gap-2 text-sm text-secondary-700">
          <input type="checkbox" checked={visible} onChange={(e) => setVisible(e.target.checked)} />
          Visible to the supplier
        </label>
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
// Record a proforma / invoice / credit note
// ============================================

function InvoiceModal({
  isOpen,
  onClose,
  onSubmit,
}: {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (kind: InvoiceKind, invoice: ReturnType<typeof emptyInvoice>, file: File | null, visible: boolean) => Promise<boolean>;
}) {
  const [kind, setKind] = useState<InvoiceKind>('proforma');
  const [invoice, setInvoice] = useState(emptyInvoice());
  const [file, setFile] = useState<File | null>(null);
  const [visible, setVisible] = useState(true);
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    if (!isOpen) return;
    setKind('proforma');
    setInvoice(emptyInvoice());
    setFile(null);
    setVisible(true);
  }, [isOpen]);
  const label = INVOICE_KIND_LABELS[kind];

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const p = invoiceProblem(invoice, label);
    if (p) return void toast.error(p);
    if (file) {
      const fp = checkUploadFile(file);
      if (fp) return void toast.error(fp);
    }
    setSaving(true);
    try {
      if (await onSubmit(kind, tidyInvoice(invoice), file, visible)) onClose();
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Record proforma / invoice / credit note" size="lg">
      <form onSubmit={submit} className="space-y-4">
        <div>
          <label className={labelClass}>What is it? *</label>
          <select className={inputClass} value={kind} onChange={(e) => setKind(e.target.value as InvoiceKind)}>
            {(Object.keys(INVOICE_KIND_LABELS) as InvoiceKind[]).map((k) => (
              <option key={k} value={k}>
                {INVOICE_KIND_LABELS[k]}
              </option>
            ))}
          </select>
        </div>
        <InvoiceFields value={invoice} onChange={setInvoice} label={label} />
        <div>
          <label className={labelClass}>Internal note</label>
          <textarea
            className={inputClass}
            maxLength={1000}
            value={invoice.note ?? ''}
            onChange={(e) => setInvoice({ ...invoice, note: e.target.value })}
          />
        </div>
        <FileField
          label="The document (optional)"
          file={file}
          onChange={setFile}
          hint="Leave empty if it came by email and you only want to record the figures"
        />
        {file && (
          <label className="flex items-center gap-2 text-sm text-secondary-700">
            <input type="checkbox" checked={visible} onChange={(e) => setVisible(e.target.checked)} />
            Visible to the supplier
          </label>
        )}
        <div className="flex justify-end gap-2">
          <button type="button" className={btnSecondary} onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className={btnPrimary} disabled={saving}>
            <Receipt className="h-4 w-4" />
            {saving ? 'Saving…' : 'Record'}
          </button>
        </div>
      </form>
    </Modal>
  );
}

// ============================================
// Record a payment
// ============================================

function PaymentModal({
  isOpen,
  onClose,
  panel,
  onSubmit,
}: {
  isOpen: boolean;
  onClose: () => void;
  panel: StaffPanel;
  onSubmit: (input: PaymentInput, proof: File | null) => Promise<boolean>;
}) {
  const blank = (): PaymentInput => ({
    amount: '',
    method: 'faster_payment',
    sent_on: todayIso(),
    cleared_on: '',
    bank_transaction_id: '',
    payment_reference: panel.purchase_order.po_number || '',
    invoice_id: '',
    note: '',
  });
  const [form, setForm] = useState<PaymentInput>(blank);
  const [proof, setProof] = useState<File | null>(null);
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    if (!isOpen) return;
    const f = blank();
    const latest = [...panel.invoices].reverse().find((i) => i.kind !== 'credit_note' && !i.superseded);
    if (latest) f.invoice_id = latest.id;
    if (Number(panel.balance.balance) > 0) f.amount = String(panel.balance.balance);
    setForm(f);
    setProof(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen]);
  const set = (k: keyof PaymentInput) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) =>
    setForm((f) => ({ ...f, [k]: e.target.value }));
  const cur = panel.purchase_order.currency || 'GBP';

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const amount = form.amount.trim().replace(/,/g, '');
    if (!/^\d+(\.\d{1,2})?$/.test(amount) || Number(amount) <= 0) return void toast.error('Enter the amount, for example 5256.65');
    if (!form.sent_on) return void toast.error('Enter the date it was sent');
    if (form.cleared_on && form.cleared_on < form.sent_on) return void toast.error('It can’t clear before it was sent');
    if (proof) {
      const fp = checkUploadFile(proof);
      if (fp) return void toast.error(fp);
    }
    setSaving(true);
    try {
      if (await onSubmit({ ...form, amount }, proof)) onClose();
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Record a payment to the supplier" size="lg">
      <form onSubmit={submit} className="space-y-4">
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div>
            <label className={labelClass}>Amount ({cur}) *</label>
            <input inputMode="decimal" className={inputClass} value={form.amount} onChange={set('amount')} />
          </div>
          <div>
            <label className={labelClass}>Method *</label>
            <select className={inputClass} value={form.method} onChange={set('method')}>
              {(Object.keys(PAYMENT_METHOD_LABELS) as PaymentMethod[]).map((m) => (
                <option key={m} value={m}>
                  {PAYMENT_METHOD_LABELS[m]}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className={labelClass}>Date sent *</label>
            <input type="date" className={inputClass} value={form.sent_on} onChange={set('sent_on')} />
          </div>
          <div>
            <label className={labelClass}>Date cleared</label>
            <input type="date" className={inputClass} value={form.cleared_on} onChange={set('cleared_on')} />
          </div>
          <div>
            <label className={labelClass}>Our bank&rsquo;s transaction ID</label>
            <input className={inputClass} value={form.bank_transaction_id} onChange={set('bank_transaction_id')} />
          </div>
          <div>
            <label className={labelClass}>Payment reference</label>
            <input className={inputClass} value={form.payment_reference} onChange={set('payment_reference')} />
          </div>
        </div>
        <div>
          <label className={labelClass}>Against</label>
          <select className={inputClass} value={form.invoice_id} onChange={set('invoice_id')}>
            <option value="">The purchase order (no proforma / invoice)</option>
            {panel.invoices.map((i) => (
              <option key={i.id} value={i.id}>
                {INVOICE_KIND_LABELS[i.kind]} {i.number} · {fmtMoney(i.total, i.currency)}
                {i.superseded ? ' (superseded)' : ''}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label className={labelClass}>Note</label>
          <textarea className={inputClass} maxLength={1000} value={form.note} onChange={set('note')} />
        </div>
        <FileField
          label="Proof of payment (optional)"
          file={proof}
          onChange={setProof}
          hint="The bank’s confirmation: the supplier can download it"
        />
        <div className="flex justify-end gap-2">
          <button type="button" className={btnSecondary} onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className={btnPrimary} disabled={saving}>
            <PoundSterling className="h-4 w-4" />
            {saving ? 'Saving…' : 'Record payment'}
          </button>
        </div>
      </form>
    </Modal>
  );
}

// ============================================
// Mark a payment cleared
// ============================================

function ClearedModal({
  payment,
  onClose,
  onSubmit,
}: {
  payment: PortalPayment | null;
  onClose: () => void;
  onSubmit: (p: PortalPayment, body: { cleared_on: string; bank_transaction_id?: string }) => Promise<boolean>;
}) {
  const [date, setDate] = useState(todayIso());
  const [txn, setTxn] = useState('');
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    if (!payment) return;
    setDate(todayIso());
    setTxn(payment.bank_transaction_id || '');
  }, [payment]);
  if (!payment) return null;
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!date) return void toast.error('Enter the date it cleared');
    if (date < payment.sent_on) return void toast.error('It can’t clear before it was sent');
    setSaving(true);
    try {
      if (await onSubmit(payment, { cleared_on: date, bank_transaction_id: txn })) onClose();
    } finally {
      setSaving(false);
    }
  };
  return (
    <Modal isOpen onClose={onClose} title={`Mark ${fmtMoney(payment.amount, payment.currency)} cleared`} size="sm">
      <form onSubmit={submit} className="space-y-4">
        <div>
          <label className={labelClass}>Cleared on *</label>
          <input type="date" className={inputClass} value={date} onChange={(e) => setDate(e.target.value)} />
        </div>
        <div>
          <label className={labelClass}>Our bank&rsquo;s transaction ID</label>
          <input className={inputClass} value={txn} onChange={(e) => setTxn(e.target.value)} />
        </div>
        <div className="flex justify-end gap-2">
          <button type="button" className={btnSecondary} onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className={btnPrimary} disabled={saving}>
            {saving ? 'Saving…' : 'Save'}
          </button>
        </div>
      </form>
    </Modal>
  );
}

// ============================================
// Panel
// ============================================

export default function SupplierPortalPanel({
  po,
  company,
  onChanged,
}: {
  po: PurchaseOrder;
  company: InvoiceCompany;
  /** The PO's own status may have changed (acknowledged / cancelled here): reload the page's PO. */
  onChanged?: () => void;
}) {
  const { canUpdate, canDelete } = usePermissions();
  const mayUpdate = canUpdate('purchase_orders');
  const mayDelete = canDelete('purchase_orders');
  const [panel, setPanel] = useState<StaffPanel | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [suppliers, setSuppliers] = useState<ShopSupplier[] | null>(null);
  const [linkTo, setLinkTo] = useState('');
  const [uploadOpen, setUploadOpen] = useState(false);
  const [invoiceOpen, setInvoiceOpen] = useState(false);
  const [paymentOpen, setPaymentOpen] = useState(false);
  const [clearing, setClearing] = useState<PortalPayment | null>(null);
  const [dispatchOpen, setDispatchOpen] = useState(false);
  const [deliveredOpen, setDeliveredOpen] = useState(false);
  const [messageError, setMessageError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setPanel(await api.getPanel(po.uuid));
      setLoadError(null);
    } catch (err) {
      const e = portalError(err, 'The supplier panel could not be loaded');
      setLoadError(e.status === 404 && e.code === 'NOT_AVAILABLE' ? '' : e.message);
    }
  }, [po.uuid]);

  // Reload when the PO itself changes (sent, received, cancelled on the page above).
  useEffect(() => {
    void load();
  }, [load, po.status, po.updated_at]);

  // Suppliers to link to, only when the PO isn't linked yet.
  useEffect(() => {
    if (!panel || panel.supplier || suppliers !== null) return;
    shopService
      .getSuppliers()
      .then((list) => setSuppliers(list))
      .catch(() => setSuppliers([]));
  }, [panel, suppliers]);

  /** Run a change that answers with the refreshed panel. */
  const run = useCallback(
    async (fn: () => Promise<StaffPanel>, success: string, failure: string): Promise<boolean> => {
      setBusy(true);
      try {
        const p = await fn();
        setPanel(p);
        toast.success(success);
        notifyToast(p);
        return true;
      } catch (err) {
        toast.error(portalError(err, failure).message);
        return false;
      } finally {
        setBusy(false);
      }
    },
    []
  );

  const download = useCallback(
    async (docId: string) => {
      try {
        openDownload(await api.documentLink(po.uuid, docId));
      } catch (err) {
        toast.error(portalError(err, 'The download could not be started').message);
      }
    },
    [po.uuid]
  );

  if (loadError === '') return null; // the portal isn't set up in this deployment
  if (!panel) {
    return loadError ? (
      <div className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{loadError}</div>
    ) : (
      <div className="h-24 animate-pulse rounded-xl border border-secondary-200 bg-secondary-50" />
    );
  }

  const p = panel.purchase_order;
  const stage = p.stage;
  const open = stage !== 'closed' && stage !== 'cancelled';
  const hasPod = panel.documents.some(
    (d) => !d.deleted_at && (d.doc_type === 'proof_of_delivery' || d.doc_type === 'delivery_note')
  );

  // ---- stage ----
  const acknowledge = async () => {
    if (!(await confirmDialog({ title: `Mark ${p.po_number} acknowledged on the supplier’s behalf?`, confirmText: 'Mark acknowledged' })))
      return;
    if (await run(() => api.setStage(po.uuid, { to: 'acknowledged' }), 'Marked acknowledged', 'Could not change the stage')) onChanged?.();
  };
  const cancel = async () => {
    const reason = await promptDialog({
      title: `Cancel ${p.po_number}?`,
      message: panel.portal.supplier_can_see ? 'The supplier will see that it was cancelled.' : undefined,
      label: 'Reason',
      defaultValue: '',
      validate: (v) => (v.trim().length >= 3 ? null : 'Give a reason'),
      confirmText: 'Cancel purchase order',
      cancelText: 'Keep it',
      danger: true,
    });
    if (reason === null) return;
    if (await run(() => api.setStage(po.uuid, { to: 'cancelled', reason: reason.trim() }), 'Purchase order cancelled', 'Could not cancel'))
      onChanged?.();
  };
  const close = async () => {
    if (!(await confirmDialog({ title: `Close ${p.po_number}?`, message: 'Use this once everything is delivered, invoiced and paid.', confirmText: 'Close' })))
      return;
    setBusy(true);
    try {
      const res = await api.setStage(po.uuid, { to: 'closed' });
      setPanel(res);
      toast.success('Purchase order closed');
    } catch (err) {
      const e = portalError(err, 'Could not close');
      if (e.code !== 'CANNOT_CLOSE') {
        toast.error(e.message);
        return;
      }
      setBusy(false);
      const reason = await promptDialog({
        title: 'Close anyway?',
        message: e.message,
        label: 'Reason (required)',
        defaultValue: '',
        validate: (v) => (v.replace(/\s/g, '').length >= 3 ? null : 'Give a reason of at least 3 characters'),
        confirmText: 'Close anyway',
        danger: true,
      });
      if (reason === null) return;
      await run(
        () => api.setStage(po.uuid, { to: 'closed', force: true, reason: reason.trim() }),
        'Purchase order closed',
        'Could not close'
      );
    } finally {
      setBusy(false);
    }
  };

  // ---- supplier link ----
  const link = async () => {
    if (!linkTo) return void toast.error('Choose a supplier');
    await run(() => api.link(po.uuid, linkTo), 'Linked to the supplier', 'Could not link the supplier');
  };

  // ---- documents ----
  const upload = (input: { file: File; doc_type: PortalDocType; note: string; visible: boolean; invoice?: ReturnType<typeof emptyInvoice> }) =>
    run(
      () =>
        api.uploadDocument(po.uuid, {
          file: input.file,
          doc_type: input.doc_type,
          note: input.note,
          invoice: input.invoice,
          visible_to_supplier: input.visible,
        }),
      `${DOC_TYPE_LABELS[input.doc_type]} uploaded`,
      'The document could not be uploaded'
    );
  const sharePdf = async () => {
    if (po.items.length === 0) return void toast.error('Add at least one line first');
    const previous = panel.documents.some((d) => d.doc_type === 'purchase_order' && !d.deleted_at);
    if (
      !(await confirmDialog({
        title: 'Share our PO PDF with the supplier?',
        message: previous
          ? 'A copy is already shared. This adds the current version as a new document.'
          : 'The supplier can download it from the portal.',
        confirmText: 'Share PDF',
      }))
    )
      return;
    await run(
      () => api.uploadDocument(po.uuid, { file: pdfFile(po, company), doc_type: 'purchase_order', visible_to_supplier: true }),
      'Our PO PDF is shared with the supplier',
      'The PDF could not be shared'
    );
  };
  const removeDoc = async (id: string, name: string) => {
    const reason = await promptDialog({
      title: `Remove ${name}?`,
      message: 'The supplier no longer sees it. The file is kept for the record.',
      label: 'Reason',
      defaultValue: '',
      validate: (v) => (v.trim() ? null : 'Give a reason'),
      confirmText: 'Remove',
      danger: true,
    });
    if (reason === null) return;
    await run(() => api.removeDocument(po.uuid, id, reason.trim()), 'Document removed', 'Could not remove the document');
  };

  // ---- invoices ----
  const recordInvoice = (kind: InvoiceKind, invoice: ReturnType<typeof emptyInvoice>, file: File | null, visible: boolean) =>
    file
      ? run(
          () =>
            api.uploadDocument(po.uuid, { file, doc_type: KIND_DOC_TYPE[kind], invoice, visible_to_supplier: visible }),
          `${INVOICE_KIND_LABELS[kind]} recorded`,
          'Could not record it'
        )
      : run(() => api.recordInvoice(po.uuid, { ...invoice, kind }), `${INVOICE_KIND_LABELS[kind]} recorded`, 'Could not record it');
  const removeInvoice = async (id: string, name: string) => {
    const reason = await promptDialog({
      title: `Remove ${name}?`,
      label: 'Reason',
      defaultValue: '',
      validate: (v) => (v.trim() ? null : 'Give a reason'),
      confirmText: 'Remove',
      danger: true,
    });
    if (reason === null) return;
    await run(() => api.removeInvoice(po.uuid, id, reason.trim()), 'Removed', 'Could not remove it');
  };

  // ---- payments ----
  const recordPayment = (input: PaymentInput, proof: File | null) =>
    run(() => api.recordPayment(po.uuid, input, proof), 'Payment recorded', 'The payment could not be recorded');
  const markCleared = (pay: PortalPayment, body: { cleared_on: string; bank_transaction_id?: string }) =>
    run(() => api.updatePayment(po.uuid, pay.id, body), 'Payment marked cleared', 'Could not update the payment');
  const voidPayment = async (pay: PortalPayment) => {
    const reason = await promptDialog({
      title: `Void the ${fmtMoney(pay.amount, pay.currency)} payment?`,
      message: 'Only for a payment recorded by mistake. It stays in the history, crossed out.',
      label: 'Reason',
      defaultValue: '',
      validate: (v) => (v.trim() ? null : 'Give a reason'),
      confirmText: 'Void payment',
      danger: true,
    });
    if (reason === null) return;
    await run(() => api.voidPayment(po.uuid, pay.id, reason.trim()), 'Payment voided', 'Could not void the payment');
  };

  // ---- dispatch / delivery ----
  const saveDispatch = (input: DispatchInput) => run(() => api.dispatch(po.uuid, input), 'Dispatch recorded', 'Could not record the dispatch');
  const saveDelivered = (input: DeliveredInput, file: File | null) =>
    run(() => api.delivered(po.uuid, input, file), 'Marked delivered', 'Could not mark it delivered');

  // ---- messages ----
  const sendMessage = async (text: string): Promise<boolean> => {
    setMessageError(null);
    try {
      const res = await api.postMessage(po.uuid, text);
      setPanel(res);
      notifyToast(res);
      return true;
    } catch (err) {
      const e = portalError(err, 'The message could not be sent');
      if (e.code === 'CUSTOMER_DETAILS_FOR_SUPPLIER') {
        setMessageError(e.message);
        void alertDialog({ title: 'Not sent: it names our customer', message: e.message });
      } else toast.error(e.message);
      return false;
    }
  };

  const visibleLine = panel.portal.supplier_can_see
    ? 'The supplier can see this purchase order in their portal.'
    : !panel.portal.enabled
      ? 'The supplier can’t see it: the supplier portal is off (Shop → Settings).'
      : !panel.supplier
        ? 'The supplier can’t see it: link it to a shop supplier below.'
        : panel.supplier.users.length === 0 || !panel.supplier.portal_enabled
          ? 'The supplier can’t see it yet: invite a contact under Shop → Suppliers (Supplier portal logins).'
          : p.status === 'draft'
            ? 'The supplier will see it once it is sent.'
            : 'The supplier can’t see it yet.';

  return (
    <div className="space-y-4">
      <SectionCard
        title={
          <span className="flex flex-wrap items-center gap-2">
            Supplier portal <StageBadge stage={stage} label={p.stage_label} />
          </span>
        }
        actions={
          mayUpdate && (
            <>
              {panel.next_stages.includes('acknowledged') && (
                <button type="button" className={btnSmall} disabled={busy} onClick={acknowledge}>
                  <CheckCircle2 className="h-3.5 w-3.5" />
                  Mark acknowledged
                </button>
              )}
              {panel.next_stages.includes('closed') && (
                <button type="button" className={btnSmall} disabled={busy} onClick={close}>
                  <Lock className="h-3.5 w-3.5" />
                  Close
                </button>
              )}
              {panel.next_stages.includes('cancelled') && (
                <button type="button" className={btnDanger} disabled={busy} onClick={cancel}>
                  <Ban className="h-3.5 w-3.5" />
                  Cancel
                </button>
              )}
            </>
          )
        }
      >
        <div className="space-y-3">
          <StageSteps stage={stage} />
          <div
            className={cn(
              'rounded-lg border p-3 text-sm',
              panel.portal.emails_enabled ? 'border-blue-200 bg-blue-50 text-blue-900' : 'border-secondary-200 bg-secondary-50 text-secondary-800'
            )}
          >
            <p>{panel.portal.notice}</p>
            <p className="mt-1 flex items-center gap-1.5 font-medium">
              {panel.portal.supplier_can_see ? <Eye className="h-4 w-4" /> : <EyeOff className="h-4 w-4" />}
              {visibleLine}
            </p>
          </div>
          {panel.supplier ? (
            <p className="text-sm text-secondary-600">
              Supplier: <span className="font-medium text-secondary-900">{panel.supplier.name}</span> ·{' '}
              {panel.supplier.users.length === 0
                ? 'no portal logins'
                : `${panel.supplier.users.length} portal login${panel.supplier.users.length === 1 ? '' : 's'}`}{' '}
              ·{' '}
              <Link href="/dashboard/shop/suppliers" className="text-primary-700 hover:underline">
                Manage logins
              </Link>
            </p>
          ) : (
            mayUpdate && (
              <div className="flex flex-col gap-2 sm:flex-row sm:items-end">
                <div className="flex-1">
                  <label className={labelClass}>Link to supplier</label>
                  <select className={inputClass} value={linkTo} onChange={(e) => setLinkTo(e.target.value)}>
                    <option value="">{suppliers === null ? 'Loading suppliers…' : 'Choose a shop supplier'}</option>
                    {(suppliers ?? []).map((s) => (
                      <option key={s.uuid} value={s.uuid}>
                        {s.name}
                      </option>
                    ))}
                  </select>
                </div>
                <button type="button" className={btnPrimary} disabled={busy || !linkTo} onClick={link}>
                  <Link2 className="h-4 w-4" />
                  Link
                </button>
              </div>
            )
          )}
        </div>
      </SectionCard>

      {/* Documents */}
      <SectionCard
        title="Documents"
        actions={
          mayUpdate && (
            <>
              <button type="button" className={btnSmall} disabled={busy} onClick={sharePdf}>
                <Share2 className="h-3.5 w-3.5" />
                Share our PO PDF with the supplier
              </button>
              <button type="button" className={btnSmall} disabled={busy} onClick={() => setUploadOpen(true)}>
                <Upload className="h-3.5 w-3.5" />
                Upload
              </button>
            </>
          )
        }
      >
        {panel.documents.length === 0 ? (
          <p className="text-sm text-secondary-500">No documents yet.</p>
        ) : (
          <ul className="divide-y divide-secondary-100 text-sm">
            {panel.documents.map((d) => {
              const removed = !!d.deleted_at;
              return (
                <li key={d.id} className={cn('flex flex-wrap items-center justify-between gap-2 py-2.5', removed && 'opacity-50')}>
                  <div className="flex min-w-0 items-start gap-2">
                    <FileText className="mt-0.5 h-4 w-4 shrink-0 text-secondary-400" />
                    <div className="min-w-0">
                      <p className={cn('truncate font-medium text-secondary-900', removed && 'line-through')}>{d.filename}</p>
                      <p className="text-xs text-secondary-500">
                        {d.label} · {d.uploaded_by_kind === 'supplier' ? 'Supplier' : 'Us'}
                        {d.uploaded_by ? ` (${d.uploaded_by})` : ''} · {fmtDateTime(d.created_at)}
                        {d.size ? ` · ${fmtSize(d.size)}` : ''}
                        {d.visible_to_supplier === false ? ' · not shown to the supplier' : ''}
                      </p>
                      {d.note && <p className="text-xs text-secondary-600">{d.note}</p>}
                      {removed && (
                        <p className="text-xs text-red-700">
                          Removed {fmtDateTime(d.deleted_at)}
                          {d.delete_reason ? `: ${d.delete_reason}` : ''}
                        </p>
                      )}
                    </div>
                  </div>
                  {!removed && (
                    <div className="flex gap-2">
                      <button type="button" className={btnSmall} onClick={() => download(d.id)}>
                        <Download className="h-3.5 w-3.5" />
                        Download
                      </button>
                      {mayDelete && (
                        <button type="button" className={btnDanger} disabled={busy} onClick={() => removeDoc(d.id, d.filename)}>
                          <Trash2 className="h-3.5 w-3.5" />
                          Remove
                        </button>
                      )}
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </SectionCard>

      {/* Proforma & invoices */}
      <SectionCard
        title="Proforma & invoices"
        actions={
          mayUpdate && (
            <button type="button" className={btnSmall} disabled={busy} onClick={() => setInvoiceOpen(true)}>
              <Receipt className="h-3.5 w-3.5" />
              Record proforma / invoice / credit note
            </button>
          )
        }
      >
        {panel.invoices.length === 0 ? (
          <p className="text-sm text-secondary-500">None yet.</p>
        ) : (
          <ul className="divide-y divide-secondary-100 text-sm">
            {panel.invoices.map((inv) => (
              <li key={inv.id} className={cn('space-y-1.5 py-3', inv.superseded && 'opacity-60')}>
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div>
                    <p className="font-medium text-secondary-900">
                      {INVOICE_KIND_LABELS[inv.kind]} {inv.number}
                      {inv.superseded && (
                        <span className="ml-2 rounded bg-secondary-100 px-1.5 py-0.5 text-xs font-normal text-secondary-600">
                          superseded by a later proforma
                        </span>
                      )}
                    </p>
                    <p className="text-xs text-secondary-500">
                      {fmtDate(inv.invoice_date)} · Net {fmtMoney(inv.net, inv.currency)} · VAT {fmtMoney(inv.vat, inv.currency)} · Total{' '}
                      <span className="font-medium text-secondary-800">{fmtMoney(inv.total, inv.currency)}</span>
                      {inv.due_date ? ` · due ${fmtDate(inv.due_date)}` : ''}
                      {inv.supplier_order_ref ? ` · their ref ${inv.supplier_order_ref}` : ''}
                      {inv.payment_terms ? ` · ${inv.payment_terms}` : ''}
                      {inv.incoterm ? ` · ${inv.incoterm}` : ''}
                      {` · by ${inv.created_by_kind === 'supplier' ? 'the supplier' : 'us'}`}
                    </p>
                    {inv.bank_details && <p className="whitespace-pre-line text-xs text-secondary-600">Bank: {inv.bank_details}</p>}
                    {inv.note && <p className="text-xs text-secondary-600">Note: {inv.note}</p>}
                  </div>
                  <div className="flex gap-2">
                    {inv.document_id && (
                      <button type="button" className={btnSmall} onClick={() => download(inv.document_id as string)}>
                        <Download className="h-3.5 w-3.5" />
                        Download
                      </button>
                    )}
                    {mayDelete && (
                      <button
                        type="button"
                        className={btnDanger}
                        disabled={busy}
                        onClick={() => removeInvoice(inv.id, `${INVOICE_KIND_LABELS[inv.kind]} ${inv.number}`)}
                      >
                        <Trash2 className="h-3.5 w-3.5" />
                        Remove
                      </button>
                    )}
                  </div>
                </div>
                {(inv.flags ?? []).length > 0 && (
                  <ul className="space-y-1">
                    {(inv.flags ?? []).map((f) => (
                      <li
                        key={f.code}
                        className="flex items-start gap-1.5 rounded-md border border-amber-200 bg-amber-50 px-2 py-1 text-xs text-amber-900"
                      >
                        <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
                        {f.message}
                      </li>
                    ))}
                  </ul>
                )}
              </li>
            ))}
          </ul>
        )}
      </SectionCard>

      {/* Payments */}
      <SectionCard
        title="Payments to the supplier"
        actions={
          mayUpdate &&
          stage !== 'draft' &&
          stage !== 'cancelled' && (
            <button type="button" className={btnSmall} disabled={busy} onClick={() => setPaymentOpen(true)}>
              <PoundSterling className="h-3.5 w-3.5" />
              Record payment
            </button>
          )
        }
      >
        <BalanceSummary balance={panel.balance} view="staff" />
        {panel.payments.length > 0 && (
          <ul className="mt-4 divide-y divide-secondary-100 text-sm">
            {panel.payments.map((pay) => (
              <li key={pay.id} className={cn('flex flex-wrap items-start justify-between gap-2 py-2.5', pay.voided && 'opacity-50')}>
                <div>
                  <p className={cn('font-medium text-secondary-900', pay.voided && 'line-through')}>
                    {fmtMoney(pay.amount, pay.currency)} · {pay.method_label}
                  </p>
                  <p className="text-xs text-secondary-500">
                    Sent {fmtDate(pay.sent_on)}
                    {pay.cleared_on ? ` · cleared ${fmtDate(pay.cleared_on)}` : ' · not cleared yet'}
                    {pay.payment_reference ? ` · ref ${pay.payment_reference}` : ''}
                    {pay.bank_transaction_id ? ` · bank ID ${pay.bank_transaction_id}` : ''}
                    {pay.against ? ` · against ${INVOICE_KIND_LABELS[pay.against.kind]} ${pay.against.number}` : ''}
                  </p>
                  {pay.note && <p className="text-xs text-secondary-600">{pay.note}</p>}
                  {pay.voided && (
                    <p className="text-xs text-red-700">
                      Voided {fmtDateTime(pay.voided_at)}
                      {pay.void_reason ? `: ${pay.void_reason}` : ''}
                    </p>
                  )}
                </div>
                {!pay.voided && (
                  <div className="flex flex-wrap gap-2">
                    {pay.proof_document_id && (
                      <button type="button" className={btnSmall} onClick={() => download(pay.proof_document_id as string)}>
                        <Download className="h-3.5 w-3.5" />
                        Proof
                      </button>
                    )}
                    {mayUpdate && !pay.cleared_on && (
                      <button type="button" className={btnSmall} disabled={busy} onClick={() => setClearing(pay)}>
                        <CheckCircle2 className="h-3.5 w-3.5" />
                        Mark cleared
                      </button>
                    )}
                    {mayUpdate && (
                      <button type="button" className={btnDanger} disabled={busy} onClick={() => voidPayment(pay)}>
                        <Undo2 className="h-3.5 w-3.5" />
                        Void
                      </button>
                    )}
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
      </SectionCard>

      {/* Dispatch & delivery */}
      <SectionCard
        title="Dispatch & delivery"
        actions={
          mayUpdate && (
            <>
              {DISPATCH_STAGES.includes(stage) && (
                <button type="button" className={btnSmall} disabled={busy} onClick={() => setDispatchOpen(true)}>
                  <Truck className="h-3.5 w-3.5" />
                  Record dispatch
                </button>
              )}
              {stage === 'dispatched' && (
                <button type="button" className={btnSmall} disabled={busy} onClick={() => setDeliveredOpen(true)}>
                  <PackageCheck className="h-3.5 w-3.5" />
                  Mark delivered
                </button>
              )}
            </>
          )
        }
      >
        {panel.shipments.length === 0 ? (
          <p className="text-sm text-secondary-500">Nothing dispatched yet.</p>
        ) : (
          <ul className="divide-y divide-secondary-100 text-sm">
            {panel.shipments.map((s) => (
              <li key={s.id} className="flex flex-wrap items-start justify-between gap-2 py-2.5">
                <div>
                  <p className="font-medium text-secondary-900">
                    {s.carrier}
                    {s.tracking_number ? ` · ${s.tracking_number}` : ''}
                  </p>
                  <p className="text-xs text-secondary-500">
                    Dispatched {fmtDate(s.dispatched_on)}
                    {s.expected_on ? ` · expected ${fmtDate(s.expected_on)}` : ''}
                    {s.delivered_on ? ` · delivered ${fmtDate(s.delivered_on)}` : ' · not delivered yet'}
                    {s.received_by ? ` · received by ${s.received_by}` : ''}
                    {` · entered by ${s.created_by_kind === 'supplier' ? 'the supplier' : 'us'}`}
                  </p>
                  {(s.note || s.delivery_note) && (
                    <p className="text-xs text-secondary-600">{[s.note, s.delivery_note].filter(Boolean).join(' · ')}</p>
                  )}
                </div>
                <div className="flex gap-2">
                  {s.tracking_url && (
                    <a href={s.tracking_url} target="_blank" rel="noopener noreferrer" className={btnSmall}>
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

      {/* Messages */}
      <SectionCard title="Messages with the supplier">
        {messageError && (
          <div className="mb-3 flex items-start gap-2 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
            <span>{messageError}</span>
          </div>
        )}
        <MessageThread
          messages={panel.messages}
          mine="staff"
          canSend={mayUpdate && stage !== 'draft'}
          onSend={sendMessage}
          placeholder="Write to the supplier. Never name our customer: the deal code is the only reference they need."
          sendHint={panel.portal.emails_enabled ? 'The supplier is emailed that there is a new message.' : 'Not emailed: they see it when they sign in.'}
        />
        {stage === 'draft' && <p className="text-xs text-secondary-500">Send the purchase order before writing to the supplier.</p>}
      </SectionCard>

      {/* History */}
      <SectionCard title="History">
        <Timeline entries={panel.timeline} view="staff" />
        {!open && p.closed_at && <p className="mt-3 text-xs text-secondary-500">Closed {fmtDateTime(p.closed_at)}</p>}
      </SectionCard>

      <UploadModal isOpen={uploadOpen} onClose={() => setUploadOpen(false)} onSubmit={upload} />
      <InvoiceModal isOpen={invoiceOpen} onClose={() => setInvoiceOpen(false)} onSubmit={recordInvoice} />
      <PaymentModal isOpen={paymentOpen} onClose={() => setPaymentOpen(false)} panel={panel} onSubmit={recordPayment} />
      <ClearedModal payment={clearing} onClose={() => setClearing(null)} onSubmit={markCleared} />
      <DispatchModal isOpen={dispatchOpen} onClose={() => setDispatchOpen(false)} onSubmit={saveDispatch} title="Record dispatch" />
      <DeliveredModal isOpen={deliveredOpen} onClose={() => setDeliveredOpen(false)} hasPod={hasPod} onSubmit={saveDelivered} />
    </div>
  );
}
