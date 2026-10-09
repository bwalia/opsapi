'use client';

import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Button, Input, Modal, Select, Textarea } from '@/components/ui';
import { apiError } from '@/components/field-service/shared';
import { CustomerPicker, FeatureValuesEditor } from '@/components/billing/shared';
import {
  billingService,
  type BillingApp,
  type BillingFeature,
  type BillingPlan,
  type FeatureMap,
} from '@/services/billing.service';

/** Give a customer access without payment: a whole plan and/or feature values, optionally until a date. */
export default function GrantModal({
  isOpen,
  onClose,
  onSaved,
  customer: fixedCustomer,
  app: fixedApp,
}: {
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
  customer?: string;
  app?: string;
}) {
  const [apps, setApps] = useState<BillingApp[]>([]);
  const [app, setApp] = useState('');
  const [customer, setCustomer] = useState('');
  const [plans, setPlans] = useState<BillingPlan[]>([]);
  const [features, setFeatures] = useState<BillingFeature[]>([]);
  const [plan, setPlan] = useState('');
  const [values, setValues] = useState<FeatureMap>({});
  const [reason, setReason] = useState('');
  const [expires, setExpires] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setApp(fixedApp || '');
    setCustomer(fixedCustomer || '');
    setPlan('');
    setValues({});
    setReason('');
    setExpires('');
    billingService
      .listApps()
      .then((list) => {
        setApps(list);
        if (!fixedApp && list.length === 1) setApp(list[0].uuid);
      })
      .catch(() => setApps([]));
  }, [isOpen, fixedApp, fixedCustomer]);

  useEffect(() => {
    if (!app) {
      setPlans([]);
      setFeatures([]);
      return;
    }
    billingService.listPlans(app).then((p) => setPlans(p.filter((x) => x.active))).catch(() => setPlans([]));
    billingService.getApp(app).then((a) => setFeatures(a.features || [])).catch(() => setFeatures([]));
  }, [app]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!plan && Object.keys(values).length === 0) {
      toast.error('Choose a plan or set at least one feature');
      return;
    }
    setSaving(true);
    try {
      await billingService.createGrant({
        app,
        customer,
        plan: plan || undefined,
        features: values,
        reason: reason.trim() || undefined,
        // End of the chosen day, in the viewer's time zone.
        expires_at: expires ? new Date(`${expires}T23:59:59`).toISOString() : undefined,
      });
      toast.success('Access granted');
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Could not grant access'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Grant access"
      description="Comp a plan, extend a trial or unlock a feature, without payment."
      size="lg"
    >
      <form onSubmit={submit} className="space-y-4">
        {!fixedApp && (
          <Select label="App" value={app} onChange={(e) => setApp(e.target.value)} required>
            <option value="">Choose an app…</option>
            {apps.map((a) => (
              <option key={a.uuid} value={a.uuid}>
                {a.name}
              </option>
            ))}
          </Select>
        )}
        {!fixedCustomer && <CustomerPicker value={customer} onChange={setCustomer} />}
        <Select label="Plan" value={plan} onChange={(e) => setPlan(e.target.value)} disabled={!app}>
          <option value="">No plan, just the features below</option>
          {plans.map((p) => (
            <option key={p.uuid} value={p.uuid}>
              {p.name}
            </option>
          ))}
        </Select>
        {app && (
          <div>
            <h3 className="text-sm font-semibold text-secondary-900 mb-1">Extra features (optional)</h3>
            <p className="text-xs text-secondary-500 mb-2">Added on top of the customer&apos;s plan; the larger value wins.</p>
            <FeatureValuesEditor features={features} value={values} onChange={setValues} optional />
          </div>
        )}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input
            label="Ends on (optional)"
            type="date"
            value={expires}
            min={new Date().toISOString().slice(0, 10)}
            onChange={(e) => setExpires(e.target.value)}
            helperText="Blank = until revoked"
          />
        </div>
        <Textarea label="Reason (optional)" value={reason} onChange={(e) => setReason(e.target.value)} rows={2} maxLength={500} />
        <div className="flex justify-end gap-2 pt-1">
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving} disabled={!app || !customer}>
            Grant access
          </Button>
        </div>
      </form>
    </Modal>
  );
}
