'use client';

/**
 * Hosted pricing page — /b/[app]/pricing (no dashboard login).
 *
 * The app's public plans and what each includes. "Buy" opens Stripe's hosted
 * checkout; the order is fulfilled by Stripe's webhook and the buyer lands on
 * /b/[app]/success. Branded from the app's settings.
 */

import React, { useMemo, useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { Check, Loader2, Minus } from 'lucide-react';
import { billingPublic, PublicApiError, type PublicPlan } from '@/services/billing-public.service';
import { accentOf, HostedShell, priceLabel, usePublicApp } from '@/components/billing/hosted';

function planNote(p: PublicPlan) {
  if (p.purchase_type === 'recurring') return p.trial_days ? `${p.trial_days}-day free trial, then billed every ${p.billing_interval}` : `Billed every ${p.billing_interval}`;
  if (p.purchase_type === 'fixed_term') return p.term_covers === 'updates' ? `${p.term_days} days of updates` : `${p.term_days} days of access`;
  return p.updates_days ? `Pay once · updates for ${Math.round(p.updates_days / 365) || 1} year(s)` : 'Pay once · all future updates';
}

export default function PricingPage() {
  const params = useParams();
  const { app, failed } = usePublicApp(params?.app as string);
  const [coupon, setCoupon] = useState('');
  const [buying, setBuying] = useState<string | null>(null);
  const [message, setMessage] = useState('');

  const plans = useMemo(() => (app?.plans || []).filter((p) => p.amount > 0), [app]);
  const features = app?.features || [];
  const accent = accentOf(app);

  const buy = async (p: PublicPlan) => {
    if (!app) return;
    setBuying(p.plan_key);
    setMessage('');
    try {
      const r = await billingPublic.checkout(app.publishable_key, { plan_key: p.plan_key, coupon: coupon.trim() || undefined });
      if (r.url) {
        window.location.assign(r.url);
        return;
      }
    } catch (err) {
      setMessage(err instanceof PublicApiError ? err.message : 'Something went wrong. Try again.');
    }
    setBuying(null);
  };

  const value = (p: PublicPlan, key: string, type: string) => {
    const v = Array.isArray(p.features) ? undefined : p.features?.[key];
    if (type === 'boolean') return v === true;
    if (v === null) return 'Unlimited';
    return typeof v === 'number' && v > 0 ? String(v) : false;
  };

  return (
    <HostedShell app={app} failed={failed}>
      {app && (
        <>
          <div>
            <h2 className="text-2xl font-semibold">Pricing</h2>
            <p className="mt-1 text-sm text-gray-600">
              Already bought?{' '}
              <Link href={`/b/${app.uuid}/account`} className="underline">
                Manage your licences
              </Link>
            </p>
          </div>

          {message && (
            <p className="rounded-lg bg-amber-50 p-3 text-sm text-amber-800" role="alert">
              {message}
            </p>
          )}
          {!app.payments && (
            <p className="rounded-lg bg-gray-100 p-3 text-sm text-gray-700">Purchases aren&apos;t open yet. Please check back soon.</p>
          )}

          {app.payments && plans.length > 0 && (
            <label className="block max-w-xs">
              <span className="mb-1 block text-sm font-medium text-gray-700">Coupon code (optional)</span>
              <input
                value={coupon}
                onChange={(e) => setCoupon(e.target.value.toUpperCase())}
                autoComplete="off"
                className="h-11 w-full rounded-lg border border-gray-300 px-3 text-base uppercase focus:outline-none focus:ring-2"
              />
              <span className="mt-1 block text-xs text-gray-500">Applied when you check out.</span>
            </label>
          )}

          <ul className="grid gap-4 sm:grid-cols-2">
            {plans.map((p) => (
              <li key={p.uuid} className="flex flex-col rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
                <h3 className="text-lg font-semibold">{p.name}</h3>
                <p className="mt-1 text-2xl font-semibold tabular-nums">{priceLabel(p)}</p>
                <p className="text-sm text-gray-500">{planNote(p)}</p>
                {p.description && <p className="mt-2 text-sm text-gray-700">{p.description}</p>}
                {features.length > 0 && (
                  <ul className="mt-4 space-y-1.5 text-sm">
                    {features.map((f) => {
                      const v = value(p, f.key, f.type);
                      return (
                        <li key={f.key} className={`flex items-center gap-2 ${v ? '' : 'text-gray-400'}`}>
                          {v ? <Check className="h-4 w-4 shrink-0" style={{ color: accent }} aria-hidden /> : <Minus className="h-4 w-4 shrink-0" aria-hidden />}
                          <span>
                            {f.name}
                            {typeof v === 'string' && `: ${v}${f.unit ? ` ${f.unit}` : ''}`}
                          </span>
                          <span className="sr-only">{v ? '(included)' : '(not included)'}</span>
                        </li>
                      );
                    })}
                  </ul>
                )}
                <button
                  type="button"
                  disabled={!app.payments || buying !== null}
                  onClick={() => buy(p)}
                  className="mt-5 inline-flex h-11 items-center justify-center rounded-lg px-4 font-medium text-white disabled:opacity-60"
                  style={{ background: accent }}
                >
                  {buying === p.plan_key ? <Loader2 className="h-4 w-4 animate-spin" aria-label="Opening checkout" /> : `Buy ${p.name}`}
                </button>
              </li>
            ))}
          </ul>
          {plans.length === 0 && <p className="text-sm text-gray-600">No plans are on sale.</p>}

        </>
      )}
    </HostedShell>
  );
}
