'use client';

import React, { useEffect, useState } from 'react';
import { Settings } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Switch, confirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService, type ShopSettings } from '@/services/shop.service';
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

function SettingsContent() {
  const { canUpdate } = usePermissions();
  const [settings, setSettings] = useState<ShopSettings | null>(null);
  const [saving, setSaving] = useState(false);
  const [billTo, setBillTo] = useState<PurchaseOrderParty>({});
  const [savingBill, setSavingBill] = useState(false);

  useEffect(() => {
    shopService
      .getSettings()
      .then((s) => {
        setSettings(s);
        setBillTo(s.po_bill_to ?? {});
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
            <h2 className="text-base font-semibold text-secondary-900">Supplier purchase orders: Bill to</h2>
            <p className="text-sm text-secondary-600">
              Printed as &ldquo;Bill to&rdquo; on purchase orders raised from paid shop orders. The supplier delivers directly to the customer.
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
