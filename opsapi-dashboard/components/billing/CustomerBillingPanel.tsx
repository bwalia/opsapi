'use client';

/**
 * A customer's billing: what they can use in each app right now, their
 * subscriptions, grants and licences. Shown on /dashboard/customers/[uuid]
 * when the viewer may read subscriptions or licences (i.e. where the Billing
 * & Entitlements module is deployed).
 */

import React, { useCallback, useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { ArrowUpCircle, Gift, KeyRound, Receipt, Trash2 } from 'lucide-react';
import { Button, Card, ConfirmDialog } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError } from '@/components/field-service/shared';
import { StatusPill } from '@/components/billing/shared';
import GrantModal from '@/components/billing/GrantModal';
import { SaleModal, UpgradeModal } from '@/components/billing/SaleModals';
import { IssueLicenseModal, LicenseDetailModal } from '@/components/billing/LicenseModals';
import { formatDate } from '@/lib/utils';
import { formatMinor } from '@/services/billing.service';
import {
  billingService,
  type Entitlements,
  type FeatureValue,
  type Grant,
  type License,
  type Purchase,
  type Subscription,
} from '@/services/billing.service';

const show = (v: FeatureValue) => (v === true ? 'Included' : v === false ? 'Not included' : v === null ? 'Unlimited' : String(v));

