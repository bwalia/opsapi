'use client';

import React, { useState, useEffect, useMemo } from 'react';
import {
  Building2,
  Save,
  Loader2,
  AlertTriangle,
  Key,
  Users as UsersIcon,
  Store as StoreIcon,
  Gauge,
  ChevronRight,
} from 'lucide-react';
import { Button, Card } from '@/components/ui';
import NamespaceFormFields, { type NamespaceFieldValues } from '@/components/namespace/NamespaceFormFields';
import MfaSettingCard from '@/components/namespace/MfaSettingCard';
import { useNamespace } from '@/contexts/NamespaceContext';
import { namespaceService } from '@/services';
import toast from 'react-hot-toast';
import type { UpdateNamespaceDto } from '@/types';
import Link from 'next/link';

const EMPTY: NamespaceFieldValues = { name: '', description: '', domain: '', logo_url: '', banner_url: '', business_type: '' };

export default function NamespaceSettingsPage() {
  const { currentNamespace, isNamespaceOwner, refreshNamespaces } = useNamespace();
  const [initial, setInitial] = useState<NamespaceFieldValues>(EMPTY);
  const [values, setValues] = useState<NamespaceFieldValues>(EMPTY);
  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    if (currentNamespace) {
      const next: NamespaceFieldValues = {
        name: currentNamespace.name || '',
        description: currentNamespace.description || '',
        domain: currentNamespace.domain || '',
        logo_url: currentNamespace.logo_url || '',
        banner_url: currentNamespace.banner_url || '',
        business_type: currentNamespace.business_type || '',
      };
      setInitial(next);
      setValues(next);
    }
  }, [currentNamespace]);

  const dirty = useMemo(() => JSON.stringify(initial) !== JSON.stringify(values), [initial, values]);

  const set = (name: keyof NamespaceFieldValues, value: string) =>
    setValues((prev) => ({ ...prev, [name]: value }));

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!currentNamespace || !values.name.trim()) {
      if (!values.name.trim()) toast.error('Workspace name is required');
      return;
    }
    setIsSaving(true);
    try {
      await namespaceService.updateCurrentNamespace(values as UpdateNamespaceDto);
      setInitial(values);
      toast.success('Settings saved');
      refreshNamespaces();
    } catch {
      toast.error('Failed to update settings');
    } finally {
      setIsSaving(false);
    }
  };

  if (!isNamespaceOwner && currentNamespace) {
    return (
      <div className="mx-auto max-w-2xl">
        <Card className="p-10 text-center">
          <AlertTriangle className="mx-auto mb-4 h-12 w-12 text-warning-500" />
          <h2 className="mb-2 text-lg font-semibold text-secondary-900">Access restricted</h2>
          <p className="text-secondary-500">Only the workspace owner can change these settings.</p>
        </Card>
      </div>
    );
  }

  if (!currentNamespace) {
    return (
      <div className="mx-auto max-w-2xl">
        <Card className="p-10 text-center">
          <Building2 className="mx-auto mb-4 h-12 w-12 text-secondary-300" />
          <p className="text-secondary-500">No workspace selected.</p>
        </Card>
      </div>
    );
  }

  const ns = currentNamespace;
  const limits: { icon: React.ReactNode; label: string; value: React.ReactNode }[] = [
    { icon: <Gauge className="h-4 w-4" />, label: 'Plan', value: <span className="capitalize">{ns.plan}</span> },
    {
      icon: <span className={`h-2 w-2 rounded-full ${ns.status === 'active' ? 'bg-success-500' : 'bg-warning-500'}`} />,
      label: 'Status',
      value: <span className="capitalize">{ns.status}</span>,
    },
    { icon: <UsersIcon className="h-4 w-4" />, label: 'Max users', value: ns.max_users },
    { icon: <StoreIcon className="h-4 w-4" />, label: 'Max stores', value: ns.max_stores },
  ];

  return (
    <form onSubmit={handleSubmit} className="mx-auto max-w-7xl">
      {/* Identity header */}
      <div className="relative overflow-hidden rounded-2xl border border-secondary-200 bg-gradient-to-br from-primary-600 to-primary-500 p-6 text-white sm:p-8">
        {ns.banner_url && (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={ns.banner_url} alt="" className="pointer-events-none absolute inset-0 h-full w-full object-cover opacity-25" onError={(e) => (e.currentTarget.style.display = 'none')} />
        )}
        <div className="relative flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-center gap-4">
            <div className="flex h-16 w-16 shrink-0 items-center justify-center overflow-hidden rounded-2xl bg-white/15 ring-1 ring-white/30 backdrop-blur">
              {ns.logo_url ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={ns.logo_url} alt="" className="h-full w-full object-cover" onError={(e) => (e.currentTarget.style.display = 'none')} />
              ) : (
                <Building2 className="h-8 w-8 text-white" />
              )}
            </div>
            <div>
              <h1 className="text-2xl font-bold leading-tight">{ns.name}</h1>
              <div className="mt-1 flex flex-wrap items-center gap-2 text-sm text-white/80">
                <code className="rounded bg-white/15 px-1.5 py-0.5 font-mono text-xs">/{ns.slug}</code>
                <span className="rounded-full bg-white/15 px-2 py-0.5 text-xs capitalize">{ns.plan} plan</span>
                <span className="rounded-full bg-white/15 px-2 py-0.5 text-xs capitalize">{ns.status}</span>
              </div>
            </div>
          </div>
          <Link
            href="/dashboard/namespace/api-keys"
            className="inline-flex items-center gap-2 self-start rounded-lg bg-white/15 px-4 py-2 text-sm font-medium text-white ring-1 ring-white/30 backdrop-blur transition hover:bg-white/25"
          >
            <Key className="h-4 w-4" /> API Keys
          </Link>
        </div>
      </div>

      {/* Two columns: forms + rail */}
      <div className="mt-6 grid grid-cols-1 gap-6 xl:grid-cols-12">
        <div className="space-y-6 xl:col-span-8">
          <NamespaceFormFields values={values} onChange={set} slug={ns.slug} disabled={isSaving} />
        </div>

        <aside className="space-y-6 xl:col-span-4">
          <MfaSettingCard />

          <Card className="p-6">
            <div className="mb-4 flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-secondary-100">
                <Gauge className="h-5 w-5 text-secondary-600" />
              </div>
              <div>
                <h2 className="text-base font-semibold text-secondary-900">Plan &amp; limits</h2>
                <p className="text-sm text-secondary-500">Set by your platform administrator</p>
              </div>
            </div>
            <dl className="divide-y divide-secondary-100">
              {limits.map((l) => (
                <div key={l.label} className="flex items-center justify-between py-2.5">
                  <dt className="flex items-center gap-2 text-sm text-secondary-500">
                    <span className="flex h-4 w-4 items-center justify-center text-secondary-400">{l.icon}</span>
                    {l.label}
                  </dt>
                  <dd className="text-sm font-semibold text-secondary-900">{l.value}</dd>
                </div>
              ))}
            </dl>
          </Card>

          <Link
            href="/dashboard/namespace/api-keys"
            className="group flex items-center gap-3 rounded-xl border border-secondary-200 bg-surface p-4 transition hover:border-primary-300 hover:bg-primary-50/40"
          >
            <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-secondary-100 group-hover:bg-primary-100">
              <Key className="h-5 w-5 text-secondary-600 group-hover:text-primary-600" />
            </div>
            <div className="min-w-0 flex-1">
              <p className="text-sm font-semibold text-secondary-900">API keys</p>
              <p className="truncate text-xs text-secondary-500">Programmatic access to this workspace</p>
            </div>
            <ChevronRight className="h-4 w-4 shrink-0 text-secondary-400 group-hover:text-primary-600" />
          </Link>
        </aside>
      </div>

      {/* Sticky action bar — stays within the content column (no sidebar-width math). */}
      <div className="sticky bottom-0 z-20 -mx-4 mt-6 flex items-center justify-between gap-3 rounded-b-lg border-t border-secondary-200 bg-surface/90 px-4 py-3 backdrop-blur sm:-mx-6 sm:px-6">
        <p className="text-sm text-secondary-500">{dirty ? 'You have unsaved changes.' : 'All changes saved.'}</p>
        <div className="flex items-center gap-3">
          <Button type="button" variant="secondary" onClick={() => setValues(initial)} disabled={!dirty || isSaving}>
            Reset
          </Button>
          <Button type="submit" disabled={!dirty || isSaving}>
            {isSaving ? (
              <><Loader2 className="mr-2 h-4 w-4 animate-spin" /> Saving…</>
            ) : (
              <><Save className="mr-2 h-4 w-4" /> Save changes</>
            )}
          </Button>
        </div>
      </div>
    </form>
  );
}
