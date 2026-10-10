'use client';

import React, { useState, useEffect, useCallback, useMemo } from 'react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  ClipboardCheck,
  Send,
  Mail,
  Ban,
  Trash2,
  Plus,
  Edit2,
  X,
  Download,
  PackageCheck,
  Receipt,
  ThumbsUp,
  FolderKanban,
  ExternalLink,
} from 'lucide-react';
import { Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PurchaseOrderStatusBadge } from '@/components/purchase-orders/PurchaseOrderStatusBadge';
import { PurchaseOrderFormModal } from '@/components/purchase-orders/PurchaseOrderFormModal';
import {
  purchaseOrdersService,
  purchaseOrderError,
  type PurchaseOrder,
  type PurchaseOrderItem,
  type PurchaseOrderItemPayload,
} from '@/services/purchase-orders.service';
import { generatePurchaseOrderPdf, purchaseOrderPdfBase64 } from '@/lib/purchase-order-pdf';
import { useNamespace } from '@/contexts/NamespaceContext';
import { formatDate, formatDateTime, formatCurrency } from '@/lib/utils';
import toast from 'react-hot-toast';

const inputClass =
  'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface';
const labelClass = 'block text-sm font-medium text-secondary-700 mb-1';
const btnSecondary =
  'flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors';

const money = (amount: number, currency: string) => formatCurrency(amount, currency || 'GBP', 'en-GB');

// ============================================
// Add / edit line
// ============================================

interface LineModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
  poUuid: string;
  item?: PurchaseOrderItem | null;
}

const LineModal: React.FC<LineModalProps> = ({ isOpen, onClose, onSaved, poUuid, item }) => {
  const [form, setForm] = useState<PurchaseOrderItemPayload>({ description: '', quantity: 1, unit_price: 0, tax_rate: 20 });
  const [isSubmitting, setIsSubmitting] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setForm(
      item
        ? { description: item.description, quantity: item.quantity, unit_price: item.unit_price, tax_rate: item.tax_rate }
        : { description: '', quantity: 1, unit_price: 0, tax_rate: 20 }
    );
  }, [isOpen, item]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.description.trim()) {
      toast.error('Description is required');
      return;
    }
    if (!(form.quantity > 0)) {
      toast.error('Quantity must be greater than 0');
      return;
    }
    setIsSubmitting(true);
    try {
      if (item) await purchaseOrdersService.updateItem(item.uuid, form);
      else await purchaseOrdersService.addItem(poUuid, form);
      toast.success(item ? 'Line updated' : 'Line added');
      onSaved();
      onClose();
    } catch (error) {
      toast.error(purchaseOrderError(error, 'Failed to save line'));
    } finally {
      setIsSubmitting(false);
    }
  };

  const total = (form.quantity || 0) * (form.unit_price || 0) * (1 + (form.tax_rate || 0) / 100);

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={item ? 'Edit Line' : 'Add Line'}>
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className={labelClass}>Description *</label>
          <input
            type="text"
            value={form.description}
            onChange={(e) => setForm((p) => ({ ...p, description: e.target.value }))}
            className={inputClass}
            placeholder="e.g. 12.5mm plasterboard 2400x1200"
          />
        </div>
        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className={labelClass}>Quantity *</label>
            <input
              type="number"
              min="0"
              step="any"
              value={form.quantity}
              onChange={(e) => setForm((p) => ({ ...p, quantity: parseFloat(e.target.value) || 0 }))}
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>Unit Price</label>
            <input
              type="number"
              min="0"
              step="0.01"
              value={form.unit_price}
              onChange={(e) => setForm((p) => ({ ...p, unit_price: parseFloat(e.target.value) || 0 }))}
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>Tax Rate (%)</label>
            <input
              type="number"
              min="0"
              max="100"
              step="any"
              value={form.tax_rate}
              onChange={(e) => setForm((p) => ({ ...p, tax_rate: parseFloat(e.target.value) || 0 }))}
              className={inputClass}
            />
          </div>
        </div>
        <p className="text-sm text-secondary-600">
          Line total (incl. tax): <span className="font-semibold">{total.toFixed(2)}</span>
        </p>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className={btnSecondary}>
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 transition-colors"
          >
            {isSubmitting ? 'Saving...' : item ? 'Save Line' : 'Add Line'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================
// Receive goods
// ============================================

interface ReceiveModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
  po: PurchaseOrder;
}

