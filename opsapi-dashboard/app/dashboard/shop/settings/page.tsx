'use client';

import React, { useEffect, useState } from 'react';
import { Settings } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Card, Switch, confirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService, type ShopSettings } from '@/services/shop.service';
import { extractApiError, formatDate } from '@/lib/utils';

function SettingsContent() {
  const { canUpdate } = usePermissions();
  const [settings, setSettings] = useState<ShopSettings | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    shopService
      .getSettings()
      .then(setSettings)
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
