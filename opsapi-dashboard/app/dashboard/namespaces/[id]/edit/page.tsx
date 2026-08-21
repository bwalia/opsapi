'use client';

import React, { useState, useEffect, useCallback, useMemo } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  Settings,
  Save,
  Loader2,
  AlertTriangle,
  ArrowLeft,
  SlidersHorizontal,
} from 'lucide-react';
import { Button, Card } from '@/components/ui';
import { PageHeader } from '@/components/layout/PageHeader';
import NamespaceFormFields, { type NamespaceFieldValues } from '@/components/namespace/NamespaceFormFields';
import { usePermissions } from '@/contexts/PermissionsContext';
import { namespaceService } from '@/services';
import type { Namespace, NamespaceStatus, NamespacePlan } from '@/types';
import toast from 'react-hot-toast';
import Link from 'next/link';

const EMPTY: NamespaceFieldValues = { name: '', description: '', domain: '', logo_url: '', banner_url: '' };
const STATUSES: NamespaceStatus[] = ['active', 'pending', 'suspended', 'archived'];
const PLANS: NamespacePlan[] = ['free', 'starter', 'professional', 'enterprise'];

interface AdminFields {
  status: NamespaceStatus;
  plan: NamespacePlan;
  max_users: number;
  max_stores: number;
}

