'use client';

/**
 * Hosted order page — /b/[app]/success?session_id=… (Stripe sends the buyer here).
 *
 * Stripe's webhook fulfils the order, usually within seconds, so the page
 * waits for it. A new licence key is shown here once (the server hands it
 * out a single time), and emailed too if the app emails keys.
 */

import React, { Suspense, useEffect, useState } from 'react';
import Link from 'next/link';
import { useParams, useSearchParams } from 'next/navigation';
import { AlertTriangle, CheckCircle2, Loader2 } from 'lucide-react';
import { billingPublic, type Order } from '@/services/billing-public.service';
import { accentOf, CopyKey, fmtDate, HostedShell, usePublicApp } from '@/components/billing/hosted';

const WAIT_SECONDS = 60;

function SuccessContent() {
  const params = useParams();
  const search = useSearchParams();
  const sessionId = search?.get('session_id') || '';
  const { app, failed } = usePublicApp(params?.app as string);
  const [order, setOrder] = useState<Order | null>(null);
  const [gaveUp, setGaveUp] = useState(false);

  useEffect(() => {
    if (!app || !sessionId) return;
    let stopped = false;
    let tries = 0;
    const poll = async () => {
      try {
        const o = await billingPublic.order(app.publishable_key, sessionId);
        if (stopped) return;
        setOrder(o);
        if (o.status === 'complete') return;
      } catch {
        // keep waiting: the webhook may not have arrived yet
      }
      if (++tries * 2 >= WAIT_SECONDS) setGaveUp(true);
      else setTimeout(poll, 2000);
    };
    poll();
    return () => {
      stopped = true;
    };
  }, [app, sessionId]);

  const accent = accentOf(app);
  const done = order?.status === 'complete';

  return (
    <HostedShell app={app} failed={failed || (!!app && !sessionId)}>
      {app && (
        <section className="rounded-xl border border-gray-200 bg-white p-6 shadow-sm" aria-live="polite">
          {!done && !gaveUp && (
            <div className="flex items-center gap-3 text-gray-700">
              <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
              Confirming your payment…
            </div>
          )}
          {!done && gaveUp && (
            <p className="text-sm text-gray-700">
              Your payment is still being confirmed. You&apos;ll get an email when it&apos;s done, or check again on{' '}
              <Link href={`/b/${app.uuid}/account`} className="underline">
                your account page
              </Link>
              .
            </p>
          )}
          {done && order && (
            <div className="space-y-4">
              <h2 className="flex items-center gap-2 text-lg font-semibold">
                <CheckCircle2 className="h-6 w-6" style={{ color: accent }} aria-hidden />
                Thank you{order.plan ? ` — ${order.plan.name} is yours` : ''}
              </h2>
              {order.key && (
                <div className="space-y-2 rounded-xl border border-amber-200 bg-amber-50 p-4">
                  <p className="flex items-start gap-2 text-sm text-amber-800">
                    <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
                    Your licence key. Copy it now: this page won&apos;t show it again
                    {order.key_emailed ? ', but we have emailed it to you too' : ''}.
                  </p>
                  <div className="flex items-center gap-2 rounded-lg bg-white px-3 py-2">
                    <code className="flex-1 break-all text-base tracking-wider">{order.key}</code>
                    <CopyKey value={order.key} />
                  </div>
                </div>
              )}
              {!order.key && order.license && (
                <p className="text-sm text-gray-700">
                  Your licence <code>{order.license.key_prefix}-…</code> is ready
                  {order.license.access_until ? ` until ${fmtDate(order.license.access_until)}` : ''}. Keep using the key you
                  already have; if you&apos;ve lost it, get a new one from your account page.
                </p>
              )}
              {!order.license && <p className="text-sm text-gray-700">Your purchase is active. You can start using it now.</p>}
              <Link
                href={`/b/${app.uuid}/account`}
                className="inline-flex min-h-11 items-center rounded-lg border border-gray-300 px-3 text-sm hover:bg-gray-50"
              >
                Manage your account
              </Link>
            </div>
          )}
        </section>
      )}
    </HostedShell>
  );
}

export default function SuccessPage() {
  return (
    <Suspense fallback={null}>
      <SuccessContent />
    </Suspense>
  );
}
