'use client';

import React, { useEffect, useState } from 'react';
import { Settings } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Switch, confirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { SHOP_DELIVERY_KEYS, shopService, type ShopSettings } from '@/services/shop.service';
import { extractApiError, formatDate } from '@/lib/utils';
import type { PurchaseOrderParty } from '@/services/purchase-orders.service';

const BILL_TO_FIELDS: [keyof PurchaseOrderParty, string][] = [
  ['company', 'Company'],
  ['line1', 'Address line 1'],
  ['line2', 'Address line 2'],
  ['city', 'Town / city'],
  ['county', 'County'],
  ['postcode', 'Postcode'],
  ['country', 'Country'],
  ['phone', 'Phone'],
  ['email', 'Email'],
  ['vat_number', 'VAT number'],
];

type DeliveryKey = (typeof SHOP_DELIVERY_KEYS)[number];
const DELIVERY_DEFAULTS: Record<DeliveryKey, number> = {
  delivery_cost_minor: 0,
  delivery_handling_min_days: 1,
  delivery_handling_max_days: 2,
  delivery_transit_min_days: 1,
  delivery_transit_max_days: 3,
  quote_valid_days: 30,
};
const DELIVERY_FIELDS: [DeliveryKey, string, string][] = [
  ['delivery_handling_min_days', 'Dispatch: from (working days)', 'In-stock items. The shop says "Ships in 1–2 days"'],
  ['delivery_handling_max_days', 'Dispatch: up to (working days)', 'Out-of-stock items use their own lead time'],
  ['delivery_transit_min_days', 'Courier: from (working days)', 'After dispatch, UK mainland'],
  ['delivery_transit_max_days', 'Courier: up to (working days)', ''],
  ['quote_valid_days', 'Quotes hold their price for (days)', 'New quotes; also the "price valid until" search engines see'],
];

