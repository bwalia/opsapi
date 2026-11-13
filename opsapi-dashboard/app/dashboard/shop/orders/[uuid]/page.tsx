'use client';

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { ArrowLeft, ArrowRight, CheckCircle2, ExternalLink, PackageCheck, Printer, Save, ShoppingCart, Truck, ClipboardList, XCircle } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { SupplierPoModal } from '@/components/shop/SupplierPoModal';
import { OrderPaymentNextStep } from '@/components/shop/OrderPaymentActions';
import { MoreMenu, NextStepPanel, PoNumberField, StatusTimeline, activePurchaseOrder, orderNextStep, orderTimeline, type PanelAction } from '@/components/shop/workflow';
import { purchaseOrdersService } from '@/services/purchase-orders.service';
import { Button, Card, ConfirmDialog, Input, Modal, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import {
  CustomerBlock,
  KeyValue,
  LinesTable,
  OrderStatusBadge,
  PrintStyles,
  SHOP_MODULE,
  SectionTitle,
  ShopError,
  ShopLoading,
  TotalsBlock,
  formatAddress,
} from '@/components/shop/shared';
import { extractApiError, formatDateTime } from '@/lib/utils';
import { formatMoney, humanize, stripePaymentUrl, stripeSessionUrl } from '@/lib/shop';
import type { ShopOrder, ShopOrderStatus, ShopTracking } from '@/types/shop';

/** Allowed manual transitions. Payment states are driven by Stripe webhooks/reconcile. */
const TRANSITIONS: Record<ShopOrderStatus, ShopOrderStatus[]> = {
  pending_payment: ['cancelled'],
  payment_failed: ['cancelled'],
  paid: ['processing', 'shipped', 'cancelled', 'refunded'],
  processing: ['shipped', 'cancelled', 'refunded'],
  shipped: ['delivered', 'refunded'],
  delivered: ['refunded'],
  cancelled: [],
  refunded: [],
};

const ACTION_LABEL: Partial<Record<ShopOrderStatus, string>> = {
  processing: 'Start processing',
  shipped: 'Mark shipped',
  delivered: 'Mark delivered',
  cancelled: 'Cancel order',
  refunded: 'Mark refunded',
};

function OrderDetail() {
  const params = useParams();
  const uuid = String(params?.uuid ?? '');
  const { canUpdate } = usePermissions();
  const editable = canUpdate(SHOP_MODULE);

  const [order, setOrder] = useState<ShopOrder | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const [notes, setNotes] = useState('');
  const [tracking, setTracking] = useState<ShopTracking>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<ShopOrderStatus | null>(null);
  const [shipOpen, setShipOpen] = useState(false);
  const [poOpen, setPoOpen] = useState(false);

  const reload = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    let active = true;
    shopService
      .getOrder(uuid)
      .then((o) => {
        if (!active) return;
        setOrder(o);
        setNotes(o.internal_notes ?? '');
        setTracking(o.tracking ?? {});
        setError(null);
      })
      .catch((err) => active && setError(extractApiError(err, 'Failed to load order')));
    return () => {
      active = false;
    };
  }, [uuid, version]);

  const update = async (label: string, body: Parameters<typeof shopService.updateOrder>[1], success: string) => {
    if (!order) return;
    setBusy(label);
    try {
      const updated = await shopService.updateOrder(order.uuid, body);
      toast.success(success);
      if (updated?.uuid) {
        setOrder(updated);
        setNotes(updated.internal_notes ?? '');
        setTracking(updated.tracking ?? {});
      } else reload();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to update order'));
    } finally {
      setBusy(null);
    }
  };

  const changeStatus = (s: ShopOrderStatus) => {
    if (s === 'shipped') {
      setShipOpen(true);
      return;
    }
    if (s === 'cancelled' || s === 'refunded') {
      setConfirm(s);
      return;
    }
    update(s, { status: s }, `Order marked ${humanize(s).toLowerCase()}`);
  };

  if (error) return <ShopError message={error} onRetry={reload} />;
  if (!order) return <ShopLoading label="Loading order…" />;

  const next = TRANSITIONS[order.status] ?? [];
  const step = orderNextStep(order);
  const po = activePurchaseOrder(order);

  const receiveAll = async () => {
    if (!po) return;
    setBusy('receive');
    try {
      await purchaseOrdersService.receive(po.uuid, { receive_all: true, note: `Received for shop order ${order.order_number}` });
      toast.success(`PO ${po.po_number} marked received`);
      reload();
    } catch (err) {
      toast.error(extractApiError(err, 'Could not mark the goods received. Open the PO to record a part delivery.'));
    } finally {
      setBusy(null);
    }
  };

  let primary: PanelAction | null = null;
  if (editable) {
    if (step.key === 'raise_po') primary = { label: 'Raise supplier PO', icon: <ClipboardList className="h-4 w-4" />, onClick: () => setPoOpen(true) };
    else if (step.key === 'send_po' && po) primary = { label: `Open PO ${po.po_number}`, icon: <ArrowRight className="h-4 w-4" />, href: `/dashboard/purchase-orders/${po.uuid}` };
    else if (step.key === 'receive') primary = { label: 'Mark received', icon: <PackageCheck className="h-4 w-4" />, loading: busy === 'receive', disabled: !!busy, onClick: receiveAll };
    else if (step.key === 'ship') primary = { label: 'Mark shipped', icon: <Truck className="h-4 w-4" />, disabled: !!busy, onClick: () => changeStatus('shipped') };
    else if (step.key === 'deliver') primary = { label: 'Mark delivered', icon: <CheckCircle2 className="h-4 w-4" />, loading: busy === 'delivered', disabled: !!busy, onClick: () => changeStatus('delivered') };
  }
  const more: PanelAction[] = [];
  if (editable) {
    for (const s of next) {
      if (primary && ((s === 'shipped' && step.key === 'ship') || (s === 'delivered' && step.key === 'deliver'))) continue;
      more.push({ label: ACTION_LABEL[s] ?? humanize(s), danger: s === 'cancelled' || s === 'refunded', icon: s === 'cancelled' ? <XCircle className="h-4 w-4" /> : undefined, disabled: !!busy, onClick: () => changeStatus(s) });
    }
    if (['paid', 'processing', 'shipped', 'delivered'].includes(order.status) && step.key !== 'raise_po') {
      more.push({ label: 'Raise another supplier PO', icon: <ClipboardList className="h-4 w-4" />, onClick: () => setPoOpen(true) });
    }
  }
  if (po && step.key !== 'send_po') more.push({ label: `Open PO ${po.po_number}`, href: `/dashboard/purchase-orders/${po.uuid}` });
  if (order.public_url) more.push({ label: 'Open customer link', icon: <ExternalLink className="h-4 w-4" />, href: order.public_url });
  more.push({ label: 'Print', icon: <Printer className="h-4 w-4" />, onClick: () => window.print() });
  const tone = ['awaiting_payment', 'awaiting_bank_transfer'].includes(step.key) ? 'waiting' : ['done', 'closed'].includes(step.key) ? 'done' : 'action';
  const savePo = async (v: string | null) => {
    setBusy('po');
    try {
      const updated = await shopService.updateOrder(order.uuid, { customer_po_number: v });
      toast.success(v ? 'PO number saved' : 'PO number removed');
      if (updated?.uuid) setOrder(updated);
      else reload();
      return true;
    } catch (err) {
      toast.error(extractApiError(err, 'Could not save the PO number'));
      return false;
    } finally {
      setBusy(null);
    }
  };
  const cur = order.currency || 'GBP';
  const quoteUuid = order.quote?.uuid ?? order.quote_uuid;
  const cleanTracking = (t: ShopTracking): ShopTracking =>
    Object.fromEntries(Object.entries(t).filter(([, v]) => v !== '' && v !== undefined && v !== null)) as ShopTracking;

  return (
    <div className="space-y-6">
      <PrintStyles />
      {poOpen && <SupplierPoModal order={order} open={poOpen} onClose={() => setPoOpen(false)} />}
      <PageHeader
        title={`Order ${order.order_number}`}
        description={`Placed ${formatDateTime(order.created_at)}`}
        icon={<ShoppingCart className="h-5 w-5" />}
        actions={
          <div className="flex flex-wrap items-center gap-2 print:hidden">
            <Link href="/dashboard/shop/orders">
              <Button variant="ghost" leftIcon={<ArrowLeft className="h-4 w-4" />}>Orders</Button>
            </Link>
          </div>
        }
      />

      {/* Getting paid comes first: a bank transfer due is the next step (Mark paid); otherwise the
          fulfilment panel, with Create invoice / the invoice under it once the order is paid. */}
      {step.key !== 'awaiting_bank_transfer' && <NextStepPanel
        step={step}
        primary={primary}
        more={more}
        tone={tone}
      />}

      <OrderPaymentNextStep
        order={order}
        editable={editable}
        onChanged={(o) => {
          if (o?.uuid) {
            setOrder(o);
            setNotes(o.internal_notes ?? '');
          } else reload();
        }}
      />

      <div className="flex flex-wrap items-center gap-3">
        <OrderStatusBadge status={order.status} />
        {order.paid_at && <span className="text-sm text-secondary-500">Paid {formatDateTime(order.paid_at)}</span>}
        {order.customer_po_number && <span className="text-sm text-secondary-700">Customer PO <span className="font-mono">{order.customer_po_number}</span></span>}
        {step.key === 'awaiting_bank_transfer' && (
          <div className="ml-auto print:hidden">
            <MoreMenu actions={more} />
          </div>
        )}
      </div>
      {order.status === 'pending_payment' && order.payment_method !== 'bank_transfer' && (
        <p className="text-xs text-secondary-500 print:hidden">
          Payment status is set by Stripe’s signed webhook. If the customer says they paid and nothing changed, use “Run reconcile” on the Overview.
        </p>
      )}

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
        <div className="space-y-6 xl:col-span-2">
          <Card>
            <SectionTitle>Lines</SectionTitle>
            <LinesTable lines={order.lines} currency={cur} />
            <div className="mt-4 border-t border-secondary-200 pt-4">
              <TotalsBlock totals={order} />
            </div>
          </Card>

          <Card className="print:hidden">
            <SectionTitle
              actions={
                editable && (
                  <Button size="sm" variant="ghost" leftIcon={<Save className="h-4 w-4" />} isLoading={busy === 'notes'} onClick={() => update('notes', { internal_notes: notes }, 'Notes saved')}>
                    Save notes
                  </Button>
                )
              }
            >
              Internal notes
            </SectionTitle>
            <Textarea
              aria-label="Internal notes"
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={5}
              disabled={!editable}
              placeholder="Not visible to the customer"
            />
          </Card>
        </div>

        <div className="space-y-6">
          <Card>
            <SectionTitle>Progress</SectionTitle>
            <StatusTimeline items={orderTimeline(order)} />
          </Card>

          <Card>
            <SectionTitle>Customer PO number</SectionTitle>
            <PoNumberField value={order.customer_po_number} editable={editable} onSave={savePo} />
            <p className="mt-1 text-xs text-secondary-500">Printed on the supplier PO as “End customer PO”.</p>
          </Card>

          {(order.purchase_orders?.length ?? 0) > 0 && (
            <Card>
              <SectionTitle>Supplier purchase orders</SectionTitle>
              <ul className="divide-y divide-secondary-100">
                {order.purchase_orders!.map((po) => (
                  <li key={po.uuid}>
                    <Link href={`/dashboard/purchase-orders/${po.uuid}`} className="-mx-2 flex items-center justify-between gap-3 rounded-lg px-2 py-2 text-sm hover:bg-secondary-50">
                      <span className="min-w-0">
                        <span className="font-mono font-medium text-secondary-900">{po.po_number}</span>
                        <span className="block truncate text-xs text-secondary-500">{po.supplier_name}</span>
                      </span>
                      <span className="shrink-0 text-xs text-secondary-600">{humanize(po.status)}</span>
                    </Link>
                  </li>
                ))}
              </ul>
            </Card>
          )}
          <Card>
            <SectionTitle>Customer</SectionTitle>
            <CustomerBlock customer={order.customer} email={order.email} />
            {order.shipping_address && (
              <div className="mt-4 border-t border-secondary-100 pt-3 text-sm">
                <p className="mb-1 text-xs font-semibold uppercase tracking-wider text-secondary-500">Ship to</p>
                <p className="text-secondary-700">{formatAddress(order.shipping_address)}</p>
              </div>
            )}
            {(order.delivery_method || order.delivery_address) && (
              <div className="mt-4 border-t border-secondary-100 pt-3 text-sm">
                <p className="mb-1 text-xs font-semibold uppercase tracking-wider text-secondary-500">Deliver directly to (agreed on the order)</p>
                {order.delivery_address && (
                  <p className="text-secondary-700">
                    {[order.delivery_address.name, order.delivery_address.company, order.delivery_address.line1, order.delivery_address.line2, order.delivery_address.city, order.delivery_address.postcode, order.delivery_address.country].filter(Boolean).join(', ')}
                  </p>
                )}
                {order.delivery_address?.email && <p className="text-secondary-600">{order.delivery_address.email}</p>}
                {order.delivery_address?.vat_number && <p className="text-secondary-600">VAT {order.delivery_address.vat_number}</p>}
                {order.delivery_method && <p className="mt-1 text-secondary-700">Method: {order.delivery_method}</p>}
              </div>
            )}
            {order.billing_address && (
              <div className="mt-3 text-sm">
                <p className="mb-1 text-xs font-semibold uppercase tracking-wider text-secondary-500">Bill to</p>
                <p className="text-secondary-700">{formatAddress(order.billing_address)}</p>
              </div>
            )}
          </Card>

          <Card>
            <SectionTitle
              actions={
                editable && (
                  <Button size="sm" variant="ghost" className="print:hidden" isLoading={busy === 'tracking'} onClick={() => update('tracking', { tracking: cleanTracking(tracking) }, 'Tracking saved')}>
                    Save
                  </Button>
                )
              }
            >
              Tracking
            </SectionTitle>
            <TrackingFields value={tracking} onChange={setTracking} disabled={!editable} />
            {tracking.url && (
              <a href={String(tracking.url)} target="_blank" rel="noopener noreferrer" className="mt-2 inline-flex items-center gap-1 text-sm text-primary-600 hover:underline">
                Track shipment <ExternalLink className="h-3.5 w-3.5" />
              </a>
            )}
          </Card>

          <Card>
            <SectionTitle>Payment</SectionTitle>
            <dl className="divide-y divide-secondary-100">
              <KeyValue label="Method">{humanize(order.payment_method || 'card')}</KeyValue>
              {order.paid_reference && <KeyValue label="Reference">{order.paid_reference}</KeyValue>}
              {typeof order.paid_amount_minor === 'number' && (
                <KeyValue label="Received">{formatMoney(order.paid_amount_minor, cur)}</KeyValue>
              )}
              {order.invoice_uuid && (
                <KeyValue label="Invoice">
                  <Link href={`/dashboard/invoices/${order.invoice_uuid}`} className="text-primary-600 hover:underline">
                    Open invoice
                  </Link>
                </KeyValue>
              )}
              <KeyValue label="Payment intent">
                {order.stripe_payment_intent_id ? (
                  <a href={stripePaymentUrl(order.stripe_payment_intent_id)} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 font-mono text-xs text-primary-600 hover:underline">
                    {order.stripe_payment_intent_id}
                    <ExternalLink className="h-3 w-3" />
                  </a>
                ) : (
                  '—'
                )}
              </KeyValue>
              <KeyValue label="Checkout session">
                {order.stripe_session_id ? (
                  <a href={stripeSessionUrl(order.stripe_session_id)} target="_blank" rel="noopener noreferrer" className="font-mono text-xs text-primary-600 hover:underline">
                    {order.stripe_session_id}
                  </a>
                ) : (
                  '—'
                )}
              </KeyValue>
              {quoteUuid && (
                <KeyValue label="From quote">
                  <Link href={`/dashboard/shop/quotes/${quoteUuid}`} className="text-primary-600 hover:underline">
                    {order.quote?.quote_number ?? order.quote_number ?? order.quote?.number ?? 'View quote'}
                  </Link>
                </KeyValue>
              )}
              {order.public_url && (
                <KeyValue label="Customer link">
                  <a href={order.public_url} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-primary-600 hover:underline">
                    Open <ExternalLink className="h-3 w-3" />
                  </a>
                </KeyValue>
              )}
            </dl>
          </Card>
        </div>
      </div>

      <Modal
        isOpen={shipOpen}
        onClose={() => setShipOpen(false)}
        title="Mark as shipped"
        description="Add tracking details for the customer"
        size="md"
        footer={
          <>
            <Button variant="ghost" onClick={() => setShipOpen(false)}>Cancel</Button>
            <Button
              isLoading={busy === 'shipped'}
              onClick={async () => {
                const t = cleanTracking({ ...tracking, shipped_at: tracking.shipped_at || new Date().toISOString() });
                await update('shipped', { status: 'shipped', tracking: t }, 'Order marked shipped');
                setShipOpen(false);
              }}
            >
              Mark shipped
            </Button>
          </>
        }
      >
        <TrackingFields value={tracking} onChange={setTracking} />
      </Modal>

      <ConfirmDialog
        isOpen={!!confirm}
        onClose={() => setConfirm(null)}
        onConfirm={async () => {
          if (!confirm) return;
          await update(confirm, { status: confirm }, `Order marked ${humanize(confirm).toLowerCase()}`);
          setConfirm(null);
        }}
        title={confirm === 'refunded' ? 'Mark as refunded?' : 'Cancel order?'}
        message={
          confirm === 'refunded'
            ? 'This only records the status. Issue the refund itself in the Stripe dashboard (a full refund is also picked up automatically from the charge.refunded webhook).'
            : 'The order will be cancelled. If it was paid, refund it in Stripe as well.'
        }
        confirmText={confirm === 'refunded' ? 'Mark refunded' : 'Cancel order'}
        variant="warning"
        isLoading={!!busy}
      />
    </div>
  );
}

function TrackingFields({ value, onChange, disabled }: { value: ShopTracking; onChange: (t: ShopTracking) => void; disabled?: boolean }) {
  const set = (k: keyof ShopTracking) => (e: React.ChangeEvent<HTMLInputElement>) => onChange({ ...value, [k]: e.target.value });
  return (
    <div className="space-y-3">
      <Input label="Carrier" id="trk-carrier" value={String(value.carrier ?? '')} onChange={set('carrier')} disabled={disabled} placeholder="DPD, UPS, DHL…" />
      <Input label="Tracking number" id="trk-number" value={String(value.tracking_number ?? '')} onChange={set('tracking_number')} disabled={disabled} className="font-mono" />
      <Input label="Tracking URL" id="trk-url" value={String(value.url ?? '')} onChange={set('url')} disabled={disabled} placeholder="https://…" />
    </div>
  );
}

export default function ShopOrderPage() {
  return (
    <ProtectedPage module="shop" title="Shop Order">
      <OrderDetail />
    </ProtectedPage>
  );
}
