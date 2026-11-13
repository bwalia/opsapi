'use client';

/**
 * Shop order "next step" for getting paid:
 *   - a pending bank-transfer order → "Mark paid" (one dialog: amount prefilled against the total, method
 *     bank transfer, reference = order number, date today)
 *   - a paid order without an invoice → "Create invoice" (one click, then open it or download its PDF)
 *   - an order with an invoice → links to it
 * Self-contained so it can sit in the order page's next-step panel (OrderPaymentNextStep) or anywhere else.
 */

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { CheckCircle2, Download, ExternalLink, FileText, Landmark } from 'lucide-react';
import { Button, Card, Input, Modal, Select } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useNamespace } from '@/contexts/NamespaceContext';
import { shopService } from '@/services/shop.service';
import { invoicesService } from '@/services/invoices.service';
import { generateInvoicePdf } from '@/lib/invoice-pdf';
import { extractApiError } from '@/lib/utils';
import { formatMoney } from '@/lib/shop';
import HowToPay from '@/components/payments/HowToPay';
import type { ShopOrder, ShopOrderInvoiceResult, ShopOrderMarkPaid } from '@/types/shop';

const PAID_STATUSES = ['paid', 'processing', 'shipped', 'delivered'];

const today = () => new Date().toISOString().slice(0, 10);

/** "1,234.56" / "£1234.5" → pence, or null. */
function toMinor(v: string): number | null {
  const n = Number(v.replace(/[£,\s]/g, ''));
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) : null;
}

export function MarkPaidDialog({
  order,
  open,
  onClose,
  onPaid,
}: {
  order: ShopOrder;
  open: boolean;
  onClose: () => void;
  onPaid: (o: ShopOrder) => void;
}) {
  const total = order.total_minor ?? 0;
  const [amount, setAmount] = useState('');
  const [method, setMethod] = useState<ShopOrderMarkPaid['method']>('bank_transfer');
  const [reference, setReference] = useState('');
  const [date, setDate] = useState(today());
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setAmount((total / 100).toFixed(2));
    setMethod(order.payment_method === 'cheque' || order.payment_method === 'other' ? order.payment_method : 'bank_transfer');
    setReference(order.order_number);
    setDate(today());
  }, [open, order, total]);

  const minor = toMinor(amount);
  const diff = minor === null ? null : minor - total;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (minor === null) return;
    setSaving(true);
    try {
      const updated = await shopService.markOrderPaid(order.uuid, {
        method,
        reference: reference.trim() || undefined,
        paid_at: date || undefined,
        amount_minor: minor,
      });
      toast.success(`${order.order_number} marked paid`);
      onPaid(updated);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not mark it paid'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      isOpen={open}
      onClose={onClose}
      title={`Mark ${order.order_number} paid`}
      description="Record the payment that arrived. The order then goes ahead as if paid by card."
      size="md"
    >
      <form onSubmit={submit} className="space-y-3">
        <div>
          <Input
            label="Amount received (£)"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            inputMode="decimal"
            autoFocus
            error={minor === null ? 'Enter an amount, e.g. 1234.56' : undefined}
          />
          <p className="mt-1 text-sm text-secondary-600">
            Expected <span className="font-medium tabular-nums">{formatMoney(total, order.currency)}</span>
            {diff !== null && diff !== 0 && (
              <span className={`ml-2 font-medium ${diff < 0 ? 'text-warning-700' : 'text-secondary-700'}`}>
                {diff < 0 ? `${formatMoney(-diff, order.currency)} short` : `${formatMoney(diff, order.currency)} over`}
              </span>
            )}
            {diff === 0 && <span className="ml-2 font-medium text-success-700">matches</span>}
          </p>
        </div>
        <Select label="Method" value={method} onChange={(e) => setMethod(e.target.value as ShopOrderMarkPaid['method'])}>
          <option value="bank_transfer">Bank transfer</option>
          <option value="cheque">Cheque</option>
          <option value="other">Other</option>
        </Select>
        <Input label="Reference" value={reference} onChange={(e) => setReference(e.target.value)} helperText="As it appears on the bank statement." />
        <Input label="Date received" type="date" value={date} max={today()} onChange={(e) => setDate(e.target.value)} />
        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving} disabled={minor === null} leftIcon={<CheckCircle2 className="h-4 w-4" />}>
            Mark paid
          </Button>
        </div>
      </form>
    </Modal>
  );
}

