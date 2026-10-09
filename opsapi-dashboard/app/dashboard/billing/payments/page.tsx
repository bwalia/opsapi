'use client';

/**
 * Billing — /dashboard/billing/payments
 *
 * Connect the workspace's own Stripe account (Stripe Connect Express) so its
 * apps can take payments on Stripe's hosted checkout. Stripe sends the admin
 * back here (?stripe=return|refresh) after onboarding.
 */

import React, { useCallback, useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { CheckCircle2, CircleDashed, CreditCard, ExternalLink } from 'lucide-react';
import { Button, Card } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, Pill } from '@/components/field-service/shared';
import { BillingNav } from '@/components/billing/shared';
import { billingService, type ConnectStatus } from '@/services/billing.service';

function Step({ done, children }: { done?: boolean; children: React.ReactNode }) {
  return (
    <li className="flex items-center gap-2 text-sm">
      {done ? (
        <CheckCircle2 className="w-4 h-4 text-green-600" aria-hidden />
      ) : (
        <CircleDashed className="w-4 h-4 text-secondary-400" aria-hidden />
      )}
      <span className={done ? 'text-secondary-900' : 'text-secondary-500'}>{children}</span>
      <span className="sr-only">{done ? '(done)' : '(to do)'}</span>
    </li>
  );
}

function PaymentsContent() {
  const { canManage } = usePermissions();
  const [status, setStatus] = useState<ConnectStatus | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    billingService
      .connectStatus()
      .then(setStatus)
      .catch((err) => toast.error(apiError(err, 'Could not load the Stripe account')));
  }, []);
  useEffect(load, [load]);

  const onboard = async () => {
    setBusy(true);
    try {
      const { url } = await billingService.connectOnboard();
      window.location.assign(url);
    } catch (err) {
      toast.error(apiError(err, 'Could not start Stripe onboarding'));
      setBusy(false);
    }
  };

  const ready = !!status?.charges_enabled;
  return (
    <div className="space-y-6">
      <PageHeader
        title="Payments"
        description="Take payments for your apps on Stripe's checkout page, paid into your own Stripe account."
        icon={<CreditCard className="w-5 h-5" />}
      />
      <BillingNav />

      <Card className="shadow-sm">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h2 className="text-base font-semibold text-secondary-900">
              Stripe account{' '}
              {status &&
                (ready ? (
                  <Pill className="bg-green-50 text-green-700">Taking payments</Pill>
                ) : status.connected ? (
                  <Pill className="bg-amber-50 text-amber-700">Setup not finished</Pill>
                ) : (
                  <Pill className="bg-secondary-100 text-secondary-600">Not connected</Pill>
                ))}{' '}
              {status?.mode === 'test' && <Pill className="bg-secondary-100 text-secondary-600">Test mode</Pill>}
            </h2>
            <p className="mt-1 text-sm text-secondary-500">
              Customers pay on Stripe&apos;s checkout page. The money goes to your Stripe account, and you are the seller on
              their receipt.
              {!!status?.platform_fee_percent && ` A ${status.platform_fee_percent}% platform fee is taken from each payment.`}
            </p>
          </div>
          {canManage('billing') && status && !ready && (
            <Button onClick={onboard} isLoading={busy}>
              {status.connected ? 'Continue setup on Stripe' : 'Connect with Stripe'}
              <ExternalLink className="w-4 h-4 ml-1.5" aria-hidden />
            </Button>
          )}
        </div>
        {status?.connected && (
          <ul className="mt-4 space-y-1.5">
            <Step done>Account created ({status.account})</Step>
            <Step done={status.details_submitted}>Business details sent to Stripe</Step>
            <Step done={status.charges_enabled}>Can take payments</Step>
            <Step done={status.payouts_enabled}>Payouts to your bank</Step>
          </ul>
        )}
        {status && !canManage('billing') && !ready && (
          <p className="mt-4 text-sm text-secondary-500">Ask a workspace admin to connect Stripe.</p>
        )}
      </Card>

      {ready && (
        <Card className="shadow-sm">
          <h2 className="text-base font-semibold text-secondary-900">Selling</h2>
          <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-secondary-600">
            <li>Each app has a hosted pricing page: open the app and copy its pricing link.</li>
            <li>Your own site or app can start a checkout through the API or the SDK.</li>
            <li>Refunds are made from Subscriptions → Purchases; access follows each app&apos;s refund policy.</li>
          </ul>
        </Card>
      )}
    </div>
  );
}

export default function PaymentsPage() {
  return (
    <ProtectedPage module="billing" title="Payments">
      <PaymentsContent />
    </ProtectedPage>
  );
}
