'use client';

/**
 * Billing — /dashboard/billing
 *
 * The products this workspace sells (apps). Each app has its own features,
 * flat-tier plans, publishable key and settings; open one to manage it.
 */

import React, { useCallback, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { AppWindow, Monitor, Plus, Server, Smartphone, Wallet } from 'lucide-react';
import { Button, Card, Input, Modal, Select } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, Pill } from '@/components/field-service/shared';
import { BillingNav, KIND_LABELS } from '@/components/billing/shared';
import { billingService, type AppKind, type BillingApp } from '@/services/billing.service';

const KIND_ICONS: Record<AppKind, React.ReactNode> = {
  web: <AppWindow className="w-5 h-5" />,
  desktop: <Monitor className="w-5 h-5" />,
  self_hosted: <Server className="w-5 h-5" />,
  mobile: <Smartphone className="w-5 h-5" />,
};

function NewAppModal({ isOpen, onClose, onCreated }: { isOpen: boolean; onClose: () => void; onCreated: (a: BillingApp) => void }) {
  const [name, setName] = useState('');
  const [kind, setKind] = useState<AppKind>('web');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (isOpen) {
      setName('');
      setKind('web');
    }
  }, [isOpen]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      const app = await billingService.createApp({ name: name.trim(), kind });
      toast.success('App created');
      onCreated(app);
    } catch (err) {
      toast.error(apiError(err, 'Could not create the app'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="New app" description="A product you sell. You can add features and plans next.">
      <form onSubmit={submit} className="space-y-4">
        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} required maxLength={120} autoFocus />
        <Select label="Kind" value={kind} onChange={(e) => setKind(e.target.value as AppKind)}>
          {Object.entries(KIND_LABELS).map(([v, l]) => (
            <option key={v} value={v}>
              {l}
            </option>
          ))}
        </Select>
        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving} disabled={!name.trim()}>
            Create app
          </Button>
        </div>
      </form>
    </Modal>
  );
}

function AppsContent() {
  const router = useRouter();
  const { canCreate } = usePermissions();
  const [apps, setApps] = useState<BillingApp[]>([]);
  const [loading, setLoading] = useState(true);
  const [newOpen, setNewOpen] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setApps(await billingService.listApps());
    } catch (err) {
      toast.error(apiError(err, 'Failed to load apps'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Billing"
        description="Sell your apps on flat-tier plans and control what each customer can use."
        icon={<Wallet className="w-5 h-5" />}
        actions={
          canCreate('billing') ? (
            <Button onClick={() => setNewOpen(true)}>
              <Plus className="w-4 h-4 mr-1.5" /> New app
            </Button>
          ) : undefined
        }
      />
      <BillingNav />

      {loading ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3" aria-busy="true">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-36 rounded-xl bg-secondary-100 animate-pulse" />
          ))}
        </div>
      ) : apps.length === 0 ? (
        <Card className="text-center py-14">
          <Wallet className="w-10 h-10 mx-auto text-secondary-300" />
          <h2 className="mt-3 text-base font-semibold text-secondary-900">No apps yet</h2>
          <p className="mt-1 text-sm text-secondary-500 max-w-md mx-auto">
            Create an app for each product you sell. Then add its features (like &ldquo;Advanced reports&rdquo; or
            &ldquo;Projects&rdquo;) and the plans that include them.
          </p>
          {canCreate('billing') && (
            <Button className="mt-5" onClick={() => setNewOpen(true)}>
              <Plus className="w-4 h-4 mr-1.5" /> New app
            </Button>
          )}
        </Card>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {apps.map((a) => (
            <button
              key={a.uuid}
              type="button"
              onClick={() => router.push(`/dashboard/billing/apps/${a.uuid}`)}
              className="text-left rounded-xl border border-secondary-200 bg-surface p-5 shadow-sm transition hover:border-primary-300 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500"
            >
              <div className="flex items-start justify-between gap-3">
                <span className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary-500/10 text-primary-600">
                  {KIND_ICONS[a.kind]}
                </span>
                <div className="flex gap-1.5">
                  <Pill className={a.mode === 'live' ? 'bg-green-50 text-green-700' : 'bg-amber-50 text-amber-700'}>
                    {a.mode === 'live' ? 'Live' : 'Test'}
                  </Pill>
                  {!a.active && <Pill className="bg-secondary-100 text-secondary-500">Inactive</Pill>}
                </div>
              </div>
              <h2 className="mt-4 font-semibold text-secondary-900">{a.name}</h2>
              <p className="text-sm text-secondary-500">
                {KIND_LABELS[a.kind]} · <span className="font-mono">{a.slug}</span>
              </p>
              <p className="mt-3 text-xs text-secondary-500">
                Offline: {a.settings?.offline_policy === 'fail_open' ? 'keeps last known access' : 'blocks access'}
              </p>
            </button>
          ))}
        </div>
      )}

      <NewAppModal
        isOpen={newOpen}
        onClose={() => setNewOpen(false)}
        onCreated={(a) => {
          setNewOpen(false);
          router.push(`/dashboard/billing/apps/${a.uuid}`);
        }}
      />
    </div>
  );
}

export default function BillingPage() {
  return (
    <ProtectedPage module="billing" title="Billing">
      <AppsContent />
    </ProtectedPage>
  );
}
