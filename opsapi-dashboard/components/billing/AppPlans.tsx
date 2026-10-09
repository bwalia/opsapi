'use client';

import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Pencil, Plus, Star, Trash2 } from 'lucide-react';
import { Button, ConfirmDialog, Input, Modal, Select, Switch, Table } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, Pill } from '@/components/field-service/shared';
import { FeatureValuesEditor } from '@/components/billing/shared';
import {
  billingService,
  describePrice,
  describeValue,
  PURCHASE_TYPE_LABELS,
  type PurchaseType,
  type BillingApp,
  type BillingFeature,
  type BillingPlan,
  type FeatureMap,
} from '@/services/billing.service';
import type { TableColumn } from '@/types';

type Interval = 'day' | 'week' | 'month' | 'year';

function PlanModal({
  app,
  features,
  plan,
  isOpen,
  onClose,
  onSaved,
}: {
  app: BillingApp;
  features: BillingFeature[];
  plan: BillingPlan | null;
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [name, setName] = useState('');
  const [planKey, setPlanKey] = useState('');
  const [price, setPrice] = useState('0');
  const [currency, setCurrency] = useState('gbp');
  const [interval, setBillingInterval] = useState<Interval>('month');
  const [trialDays, setTrialDays] = useState('0');
  const [ptype, setPtype] = useState<PurchaseType>('recurring');
  const [termDays, setTermDays] = useState('30');
  const [termCovers, setTermCovers] = useState<'access' | 'updates'>('access');
  const [updatesDays, setUpdatesDays] = useState('');
  const [appStoreId, setAppStoreId] = useState('');
  const [playStoreId, setPlayStoreId] = useState('');
  const [values, setValues] = useState<FeatureMap>({});
  const [isDefault, setIsDefault] = useState(false);
  const [isPublic, setIsPublic] = useState(true);
  const [active, setActive] = useState(true);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setName(plan?.name || '');
    setPlanKey(plan?.plan_key || '');
    setPrice(plan ? String(plan.amount / 100) : '0');
    setCurrency(plan?.currency || 'gbp');
    setBillingInterval((plan?.billing_interval as Interval) || 'month');
    setTrialDays(String(plan?.trial_days ?? 0));
    setPtype(plan?.purchase_type || 'recurring');
    setTermDays(String(plan?.term_days ?? 30));
    setTermCovers(plan?.term_covers || 'access');
    setUpdatesDays(plan?.updates_days ? String(plan.updates_days) : '');
    setAppStoreId(plan?.store_products?.app_store || '');
    setPlayStoreId(plan?.store_products?.play_store || '');
    // Every feature gets a value on a plan (off / 0 unless set).
    const v: FeatureMap = {};
    for (const f of features) v[f.key] = plan && f.key in plan.features ? plan.features[f.key] : f.type === 'boolean' ? false : 0;
    setValues(v);
    setIsDefault(plan?.is_default ?? false);
    setIsPublic(plan?.is_public ?? true);
    setActive(plan?.active ?? true);
  }, [isOpen, plan, features]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const amount = Math.round(Number(price) * 100);
    if (!Number.isFinite(amount) || amount < 0) {
      toast.error('Enter a price of 0 or more');
      return;
    }
    setSaving(true);
    try {
      const body = {
        name: name.trim(),
        plan_key: planKey.trim() || undefined,
        amount,
        currency,
        purchase_type: ptype,
        ...(ptype === 'recurring'
          ? { billing_interval: interval, trial_days: Math.max(0, Math.floor(Number(trialDays) || 0)) }
          : {}),
        ...(ptype === 'fixed_term' ? { term_days: Math.max(1, Math.floor(Number(termDays) || 1)), term_covers: termCovers } : {}),
        ...(ptype === 'one_time' ? { updates_days: updatesDays.trim() ? Math.max(1, Math.floor(Number(updatesDays))) : null } : {}),
        store_products: Object.fromEntries(
          Object.entries({ app_store: appStoreId.trim(), play_store: playStoreId.trim() }).filter(([, v]) => v)
        ),
        features: values,
        is_default: isDefault,
        is_public: isPublic,
        active,
      };
      if (plan) await billingService.updatePlan(plan.uuid, body);
      else await billingService.createPlan({ ...body, app: app.uuid });
      toast.success(plan ? 'Plan updated' : 'Plan created');
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Could not save the plan'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={plan ? `Edit ${plan.name}` : 'New plan'} size="xl">
      <form onSubmit={submit} className="space-y-5">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Pro" required autoFocus />
          <Input
            label="Plan key"
            value={planKey}
            onChange={(e) => setPlanKey(e.target.value)}
            placeholder="pro (from the name if blank)"
            pattern="[a-z0-9][a-z0-9_\-]{0,63}"
            className="font-mono"
          />
          <Select
            label="Sold as"
            value={ptype}
            onChange={(e) => setPtype(e.target.value as PurchaseType)}
            helperText={
              ptype === 'recurring'
                ? 'Renews every period until cancelled.'
                : ptype === 'one_time'
                  ? 'Paid once; access never ends.'
                  : 'Paid once for a number of days; buying again adds more.'
            }
          >
            {Object.entries(PURCHASE_TYPE_LABELS).map(([v, l]) => (
              <option key={v} value={v}>
                {l}
              </option>
            ))}
          </Select>
          <Input
            label="Price"
            type="number"
            min={0}
            step="0.01"
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            helperText="0 for a free plan"
            required
          />
          <div className="grid grid-cols-2 gap-3">
            <Select label="Currency" value={currency} onChange={(e) => setCurrency(e.target.value)}>
              {['gbp', 'usd', 'eur', 'inr', 'aud', 'cad'].map((c) => (
                <option key={c} value={c}>
                  {c.toUpperCase()}
                </option>
              ))}
            </Select>
            {ptype === 'recurring' && (
              <Select label="Billed every" value={interval} onChange={(e) => setBillingInterval(e.target.value as Interval)}>
                <option value="month">Month</option>
                <option value="year">Year</option>
                <option value="week">Week</option>
                <option value="day">Day</option>
              </Select>
            )}
          </div>
          {ptype === 'recurring' && (
            <Input label="Free trial (days)" type="number" min={0} value={trialDays} onChange={(e) => setTrialDays(e.target.value)} />
          )}
          {ptype === 'fixed_term' && (
            <div className="grid grid-cols-2 gap-3">
              <Input label="Term (days)" type="number" min={1} value={termDays} onChange={(e) => setTermDays(e.target.value)} required />
              <Select label="The term covers" value={termCovers} onChange={(e) => setTermCovers(e.target.value as 'access' | 'updates')}>
                <option value="access">Access</option>
                <option value="updates">Updates only</option>
              </Select>
            </div>
          )}
          {ptype === 'one_time' && (
            <Input
              label="Updates included (days)"
              type="number"
              min={1}
              value={updatesDays}
              onChange={(e) => setUpdatesDays(e.target.value)}
              helperText="Blank = every future version. Features released after this window aren't included."
            />
          )}
        </div>

        <div>
          <h3 className="text-sm font-semibold text-secondary-900 mb-2">What this plan includes</h3>
          <FeatureValuesEditor features={features} value={values} onChange={setValues} />
        </div>

        <details className="rounded-lg border border-secondary-200 px-3 py-2">
          <summary className="cursor-pointer text-sm font-medium text-secondary-800">App store product ids (optional)</summary>
          <div className="mt-3 grid grid-cols-1 sm:grid-cols-2 gap-3">
            <Input label="App Store product id" value={appStoreId} onChange={(e) => setAppStoreId(e.target.value)} placeholder="com.example.pro" />
            <Input label="Google Play product id" value={playStoreId} onChange={(e) => setPlayStoreId(e.target.value)} placeholder="pro_yearly" />
          </div>
          <p className="mt-2 text-xs text-secondary-500">Store purchases your server records with these ids resolve to this plan.</p>
        </details>

        <div className="grid gap-3 sm:grid-cols-3">
          {[
            { label: 'Default plan', hint: 'Every customer gets it for free', checked: isDefault, set: setIsDefault },
            { label: 'Public', hint: 'Shown on the pricing endpoint', checked: isPublic, set: setIsPublic },
            { label: 'Active', hint: 'Can be chosen', checked: active, set: setActive },
          ].map((t) => (
            <div key={t.label} className="flex items-center justify-between gap-2 rounded-lg border border-secondary-200 px-3 py-2">
              <div>
                <p className="text-sm font-medium text-secondary-800">{t.label}</p>
                <p className="text-xs text-secondary-500">{t.hint}</p>
              </div>
              <Switch checked={t.checked} onChange={t.set} aria-label={t.label} />
            </div>
          ))}
        </div>

        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving} disabled={!name.trim()}>
            {plan ? 'Save plan' : 'Create plan'}
          </Button>
        </div>
      </form>
    </Modal>
  );
}