export default function CustomerBillingPanel({ customerUuid }: { customerUuid: string }) {
  const { canRead, canCreate, canDelete } = usePermissions();
  const readSubs = canRead('subscriptions');
  const readLicenses = canRead('licenses');
  const [apps, setApps] = useState<{ uuid: string; name: string }[]>([]);
  const [ents, setEnts] = useState<Record<string, Entitlements>>({});
  const [subs, setSubs] = useState<Subscription[]>([]);
  const [grants, setGrants] = useState<Grant[]>([]);
  const [licenses, setLicenses] = useState<License[]>([]);
  const [purchases, setPurchases] = useState<Purchase[]>([]);
  const [saleOpen, setSaleOpen] = useState(false);
  const [upgradeOpen, setUpgradeOpen] = useState(false);
  const [grantOpen, setGrantOpen] = useState(false);
  const [issueOpen, setIssueOpen] = useState(false);
  const [openLicense, setOpenLicense] = useState<string | null>(null);
  const [revokeTarget, setRevokeTarget] = useState<Grant | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const q = { customer: customerUuid, per_page: 50 };
    const [s, g, l, p] = await Promise.all([
      readSubs ? billingService.listSubscriptions(q).then((r) => r.data) : Promise.resolve([]),
      readSubs ? billingService.listGrants(q).then((r) => r.data) : Promise.resolve([]),
      readLicenses ? billingService.listLicenses(q).then((r) => r.data) : Promise.resolve([]),
      readSubs ? billingService.listPurchases(q).then((r) => r.data) : Promise.resolve([]),
    ]).catch(() => [[], [], [], []] as [Subscription[], Grant[], License[], Purchase[]]);
    setSubs(s);
    setGrants(g);
    setLicenses(l);
    setPurchases(p);
    // Every app (needs billing.read), else the apps this customer appears in.
    let list: { uuid: string; name: string }[] = [];
    try {
      list = await billingService.listApps();
    } catch {
      const seen = new Map<string, string>();
      for (const r of [...s, ...g, ...l, ...p]) seen.set(r.app_uuid, r.app_name);
      list = Array.from(seen, ([uuid, name]) => ({ uuid, name }));
    }
    setApps(list);
    if (readSubs) {
      const pairs = await Promise.all(
        list.map((a) =>
          billingService
            .entitlements(a.uuid, customerUuid)
            .then((e) => [a.uuid, e] as const)
            .catch(() => null)
        )
      );
      setEnts(Object.fromEntries(pairs.filter((p): p is readonly [string, Entitlements] => !!p)));
    }
  }, [customerUuid, readSubs, readLicenses]);

  useEffect(() => {
    if (readSubs || readLicenses) load();
  }, [load, readSubs, readLicenses]);

  if (!readSubs && !readLicenses) return null;

  const revoke = async () => {
    if (!revokeTarget) return;
    setBusy(true);
    try {
      await billingService.revokeGrant(revokeTarget.uuid);
      toast.success('Grant revoked');
      setRevokeTarget(null);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not revoke'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card className="shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3 mb-4">
        <div>
          <h2 className="text-base font-semibold text-secondary-900">Billing</h2>
          <p className="text-sm text-secondary-500">What this customer can use in your apps, and why.</p>
        </div>
        <div className="flex flex-wrap gap-2">
          {canCreate('subscriptions') && (
            <Button type="button" variant="outline" size="sm" onClick={() => setSaleOpen(true)}>
              <Receipt className="w-4 h-4 mr-1.5" /> Record a sale
            </Button>
          )}
          {canCreate('subscriptions') && (
            <Button type="button" variant="outline" size="sm" onClick={() => setUpgradeOpen(true)}>
              <ArrowUpCircle className="w-4 h-4 mr-1.5" /> Upgrade
            </Button>
          )}
          {canCreate('subscriptions') && (
            <Button type="button" variant="outline" size="sm" onClick={() => setGrantOpen(true)}>
              <Gift className="w-4 h-4 mr-1.5" /> Grant access
            </Button>
          )}
          {canCreate('licenses') && (
            <Button type="button" variant="outline" size="sm" onClick={() => setIssueOpen(true)}>
              <KeyRound className="w-4 h-4 mr-1.5" /> Issue licence
            </Button>
          )}
        </div>
      </div>

      {apps.length === 0 ? (
        <p className="text-sm text-secondary-500">No apps yet.</p>
      ) : (
        <div className="space-y-4">
          {apps.map((a) => {
            const e = ents[a.uuid];
            const appSubs = subs.filter((s) => s.app_uuid === a.uuid);
            const appGrants = grants.filter((g) => g.app_uuid === a.uuid);
            const appLicenses = licenses.filter((l) => l.app_uuid === a.uuid);
            const appPurchases = purchases.filter((p) => p.app_uuid === a.uuid);
            return (
              <section key={a.uuid} className="rounded-lg border border-secondary-200 p-4" aria-label={a.name}>
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="font-medium text-secondary-900">{a.name}</h3>
                  {e && <StatusPill status={e.status} />}
                  {e?.plan && <span className="text-sm text-secondary-600">{e.plan.name}</span>}
                </div>
                {e && Object.keys(e.features).length > 0 && (
                  <dl className="mt-3 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-4 gap-y-1 text-sm">
                    {Object.entries(e.features).map(([k, v]) => (
                      <div key={k} className="flex justify-between gap-2 border-b border-secondary-50 py-1">
                        <dt className="font-mono text-xs text-secondary-500">{k}</dt>
                        <dd className="text-secondary-800">{show(v)}</dd>
                      </div>
                    ))}
                  </dl>
                )}

                {appSubs.length > 0 && (
                  <ul className="mt-3 text-sm text-secondary-700 space-y-1">
                    {appSubs.map((s) => (
                      <li key={s.uuid}>
                        Subscription: {s.plan_name || '—'} · <StatusPill status={s.status} />
                        {s.current_period_end && <> · until {formatDate(s.current_period_end)}</>}
                      </li>
                    ))}
                  </ul>
                )}

                {appPurchases.length > 0 && (
                  <ul className="mt-3 text-sm text-secondary-700 space-y-1">
                    {appPurchases.map((p) => (
                      <li key={p.uuid}>
                        Purchase: {p.plan_name} · {formatMinor(p.amount, p.currency)}
                        {p.coupon_code ? ` (coupon ${p.coupon_code})` : ''} · <StatusPill status={p.status} />
                        {p.access_until ? ` · access until ${formatDate(p.access_until)}` : ''}
                        {p.updates_until ? ` · updates until ${formatDate(p.updates_until)}` : ''}
                      </li>
                    ))}
                  </ul>
                )}

                {appGrants.length > 0 && (
                  <ul className="mt-3 space-y-1">
                    {appGrants.map((g) => (
                      <li key={g.uuid} className="flex items-center justify-between gap-2 text-sm text-secondary-700">
                        <span>
                          Grant: {g.plan_name || Object.keys(g.features).join(', ')}
                          {g.expires_at ? ` · until ${formatDate(g.expires_at)}` : ''}
                          {g.reason ? ` · ${g.reason}` : ''}
                        </span>
                        {canDelete('subscriptions') && (
                          <button
                            type="button"
                            onClick={() => setRevokeTarget(g)}
                            className="p-2 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
                            aria-label="Revoke grant"
                          >
                            <Trash2 className="w-4 h-4" />
                          </button>
                        )}
                      </li>
                    ))}
                  </ul>
                )}

                {appLicenses.length > 0 && (
                  <ul className="mt-3 flex flex-wrap gap-2">
                    {appLicenses.map((l) => (
                      <li key={l.uuid}>
                        <button
                          type="button"
                          onClick={() => setOpenLicense(l.uuid)}
                          className="inline-flex items-center gap-2 rounded-lg border border-secondary-200 px-2.5 py-1.5 text-sm hover:border-primary-300"
                        >
                          <KeyRound className="w-3.5 h-3.5 text-secondary-400" aria-hidden />
                          <code>{l.key_prefix}-…</code>
                          <StatusPill status={l.status} />
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </section>
            );
          })}
        </div>
      )}

      <GrantModal
        isOpen={grantOpen}
        customer={customerUuid}
        onClose={() => setGrantOpen(false)}
        onSaved={() => {
          setGrantOpen(false);
          load();
        }}
      />
      <SaleModal isOpen={saleOpen} customer={customerUuid} onClose={() => setSaleOpen(false)} onSaved={load} />
      <UpgradeModal isOpen={upgradeOpen} customer={customerUuid} onClose={() => setUpgradeOpen(false)} onSaved={load} />
      <IssueLicenseModal isOpen={issueOpen} customer={customerUuid} onClose={() => setIssueOpen(false)} onIssued={load} />
      <LicenseDetailModal uuid={openLicense} onClose={() => setOpenLicense(null)} onChanged={load} />
      <ConfirmDialog
        isOpen={!!revokeTarget}
        onClose={() => setRevokeTarget(null)}
        onConfirm={revoke}
        title="Revoke this grant?"
        message="The customer loses this access at their app's next check."
        confirmText="Revoke"
        variant="danger"
        isLoading={busy}
      />
    </Card>
  );
}