function SettingsContent() {
  const { canUpdate } = usePermissions();
  const [settings, setSettings] = useState<ShopSettings | null>(null);
  const [saving, setSaving] = useState(false);
  const [billTo, setBillTo] = useState<PurchaseOrderParty>({});
  const [savingBill, setSavingBill] = useState(false);
  const [alertEmail, setAlertEmail] = useState('');
  const [savingAlert, setSavingAlert] = useState(false);
  const [savingNotify, setSavingNotify] = useState(false);
  const [deliverTo, setDeliverTo] = useState<PurchaseOrderParty>({});
  const [savingDeliver, setSavingDeliver] = useState(false);
  const [dealPrefix, setDealPrefix] = useState('WS');
  const [dealLength, setDealLength] = useState('8');
  const [savingDeal, setSavingDeal] = useState(false);
  const [delivery, setDelivery] = useState<Record<DeliveryKey, string>>(() =>
    Object.fromEntries(SHOP_DELIVERY_KEYS.map((k) => [k, String(k === 'delivery_cost_minor' ? DELIVERY_DEFAULTS[k] / 100 : DELIVERY_DEFAULTS[k])])) as Record<DeliveryKey, string>,
  );
  const [savingDelivery, setSavingDelivery] = useState(false);

  useEffect(() => {
    shopService
      .getSettings()
      .then((s) => {
        setSettings(s);
        setBillTo(s.po_bill_to ?? {});
        setAlertEmail(s.order_alert_email ?? '');
        setDeliverTo(s.po_deliver_to ?? {});
        setDealPrefix(s.deal_code_prefix ?? 'WS');
        setDealLength(String(s.deal_code_length ?? 8));
        setDelivery(
          Object.fromEntries(
            SHOP_DELIVERY_KEYS.map((k) => {
              const v = s[k] ?? DELIVERY_DEFAULTS[k];
              return [k, k === 'delivery_cost_minor' ? (v / 100).toFixed(2) : String(v)];
            }),
          ) as Record<DeliveryKey, string>,
        );
      })
      .catch((e) => toast.error(extractApiError(e, 'Could not load shop settings')));
  }, []);

  const setCheckout = async (on: boolean) => {
    if (
      on &&
      !(await confirmDialog({
        title: 'Turn on online checkout?',
        message: 'Customers will be able to pay for orders by card at the prices shown in the shop.',
        confirmText: 'Turn on',
      }))
    )
      return;
    setSaving(true);
    try {
      setSettings(await shopService.updateSettings({ checkout_enabled: on }));
      toast.success(on ? 'Online checkout is on' : 'Online checkout is off: the shop takes enquiries');
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save'));
    } finally {
      setSaving(false);
    }
  };

  const saveBillTo = async () => {
    setSavingBill(true);
    try {
      const clean = Object.fromEntries(Object.entries(billTo).filter(([, v]) => typeof v === 'string' && v.trim())) as PurchaseOrderParty;
      const s = await shopService.updateSettings({ po_bill_to: Object.keys(clean).length ? clean : null });
      setSettings(s);
      setBillTo(s.po_bill_to ?? {});
      toast.success('Bill-to details saved');
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save'));
    } finally {
      setSavingBill(false);
    }
  };

  const saveDeliverTo = async () => {
    setSavingDeliver(true);
    try {
      const clean = Object.fromEntries(Object.entries(deliverTo).filter(([, v]) => typeof v === 'string' && v.trim())) as PurchaseOrderParty;
      const s = await shopService.updateSettings({ po_deliver_to: Object.keys(clean).length ? clean : null });
      setSettings(s);
      setDeliverTo(s.po_deliver_to ?? {});
      toast.success('Delivery address saved');
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save'));
    } finally {
      setSavingDeliver(false);
    }
  };

  const saveDelivery = async () => {
    const body: Partial<Record<DeliveryKey, number>> = {};
    for (const k of SHOP_DELIVERY_KEYS) {
      const n = Number(delivery[k]);
      if (!Number.isFinite(n) || n < 0) {
        toast.error('Enter a number of 0 or more in every delivery field');
        return;
      }
      body[k] = k === 'delivery_cost_minor' ? Math.round(n * 100) : Math.round(n);
    }
    setSavingDelivery(true);
    try {
      setSettings(await shopService.updateSettings(body));
      toast.success('Delivery settings saved');
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save'));
    } finally {
      setSavingDelivery(false);
    }
  };

  const saveDealCodes = async () => {
    setSavingDeal(true);
    try {
      const s = await shopService.updateSettings({ deal_code_prefix: dealPrefix.trim(), deal_code_length: Number(dealLength) });
      setSettings(s);
      setDealPrefix(s.deal_code_prefix ?? 'WS');
      setDealLength(String(s.deal_code_length ?? 8));
      toast.success('Deal code settings saved. New deals use them; existing codes stay as they are.');
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save'));
    } finally {
      setSavingDeal(false);
    }
  };

  const setCustomerNotifications = async (on: boolean) => {
    if (
      on &&
      !(await confirmDialog({
        title: 'Turn on customer emails from the shop?',
        message:
          'Customers will be emailed from the shop’s current sending address: order updates your team sends from an order page, and the outcome when you approve or decline a delivery change request. Only turn this on once the sending address has been changed.',
        confirmText: 'Turn on',
      }))
    )
      return;
    setSavingNotify(true);
    try {
      setSettings(await shopService.updateSettings({ customer_delivery_notifications: on }));
      toast.success(on ? 'Customer emails from the shop are on' : 'Customer emails from the shop are off');
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save'));
    } finally {
      setSavingNotify(false);
    }
  };

  const saveAlertEmail = async () => {
    setSavingAlert(true);
    try {
      const s = await shopService.updateSettings({ order_alert_email: alertEmail.trim() || null });
      setSettings(s);
      setAlertEmail(s.order_alert_email ?? '');
      toast.success(s.order_alert_email ? `New-order alerts go to ${s.order_alert_email}` : 'New-order alerts go to the Leads notification email');
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save'));
    } finally {
      setSavingAlert(false);
    }
  };

  return (
    <div className="space-y-6">
      <PageHeader
        title="Shop settings"
        description="How customers buy. Changes reach the shop and the website within a minute."
        icon={<Settings className="h-5 w-5" />}
      />
      <Card className="p-6">
        <div className="flex items-start justify-between gap-6">
          <div className="space-y-1">
            <h2 className="text-base font-semibold text-secondary-900">Online checkout</h2>
            <p className="text-sm text-secondary-600">
              {settings?.checkout_enabled
                ? 'On: customers can pay for orders by card.'
                : 'Off: prices show as estimates and customers send an enquiry from their basket. Each enquiry creates a quote and a CRM lead; you confirm the final price.'}
            </p>
            <p className="text-xs text-secondary-500">
              Trade membership sign-up is not affected.
              {settings?.updated_at ? ` Last changed ${formatDate(settings.updated_at)}.` : ''}
            </p>
          </div>
          <Switch
            aria-label="Online checkout"
            checked={!!settings?.checkout_enabled}
            disabled={!settings || saving || !canUpdate('shop')}
            onChange={setCheckout}
          />
        </div>
      </Card>
      <Card className="p-6">
        <div className="mb-4 flex items-start justify-between gap-4">
          <div className="space-y-1">
            <h2 className="text-base font-semibold text-secondary-900">New-order alerts</h2>
            <p className="text-sm text-secondary-600">
              We email this address when an order is paid online or a customer chooses to pay by bank transfer (and send the Telegram alert if it is on under Leads → Notifications). Customers are not emailed.
              Leave it empty to use the Leads notification email.
            </p>
          </div>
          <Button size="sm" isLoading={savingAlert} disabled={!settings || !canUpdate('shop')} onClick={saveAlertEmail}>Save</Button>
        </div>
        <Input
          label="Alert email"
          id="order-alert-email"
          type="email"
          placeholder="sales@example.com"
          value={alertEmail}
          disabled={!canUpdate('shop')}
          onChange={(e) => setAlertEmail(e.target.value)}
        />
      </Card>
      <Card className="p-6">
        <div className="flex items-start justify-between gap-6">
          <div className="space-y-1">
            <h2 className="text-base font-semibold text-secondary-900">Customer emails from the shop (order updates and delivery decisions)</h2>
            <p className="text-sm text-secondary-600">
              {settings?.customer_delivery_notifications
                ? 'On: your team can email a customer an update from the order page (“Email the customer”), and customers are emailed the outcome when you approve or decline their delivery change request.'
                : 'Off: no emails go to customers from the shop. On an order page you can still send a test of an update to yourself. Customers see delivery change decisions on their order page.'}
            </p>
            <p className="text-xs text-secondary-500">
              Keep this off until the shop’s sending email address has been changed. There is no SMS sending yet. New requests always alert staff (New-order alerts above).
            </p>
          </div>
          <Switch
            aria-label="Customer emails from the shop"
            checked={!!settings?.customer_delivery_notifications}
            disabled={!settings || savingNotify || !canUpdate('shop')}
            onChange={setCustomerNotifications}
          />
        </div>
      </Card>
      <Card className="p-6">
        <div className="mb-4 flex items-start justify-between gap-4">
          <div className="space-y-1">
            <h2 className="text-base font-semibold text-secondary-900">Supplier purchase orders: Bill to</h2>
            <p className="text-sm text-secondary-600">
              Printed as &ldquo;Bill to&rdquo; on purchase orders raised from paid shop orders.
            </p>
          </div>
          <Button size="sm" isLoading={savingBill} disabled={!settings || !canUpdate('shop')} onClick={saveBillTo}>Save</Button>
        </div>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          {BILL_TO_FIELDS.map(([k, label]) => (
            <Input
              key={k}
              label={label}
              id={`bill-${k}`}
              value={billTo[k] ?? ''}
              disabled={!canUpdate('shop')}
              onChange={(e) => setBillTo({ ...billTo, [k]: e.target.value })}
            />
          ))}
        </div>
      </Card>
      <Card className="p-6">
        <div className="mb-4 flex items-start justify-between gap-4">
          <div className="space-y-1">
            <h2 className="text-base font-semibold text-secondary-900">Supplier purchase orders: deliver to us</h2>
            <p className="text-sm text-secondary-600">
              Suppliers deliver here unless you tick a drop-ship on the purchase order. Leave it empty to use the Bill to address.
            </p>
          </div>
          <Button size="sm" isLoading={savingDeliver} disabled={!settings || !canUpdate('shop')} onClick={saveDeliverTo}>Save</Button>
        </div>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          {BILL_TO_FIELDS.filter(([k]) => k !== 'vat_number').map(([k, label]) => (
            <Input
              key={k}
              label={label}
              id={`deliver-${k}`}
              value={deliverTo[k] ?? ''}
              disabled={!canUpdate('shop')}
              onChange={(e) => setDeliverTo({ ...deliverTo, [k]: e.target.value })}
            />
          ))}
        </div>
      </Card>
      <Card className="p-6">
        <div className="mb-4 flex items-start justify-between gap-4">
          <div className="space-y-1">
            <h2 className="text-base font-semibold text-secondary-900">UK delivery and quote validity</h2>
            <p className="text-sm text-secondary-600">
              What the shop tells customers and search engines (Google Shopping) about delivery. Keep it the same as the basket and your Terms of Sale:
              a delivery cost of 0 shows as &ldquo;Included&rdquo;.
            </p>
          </div>
          <Button size="sm" isLoading={savingDelivery} disabled={!settings || !canUpdate('shop')} onClick={saveDelivery}>Save</Button>
        </div>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Input
            label="UK delivery cost (£ ex VAT)"
            id="delivery-cost"
            inputMode="decimal"
            value={delivery.delivery_cost_minor}
            helperText="0 = included in the price"
            disabled={!canUpdate('shop')}
            onChange={(e) => setDelivery({ ...delivery, delivery_cost_minor: e.target.value })}
          />
          {DELIVERY_FIELDS.map(([k, label, help]) => (
            <Input
              key={k}
              label={label}
              id={`delivery-${k}`}
              type="number"
              min={k === 'quote_valid_days' ? 1 : 0}
              value={delivery[k]}
              helperText={help || undefined}
              disabled={!canUpdate('shop')}
              onChange={(e) => setDelivery({ ...delivery, [k]: e.target.value })}
            />
          ))}
        </div>
      </Card>
      <Card className="p-6">
        <div className="mb-4 flex items-start justify-between gap-4">
          <div className="space-y-1">
            <h2 className="text-base font-semibold text-secondary-900">Deal codes</h2>
            <p className="text-sm text-secondary-600">
              Every deal gets one private code (for example {dealPrefix || 'WS'}-DT5Z-994X) that links the customer’s quotes and orders to supplier requests and purchase orders.
              Suppliers see only the code. Customers never see it.
            </p>
          </div>
          <Button size="sm" isLoading={savingDeal} disabled={!settings || !canUpdate('shop')} onClick={saveDealCodes}>Save</Button>
        </div>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Input label="Prefix" id="deal-prefix" value={dealPrefix} maxLength={6} helperText="1 to 6 letters or numbers" disabled={!canUpdate('shop')} onChange={(e) => setDealPrefix(e.target.value.toUpperCase())} />
          <Input label="Length (random characters)" id="deal-length" type="number" min={6} max={16} value={dealLength} helperText="6 to 16. 8 gives XXXX-XXXX" disabled={!canUpdate('shop')} onChange={(e) => setDealLength(e.target.value)} />
        </div>
      </Card>
    </div>
  );
}

export default function ShopSettingsPage() {
  return (
    <ProtectedPage module="shop" title="Shop Settings">
      <SettingsContent />
    </ProtectedPage>
  );
}