export default function AppPlans({ app, features }: { app: BillingApp; features: BillingFeature[] }) {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [plans, setPlans] = useState<BillingPlan[]>([]);
  const [loading, setLoading] = useState(true);
  const [modalOpen, setModalOpen] = useState(false);
  const [editing, setEditing] = useState<BillingPlan | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<BillingPlan | null>(null);
  const [deleting, setDeleting] = useState(false);

  const load = React.useCallback(async () => {
    setLoading(true);
    try {
      setPlans(await billingService.listPlans(app.uuid));
    } catch (err) {
      toast.error(apiError(err, 'Failed to load plans'));
    } finally {
      setLoading(false);
    }
  }, [app.uuid]);

  useEffect(() => {
    load();
  }, [load]);

  const remove = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await billingService.deletePlan(deleteTarget.uuid);
      toast.success('Plan deleted');
      setDeleteTarget(null);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete the plan'));
    } finally {
      setDeleting(false);
    }
  };

  const columns: TableColumn<BillingPlan>[] = [
    {
      key: 'name',
      header: 'Plan',
      render: (p) => (
        <div>
          <p className="font-medium text-secondary-900 flex items-center gap-1.5">
            {p.name}
            {p.is_default && <Star className="w-3.5 h-3.5 text-amber-500 fill-amber-400" aria-label="Default plan" />}
          </p>
          <code className="text-xs text-secondary-500">{p.plan_key}</code>
        </div>
      ),
    },
    {
      key: 'price',
      header: 'Price',
      render: (p) => (
        <span className="tabular-nums">
          {describePrice(p)}
          <span className="block text-xs text-secondary-500">
            {PURCHASE_TYPE_LABELS[p.purchase_type] ?? p.purchase_type}
            {p.purchase_type === 'one_time' && p.updates_days ? ` · ${p.updates_days} days of updates` : ''}
            {p.purchase_type === 'recurring' && p.trial_days > 0 ? ` · ${p.trial_days}-day trial` : ''}
          </span>
        </span>
      ),
    },
    {
      key: 'features',
      header: 'Includes',
      render: (p) => (
        <ul className="text-xs text-secondary-600 space-y-0.5">
          {features.map((f) => (
            <li key={f.key}>
              <span className="text-secondary-500">{f.name}:</span> {describeValue(f, p.features[f.key])}
            </li>
          ))}
        </ul>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (p) => (
        <div className="flex flex-wrap gap-1">
          {!p.active && <Pill className="bg-secondary-100 text-secondary-500">Inactive</Pill>}
          {p.active && p.is_public && <Pill className="bg-green-50 text-green-700">Public</Pill>}
          {p.active && !p.is_public && <Pill className="bg-secondary-100 text-secondary-700">Hidden</Pill>}
        </div>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-24',
      render: (p) => (
        <div className="flex items-center gap-1">
          {canUpdate('billing') && (
            <button
              type="button"
              onClick={() => {
                setEditing(p);
                setModalOpen(true);
              }}
              className="p-2 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
              aria-label={`Edit ${p.name}`}
            >
              <Pencil className="w-4 h-4" />
            </button>
          )}
          {canDelete('billing') && (
            <button
              type="button"
              onClick={() => setDeleteTarget(p)}
              className="p-2 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
              aria-label={`Delete ${p.name}`}
            >
              <Trash2 className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-secondary-500">
          Flat tiers. The <Star className="inline w-3.5 h-3.5 text-amber-500 fill-amber-400" aria-hidden /> default plan is what
          every customer has without paying.
        </p>
        {canCreate('billing') && (
          <Button
            onClick={() => {
              setEditing(null);
              setModalOpen(true);
            }}
          >
            <Plus className="w-4 h-4 mr-1.5" /> New plan
          </Button>
        )}
      </div>
      <Table columns={columns} data={plans} keyExtractor={(p) => p.uuid} isLoading={loading} emptyMessage="No plans yet." />
      <PlanModal
        app={app}
        features={features}
        plan={editing}
        isOpen={modalOpen}
        onClose={() => setModalOpen(false)}
        onSaved={() => {
          setModalOpen(false);
          load();
        }}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title={`Delete ${deleteTarget?.name || 'plan'}?`}
        message="It can no longer be chosen. Customers already on it keep its features."
        confirmText="Delete plan"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}
