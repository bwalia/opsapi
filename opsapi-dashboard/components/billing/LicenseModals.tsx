'use client';

import React, { useCallback, useEffect, useRef, useState } from 'react';
import toast from 'react-hot-toast';
import { AlertTriangle, Laptop } from 'lucide-react';
import { Button, ConfirmDialog, Input, Modal, Select } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError } from '@/components/field-service/shared';
import { CopyButton, CustomerPicker, StatusPill } from '@/components/billing/shared';
import { formatDate, formatRelativeTime } from '@/lib/utils';
import { billingService, type BillingApp, type BillingPlan, type License } from '@/services/billing.service';

const endOfDay = (d: string) => new Date(`${d}T23:59:59`).toISOString();

/** Issue a licence key. The key is shown once, then only its first group. */
export function IssueLicenseModal({
  isOpen,
  onClose,
  onIssued,
  customer: fixedCustomer,
}: {
  isOpen: boolean;
  onClose: () => void;
  onIssued: () => void;
  customer?: string;
}) {
  const [apps, setApps] = useState<BillingApp[]>([]);
  const [plans, setPlans] = useState<BillingPlan[]>([]);
  const [app, setApp] = useState('');
  const [customer, setCustomer] = useState('');
  const [plan, setPlan] = useState('');
  const [seats, setSeats] = useState('1');
  const [expires, setExpires] = useState('');
  const [saving, setSaving] = useState(false);
  const [issuedKey, setIssuedKey] = useState<string | null>(null);

  useEffect(() => {
    if (!isOpen) return;
    setCustomer(fixedCustomer || '');
    setPlan('');
    setSeats('1');
    setExpires('');
    setIssuedKey(null);
    billingService
      .listApps()
      .then((list) => {
        const licensable = list.filter((a) => a.kind === 'desktop' || a.kind === 'self_hosted');
        const shown = licensable.length > 0 ? licensable : list;
        setApps(shown);
        setApp(shown.length === 1 ? shown[0].uuid : '');
      })
      .catch(() => setApps([]));
  }, [isOpen, fixedCustomer]);

  useEffect(() => {
    if (app) billingService.listPlans(app).then((p) => setPlans(p.filter((x) => x.active))).catch(() => setPlans([]));
    else setPlans([]);
  }, [app]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      const res = await billingService.createLicense({
        app,
        customer,
        plan: plan || undefined,
        max_activations: seats.trim() === '' ? null : Math.max(1, Math.floor(Number(seats))),
        expires_at: expires ? endOfDay(expires) : undefined,
      });
      setIssuedKey(res.key);
      onIssued();
    } catch (err) {
      toast.error(apiError(err, 'Could not issue the licence'));
    } finally {
      setSaving(false);
    }
  };

  if (issuedKey) {
    return (
      <Modal isOpen={isOpen} onClose={onClose} title="Licence issued">
        <div className="space-y-4">
          <div className="flex items-start gap-2 rounded-lg bg-amber-50 p-3 text-sm text-amber-800">
            <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" aria-hidden />
            <p>Copy the key now and send it to the customer. It won&apos;t be shown again.</p>
          </div>
          <div className="flex items-center gap-2 rounded-lg border border-secondary-200 bg-secondary-50 px-3 py-3">
            <code className="flex-1 break-all text-base tracking-wider text-secondary-900">{issuedKey}</code>
            <CopyButton value={issuedKey} label="Copy licence key" />
          </div>
          <div className="flex justify-end">
            <Button onClick={onClose}>Done</Button>
          </div>
        </div>
      </Modal>
    );
  }

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Issue a licence" description="A key for desktop or self-hosted software.">
      <form onSubmit={submit} className="space-y-4">
        <Select label="App" value={app} onChange={(e) => setApp(e.target.value)} required>
          <option value="">Choose an app…</option>
          {apps.map((a) => (
            <option key={a.uuid} value={a.uuid}>
              {a.name}
            </option>
          ))}
        </Select>
        {!fixedCustomer && <CustomerPicker value={customer} onChange={setCustomer} />}
        <Select
          label="Plan"
          value={plan}
          onChange={(e) => setPlan(e.target.value)}
          disabled={!app}
          helperText="Without a plan the licence follows the customer's own plan and grants."
        >
          <option value="">The customer&apos;s plan</option>
          {plans.map((p) => (
            <option key={p.uuid} value={p.uuid}>
              {p.name}
            </option>
          ))}
        </Select>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input
            label="Devices"
            type="number"
            min={1}
            value={seats}
            onChange={(e) => setSeats(e.target.value)}
            helperText="Blank = unlimited"
          />
          <Input
            label="Expires on (optional)"
            type="date"
            min={new Date().toISOString().slice(0, 10)}
            value={expires}
            onChange={(e) => setExpires(e.target.value)}
          />
        </div>
        <div className="flex justify-end gap-2 pt-1">
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving} disabled={!app || !customer}>
            Issue licence
          </Button>
        </div>
      </form>
    </Modal>
  );
}

