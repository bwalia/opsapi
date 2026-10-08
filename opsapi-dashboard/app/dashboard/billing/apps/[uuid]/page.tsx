'use client';

/**
 * Billing — one app: overview (numbers, keys, settings), features, plans.
 */

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { ArrowLeft, Wallet } from 'lucide-react';
import { Card } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { apiError } from '@/components/field-service/shared';
import { BillingNav, KIND_LABELS, Tabs } from '@/components/billing/shared';
import AppOverview from '@/components/billing/AppOverview';
import AppFeatures from '@/components/billing/AppFeatures';
import AppPlans from '@/components/billing/AppPlans';
import { billingService, type BillingApp } from '@/services/billing.service';

type Tab = 'overview' | 'features' | 'plans';
const TABS: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'features', label: 'Features' },
  { id: 'plans', label: 'Plans' },
];

function AppContent() {
  const params = useParams();
  const router = useRouter();
  const uuid = params?.uuid as string;
  const [app, setApp] = useState<BillingApp | null>(null);
  const [missing, setMissing] = useState(false);
  const [tab, setTab] = useState<Tab>('overview');

  const load = useCallback(() => {
    billingService
      .getApp(uuid)
      .then(setApp)
      .catch((err) => {
        setMissing(true);
        toast.error(apiError(err, 'App not found'));
      });
  }, [uuid]);

  useEffect(() => {
    load();
  }, [load]);

  if (missing) {
    return (
      <Card className="text-center py-14">
        <p className="text-secondary-600">This app doesn&apos;t exist or was deleted.</p>
        <Link href="/dashboard/billing" className="mt-3 inline-block text-primary-600 hover:underline">
          Back to apps
        </Link>
      </Card>
    );
  }
  if (!app) return <div className="h-40 rounded-xl bg-secondary-100 animate-pulse" aria-busy="true" />;

  const features = app.features || [];
  return (
    <div className="space-y-6">
      <Link href="/dashboard/billing" className="inline-flex items-center text-sm text-secondary-500 hover:text-secondary-800">
        <ArrowLeft className="w-4 h-4 mr-1" /> Apps
      </Link>
      <PageHeader
        title={app.name}
        description={`${KIND_LABELS[app.kind]} · ${app.mode === 'live' ? 'Live' : 'Test'} mode`}
        icon={<Wallet className="w-5 h-5" />}
      />
      <BillingNav />
      <Tabs tabs={TABS} value={tab} onChange={setTab} label="App sections" />
      <div role="tabpanel">
        {tab === 'overview' && (
          <AppOverview
            app={app}
            onChange={(a) => setApp((prev) => ({ ...a, features: prev?.features }))}
            onDeleted={() => router.push('/dashboard/billing')}
          />
        )}
        {tab === 'features' && <AppFeatures app={app} features={features} onChanged={load} />}
        {tab === 'plans' && <AppPlans app={app} features={features} />}
      </div>
    </div>
  );
}

export default function BillingAppPage() {
  return (
    <ProtectedPage module="billing" title="Billing">
      <AppContent />
    </ProtectedPage>
  );
}