export default function EditNamespacePage() {
  const params = useParams();
  const router = useRouter();
  const { isAdmin } = usePermissions();
  const namespaceId = params.id as string;
  const detailHref = `/dashboard/namespaces/${namespaceId}`;

  const [namespace, setNamespace] = useState<Namespace | null>(null);
  const [values, setValues] = useState<NamespaceFieldValues>(EMPTY);
  const [initial, setInitial] = useState<NamespaceFieldValues>(EMPTY);
  const [admin, setAdmin] = useState<AdminFields>({ status: 'active', plan: 'free', max_users: 0, max_stores: 0 });
  const [initialAdmin, setInitialAdmin] = useState<AdminFields>(admin);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  const load = useCallback(async () => {
    if (!namespaceId) return;
    setIsLoading(true);
    setError(null);
    try {
      const ns = await namespaceService.getNamespaceById(namespaceId);
      setNamespace(ns);
      const v: NamespaceFieldValues = {
        name: ns.name || '',
        description: ns.description || '',
        domain: ns.domain || '',
        logo_url: ns.logo_url || '',
        banner_url: ns.banner_url || '',
      };
      const a: AdminFields = {
        status: ns.status,
        plan: ns.plan,
        max_users: ns.max_users ?? 0,
        max_stores: ns.max_stores ?? 0,
      };
      setValues(v); setInitial(v);
      setAdmin(a); setInitialAdmin(a);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to load namespace';
      setError(message);
      toast.error(message);
    } finally {
      setIsLoading(false);
    }
  }, [namespaceId]);

  useEffect(() => {
    if (isAdmin) load();
  }, [isAdmin, load]);

  const dirty = useMemo(
    () => JSON.stringify(initial) !== JSON.stringify(values) || JSON.stringify(initialAdmin) !== JSON.stringify(admin),
    [initial, values, initialAdmin, admin],
  );

  const set = (name: keyof NamespaceFieldValues, value: string) =>
    setValues((prev) => ({ ...prev, [name]: value }));

  const reset = () => { setValues(initial); setAdmin(initialAdmin); };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!values.name.trim()) return toast.error('Namespace name is required');
    setIsSaving(true);
    try {
      const updated = await namespaceService.updateNamespaceAdmin(namespaceId, {
        ...values,
        status: admin.status,
        plan: admin.plan,
        max_users: Number(admin.max_users) || 0,
        max_stores: Number(admin.max_stores) || 0,
      });
      setNamespace(updated);
      setInitial(values); setInitialAdmin(admin);
      toast.success('Namespace updated');
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to update namespace');
    } finally {
      setIsSaving(false);
    }
  };

  // ---- Guards --------------------------------------------------------------
  if (!isAdmin) {
    return (
      <Card className="p-8 text-center max-w-lg mx-auto">
        <AlertTriangle className="w-12 h-12 text-warning-500 mx-auto mb-4" />
        <h2 className="text-lg font-semibold text-secondary-900 mb-2">Access Restricted</h2>
        <p className="text-secondary-500 mb-4">You need platform administrator access to edit a namespace.</p>
        <Link href="/dashboard/namespaces"><Button variant="outline">Back to Namespaces</Button></Link>
      </Card>
    );
  }

  if (isLoading) {
    return (
      <div className="flex justify-center py-24">
        <Loader2 className="w-6 h-6 animate-spin text-primary-500" />
      </div>
    );
  }

  if (error || !namespace) {
    return (
      <Card className="p-8 text-center max-w-lg mx-auto">
        <AlertTriangle className="w-12 h-12 text-error-500 mx-auto mb-4" />
        <h2 className="text-lg font-semibold text-secondary-900 mb-2">{error || 'Namespace not found'}</h2>
        <div className="flex items-center justify-center gap-3 mt-4">
          <Link href="/dashboard/namespaces"><Button variant="outline">Back to Namespaces</Button></Link>
          <Button onClick={load}>Try again</Button>
        </div>
      </Card>
    );
  }

  const selectCls =
    'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm bg-surface focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 capitalize';
  const numberCls =
    'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500';

  return (
    <div className="max-w-4xl">
      <div className="flex items-center gap-2 mb-2">
        <button
          onClick={() => router.push(detailHref)}
          className="inline-flex items-center justify-center w-8 h-8 rounded-lg border border-secondary-200 text-secondary-500 hover:text-secondary-800 hover:border-secondary-300 transition-colors"
          aria-label="Back to namespace"
        >
          <ArrowLeft className="w-4 h-4" />
        </button>
        <span className="text-sm text-secondary-500">Editing @{namespace.slug}</span>
      </div>

      <PageHeader
        title={`Edit ${namespace.name}`}
        description="Update this namespace's profile, branding, plan and limits."
        icon={<Settings className="h-5 w-5" />}
      />

      <form onSubmit={handleSubmit} className="mt-6 space-y-6">
        <NamespaceFormFields values={values} onChange={set} slug={namespace.slug} disabled={isSaving} />

        {/* Admin-only: plan, status, limits */}
        <Card className="p-6">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-10 h-10 rounded-lg bg-primary-100 flex items-center justify-center">
              <SlidersHorizontal className="w-5 h-5 text-primary-600" />
            </div>
            <div>
              <h2 className="text-base font-semibold text-secondary-900">Plan &amp; Limits</h2>
              <p className="text-sm text-secondary-500">Administrator-only controls</p>
            </div>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">Status</label>
              <select
                value={admin.status}
                onChange={(e) => setAdmin((p) => ({ ...p, status: e.target.value as NamespaceStatus }))}
                className={selectCls}
                disabled={isSaving}
              >
                {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
              </select>
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">Plan</label>
              <select
                value={admin.plan}
                onChange={(e) => setAdmin((p) => ({ ...p, plan: e.target.value as NamespacePlan }))}
                className={selectCls}
                disabled={isSaving}
              >
                {PLANS.map((p) => <option key={p} value={p}>{p}</option>)}
              </select>
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">Max Users</label>
              <input
                type="number" min={0}
                value={admin.max_users}
                onChange={(e) => setAdmin((p) => ({ ...p, max_users: Number(e.target.value) }))}
                className={numberCls}
                disabled={isSaving}
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">Max Stores</label>
              <input
                type="number" min={0}
                value={admin.max_stores}
                onChange={(e) => setAdmin((p) => ({ ...p, max_stores: Number(e.target.value) }))}
                className={numberCls}
                disabled={isSaving}
              />
            </div>
          </div>
        </Card>

        {/* Sticky action bar */}
        <div className="sticky bottom-0 -mx-4 sm:-mx-6 px-4 sm:px-6 py-3 bg-surface/90 backdrop-blur border-t border-secondary-200 z-20 flex items-center justify-between gap-3 rounded-b-lg">
          <p className="text-sm text-secondary-500">
            {dirty ? 'You have unsaved changes.' : 'All changes saved.'}
          </p>
          <div className="flex items-center gap-3">
            <Button type="button" variant="secondary" onClick={reset} disabled={!dirty || isSaving}>
              Reset
            </Button>
            <Button type="submit" disabled={!dirty || isSaving}>
              {isSaving ? (
                <><Loader2 className="w-4 h-4 mr-2 animate-spin" /> Saving…</>
              ) : (
                <><Save className="w-4 h-4 mr-2" /> Save Changes</>
              )}
            </Button>
          </div>
        </div>
      </form>
    </div>
  );
}
