'use client';

/** Upgrade paths of an app: which plan can move to which, and at what price. */

import React, { useCallback, useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { ArrowRight, Plus, Trash2 } from 'lucide-react';
import { Button, ConfirmDialog, Input, Modal, Select, Switch, Table } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, Pill } from '@/components/field-service/shared';
import { billingService, formatMinor, type BillingApp, type BillingPlan, type UpgradePath } from '@/services/billing.service';
import type { TableColumn } from '@/types';

const PRICING_LABELS = {
  difference: 'Pays the price difference',
  fixed: 'Pays a fixed price',
  free: 'Free',
} as const;

function NewPathModal({
  app,
  plans,
  isOpen,
  onClose,
  onSaved,
}: {
  app: BillingApp;
  plans: BillingPlan[];
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [pricing, setPricing] = useState<'difference' | 'fixed' | 'free'>('difference');
  const [price, setPrice] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (isOpen) {
      setFrom('');
      setTo('');
      setPricing('difference');
      setPrice('');
    }
  }, [isOpen]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      await billingService.createUpgrade(app.uuid, {
        from_plan: from,
        to_plan: to,
        pricing,
        ...(pricing === 'fixed' ? { amount: Math.round(Number(price) * 100) } : {}),
      });
      toast.success('Upgrade path added');
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Could not add the upgrade path'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Add an upgrade path" description="Customers on one plan can move to another at any time.">
      <form onSubmit={submit} className="space-y-4">
        <Select label="From plan" value={from} onChange={(e) => setFrom(e.target.value)} required>
          <option value="">Choose…</option>
          {plans.map((p) => (
            <option key={p.uuid} value={p.uuid}>
              {p.name}
            </option>
          ))}
        </Select>
        <Select label="To plan" value={to} onChange={(e) => setTo(e.target.value)} required>
          <option value="">Choose…</option>
          {plans
            .filter((p) => p.uuid !== from)
            .map((p) => (
              <option key={p.uuid} value={p.uuid}>
                {p.name}
              </option>
            ))}
        </Select>
        <Select label="Price" value={pricing} onChange={(e) => setPricing(e.target.value as typeof pricing)}>
          {Object.entries(PRICING_LABELS).map(([v, l]) => (
            <option key={v} value={v}>
              {l}
            </option>
          ))}
        </Select>
        {pricing === 'fixed' && (
          <Input label="Upgrade price" type="number" min={0} step="0.01" value={price} onChange={(e) => setPrice(e.target.value)} required />
        )}
        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving} disabled={!from || !to}>
            Add path
          </Button>
        </div>
      </form>
    </Modal>
  );
}

export default function AppUpgrades({ app }: { app: BillingApp }) {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [paths, setPaths] = useState<UpgradePath[]>([]);
  const [plans, setPlans] = useState<BillingPlan[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<UpgradePath | null>(null);

  const load = useCallback(() => {
    Promise.all([billingService.listUpgrades(app.uuid), billingService.listPlans(app.uuid)])
      .then(([u, p]) => {
        setPaths(u);
        setPlans(p.filter((x) => x.active));
      })
      .catch((err) => toast.error(apiError(err, 'Failed to load upgrade paths')))
      .finally(() => setLoading(false));
  }, [app.uuid]);

  useEffect(() => {
    load();
  }, [load]);

  const toggle = async (p: UpgradePath) => {
    try {
      await billingService.updateUpgrade(app.uuid, p.uuid, { active: !p.active });
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not update'));
    }
  };

  const remove = async () => {
    if (!deleteTarget) return;
    try {
      await billingService.deleteUpgrade(app.uuid, deleteTarget.uuid);
      toast.success('Upgrade path removed');
      setDeleteTarget(null);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not remove'));
    }
  };

  const columns: TableColumn<UpgradePath>[] = [
    {
      key: 'path',
      header: 'Upgrade',
      render: (p) => (
        <span className="inline-flex items-center gap-2 font-medium text-secondary-900">
          {p.from_plan_name} <ArrowRight className="w-4 h-4 text-secondary-400" aria-hidden /> {p.to_plan_name}
        </span>
      ),
    },
    {
      key: 'pricing',
      header: 'Price',
      render: (p) =>
        p.pricing === 'fixed' && p.amount != null ? formatMinor(p.amount, p.currency || 'gbp') : PRICING_LABELS[p.pricing],
    },
    {
      key: 'active',
      header: 'Active',
      render: (p) =>
        canUpdate('billing') ? (
          <Switch checked={p.active} onChange={() => toggle(p)} aria-label={`Upgrade ${p.from_plan_name} to ${p.to_plan_name} active`} />
        ) : (
          <Pill className={p.active ? 'bg-green-50 text-green-700' : 'bg-secondary-100 text-secondary-500'}>{p.active ? 'Active' : 'Off'}</Pill>
        ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-16',
      render: (p) =>
        canDelete('billing') ? (
          <button
            type="button"
            onClick={() => setDeleteTarget(p)}
            className="p-2 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
            aria-label="Remove upgrade path"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        ) : null,
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-secondary-500">
          Customers can upgrade at any time along these paths. Subscriptions are prorated; one-time and fixed-term buyers
          pay the price shown. Every change is kept in the plan history.
        </p>
        {canCreate('billing') && (
          <Button onClick={() => setOpen(true)} disabled={plans.length < 2}>
            <Plus className="w-4 h-4 mr-1.5" /> Add path
          </Button>
        )}
      </div>
      <Table columns={columns} data={paths} keyExtractor={(p) => p.uuid} isLoading={loading} emptyMessage="No upgrade paths yet." />
      <NewPathModal
        app={app}
        plans={plans}
        isOpen={open}
        onClose={() => setOpen(false)}
        onSaved={() => {
          setOpen(false);
          load();
        }}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Remove this upgrade path?"
        message="Customers can no longer upgrade this way. Past upgrades stay in the history."
        confirmText="Remove"
        variant="danger"
      />
    </div>
  );
}
