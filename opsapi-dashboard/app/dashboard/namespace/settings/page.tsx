'use client';

import React, { useState, useEffect, useMemo } from 'react';
import {
  Settings,
  Building2,
  Save,
  Loader2,
  AlertTriangle,
  FileText,
  Key,
} from 'lucide-react';
import { Button, Card, Badge } from '@/components/ui';
import { PageHeader } from '@/components/layout/PageHeader';
import NamespaceFormFields, { type NamespaceFieldValues } from '@/components/namespace/NamespaceFormFields';
import { useNamespace } from '@/contexts/NamespaceContext';
import { namespaceService } from '@/services';
import toast from 'react-hot-toast';
import Link from 'next/link';

const EMPTY: NamespaceFieldValues = { name: '', description: '', domain: '', logo_url: '', banner_url: '' };

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
      if (!values.name.trim()) toast.error('Namespace name is required');
      return;
    }
    setIsSaving(true);
    try {
      await namespaceService.updateCurrentNamespace(values);
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
      <div className="space-y-6">
        <h1 className="text-2xl font-bold text-secondary-900">Namespace Settings</h1>
        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-warning-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">Access Restricted</h2>
          <p className="text-secondary-500">Only namespace owners can change these settings.</p>
        </Card>
      </div>
    );
  }

  if (!currentNamespace) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold text-secondary-900">Namespace Settings</h1>
        <Card className="p-8 text-center">
          <Building2 className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
          <p className="text-secondary-500">No namespace selected.</p>
        </Card>
      </div>
    );
  }

  return (
    <div className="max-w-4xl">
      <PageHeader
        title="Namespace Settings"
        description={`Configure ${currentNamespace.name}`}
        icon={<Settings className="h-5 w-5" />}
        actions={
          <Link
            href={`/dashboard/namespace/api-keys`}
            className="inline-flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            <Key className="w-4 h-4" />
            API Keys
          </Link>
        }
      />

      <form onSubmit={handleSubmit} className="mt-6 space-y-6">
        <NamespaceFormFields values={values} onChange={set} slug={currentNamespace.slug} disabled={isSaving} />

        {/* Plan & limits (read-only) */}
        <Card className="p-6">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-10 h-10 rounded-lg bg-secondary-100 flex items-center justify-center">
              <FileText className="w-5 h-5 text-secondary-600" />
            </div>
            <div>
              <h2 className="text-base font-semibold text-secondary-900">Plan &amp; Limits</h2>
              <p className="text-sm text-secondary-500">Managed by your platform administrator</p>
            </div>
          </div>

          <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
            <div className="p-4 bg-secondary-50 rounded-lg">
              <p className="text-xs text-secondary-500">Current Plan</p>
              <Badge variant="default" className="mt-1 capitalize">{currentNamespace.plan}</Badge>
            </div>
            <div className="p-4 bg-secondary-50 rounded-lg">
              <p className="text-xs text-secondary-500">Status</p>
              <Badge
                variant={currentNamespace.status === 'active' ? 'success' : 'warning'}
                className="mt-1 capitalize"
              >
                {currentNamespace.status}
              </Badge>
            </div>
            <div className="p-4 bg-secondary-50 rounded-lg">
              <p className="text-xs text-secondary-500">Max Users</p>
              <p className="text-lg font-semibold text-secondary-900 mt-1">{currentNamespace.max_users}</p>
            </div>
            <div className="p-4 bg-secondary-50 rounded-lg">
              <p className="text-xs text-secondary-500">Max Stores</p>
              <p className="text-lg font-semibold text-secondary-900 mt-1">{currentNamespace.max_stores}</p>
            </div>
          </div>
        </Card>

        {/* Sticky action bar — sticks to the viewport bottom, stays within the
            content column (no sidebar-width math needed). */}
        <div className="sticky bottom-0 -mx-4 sm:-mx-6 px-4 sm:px-6 py-3 bg-surface/90 backdrop-blur border-t border-secondary-200 z-20 flex items-center justify-between gap-3 rounded-b-lg">
          <p className="text-sm text-secondary-500">
            {dirty ? 'You have unsaved changes.' : 'All changes saved.'}
          </p>
          <div className="flex items-center gap-3">
            <Button
              type="button"
              variant="secondary"
              onClick={() => setValues(initial)}
              disabled={!dirty || isSaving}
            >
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