/** A licence: status, devices (free a seat), suspend/resume, revoke. */
export function LicenseDetailModal({
  uuid,
  onClose,
  onChanged,
}: {
  uuid: string | null;
  onClose: () => void;
  onChanged: () => void;
}) {
  const { canUpdate, canDelete } = usePermissions();
  const [lic, setLic] = useState<License | null>(null);
  const [busy, setBusy] = useState(false);
  const [revokeOpen, setRevokeOpen] = useState(false);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;

  const load = useCallback(async () => {
    if (!uuid) return;
    try {
      setLic(await billingService.getLicense(uuid));
    } catch (err) {
      toast.error(apiError(err, 'Licence not found'));
      closeRef.current();
    }
  }, [uuid]);

  useEffect(() => {
    setLic(null);
    load();
  }, [load]);

  const act = async (fn: () => Promise<unknown>, done: string) => {
    setBusy(true);
    try {
      await fn();
      toast.success(done);
      await load();
      onChanged();
    } catch (err) {
      toast.error(apiError(err, 'Something went wrong'));
    } finally {
      setBusy(false);
    }
  };

  const live = (lic?.activations || []).filter((a) => !a.deactivated_at);

  return (
    <Modal isOpen={!!uuid} onClose={onClose} title={lic ? `Licence ${lic.key_prefix}-…` : 'Licence'} size="lg">
      {!lic ? (
        <div className="h-32 rounded-lg bg-secondary-100 animate-pulse" aria-busy="true" />
      ) : (
        <div className="space-y-5">
          <dl className="grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
            <div>
              <dt className="text-xs text-secondary-500">Status</dt>
              <dd className="mt-0.5">
                <StatusPill status={lic.status} />
              </dd>
            </div>
            <div>
              <dt className="text-xs text-secondary-500">Customer</dt>
              <dd className="mt-0.5 text-secondary-900 break-all">{lic.customer_email}</dd>
            </div>
            <div>
              <dt className="text-xs text-secondary-500">App / plan</dt>
              <dd className="mt-0.5 text-secondary-900">
                {lic.app_name} · {lic.plan_name || "customer's plan"}
              </dd>
            </div>
            <div>
              <dt className="text-xs text-secondary-500">Devices</dt>
              <dd className="mt-0.5 text-secondary-900">
                {lic.active_activations} of {lic.max_activations ?? 'unlimited'}
              </dd>
            </div>
            <div>
              <dt className="text-xs text-secondary-500">Expires</dt>
              <dd className="mt-0.5 text-secondary-900">{lic.expires_at ? formatDate(lic.expires_at) : 'Never'}</dd>
            </div>
            <div>
              <dt className="text-xs text-secondary-500">Issued</dt>
              <dd className="mt-0.5 text-secondary-900">{formatDate(lic.created_at)}</dd>
            </div>
          </dl>

          <div>
            <h3 className="text-sm font-semibold text-secondary-900 mb-2">Devices using it</h3>
            {live.length === 0 ? (
              <p className="text-sm text-secondary-500">Not activated on any device.</p>
            ) : (
              <ul className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
                {live.map((a) => (
                  <li key={a.uuid} className="flex items-center justify-between gap-3 px-3 py-2.5">
                    <div className="flex items-center gap-2.5 min-w-0">
                      <Laptop className="w-4 h-4 text-secondary-400 shrink-0" aria-hidden />
                      <div className="min-w-0">
                        <p className="text-sm text-secondary-900 truncate">{a.name || 'Unnamed device'}</p>
                        <p className="text-xs text-secondary-500">
                          {[a.platform, a.app_version && `v${a.app_version}`].filter(Boolean).join(' · ') || '—'} · seen{' '}
                          {formatRelativeTime(a.last_seen_at)}
                        </p>
                      </div>
                    </div>
                    {canDelete('licenses') && lic.status !== 'revoked' && (
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={busy}
                        onClick={() => act(() => billingService.removeActivation(lic.uuid, a.uuid), 'Seat freed')}
                      >
                        Free seat
                      </Button>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </div>

          {canUpdate('licenses') && lic.status !== 'revoked' && (
            <div className="flex flex-wrap justify-end gap-2 border-t border-secondary-100 pt-4">
              {lic.status === 'active' ? (
                <Button
                  variant="outline"
                  disabled={busy}
                  onClick={() => act(() => billingService.updateLicense(lic.uuid, { status: 'suspended' }), 'Licence suspended')}
                >
                  Suspend
                </Button>
              ) : (
                <Button
                  variant="outline"
                  disabled={busy}
                  onClick={() =>
                    act(
                      () =>
                        billingService.updateLicense(lic.uuid, {
                          status: 'active',
                          ...(lic.status === 'expired' ? { expires_at: null } : {}),
                        }),
                      'Licence resumed'
                    )
                  }
                >
                  {lic.status === 'expired' ? 'Resume (remove expiry)' : 'Resume'}
                </Button>
              )}
              <Button variant="danger" disabled={busy} onClick={() => setRevokeOpen(true)}>
                Revoke
              </Button>
            </div>
          )}
        </div>
      )}
      <ConfirmDialog
        isOpen={revokeOpen}
        onClose={() => setRevokeOpen(false)}
        onConfirm={() => {
          setRevokeOpen(false);
          if (lic) act(() => billingService.revokeLicense(lic.uuid), 'Licence revoked');
        }}
        title="Revoke this licence?"
        message="It stops working on every device at the next check-in. This can't be undone; issue a new key if needed."
        confirmText="Revoke"
        variant="danger"
        isLoading={busy}
      />
    </Modal>
  );
}
