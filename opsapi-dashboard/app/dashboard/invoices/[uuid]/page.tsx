'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  FileText,
  Send,
  Ban,
  Trash2,
  Plus,
  DollarSign,
  Edit2,
  X,
} from 'lucide-react';
import { Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  invoicesService,
  type Invoice,
  type InvoiceStatus,
  type InvoiceLineItem,
  type InvoicePayment,
  type LineItemPayload,
  type PaymentPayload,
  type InvoicePayload,
} from '@/services/invoices.service';
import { formatDate, formatCurrency } from '@/lib/utils';
import toast from 'react-hot-toast';

// Status badge component
const InvoiceStatusBadge: React.FC<{ status: InvoiceStatus }> = ({ status }) => {
  const config: Record<InvoiceStatus, { label: string; classes: string }> = {
    draft: { label: 'Draft', classes: 'bg-gray-100 text-gray-700' },
    sent: { label: 'Sent', classes: 'bg-blue-100 text-blue-700' },
    paid: { label: 'Paid', classes: 'bg-green-100 text-green-700' },
    partially_paid: { label: 'Partially Paid', classes: 'bg-yellow-100 text-yellow-700' },
    overdue: { label: 'Overdue', classes: 'bg-red-100 text-red-700' },
    cancelled: { label: 'Cancelled', classes: 'bg-gray-100 text-gray-700' },
    void: { label: 'Void', classes: 'bg-gray-100 text-gray-500' },
  };

  const { label, classes } = config[status] || { label: status, classes: 'bg-gray-100 text-gray-700' };

  return (
    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${classes}`}>
      {label}
    </span>
  );
};

// Add Line Item Modal
interface AddLineItemModalProps {
  isOpen: boolean;
  onClose: () => void;
  onAdded: () => void;
  invoiceUuid: string;
}

const AddLineItemModal: React.FC<AddLineItemModalProps> = ({ isOpen, onClose, onAdded, invoiceUuid }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState<LineItemPayload>({
    description: '',
    quantity: 1,
    unit_price: 0,
    tax_rate: 0,
  });

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!formData.description.trim()) {
      toast.error('Description is required');
      return;
    }

    if (formData.quantity <= 0) {
      toast.error('Quantity must be greater than 0');
      return;
    }

    setIsSubmitting(true);
    try {
      await invoicesService.addLineItem(invoiceUuid, formData);
      toast.success('Line item added successfully');
      onAdded();
      onClose();
      setFormData({ description: '', quantity: 1, unit_price: 0, tax_rate: 0 });
    } catch (error) {
      console.error('Failed to add line item:', error);
      toast.error('Failed to add line item');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Add Line Item">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Description *</label>
          <input
            type="text"
            value={formData.description}
            onChange={(e) => setFormData((prev) => ({ ...prev, description: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            placeholder="Item description"
            required
          />
        </div>

        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Quantity *</label>
            <input
              type="number"
              value={formData.quantity}
              onChange={(e) => setFormData((prev) => ({ ...prev, quantity: parseFloat(e.target.value) || 0 }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              min="0.01"
              step="0.01"
              required
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Unit Price *</label>
            <input
              type="number"
              value={formData.unit_price}
              onChange={(e) => setFormData((prev) => ({ ...prev, unit_price: parseFloat(e.target.value) || 0 }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              min="0"
              step="0.01"
              required
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Tax Rate (%)</label>
            <input
              type="number"
              value={formData.tax_rate || ''}
              onChange={(e) => setFormData((prev) => ({ ...prev, tax_rate: parseFloat(e.target.value) || 0 }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              min="0"
              step="0.01"
              placeholder="0"
            />
          </div>
        </div>

        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {isSubmitting ? 'Adding...' : 'Add Item'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

// Record Payment Modal
interface RecordPaymentModalProps {
  isOpen: boolean;
  onClose: () => void;
  onRecorded: () => void;
  invoiceUuid: string;
  balanceDue: number;
  currency: string;
}

const RecordPaymentModal: React.FC<RecordPaymentModalProps> = ({
  isOpen,
  onClose,
  onRecorded,
  invoiceUuid,
  balanceDue,
  currency,
}) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState<PaymentPayload>({
    amount: balanceDue,
    payment_method: 'bank_transfer',
    payment_date: new Date().toISOString().split('T')[0],
    reference: '',
    notes: '',
  });

  useEffect(() => {
    setFormData((prev) => ({ ...prev, amount: balanceDue }));
  }, [balanceDue]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (formData.amount <= 0) {
      toast.error('Payment amount must be greater than 0');
      return;
    }

    if (formData.amount > balanceDue) {
      toast.error('Payment amount cannot exceed balance due');
      return;
    }

    setIsSubmitting(true);
    try {
      await invoicesService.recordPayment(invoiceUuid, formData);
      toast.success('Payment recorded successfully');
      onRecorded();
      onClose();
    } catch (error) {
      console.error('Failed to record payment:', error);
      toast.error('Failed to record payment');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Record Payment">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="bg-blue-50 rounded-lg p-3 text-sm text-blue-700">
          Balance Due: <span className="font-semibold">{formatCurrency(balanceDue, currency)}</span>
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Amount *</label>
            <input
              type="number"
              value={formData.amount}
              onChange={(e) => setFormData((prev) => ({ ...prev, amount: parseFloat(e.target.value) || 0 }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              min="0.01"
              max={balanceDue}
              step="0.01"
              required
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Payment Date *</label>
            <input
              type="date"
              value={formData.payment_date}
              onChange={(e) => setFormData((prev) => ({ ...prev, payment_date: e.target.value }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              required
            />
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Payment Method *</label>
          <select
            value={formData.payment_method}
            onChange={(e) => setFormData((prev) => ({ ...prev, payment_method: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
          >
            <option value="bank_transfer">Bank Transfer</option>
            <option value="credit_card">Credit Card</option>
            <option value="cash">Cash</option>
            <option value="check">Check</option>
            <option value="paypal">PayPal</option>
            <option value="other">Other</option>
          </select>
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Reference</label>
          <input
            type="text"
            value={formData.reference}
            onChange={(e) => setFormData((prev) => ({ ...prev, reference: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            placeholder="Transaction reference or check number"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Notes</label>
          <textarea
            value={formData.notes}
            onChange={(e) => setFormData((prev) => ({ ...prev, notes: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            rows={2}
            placeholder="Optional notes..."
          />
        </div>

        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {isSubmitting ? 'Recording...' : 'Record Payment'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

// Edit Invoice Modal
interface EditInvoiceModalProps {
  isOpen: boolean;
  onClose: () => void;
  onUpdated: () => void;
  invoice: Invoice;
}

const EditInvoiceModal: React.FC<EditInvoiceModalProps> = ({ isOpen, onClose, onUpdated, invoice }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState<InvoicePayload>({
    customer_name: invoice.customer_name,
    customer_email: invoice.customer_email || '',
    issue_date: invoice.issue_date,
    due_date: invoice.due_date,
    currency: invoice.currency,
    notes: invoice.notes || '',
    payment_terms_days: invoice.payment_terms_days,
  });

  useEffect(() => {
    setFormData({
      customer_name: invoice.customer_name,
      customer_email: invoice.customer_email || '',
      issue_date: invoice.issue_date,
      due_date: invoice.due_date,
      currency: invoice.currency,
      notes: invoice.notes || '',
      payment_terms_days: invoice.payment_terms_days,
    });
  }, [invoice]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!formData.customer_name.trim()) {
      toast.error('Customer name is required');
      return;
    }

    setIsSubmitting(true);
    try {
      await invoicesService.updateInvoice(invoice.uuid, formData);
      toast.success('Invoice updated successfully');
      onUpdated();
      onClose();
    } catch (error) {
      console.error('Failed to update invoice:', error);
      toast.error('Failed to update invoice');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Edit Invoice">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Customer Name *</label>
          <input
            type="text"
            value={formData.customer_name}
            onChange={(e) => setFormData((prev) => ({ ...prev, customer_name: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            required
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Customer Email</label>
          <input
            type="email"
            value={formData.customer_email}
            onChange={(e) => setFormData((prev) => ({ ...prev, customer_email: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
          />
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Issue Date *</label>
            <input
              type="date"
              value={formData.issue_date}
              onChange={(e) => setFormData((prev) => ({ ...prev, issue_date: e.target.value }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              required
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Due Date *</label>
            <input
              type="date"
              value={formData.due_date}
              onChange={(e) => setFormData((prev) => ({ ...prev, due_date: e.target.value }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              required
            />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Currency</label>
            <select
              value={formData.currency}
              onChange={(e) => setFormData((prev) => ({ ...prev, currency: e.target.value }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
            >
              <option value="USD">USD</option>
              <option value="EUR">EUR</option>
              <option value="GBP">GBP</option>
              <option value="CAD">CAD</option>
              <option value="AUD">AUD</option>
              <option value="INR">INR</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Payment Terms (days)</label>
            <input
              type="number"
              value={formData.payment_terms_days || ''}
              onChange={(e) =>
                setFormData((prev) => ({ ...prev, payment_terms_days: parseInt(e.target.value) || undefined }))
              }
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              min="0"
            />
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Notes</label>
          <textarea
            value={formData.notes}
            onChange={(e) => setFormData((prev) => ({ ...prev, notes: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            rows={3}
          />
        </div>

        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {isSubmitting ? 'Saving...' : 'Save Changes'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

function InvoiceDetailContent() {
  const params = useParams();
  const router = useRouter();
  const uuid = params.uuid as string;

  // State
  const [invoice, setInvoice] = useState<Invoice | null>(null);
  const [payments, setPayments] = useState<InvoicePayment[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isAddItemModalOpen, setIsAddItemModalOpen] = useState(false);
  const [isPaymentModalOpen, setIsPaymentModalOpen] = useState(false);
  const [isEditModalOpen, setIsEditModalOpen] = useState(false);

  // Fetch invoice data
  const fetchInvoice = useCallback(async () => {
    setIsLoading(true);
    try {
      const [invoiceData, paymentsData] = await Promise.all([
        invoicesService.getInvoice(uuid),
        invoicesService.getPayments(uuid),
      ]);
      setInvoice(invoiceData);
      setPayments(paymentsData);
    } catch (error) {
      console.error('Failed to fetch invoice:', error);
      toast.error('Failed to load invoice details');
    } finally {
      setIsLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    fetchInvoice();
  }, [fetchInvoice]);

  // Action handlers
  const handleSendInvoice = useCallback(async () => {
    if (!invoice) return;
    try {
      await invoicesService.sendInvoice(invoice.uuid);
      toast.success('Invoice sent successfully');
      fetchInvoice();
    } catch (error) {
      console.error('Failed to send invoice:', error);
      toast.error('Failed to send invoice');
    }
  }, [invoice, fetchInvoice]);

  const handleVoidInvoice = useCallback(async () => {
    if (!invoice) return;
    if (!window.confirm('Are you sure you want to void this invoice? This action cannot be undone.')) return;
    try {
      await invoicesService.voidInvoice(invoice.uuid);
      toast.success('Invoice voided successfully');
      fetchInvoice();
    } catch (error) {
      console.error('Failed to void invoice:', error);
      toast.error('Failed to void invoice');
    }
  }, [invoice, fetchInvoice]);

  const handleDeleteInvoice = useCallback(async () => {
    if (!invoice) return;
    if (!window.confirm('Are you sure you want to delete this invoice? This action cannot be undone.')) return;
    try {
      await invoicesService.deleteInvoice(invoice.uuid);
      toast.success('Invoice deleted successfully');
      router.push('/dashboard/invoices');
    } catch (error) {
      console.error('Failed to delete invoice:', error);
      toast.error('Failed to delete invoice');
    }
  }, [invoice, router]);

  const handleDeleteLineItem = useCallback(
    async (itemUuid: string) => {
      if (!window.confirm('Are you sure you want to remove this line item?')) return;
      try {
        await invoicesService.deleteLineItem(itemUuid);
        toast.success('Line item removed');
        fetchInvoice();
      } catch (error) {
        console.error('Failed to delete line item:', error);
        toast.error('Failed to remove line item');
      }
    },
    [fetchInvoice]
  );

  // Determine which actions are available based on status
  const canEdit = invoice?.status === 'draft';
  const canSend = invoice?.status === 'draft';
  const canVoid = invoice?.status !== 'void' && invoice?.status !== 'paid' && invoice?.status !== 'cancelled';
  const canDelete = invoice?.status === 'draft';
  const canAddItems = invoice?.status === 'draft';
  const canRecordPayment =
    invoice?.status === 'sent' ||
    invoice?.status === 'partially_paid' ||
    invoice?.status === 'overdue';

  // Loading state
  if (isLoading) {
    return (
      <div className="space-y-6">
        <div className="flex items-center gap-4">
          <div className="w-10 h-10 bg-secondary-200 rounded-lg animate-pulse" />
          <div className="space-y-2">
            <div className="w-48 h-6 bg-secondary-200 rounded animate-pulse" />
            <div className="w-32 h-4 bg-secondary-200 rounded animate-pulse" />
          </div>
        </div>
        <div className="bg-white rounded-xl border border-secondary-200 p-6">
          <div className="space-y-4">
            {[...Array(5)].map((_, i) => (
              <div key={i} className="w-full h-8 bg-secondary-100 rounded animate-pulse" />
            ))}
          </div>
        </div>
      </div>
    );
  }

  if (!invoice) {
    return (
      <div className="text-center py-12">
        <FileText className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
        <h3 className="text-lg font-medium text-secondary-900 mb-2">Invoice not found</h3>
        <p className="text-secondary-500 mb-4">The invoice you are looking for does not exist or has been removed.</p>
        <button
          onClick={() => router.push('/dashboard/invoices')}
          className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors"
        >
          Back to Invoices
        </button>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Back Button & Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-4">
          <button
            onClick={() => router.push('/dashboard/invoices')}
            className="p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
          >
            <ArrowLeft className="w-5 h-5" />
          </button>
          <div>
            <div className="flex items-center gap-3">
              <h1 className="text-2xl font-bold text-secondary-900">
                Invoice {invoice.invoice_number || `#${invoice.uuid.slice(0, 8)}`}
              </h1>
              <InvoiceStatusBadge status={invoice.status} />
            </div>
            <p className="text-secondary-500 mt-1">
              Created {formatDate(invoice.created_at)}
            </p>
          </div>
        </div>

        {/* Action Buttons */}
        <div className="flex items-center gap-2">
          {canEdit && (
            <button
              onClick={() => setIsEditModalOpen(true)}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
            >
              <Edit2 className="w-4 h-4" />
              Edit
            </button>
          )}
          {canSend && (
            <button
              onClick={handleSendInvoice}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-lg hover:bg-blue-700 transition-colors"
            >
              <Send className="w-4 h-4" />
              Send
            </button>
          )}
          {canRecordPayment && (
            <button
              onClick={() => setIsPaymentModalOpen(true)}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-green-600 rounded-lg hover:bg-green-700 transition-colors"
            >
              <DollarSign className="w-4 h-4" />
              Record Payment
            </button>
          )}
          {canVoid && (
            <button
              onClick={handleVoidInvoice}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-amber-700 bg-amber-50 border border-amber-200 rounded-lg hover:bg-amber-100 transition-colors"
            >
              <Ban className="w-4 h-4" />
              Void
            </button>
          )}
          {canDelete && (
            <button
              onClick={handleDeleteInvoice}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-red-700 bg-red-50 border border-red-200 rounded-lg hover:bg-red-100 transition-colors"
            >
              <Trash2 className="w-4 h-4" />
              Delete
            </button>
          )}
        </div>
      </div>

      {/* Invoice Details */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Customer Info */}
        <div className="bg-white rounded-xl border border-secondary-200 p-5 shadow-sm">
          <h3 className="font-medium text-secondary-900 mb-3">Customer Information</h3>
          <div className="space-y-2 text-sm">
            <div>
              <span className="text-secondary-500">Name:</span>
              <span className="ml-2 text-secondary-900 font-medium">{invoice.customer_name}</span>
            </div>
            {invoice.customer_email && (
              <div>
                <span className="text-secondary-500">Email:</span>
                <span className="ml-2 text-secondary-900">{invoice.customer_email}</span>
              </div>
            )}
          </div>
        </div>

        {/* Invoice Info */}
        <div className="bg-white rounded-xl border border-secondary-200 p-5 shadow-sm">
          <h3 className="font-medium text-secondary-900 mb-3">Invoice Details</h3>
          <div className="space-y-2 text-sm">
            <div>
              <span className="text-secondary-500">Issue Date:</span>
              <span className="ml-2 text-secondary-900">{formatDate(invoice.issue_date)}</span>
            </div>
            <div>
              <span className="text-secondary-500">Due Date:</span>
              <span className="ml-2 text-secondary-900">{formatDate(invoice.due_date)}</span>
            </div>
            <div>
              <span className="text-secondary-500">Currency:</span>
              <span className="ml-2 text-secondary-900">{invoice.currency}</span>
            </div>
            {invoice.payment_terms_days && (
              <div>
                <span className="text-secondary-500">Payment Terms:</span>
                <span className="ml-2 text-secondary-900">Net {invoice.payment_terms_days} days</span>
              </div>
            )}
          </div>
        </div>

        {/* Amount Summary */}
        <div className="bg-white rounded-xl border border-secondary-200 p-5 shadow-sm">
          <h3 className="font-medium text-secondary-900 mb-3">Amount Summary</h3>
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-secondary-500">Subtotal</span>
              <span className="text-secondary-900">{formatCurrency(invoice.subtotal, invoice.currency)}</span>
            </div>
            {invoice.tax_total > 0 && (
              <div className="flex justify-between">
                <span className="text-secondary-500">Tax</span>
                <span className="text-secondary-900">{formatCurrency(invoice.tax_total, invoice.currency)}</span>
              </div>
            )}
            <div className="flex justify-between pt-2 border-t border-secondary-200 font-semibold">
              <span className="text-secondary-900">Total</span>
              <span className="text-primary-600">{formatCurrency(invoice.total, invoice.currency)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-secondary-500">Amount Paid</span>
              <span className="text-green-600">{formatCurrency(invoice.amount_paid, invoice.currency)}</span>
            </div>
            <div className="flex justify-between pt-2 border-t border-secondary-200 font-semibold">
              <span className="text-secondary-900">Balance Due</span>
              <span className={invoice.balance_due > 0 ? 'text-red-600' : 'text-green-600'}>
                {formatCurrency(invoice.balance_due, invoice.currency)}
              </span>
            </div>
          </div>
        </div>
      </div>

      {/* Line Items */}
      <div className="bg-white rounded-xl border border-secondary-200 shadow-sm">
        <div className="flex items-center justify-between p-5 border-b border-secondary-200">
          <h3 className="font-medium text-secondary-900">Line Items</h3>
          {canAddItems && (
            <button
              onClick={() => setIsAddItemModalOpen(true)}
              className="flex items-center gap-2 px-3 py-1.5 text-sm font-medium text-primary-600 bg-primary-50 rounded-lg hover:bg-primary-100 transition-colors"
            >
              <Plus className="w-4 h-4" />
              Add Item
            </button>
          )}
        </div>

        {invoice.items && invoice.items.length > 0 ? (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-secondary-50">
                <tr>
                  <th className="text-left px-5 py-3 text-secondary-600 font-medium">Description</th>
                  <th className="text-center px-5 py-3 text-secondary-600 font-medium">Qty</th>
                  <th className="text-right px-5 py-3 text-secondary-600 font-medium">Unit Price</th>
                  <th className="text-right px-5 py-3 text-secondary-600 font-medium">Tax</th>
                  <th className="text-right px-5 py-3 text-secondary-600 font-medium">Total</th>
                  {canAddItems && (
                    <th className="text-center px-5 py-3 text-secondary-600 font-medium w-16"></th>
                  )}
                </tr>
              </thead>
              <tbody className="divide-y divide-secondary-200">
                {invoice.items.map((item: InvoiceLineItem) => (
                  <tr key={item.uuid} className="hover:bg-secondary-50">
                    <td className="px-5 py-3 text-secondary-900">{item.description}</td>
                    <td className="px-5 py-3 text-center text-secondary-600">{item.quantity}</td>
                    <td className="px-5 py-3 text-right text-secondary-600">
                      {formatCurrency(item.unit_price, invoice.currency)}
                    </td>
                    <td className="px-5 py-3 text-right text-secondary-600">
                      {item.tax_amount ? formatCurrency(item.tax_amount, invoice.currency) : '-'}
                    </td>
                    <td className="px-5 py-3 text-right font-medium text-secondary-900">
                      {formatCurrency(item.total, invoice.currency)}
                    </td>
                    {canAddItems && (
                      <td className="px-5 py-3 text-center">
                        <button
                          onClick={() => handleDeleteLineItem(item.uuid)}
                          className="p-1 text-secondary-400 hover:text-red-500 rounded transition-colors"
                          title="Remove item"
                        >
                          <X className="w-4 h-4" />
                        </button>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="text-center py-8 text-secondary-500">
            <FileText className="w-8 h-8 mx-auto mb-2 text-secondary-300" />
            <p>No line items yet.</p>
            {canAddItems && (
              <button
                onClick={() => setIsAddItemModalOpen(true)}
                className="mt-2 text-sm text-primary-600 hover:text-primary-700"
              >
                Add your first item
              </button>
            )}
          </div>
        )}
      </div>

      {/* Payments */}
      <div className="bg-white rounded-xl border border-secondary-200 shadow-sm">
        <div className="flex items-center justify-between p-5 border-b border-secondary-200">
          <h3 className="font-medium text-secondary-900">Payments</h3>
          {canRecordPayment && (
            <button
              onClick={() => setIsPaymentModalOpen(true)}
              className="flex items-center gap-2 px-3 py-1.5 text-sm font-medium text-green-600 bg-green-50 rounded-lg hover:bg-green-100 transition-colors"
            >
              <DollarSign className="w-4 h-4" />
              Record Payment
            </button>
          )}
        </div>

        {payments.length > 0 ? (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-secondary-50">
                <tr>
                  <th className="text-left px-5 py-3 text-secondary-600 font-medium">Date</th>
                  <th className="text-left px-5 py-3 text-secondary-600 font-medium">Method</th>
                  <th className="text-left px-5 py-3 text-secondary-600 font-medium">Reference</th>
                  <th className="text-right px-5 py-3 text-secondary-600 font-medium">Amount</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-secondary-200">
                {payments.map((payment: InvoicePayment) => (
                  <tr key={payment.uuid} className="hover:bg-secondary-50">
                    <td className="px-5 py-3 text-secondary-900">{formatDate(payment.payment_date)}</td>
                    <td className="px-5 py-3 text-secondary-600 capitalize">
                      {payment.payment_method.replace('_', ' ')}
                    </td>
                    <td className="px-5 py-3 text-secondary-600">{payment.reference || '-'}</td>
                    <td className="px-5 py-3 text-right font-medium text-green-600">
                      {formatCurrency(payment.amount, invoice.currency)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="text-center py-8 text-secondary-500">
            <DollarSign className="w-8 h-8 mx-auto mb-2 text-secondary-300" />
            <p>No payments recorded yet.</p>
          </div>
        )}
      </div>

      {/* Notes */}
      {invoice.notes && (
        <div className="bg-amber-50 rounded-xl border border-amber-200 p-5">
          <h3 className="font-medium text-amber-900 mb-2">Notes</h3>
          <p className="text-sm text-amber-700 whitespace-pre-line">{invoice.notes}</p>
        </div>
      )}

      {/* Modals */}
      <AddLineItemModal
        isOpen={isAddItemModalOpen}
        onClose={() => setIsAddItemModalOpen(false)}
        onAdded={fetchInvoice}
        invoiceUuid={uuid}
      />

      {canRecordPayment && (
        <RecordPaymentModal
          isOpen={isPaymentModalOpen}
          onClose={() => setIsPaymentModalOpen(false)}
          onRecorded={fetchInvoice}
          invoiceUuid={uuid}
          balanceDue={invoice.balance_due}
          currency={invoice.currency}
        />
      )}

      {invoice && (
        <EditInvoiceModal
          isOpen={isEditModalOpen}
          onClose={() => setIsEditModalOpen(false)}
          onUpdated={fetchInvoice}
          invoice={invoice}
        />
      )}
    </div>
  );
}

export default function InvoiceDetailPage() {
  return (
    <ProtectedPage module="invoices" title="Invoice Details">
      <InvoiceDetailContent />
    </ProtectedPage>
  );
}
