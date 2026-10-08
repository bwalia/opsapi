'use client';

/**
 * The hosted billing pages (/b/[app]/…): no dashboard login, branded from the
 * app's settings. Shared shell, formatting and the copy-key button.
 */

import React, { useEffect, useState } from 'react';
import { Check, Copy, KeyRound, Loader2 } from 'lucide-react';
import { billingPublic, type PublicApp } from '@/services/billing-public.service';

export const fmtDate = (v?: string | null) =>
  v ? new Date(v.replace(' ', 'T')).toLocaleDateString(undefined, { dateStyle: 'medium' }) : null;

export const money = (amount: number, currency: string) =>
  new Intl.NumberFormat(undefined, { style: 'currency', currency: (currency || 'gbp').toUpperCase() }).format(amount / 100);

export function CopyKey({ value }: { value: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      onClick={async () => {
        await navigator.clipboard.writeText(value);
        setCopied(true);
        setTimeout(() => setCopied(false), 1500);
      }}
      className="inline-flex h-11 w-11 items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100"
      aria-label="Copy licence key"
    >
      {copied ? <Check className="h-5 w-5" /> : <Copy className="h-5 w-5" />}
    </button>
  );
}

/** Load the app's public info. */
export function usePublicApp(appRef: string) {
  const [app, setApp] = useState<PublicApp | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    billingPublic
      .app(appRef)
      .then(setApp)
      .catch(() => setFailed(true));
  }, [appRef]);
  return { app, failed };
}

export const accentOf = (app: PublicApp | null) => app?.accent_color || '#2563eb';

export function HostedShell({
  app,
  failed,
  headerRight,
  children,
}: {
  app: PublicApp | null;
  failed?: boolean;
  headerRight?: React.ReactNode;
  children: React.ReactNode;
}) {
  if (failed) {
    return <main className="min-h-dvh grid place-items-center bg-gray-50 p-6 text-gray-600">This page is not available.</main>;
  }
  if (!app) {
    return (
      <main className="min-h-dvh grid place-items-center bg-gray-50" aria-busy="true">
        <Loader2 className="h-6 w-6 animate-spin text-gray-400" />
      </main>
    );
  }
  const accent = accentOf(app);
  return (
    <main className="min-h-dvh bg-gray-50 text-gray-900">
      <header className="border-b border-gray-200 bg-white">
        <div className="mx-auto flex max-w-3xl items-center justify-between gap-3 px-4 py-4">
          <div className="flex items-center gap-3">
            {app.logo_url ? (
              // no-referrer: the success page's URL carries the Stripe session id (which reveals a new key once).
              // eslint-disable-next-line @next/next/no-img-element
              <img src={app.logo_url} alt="" referrerPolicy="no-referrer" className="h-9 w-9 rounded-lg object-contain" />
            ) : (
              <span className="flex h-9 w-9 items-center justify-center rounded-lg text-white" style={{ background: accent }}>
                <KeyRound className="h-5 w-5" aria-hidden />
              </span>
            )}
            <h1 className="text-lg font-semibold">{app.display_name || app.name}</h1>
          </div>
          {headerRight}
        </div>
      </header>
      <div className="mx-auto max-w-3xl space-y-6 px-4 py-8">
        {children}
        <footer className="flex flex-wrap gap-4 pt-4 text-xs text-gray-500">
          {app.support_email && (
            <a href={`mailto:${app.support_email}`} className="hover:underline">
              Support: {app.support_email}
            </a>
          )}
          {app.terms_url && (
            <a href={app.terms_url} className="hover:underline" rel="noopener noreferrer">
              Terms
            </a>
          )}
          {app.privacy_url && (
            <a href={app.privacy_url} className="hover:underline" rel="noopener noreferrer">
              Privacy
            </a>
          )}
        </footer>
      </div>
    </main>
  );
}

/** "£12.00 / year", "£99.00", "£9.00 for 30 days" */
export function priceLabel(p: { amount: number; currency: string; purchase_type: string; billing_interval?: string | null; term_days?: number | null }) {
  if (p.amount === 0) return 'Free';
  const m = money(p.amount, p.currency);
  if (p.purchase_type === 'recurring') return `${m} / ${p.billing_interval || 'month'}`;
  if (p.purchase_type === 'fixed_term') return `${m} for ${p.term_days} days`;
  return m;
}
