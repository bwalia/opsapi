'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { RefreshCw, Trash2 } from 'lucide-react';
import { Button, Card, ConfirmDialog, Input, Select, Switch, Textarea } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError } from '@/components/field-service/shared';
import { CopyButton, KIND_LABELS } from '@/components/billing/shared';
import {
  billingService,
  formatMinor,
  type AppKind,
  type AppReport,
  type BillingApp,
  type OfflinePolicy,
} from '@/services/billing.service';

function Stat({ label, value, hint }: { label: string; value: React.ReactNode; hint?: string }) {
  return (
    <Card padding="sm" className="shadow-sm">
      <p className="text-xs font-medium text-secondary-500">{label}</p>
      <p className="mt-1 text-xl font-semibold text-secondary-900 tabular-nums">{value}</p>
      {hint && <p className="text-xs text-secondary-400">{hint}</p>}
    </Card>
  );
}

export default function AppOverview({
  app,
  onChange,
  onDeleted,
}: {
  app: BillingApp;
  onChange: (a: BillingApp) => void;
  onDeleted: () => void;
}) {
  const { canUpdate, canDelete } = usePermissions();
  const editable = canUpdate('billing');
  const [report, setReport] = useState<AppReport | null>(null);
  const [form, setForm] = useState(() => toForm(app));
  const [saving, setSaving] = useState(false);
  const [rotateOpen, setRotateOpen] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => setForm(toForm(app)), [app]);
  useEffect(() => {
    billingService.report(app.uuid).then(setReport).catch(() => setReport(null));
  }, [app.uuid]);

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      const updated = await billingService.updateApp(app.uuid, {
        name: form.name.trim(),
        kind: form.kind,
        mode: form.mode,
        offline_policy: form.offline_policy,
        offline_grace_seconds: Math.round(Number(form.grace_hours) * 3600),
        entitlement_ttl_seconds: Math.round(Number(form.ttl_minutes) * 60),
        past_due_grace_days: Math.round(Number(form.past_due_days)),
        allowed_return_urls: form.return_urls.split('\n').map((u) => u.trim()).filter(Boolean),
        active: form.active,
      });
      if (updated.publishable_key !== app.publishable_key) {
        toast('Mode changed: the app has a new publishable key', { icon: '🔑' });
      }
      onChange(updated);
      toast.success('Saved');
    } catch (err) {
      toast.error(apiError(err, 'Could not save'));
    } finally {
      setSaving(false);
    }
  };

  const rotate = async () => {
    setBusy(true);
    try {
      onChange(await billingService.rotateKey(app.uuid));
      toast.success('New publishable key issued');
      setRotateOpen(false);
    } catch (err) {
      toast.error(apiError(err, 'Could not rotate the key'));
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    setBusy(true);
    try {
      await billingService.deleteApp(app.uuid);
      toast.success('App deleted');
      onDeleted();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete the app'));
      setBusy(false);
    }
  };

  const set = <K extends keyof ReturnType<typeof toForm>>(k: K, v: ReturnType<typeof toForm>[K]) =>
    setForm((f) => ({ ...f, [k]: v }));

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
        <Stat label="Active subscriptions" value={report?.active ?? '—'} hint={report ? `${report.trialing} trialing` : undefined} />
        <Stat
          label="Monthly recurring revenue"
          value={report && report.mrr.length > 0 ? report.mrr.map((m) => formatMinor(m.amount, m.currency)).join(' + ') : '—'}
        />
        <Stat label="Past due" value={report?.past_due ?? '—'} hint={report ? `${report.churned_30d} cancelled in 30 days` : undefined} />
        <Stat
          label="Access without payment"
          value={report?.active_grants ?? '—'}
          hint={report ? `${report.active_licenses} licences · ${report.active_activations} devices` : undefined}
        />
      </div>

      <Card className="shadow-sm">
        <h2 className="text-base font-semibold text-secondary-900">Keys</h2>
        <p className="mt-1 text-sm text-secondary-500">
          The publishable key only identifies this app on public endpoints (pricing page, licence activation). It is
          safe in browsers and desktop builds. Your server calls the entitlement API with a{' '}
          <Link href="/dashboard/namespace/api-keys" className="text-primary-600 hover:underline">
            workspace API key
          </Link>{' '}
          scoped to <span className="font-mono">entitlements</span>; never ship that one to clients.
        </p>
        <dl className="mt-4 grid gap-3 sm:grid-cols-2 [&>div]:min-w-0">
          <div>
            <dt className="text-xs font-medium text-secondary-500">Publishable key ({app.mode})</dt>
            <dd className="mt-1 flex flex-wrap items-center gap-1 min-w-0">
              <code className="min-w-0 max-w-full truncate rounded bg-secondary-100 px-2 py-1 text-xs">{app.publishable_key}</code>
              <CopyButton value={app.publishable_key} label="Copy publishable key" />
              {editable && (
                <button
                  type="button"
                  onClick={() => setRotateOpen(true)}
                  className="inline-flex items-center justify-center p-2 rounded-lg text-secondary-500 hover:text-primary-600 hover:bg-primary-50"
                  aria-label="Issue a new publishable key"
                  title="Issue a new publishable key"
                >
                  <RefreshCw className="w-4 h-4" />
                </button>
              )}
            </dd>
          </div>
          <div>
            <dt className="text-xs font-medium text-secondary-500">App id (use the id or the slug in API calls)</dt>
            <dd className="mt-1 flex flex-wrap items-center gap-1 min-w-0">
              <code className="min-w-0 max-w-full truncate rounded bg-secondary-100 px-2 py-1 text-xs">{app.uuid}</code>
              <CopyButton value={app.uuid} label="Copy app id" />
              <code className="rounded bg-secondary-100 px-2 py-1 text-xs">{app.slug}</code>
            </dd>
          </div>
        </dl>
      </Card>

      <form onSubmit={save}>
        <Card className="shadow-sm">
          <h2 className="text-base font-semibold text-secondary-900 mb-4">Settings</h2>
          <fieldset disabled={!editable} className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Input label="Name" value={form.name} onChange={(e) => set('name', e.target.value)} required maxLength={120} />
            <Select label="Kind" value={form.kind} onChange={(e) => set('kind', e.target.value as AppKind)}>
              {Object.entries(KIND_LABELS).map(([v, l]) => (
                <option key={v} value={v}>
                  {l}
                </option>
              ))}
            </Select>
            <Select
              label="Mode"
              value={form.mode}
              onChange={(e) => set('mode', e.target.value as 'test' | 'live')}
              helperText="Switching mode issues a new publishable key."
            >
              <option value="test">Test</option>
              <option value="live">Live</option>
            </Select>
            <Select
              label="If OpsAPI can't be reached"
              value={form.offline_policy}
              onChange={(e) => set('offline_policy', e.target.value as OfflinePolicy)}
            >
              <option value="fail_closed">Block access (fail closed)</option>
              <option value="fail_open">Keep last known access (fail open)</option>
            </Select>
            <Input
              label="Offline grace (hours)"
              type="number"
              min={0}
              max={8760}
              value={form.grace_hours}
              onChange={(e) => set('grace_hours', e.target.value)}
              helperText="How long a fail-open app, or a licence file, works without checking in."
            />
            <Input
              label="Entitlement token lifetime (minutes)"
              type="number"
              min={1}
              max={1440}
              value={form.ttl_minutes}
              onChange={(e) => set('ttl_minutes', e.target.value)}
              helperText="Apps re-check access this often."
            />
            <Input
              label="Past-due grace (days)"
              type="number"
              min={0}
              max={90}
              value={form.past_due_days}
              onChange={(e) => set('past_due_days', e.target.value)}
              helperText="A failed renewal keeps access this long while the payment is retried."
            />
            <div className="flex items-center justify-between rounded-lg border border-secondary-200 px-3 py-2">
              <div>
                <p className="text-sm font-medium text-secondary-800">Active</p>
                <p className="text-xs text-secondary-500">An inactive app&apos;s keys stop working.</p>
              </div>
              <Switch checked={form.active} onChange={(v) => set('active', v)} aria-label="App active" />
            </div>
            <div className="sm:col-span-2">
              <Textarea
                label="Allowed checkout return URLs (one per line)"
                value={form.return_urls}
                onChange={(e) => set('return_urls', e.target.value)}
                rows={3}
                placeholder="https://app.example.com/billing/done"
              />
            </div>
          </fieldset>
          {editable && (
            <div className="mt-5 flex flex-wrap justify-between gap-2">
              {canDelete('billing') ? (
                <Button type="button" variant="ghost" className="text-error-600" onClick={() => setDeleteOpen(true)}>
                  <Trash2 className="w-4 h-4 mr-1.5" /> Delete app
                </Button>
              ) : (
                <span />
              )}
              <Button type="submit" isLoading={saving}>
                Save settings
              </Button>
            </div>
          )}
        </Card>
      </form>

      <ConfirmDialog
        isOpen={rotateOpen}
        onClose={() => setRotateOpen(false)}
        onConfirm={rotate}
        title="Issue a new publishable key?"
        message="The current key stops working at once. Update your pricing page and app builds with the new key."
        confirmText="Issue new key"
        variant="warning"
        isLoading={busy}
      />
      <ConfirmDialog
        isOpen={deleteOpen}
        onClose={() => setDeleteOpen(false)}
        onConfirm={remove}
        title={`Delete ${app.name}?`}
        message="Its keys stop working at once. Plans, subscriptions and licences are kept for your records."
        confirmText="Delete app"
        variant="danger"
        isLoading={busy}
      />
    </div>
  );
}

function toForm(a: BillingApp) {
  return {
    name: a.name,
    kind: a.kind,
    mode: a.mode,
    offline_policy: a.offline_policy,
    grace_hours: String(Math.round((a.offline_grace_seconds / 3600) * 100) / 100),
    ttl_minutes: String(Math.round((a.entitlement_ttl_seconds / 60) * 100) / 100),
    past_due_days: String(a.past_due_grace_days),
    return_urls: (Array.isArray(a.allowed_return_urls) ? a.allowed_return_urls : []).join('\n'),
    active: a.active,
  };
}