const ReceiveModal: React.FC<ReceiveModalProps> = ({ isOpen, onClose, onSaved, po }) => {
  const [qty, setQty] = useState<Record<string, string>>({});
  const [note, setNote] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    const init: Record<string, string> = {};
    po.items.forEach((it) => (init[it.uuid] = String(it.received_quantity)));
    setQty(init);
    setNote('');
  }, [isOpen, po.items]);

  const receiveAll = () => {
    const all: Record<string, string> = {};
    po.items.forEach((it) => (all[it.uuid] = String(it.quantity)));
    setQty(all);
  };

  const handleSubmit = async () => {
    const lines = [];
    for (const it of po.items) {
      const v = parseFloat(qty[it.uuid] ?? '');
      if (Number.isNaN(v) || v < 0) {
        toast.error(`Enter a received quantity for "${it.description}"`);
        return;
      }
      if (v > it.quantity) {
        toast.error(`"${it.description}": received ${v} is more than the ${it.quantity} ordered`);
        return;
      }
      if (v !== it.received_quantity) lines.push({ item_uuid: it.uuid, received_quantity: v });
    }
    if (lines.length === 0) {
      toast.error('No quantities changed');
      return;
    }
    setIsSubmitting(true);
    try {
      const updated = await purchaseOrdersService.receive(po.uuid, { items: lines, note: note || undefined });
      toast.success(updated.status === 'received' ? 'All goods received' : 'Receipt recorded');
      onSaved();
      onClose();
    } catch (error) {
      toast.error(purchaseOrderError(error, 'Failed to record receipt'));
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={`Receive Goods — ${po.po_number}`} size="lg">
      <div className="space-y-4">
        <p className="text-sm text-secondary-500">
          Enter the total quantity received so far on each line. When every line is complete the order becomes
          Received.
        </p>
        <div className="overflow-x-auto border border-secondary-200 rounded-lg">
          <table className="w-full text-sm">
            <thead className="bg-secondary-50">
              <tr>
                <th className="text-left px-4 py-2 text-secondary-600 font-medium">Item</th>
                <th className="text-right px-4 py-2 text-secondary-600 font-medium">Ordered</th>
                <th className="text-right px-4 py-2 text-secondary-600 font-medium w-36">Received</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-secondary-200">
              {po.items.map((it) => (
                <tr key={it.uuid}>
                  <td className="px-4 py-2 text-secondary-900">{it.description}</td>
                  <td className="px-4 py-2 text-right text-secondary-600">{it.quantity}</td>
                  <td className="px-4 py-2 text-right">
                    <input
                      type="number"
                      min="0"
                      max={it.quantity}
                      step="any"
                      value={qty[it.uuid] ?? ''}
                      onChange={(e) => setQty((p) => ({ ...p, [it.uuid]: e.target.value }))}
                      aria-label={`Received quantity for ${it.description}`}
                      className={`${inputClass} text-right`}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div>
          <label className={labelClass}>Note</label>
          <input
            type="text"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            className={inputClass}
            placeholder="Delivery note number, condition, etc."
          />
        </div>
        <div className="flex justify-between gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={receiveAll} className={btnSecondary}>
            <PackageCheck className="w-4 h-4" />
            Receive All
          </button>
          <div className="flex gap-3">
            <button type="button" onClick={onClose} className={btnSecondary}>
              Cancel
            </button>
            <button
              type="button"
              onClick={handleSubmit}
              disabled={isSubmitting}
              className="px-4 py-2 text-sm font-medium text-white bg-green-600 rounded-lg hover:bg-green-700 disabled:opacity-50 transition-colors"
            >
              {isSubmitting ? 'Saving...' : 'Record Receipt'}
            </button>
          </div>
        </div>
      </div>
    </Modal>
  );
};

// ============================================
// Convert to bill
// ============================================

const BILL_CATEGORIES = [
  { value: 'purchases', label: 'Purchases' },
  { value: 'materials', label: 'Materials' },
  { value: 'subcontractors', label: 'Subcontractors' },
  { value: 'professional_fees', label: 'Professional Fees' },
  { value: 'other', label: 'Other' },
];

interface BillModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
  po: PurchaseOrder;
}

const BillModal: React.FC<BillModalProps> = ({ isOpen, onClose, onSaved, po }) => {
  const [billDate, setBillDate] = useState(new Date().toISOString().slice(0, 10));
  const [category, setCategory] = useState('purchases');
  const [notes, setNotes] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);

  // Bills what has been received (matches the backend's billAmounts).
  const amounts = useMemo(() => {
    let net = 0;
    let tax = 0;
    po.items.forEach((it) => {
      const lineNet = it.received_quantity * it.unit_price;
      net += lineNet;
      tax += (lineNet * it.tax_rate) / 100;
    });
    return { net, tax, gross: net + tax };
  }, [po.items]);

  const handleSubmit = async () => {
    setIsSubmitting(true);
    try {
      const updated = await purchaseOrdersService.convertToBill(po.uuid, {
        bill_date: billDate,
        category,
        notes: notes || undefined,
      });
      toast.success(
        updated.accounting_expense_created
          ? 'Billed — expense added to the purchase ledger'
          : 'Purchase order marked as billed'
      );
      onSaved();
      onClose();
    } catch (error) {
      toast.error(purchaseOrderError(error, 'Failed to convert to bill'));
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={`Convert ${po.po_number} to Bill`}>
      <div className="space-y-4">
        <p className="text-sm text-secondary-500">
          Bills the goods received so far. If Bookkeeping is enabled, a pending expense for {po.supplier_name} is
          added to the purchase ledger. This can only be done once.
        </p>
        <div className="bg-secondary-50 rounded-lg p-4 text-sm space-y-1">
          <div className="flex justify-between">
            <span className="text-secondary-500">Net</span>
            <span>{money(amounts.net, po.currency)}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-secondary-500">Tax</span>
            <span>{money(amounts.tax, po.currency)}</span>
          </div>
          <div className="flex justify-between font-semibold pt-1 border-t border-secondary-200">
            <span>Bill total</span>
            <span>{money(amounts.gross, po.currency)}</span>
          </div>
        </div>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className={labelClass}>Bill Date</label>
            <input type="date" value={billDate} onChange={(e) => setBillDate(e.target.value)} className={inputClass} />
          </div>
          <div>
            <label className={labelClass}>Expense Category</label>
            <select value={category} onChange={(e) => setCategory(e.target.value)} className={inputClass}>
              {BILL_CATEGORIES.map((c) => (
                <option key={c.value} value={c.value}>
                  {c.label}
                </option>
              ))}
            </select>
          </div>
        </div>
        <div>
          <label className={labelClass}>Notes</label>
          <input
            type="text"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            className={inputClass}
            placeholder="Supplier invoice number, etc."
          />
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className={btnSecondary}>
            Cancel
          </button>
          <button
            type="button"
            onClick={handleSubmit}
            disabled={isSubmitting || amounts.gross <= 0}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 transition-colors"
          >
            {isSubmitting ? 'Billing...' : 'Convert to Bill'}
          </button>
        </div>
      </div>
    </Modal>
  );
};

// ============================================
// Page
// ============================================

function PurchaseOrderDetailContent() {
  const params = useParams();
  const router = useRouter();
  const uuid = params.uuid as string;
  const { currentNamespace } = useNamespace();

  const [po, setPo] = useState<PurchaseOrder | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [lineModal, setLineModal] = useState<{ open: boolean; item: PurchaseOrderItem | null }>({
    open: false,
    item: null,
  });
  const [isEditOpen, setIsEditOpen] = useState(false);
  const [isReceiveOpen, setIsReceiveOpen] = useState(false);
  const [isBillOpen, setIsBillOpen] = useState(false);

  const company = useMemo(() => ({ name: currentNamespace?.name || 'Your Company' }), [currentNamespace]);

  const fetchPo = useCallback(async () => {
    try {
      setPo(await purchaseOrdersService.getPurchaseOrder(uuid));
    } catch (error) {
      console.error('Failed to fetch purchase order:', error);
      setPo(null);
    } finally {
      setIsLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    fetchPo();
  }, [fetchPo]);

  // Run a workflow action, toast the result and reload.
  const act = useCallback(
    async (fn: () => Promise<unknown>, success: string, failure: string) => {
      setBusy(true);
      try {
        await fn();
        toast.success(success);
        await fetchPo();
      } catch (error) {
        toast.error(purchaseOrderError(error, failure));
      } finally {
        setBusy(false);
      }
    },
    [fetchPo]
  );

  const handleEmail = useCallback(async () => {
    if (!po) return;
    const to = po.supplier_email?.trim();
    if (!to) {
      toast.error('Add a supplier email before sending.');
      return;
    }
    if (po.items.length === 0) {
      toast.error('Add at least one line before sending.');
      return;
    }
    if (!window.confirm(`Email purchase order ${po.po_number} to ${to}?`)) return;
    const { base64, filename } = purchaseOrderPdfBase64(po, company);
    await act(
      () => purchaseOrdersService.emailPurchaseOrder(po.uuid, { pdf_base64: base64, filename }),
      `Purchase order emailed to ${to}`,
      'Failed to email purchase order'
    );
  }, [po, company, act]);

  const handleCancel = useCallback(async () => {
    if (!po) return;
    const reason = window.prompt(`Cancel ${po.po_number}? Optionally give a reason:`, '');
    if (reason === null) return;
    await act(() => purchaseOrdersService.cancel(po.uuid, reason || undefined), 'Purchase order cancelled', 'Failed to cancel');
  }, [po, act]);

  const handleDelete = useCallback(async () => {
    if (!po) return;
    if (!window.confirm('Delete this draft purchase order? This cannot be undone.')) return;
    try {
      await purchaseOrdersService.deletePurchaseOrder(po.uuid);
      toast.success('Purchase order deleted');
      router.push('/dashboard/purchase-orders');
    } catch (error) {
      toast.error(purchaseOrderError(error, 'Failed to delete purchase order'));
    }
  }, [po, router]);

  const handleDeleteLine = useCallback(
    async (itemUuid: string) => {
      if (!window.confirm('Remove this line?')) return;
      await act(() => purchaseOrdersService.deleteItem(itemUuid), 'Line removed', 'Failed to remove line');
    },
    [act]
  );

  if (isLoading) {
    return (
      <div className="space-y-6">
        <div className="w-64 h-8 bg-secondary-200 rounded animate-pulse" />
        <div className="bg-surface rounded-xl border border-secondary-200 p-6 space-y-4">
          {[...Array(5)].map((_, i) => (
            <div key={i} className="w-full h-8 bg-secondary-100 rounded animate-pulse" />
          ))}
        </div>
      </div>
    );
  }

  if (!po) {
    return (
      <div className="text-center py-12">
        <ClipboardCheck className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
        <h3 className="text-lg font-medium text-secondary-900 mb-2">Purchase order not found</h3>
        <p className="text-secondary-500 mb-4">It does not exist or has been removed.</p>
        <button
          onClick={() => router.push('/dashboard/purchase-orders')}
          className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors"
        >
          Back to Purchase Orders
        </button>
      </div>
    );
  }

  const s = po.status;
  const isDraft = s === 'draft';
  const canEdit = s === 'draft' || s === 'sent' || s === 'acknowledged';
  const canResend = s === 'sent' || s === 'acknowledged';
  const canAcknowledge = s === 'sent';
  const canReceive = (s === 'sent' || s === 'acknowledged' || s === 'partially_received') && po.items.length > 0;
  const canBill = s === 'received' || s === 'partially_received';
  const canCancel = s === 'draft' || s === 'sent' || s === 'acknowledged';
  const receipts = po.metadata?.receipts || [];
  const bill = po.metadata?.bill;
  const itemName = (itemUuid: string) => po.items.find((i) => i.uuid === itemUuid)?.description || 'Removed line';

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="flex items-center gap-4">
          <button
            onClick={() => router.push('/dashboard/purchase-orders')}
            className="p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
            aria-label="Back to purchase orders"
          >
            <ArrowLeft className="w-5 h-5" />
          </button>
          <div>
            <div className="flex items-center gap-3">
              <h1 className="text-2xl font-bold text-secondary-900">Purchase Order {po.po_number}</h1>
              <PurchaseOrderStatusBadge status={po.status} />
            </div>
            <p className="text-secondary-500 mt-1">
              {po.supplier_name} · Created {formatDate(po.created_at)}
            </p>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <button onClick={() => generatePurchaseOrderPdf(po, company)} className={btnSecondary}>
            <Download className="w-4 h-4" />
            Download PDF
          </button>
          {canEdit && (
            <button onClick={() => setIsEditOpen(true)} className={btnSecondary}>
              <Edit2 className="w-4 h-4" />
              Edit
            </button>
          )}
          {isDraft && (
            <>
              <button
                onClick={() =>
                  act(() => purchaseOrdersService.markSent(po.uuid), 'Marked as sent', 'Failed to mark as sent')
                }
                disabled={busy}
                className={btnSecondary}
              >
                <Send className="w-4 h-4" />
                Mark Sent
              </button>
              <button
                onClick={handleEmail}
                disabled={busy}
                className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-lg hover:bg-blue-700 disabled:opacity-50 transition-colors"
              >
                <Mail className="w-4 h-4" />
                Send
              </button>
            </>
          )}
          {canResend && (
            <button onClick={handleEmail} disabled={busy} className={btnSecondary}>
              <Mail className="w-4 h-4" />
              Resend
            </button>
          )}
          {canAcknowledge && (
            <button
              onClick={() =>
                act(() => purchaseOrdersService.acknowledge(po.uuid), 'Marked as acknowledged', 'Failed to update')
              }
              disabled={busy}
              className={btnSecondary}
            >
              <ThumbsUp className="w-4 h-4" />
              Acknowledged
            </button>
          )}
          {canReceive && (
            <button
              onClick={() => setIsReceiveOpen(true)}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-green-600 rounded-lg hover:bg-green-700 transition-colors"
            >
              <PackageCheck className="w-4 h-4" />
              Receive Goods
            </button>
          )}
          {canBill && (
            <button
              onClick={() => setIsBillOpen(true)}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors"
            >
              <Receipt className="w-4 h-4" />
              Convert to Bill
            </button>
          )}
          {canCancel && (
            <button
              onClick={handleCancel}
              disabled={busy}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-amber-700 bg-amber-50 border border-amber-200 rounded-lg hover:bg-amber-100 transition-colors"
            >
              <Ban className="w-4 h-4" />
              Cancel
            </button>
          )}
          {isDraft && (
            <button
              onClick={handleDelete}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-red-700 bg-red-50 border border-red-200 rounded-lg hover:bg-red-100 transition-colors"
            >
              <Trash2 className="w-4 h-4" />
              Delete
            </button>
          )}
        </div>
      </div>

      {/* Info cards */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="bg-surface rounded-xl border border-secondary-200 p-5 shadow-sm">
          <h3 className="font-medium text-secondary-900 mb-3">Supplier</h3>
          <div className="space-y-2 text-sm">
            <p className="text-secondary-900 font-medium">{po.supplier_name}</p>
            {po.supplier_email && <p className="text-secondary-700">{po.supplier_email}</p>}
            {po.supplier_phone && <p className="text-secondary-700">{po.supplier_phone}</p>}
            {po.supplier_address && <p className="text-secondary-600 whitespace-pre-line">{po.supplier_address}</p>}
            {po.supplier_company_uuid && (
              <Link
                href={`/dashboard/crm/${po.supplier_company_uuid}`}
                className="inline-flex items-center gap-1 text-primary-600 hover:text-primary-700"
              >
                CRM company <ExternalLink className="w-3 h-3" />
              </Link>
            )}
          </div>
        </div>

        <div className="bg-surface rounded-xl border border-secondary-200 p-5 shadow-sm">
          <h3 className="font-medium text-secondary-900 mb-3">Order Details</h3>
          <dl className="space-y-2 text-sm">
            <div>
              <dt className="inline text-secondary-500">Issued:</dt>
              <dd className="inline ml-2 text-secondary-900">{formatDate(po.issue_date)}</dd>
            </div>
            <div>
              <dt className="inline text-secondary-500">Expected:</dt>
              <dd className="inline ml-2 text-secondary-900">{po.expected_date ? formatDate(po.expected_date) : '-'}</dd>
            </div>
            {po.reference && (
              <div>
                <dt className="inline text-secondary-500">Reference:</dt>
                <dd className="inline ml-2 text-secondary-900">{po.reference}</dd>
              </div>
            )}
            <div>
              <dt className="inline text-secondary-500">Currency:</dt>
              <dd className="inline ml-2 text-secondary-900">{po.currency}</dd>
            </div>
            {po.delivery_address && (
              <div>
                <dt className="text-secondary-500">Deliver to:</dt>
                <dd className="text-secondary-900 whitespace-pre-line">{po.delivery_address}</dd>
              </div>
            )}
            {po.project_uuid && (
              <div className="pt-1">
                <dt className="sr-only">Project</dt>
                <dd>
                  <Link
                    href={`/dashboard/projects/${po.project_uuid}`}
                    className="inline-flex items-center gap-2 text-primary-600 hover:text-primary-700 font-medium"
                  >
                    <FolderKanban className="w-4 h-4" />
                    {po.project?.name || 'Linked project'}
                  </Link>
                </dd>
              </div>
            )}
          </dl>
        </div>

        <div className="bg-surface rounded-xl border border-secondary-200 p-5 shadow-sm">
          <h3 className="font-medium text-secondary-900 mb-3">Amount Summary</h3>
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-secondary-500">Subtotal</span>
              <span className="text-secondary-900">{money(po.subtotal, po.currency)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-secondary-500">Tax</span>
              <span className="text-secondary-900">{money(po.tax_total, po.currency)}</span>
            </div>
            <div className="flex justify-between pt-2 border-t border-secondary-200 font-semibold">
              <span className="text-secondary-900">Total</span>
              <span className="text-primary-600">{money(po.total, po.currency)}</span>
            </div>
            {bill && (
              <div className="flex justify-between pt-2 border-t border-secondary-200">
                <span className="text-secondary-500">Billed</span>
                <span className="text-green-600 font-medium">{money(bill.gross, po.currency)}</span>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Lines */}
      <div className="bg-surface rounded-xl border border-secondary-200 shadow-sm">
        <div className="flex items-center justify-between p-5 border-b border-secondary-200">
          <h3 className="font-medium text-secondary-900">Lines</h3>
          {isDraft && (
            <button
              onClick={() => setLineModal({ open: true, item: null })}
              className="flex items-center gap-2 px-3 py-1.5 text-sm font-medium text-primary-600 bg-primary-50 rounded-lg hover:bg-primary-100 transition-colors"
            >
              <Plus className="w-4 h-4" />
              Add Line
            </button>
          )}
        </div>
        {po.items.length > 0 ? (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-secondary-50">
                <tr>
                  <th className="text-left px-5 py-3 text-secondary-600 font-medium">Description</th>
                  <th className="text-right px-5 py-3 text-secondary-600 font-medium">Qty</th>
                  <th className="text-right px-5 py-3 text-secondary-600 font-medium">Received</th>
                  <th className="text-right px-5 py-3 text-secondary-600 font-medium">Unit Price</th>
                  <th className="text-right px-5 py-3 text-secondary-600 font-medium">Tax</th>
                  <th className="text-right px-5 py-3 text-secondary-600 font-medium">Total</th>
                  {isDraft && <th className="w-20" />}
                </tr>
              </thead>
              <tbody className="divide-y divide-secondary-200">
                {po.items.map((it) => {
                  const done = it.received_quantity >= it.quantity;
                  return (
                    <tr key={it.uuid} className="hover:bg-secondary-50">
                      <td className="px-5 py-3 text-secondary-900">{it.description}</td>
                      <td className="px-5 py-3 text-right text-secondary-600">{it.quantity}</td>
                      <td
                        className={`px-5 py-3 text-right ${
                          done ? 'text-green-600 font-medium' : it.received_quantity > 0 ? 'text-amber-600' : 'text-secondary-400'
                        }`}
                      >
                        {it.received_quantity}
                      </td>
                      <td className="px-5 py-3 text-right text-secondary-600">{money(it.unit_price, po.currency)}</td>
                      <td className="px-5 py-3 text-right text-secondary-600">
                        {it.tax_amount ? `${money(it.tax_amount, po.currency)} (${it.tax_rate}%)` : '-'}
                      </td>
                      <td className="px-5 py-3 text-right font-medium text-secondary-900">
                        {money(it.line_total, po.currency)}
                      </td>
                      {isDraft && (
                        <td className="px-5 py-3 text-right whitespace-nowrap">
                          <button
                            onClick={() => setLineModal({ open: true, item: it })}
                            className="p-1 text-secondary-400 hover:text-primary-600 rounded transition-colors"
                            title="Edit line"
                          >
                            <Edit2 className="w-4 h-4" />
                          </button>
                          <button
                            onClick={() => handleDeleteLine(it.uuid)}
                            className="p-1 text-secondary-400 hover:text-red-500 rounded transition-colors"
                            title="Remove line"
                          >
                            <X className="w-4 h-4" />
                          </button>
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="text-center py-8 text-secondary-500">
            <ClipboardCheck className="w-8 h-8 mx-auto mb-2 text-secondary-300" />
            <p>No lines yet.</p>
            {isDraft && (
              <button
                onClick={() => setLineModal({ open: true, item: null })}
                className="mt-2 text-sm text-primary-600 hover:text-primary-700"
              >
                Add your first line
              </button>
            )}
          </div>
        )}
      </div>

      {/* Bill */}
      {bill && (
        <div className="bg-green-50 rounded-xl border border-green-200 p-5">
          <h3 className="font-medium text-green-900 mb-2">Bill</h3>
          <p className="text-sm text-green-800">
            Billed {money(bill.gross, po.currency)} (net {money(bill.net, po.currency)}, tax{' '}
            {money(bill.tax, po.currency)}){po.billed_at ? ` on ${formatDate(po.billed_at)}` : ''}.
          </p>
          {po.metadata.expense_uuid ? (
            <Link
              href="/dashboard/accounting/purchase-ledger"
              className="inline-flex items-center gap-1 mt-2 text-sm font-medium text-green-700 hover:text-green-900"
            >
              View in the purchase ledger <ExternalLink className="w-3 h-3" />
            </Link>
          ) : (
            <p className="text-xs text-green-700 mt-1">Bookkeeping is not enabled, so no ledger expense was created.</p>
          )}
        </div>
      )}

      {/* Receipt history */}
      {receipts.length > 0 && (
        <div className="bg-surface rounded-xl border border-secondary-200 shadow-sm">
          <div className="p-5 border-b border-secondary-200">
            <h3 className="font-medium text-secondary-900">Goods Received</h3>
          </div>
          <ul className="divide-y divide-secondary-200 text-sm">
            {receipts.map((r, i) => (
              <li key={i} className="px-5 py-3">
                <p className="text-secondary-900 font-medium">
                  {r.at ? formatDateTime(r.at.replace(' ', 'T') + (r.at.endsWith('Z') ? '' : 'Z')) : 'Receipt'}
                  {r.note ? ` — ${r.note}` : ''}
                </p>
                <p className="text-secondary-600">
                  {(r.lines || []).map((l) => `${itemName(l.item_uuid)}: ${l.received_quantity}`).join(' · ')}
                </p>
              </li>
            ))}
          </ul>
        </div>
      )}

      {(po.notes || po.terms || po.metadata?.cancelled_reason) && (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          {po.notes && (
            <div className="bg-amber-50 rounded-xl border border-amber-200 p-5">
              <h3 className="font-medium text-amber-900 mb-2">Notes</h3>
              <p className="text-sm text-amber-800 whitespace-pre-line">{po.notes}</p>
            </div>
          )}
          {po.terms && (
            <div className="bg-secondary-50 rounded-xl border border-secondary-200 p-5">
              <h3 className="font-medium text-secondary-900 mb-2">Terms</h3>
              <p className="text-sm text-secondary-700 whitespace-pre-line">{po.terms}</p>
            </div>
          )}
          {po.metadata?.cancelled_reason && (
            <div className="bg-gray-50 rounded-xl border border-gray-200 p-5">
              <h3 className="font-medium text-gray-900 mb-2">Cancellation reason</h3>
              <p className="text-sm text-gray-700">{String(po.metadata.cancelled_reason)}</p>
            </div>
          )}
        </div>
      )}

      <LineModal
        isOpen={lineModal.open}
        onClose={() => setLineModal({ open: false, item: null })}
        onSaved={fetchPo}
        poUuid={po.uuid}
        item={lineModal.item}
      />
      <PurchaseOrderFormModal
        isOpen={isEditOpen}
        onClose={() => setIsEditOpen(false)}
        onSaved={() => fetchPo()}
        purchaseOrder={po}
      />
      <ReceiveModal isOpen={isReceiveOpen} onClose={() => setIsReceiveOpen(false)} onSaved={fetchPo} po={po} />
      <BillModal isOpen={isBillOpen} onClose={() => setIsBillOpen(false)} onSaved={fetchPo} po={po} />
    </div>
  );
}

export default function PurchaseOrderDetailPage() {
  return (
    <ProtectedPage module="purchase_orders" title="Purchase Order">
      <PurchaseOrderDetailContent />
    </ProtectedPage>
  );
}
