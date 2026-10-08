'use client';

/**
 * Hosted "my licences" page — /b/[app]/account (no dashboard login).
 *
 * The customer asks for an access link by email; the link brings them back
 * with #token=… (a fragment: it never reaches server logs), which is swapped
 * for a 30-minute session. They can then see their licences and purchases,
 * free a device, get a new key for a lost one, upgrade along the seller's
 * upgrade paths and manage a paid subscription in Stripe's Customer Portal.
 * Branded from the app's settings.
 */

import React, { useCallback, useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import { AlertTriangle, ArrowUpCircle, CreditCard, Laptop, Loader2, LogOut, Mail } from 'lucide-react';
import { billingPublic, PublicApiError, type MyAccount, type PublicApp } from '@/services/billing-public.service';
import { accentOf, CopyKey, fmtDate as fmt, HostedShell, money, priceLabel } from '@/components/billing/hosted';

export default function AccountPage() {
  const params = useParams();
  const appRef = params?.app as string;
  const [app, setApp] = useState<PublicApp | null>(null);
  const [failed, setFailed] = useState('');
  const [session, setSession] = useState<string | null>(null);
  const [account, setAccount] = useState<MyAccount | null>(null);
  const [email, setEmail] = useState('');
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [newKey, setNewKey] = useState<{ licence: string; key: string } | null>(null);

  const storageKey = `billing-session:${appRef}`;

  // App info, then a session from the link (#token=…) or from this tab.
  useEffect(() => {
    billingPublic
      .app(appRef)
      .then(async (a) => {
        setApp(a);
        const token = new URLSearchParams(window.location.hash.slice(1)).get('token');
        if (token) {
          history.replaceState(null, '', window.location.pathname + window.location.search);
          try {
            const s = await billingPublic.openSession(a.publishable_key, token);
            sessionStorage.setItem(storageKey, s.session);
            setSession(s.session);
          } catch (err) {
            setMessage(err instanceof PublicApiError ? err.message : 'This link is invalid or has expired.');
          }
        } else {
          setSession(sessionStorage.getItem(storageKey));
        }
      })
      .catch(() => setFailed('This page is not available.'));
  }, [appRef, storageKey]);

  const load = useCallback(() => {
    if (!app || !session) return;
    billingPublic
      .me(app.publishable_key, session)
      .then(setAccount)
      .catch(() => {
        sessionStorage.removeItem(storageKey);
        setSession(null);
        setAccount(null);
        setMessage('Your session has ended. Request a new link to continue.');
      });
  }, [app, session, storageKey]);

  useEffect(() => {
    load();
  }, [load]);

  const accent = accentOf(app);

  // Leave for Stripe (checkout for a paid upgrade, or the Customer Portal).
  const go = async (fn: () => Promise<{ url?: string; upgraded?: boolean }>) => {
    setBusy(true);
    setMessage('');
    try {
      const r = await fn();
      if (r.url) {
        window.location.assign(r.url);
        return;
      }
      load();
    } catch (err) {
      setMessage(err instanceof PublicApiError ? err.message : 'Something went wrong. Try again.');
    }
    setBusy(false);
  };

  const requestLink = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!app) return;
    setBusy(true);
    setMessage('');
    try {
      await billingPublic.requestLink(app.publishable_key, email.trim());
      setSent(true);
    } catch (err) {
      setMessage(err instanceof PublicApiError ? err.message : 'Something went wrong. Try again.');
    } finally {
      setBusy(false);
    }
  };

  const act = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setMessage('');
    try {
      await fn();
      load();
    } catch (err) {
      setMessage(err instanceof PublicApiError ? err.message : 'Something went wrong. Try again.');
    } finally {
      setBusy(false);
    }
  };

  if (!app || failed) return <HostedShell app={app} failed={!!failed}>{null}</HostedShell>;

  return (
    <HostedShell
      app={app}
      headerRight={
        account && session ? (
          <button
            type="button"
            onClick={() =>
              act(async () => {
                await billingPublic.signOut(app.publishable_key, session).catch(() => undefined);
                sessionStorage.removeItem(storageKey);
                setSession(null);
                setAccount(null);
              })
            }
            className="inline-flex min-h-11 items-center gap-1.5 rounded-lg px-3 text-sm text-gray-600 hover:bg-gray-100"
          >
            <LogOut className="h-4 w-4" aria-hidden /> Sign out
          </button>
        ) : null
      }
    >
      {message && (
        <p className="rounded-lg bg-amber-50 p-3 text-sm text-amber-800" role="alert">
          {message}
        </p>
      )}

      {!account && (
        <section className="rounded-xl border border-gray-200 bg-white p-6 shadow-sm">
          {sent ? (
            <div className="text-center" aria-live="polite">
              <Mail className="mx-auto h-10 w-10" style={{ color: accent }} aria-hidden />
              <h2 className="mt-3 text-lg font-semibold">Check your email</h2>
              <p className="mt-1 text-sm text-gray-600">
                If {email} has a licence or purchase, we&apos;ve sent a link to open your account. It works once, for 15 minutes.
              </p>
            </div>
          ) : (
            <form onSubmit={requestLink} className="space-y-4">
              <div>
                <h2 className="text-lg font-semibold">Manage your licences</h2>
                <p className="text-sm text-gray-600">Enter the email you bought with. We&apos;ll send you a link to sign in.</p>
              </div>
              <label className="block">
                <span className="mb-1 block text-sm font-medium text-gray-700">Email</span>
                <input
                  type="email"
                  required
                  autoComplete="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="h-11 w-full rounded-lg border border-gray-300 px-3 text-base focus:outline-none focus:ring-2"
                />
              </label>
              <button
                type="submit"
                disabled={busy}
                className="inline-flex h-11 w-full items-center justify-center rounded-lg px-4 font-medium text-white disabled:opacity-60"
                style={{ background: accent }}
              >
                {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Email me a link'}
              </button>
            </form>
          )}
        </section>
      )}

      {account && session && (
        <>
          <p className="text-sm text-gray-600">Signed in as {account.customer.email}</p>

          {newKey && (
            <section className="space-y-2 rounded-xl border border-amber-200 bg-amber-50 p-4" aria-live="polite">
              <p className="flex items-start gap-2 text-sm text-amber-800">
                <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
                Your new key. Copy it now: it won&apos;t be shown again. Your devices stay activated; the old key no longer works.
              </p>
              <div className="flex items-center gap-2 rounded-lg bg-white px-3 py-2">
                <code className="flex-1 break-all text-base tracking-wider">{newKey.key}</code>
                <CopyKey value={newKey.key} />
              </div>
            </section>
          )}

          <section>
            <h2 className="mb-3 text-base font-semibold">Licences</h2>
            {account.licences.length === 0 && <p className="text-sm text-gray-600">No licences.</p>}
            <ul className="space-y-4">
              {account.licences.map((l) => {
                const live = l.activations.filter((d) => !d.deactivated_at);
                return (
                  <li key={l.uuid} className="rounded-xl border border-gray-200 bg-white p-4 shadow-sm">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <div>
                        <p className="font-medium">
                          {l.plan_name || 'Licence'} <code className="ml-1 text-sm text-gray-500">{l.key_prefix}-…</code>
                        </p>
                        <p className="text-xs text-gray-500">
                          {l.status} · {l.access_until ? `access until ${fmt(l.access_until)}` : 'perpetual'} ·{' '}
                          {l.updates_until ? `updates until ${fmt(l.updates_until)}` : 'all updates'}
                        </p>
                      </div>
                      {l.status !== 'revoked' && (
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() =>
                            act(async () => {
                              const r = await billingPublic.reissue(app.publishable_key, session, l.uuid);
                              setNewKey({ licence: l.uuid, key: r.key });
                            })
                          }
                          className="inline-flex min-h-11 items-center rounded-lg border border-gray-300 px-3 text-sm hover:bg-gray-50"
                        >
                          I lost my key
                        </button>
                      )}
                    </div>
                    <h3 className="mt-3 text-sm font-medium text-gray-700">
                      Devices ({live.length}
                      {l.max_activations ? ` of ${l.max_activations}` : ''})
                    </h3>
                    {live.length === 0 ? (
                      <p className="text-sm text-gray-500">Not activated on any device.</p>
                    ) : (
                      <ul className="mt-1 divide-y divide-gray-100">
                        {live.map((d) => (
                          <li key={d.uuid} className="flex items-center justify-between gap-3 py-2">
                            <span className="flex min-w-0 items-center gap-2 text-sm">
                              <Laptop className="h-4 w-4 shrink-0 text-gray-400" aria-hidden />
                              <span className="truncate">
                                {d.name || 'Device'}
                                <span className="text-gray-500">
                                  {' '}
                                  · {[d.platform, d.app_version && `v${d.app_version}`].filter(Boolean).join(' · ')} · last
                                  seen {fmt(d.last_seen_at)}
                                </span>
                              </span>
                            </span>
                            <button
                              type="button"
                              disabled={busy}
                              onClick={() => act(() => billingPublic.freeDevice(app.publishable_key, session, l.uuid, d.uuid))}
                              className="inline-flex min-h-11 shrink-0 items-center rounded-lg px-3 text-sm text-gray-600 hover:bg-gray-100"
                            >
                              Remove
                            </button>
                          </li>
                        ))}
                      </ul>
                    )}
                  </li>
                );
              })}
            </ul>
          </section>

          {((account.payments && (account.upgrades?.length ?? 0) > 0) || account.can_manage_billing) && (
            <section className="rounded-xl border border-gray-200 bg-white p-4 shadow-sm">
              <h2 className="text-base font-semibold">Your plan{account.current_plan ? `: ${account.current_plan.name}` : ''}</h2>
              {account.payments && (account.upgrades?.length ?? 0) > 0 && (
                <ul className="mt-3 space-y-2">
                  {account.upgrades!.map((u) => (
                    <li key={u.plan_key} className="flex flex-wrap items-center justify-between gap-3">
                      <span className="text-sm">
                        Upgrade to <strong>{u.name}</strong>
                        <span className="text-gray-500">
                          {' '}
                          · {u.purchase_type === 'recurring' ? priceLabel(u) + ', prorated' : u.amount === 0 ? 'free' : money(u.amount, u.currency)}
                        </span>
                      </span>
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => go(() => billingPublic.upgrade(app.publishable_key, session, u.plan_key))}
                        className="inline-flex min-h-11 items-center gap-1.5 rounded-lg px-3 text-sm font-medium text-white disabled:opacity-60"
                        style={{ background: accent }}
                      >
                        <ArrowUpCircle className="h-4 w-4" aria-hidden /> Upgrade
                      </button>
                    </li>
                  ))}
                </ul>
              )}
              {account.can_manage_billing && (
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => go(() => billingPublic.portal(app.publishable_key, session))}
                  className="mt-3 inline-flex min-h-11 items-center gap-1.5 rounded-lg border border-gray-300 px-3 text-sm hover:bg-gray-50"
                >
                  <CreditCard className="h-4 w-4" aria-hidden /> Manage billing (payment method, invoices, cancel)
                </button>
              )}
            </section>
          )}

          {(account.purchases.length > 0 || account.subscriptions.length > 0) && (
            <section>
              <h2 className="mb-3 text-base font-semibold">Purchases</h2>
              <ul className="divide-y divide-gray-100 rounded-xl border border-gray-200 bg-white shadow-sm">
                {account.subscriptions.map((s) => (
                  <li key={s.uuid} className="flex justify-between gap-3 px-4 py-3 text-sm">
                    <span>{s.plan_name || 'Subscription'} (subscription)</span>
                    <span className="text-gray-600">
                      {s.status}
                      {s.current_period_end ? ` · renews ${fmt(s.current_period_end)}` : ''}
                    </span>
                  </li>
                ))}
                {account.purchases.map((p) => (
                  <li key={p.uuid} className="flex justify-between gap-3 px-4 py-3 text-sm">
                    <span>
                      {p.plan_name} · {fmt(p.created_at)}
                    </span>
                    <span className="text-gray-600">
                      {money(p.amount, p.currency)} · {p.status}
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </>
      )}
    </HostedShell>
  );
}