/** Create the invoice (idempotent) and return it; shared by the button and the "download PDF" link. */
export function useOrderInvoice(order: ShopOrder, onCreated?: () => void) {
  const { currentNamespace } = useNamespace();
  const [busy, setBusy] = useState<'create' | 'pdf' | null>(null);
  const [created, setCreated] = useState<ShopOrderInvoiceResult | null>(null);

  const create = async () => {
    setBusy('create');
    try {
      const res = await shopService.createOrderInvoice(order.uuid);
      setCreated(res);
      toast.success(res.existing ? `Invoice ${res.invoice_number} already exists` : `Invoice ${res.invoice_number} created`);
      onCreated?.();
    } catch (err) {
      toast.error(extractApiError(err, 'Could not create the invoice'));
    } finally {
      setBusy(null);
    }
  };

  const downloadPdf = async (invoiceUuid: string) => {
    setBusy('pdf');
    try {
      const inv = await invoicesService.getInvoice(invoiceUuid);
      generateInvoicePdf(inv, { name: currentNamespace?.name || 'Your Company' });
    } catch (err) {
      toast.error(extractApiError(err, 'Could not build the PDF'));
    } finally {
      setBusy(null);
    }
  };

  return { busy, created, create, downloadPdf };
}

/**
 * The payment next step for an order, or null when there is none. Mark paid for a pending bank-transfer order;
 * Create invoice for a paid order without one; otherwise links to the invoice.
 */
export function OrderPaymentNextStep({
  order,
  editable,
  onChanged,
}: {
  order: ShopOrder;
  editable: boolean;
  onChanged: (o?: ShopOrder) => void;
}) {
  const { hasPermission } = usePermissions();
  const canInvoice = hasPermission('invoices', 'create');
  const [markOpen, setMarkOpen] = useState(false);
  const inv = useOrderInvoice(order, () => onChanged());
  const invoiceUuid = inv.created?.invoice_uuid || order.invoice_uuid || null;
  const cur = order.currency || 'GBP';

  const awaitingTransfer = order.status === 'pending_payment' && order.payment_method === 'bank_transfer';
  const paid = PAID_STATUSES.includes(order.status);

  if (awaitingTransfer) {
    const days = order.days_waiting;
    return (
      <Card padding="md" className="border-warning-300 bg-warning-50/60 print:hidden">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="min-w-0">
            <p className="flex items-center gap-2 font-semibold text-secondary-900">
              <Landmark className="h-4 w-4 text-warning-700" /> Waiting for a bank transfer of {formatMoney(order.total_minor, cur)}
            </p>
            <p className="mt-1 text-sm text-secondary-600">
              Reference <span className="font-mono font-medium">{order.payment_reference || order.order_number}</span>
              {typeof days === 'number' && ` · ${days === 0 ? 'chosen today' : `waiting ${days} day${days === 1 ? '' : 's'}`}`}. Stock is held
              for 14 days.
            </p>
          </div>
          {editable && (
            <Button onClick={() => setMarkOpen(true)} leftIcon={<CheckCircle2 className="h-4 w-4" />}>
              Mark paid
            </Button>
          )}
        </div>
        {(order.payment_methods?.length ?? 0) > 0 && (
          <details className="mt-3">
            <summary className="cursor-pointer text-sm text-secondary-600">What the customer was asked to pay into</summary>
            <HowToPay className="mt-2" methods={order.payment_methods!} reference={order.payment_reference || order.order_number} />
          </details>
        )}
        <MarkPaidDialog
          order={order}
          open={markOpen}
          onClose={() => setMarkOpen(false)}
          onPaid={(o) => {
            setMarkOpen(false);
            onChanged(o);
          }}
        />
      </Card>
    );
  }

  if (invoiceUuid) {
    const number = inv.created?.invoice_number;
    return (
      <Card padding="md" className="print:hidden">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="flex items-center gap-2 text-sm text-secondary-700">
            <FileText className="h-4 w-4 text-secondary-500" /> Invoice {number ? <span className="font-mono">{number}</span> : 'raised'} for this order
          </p>
          <div className="flex flex-wrap gap-2">
            <Link href={`/dashboard/invoices/${invoiceUuid}`}>
              <Button size="sm" variant={inv.created ? 'primary' : 'outline'} leftIcon={<ExternalLink className="h-4 w-4" />}>
                Open invoice
              </Button>
            </Link>
            <Button
              size="sm"
              variant="ghost"
              isLoading={inv.busy === 'pdf'}
              leftIcon={<Download className="h-4 w-4" />}
              onClick={() => inv.downloadPdf(invoiceUuid)}
            >
              Download PDF
            </Button>
          </div>
        </div>
      </Card>
    );
  }

  if (paid && editable && canInvoice) {
    return (
      <Card padding="md" className="print:hidden">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <p className="font-semibold text-secondary-900">Paid — invoice it</p>
            <p className="text-sm text-secondary-600">
              One click makes a draft invoice with these lines, the discount, delivery, VAT, the customer&apos;s PO number and your bank details.
            </p>
          </div>
          <Button onClick={inv.create} isLoading={inv.busy === 'create'} leftIcon={<FileText className="h-4 w-4" />}>
            Create invoice
          </Button>
        </div>
      </Card>
    );
  }

  return null;
}

export default OrderPaymentNextStep;
