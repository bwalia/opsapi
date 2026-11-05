'use client';

/**
 * A partner's private link for one referral (no sign-in): see what's asked,
 * accept or decline, and later say whether they won the work and its final
 * value. The link's secret is in the URL; the API only stores its hash.
 */
import React, { useCallback, useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import { CheckCircle2, Handshake, Loader2, XCircle } from 'lucide-react';

const API = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';

interface View {
  from: string;
  partner: string;
  status: string;
  status_label: string;
  title: string;
  wants: string | null;
  summary: string | null;
  message: string | null;
  deal_value: number | null;
  currency: string | null;
  commission_type: 'percent' | 'fixed';
  commission_value: number;
  customer: { name: string | null; company: string | null; email: string | null; phone: string | null } | null;
  can: { accept: boolean; decline: boolean; won: boolean; lost: boolean };
  expires_at: string;
}

function money(v: number | null, c: string | null) {
  if (v === null || v === undefined) return 'to be agreed';
  try { return new Intl.NumberFormat(undefined, { style: 'currency', currency: c || 'GBP', maximumFractionDigits: 0 }).format(v); }
  catch { return `${v} ${c ?? ''}`; }
}

export default function PartnerReferralPage() {
  const { token } = useParams<{ token: string }>();
  const [view, setView] = useState<View | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [value, setValue] = useState('');
  const [done, setDone] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const res = await fetch(`${API}/api/v2/public/referrals/${encodeURIComponent(token)}`);
      const body = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(body?.error || 'This link could not be opened.');
      setView(body.data);
      if (body.data?.deal_value) setValue(String(body.data.deal_value));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'This link could not be opened.');
    }
  }, [token]);
  useEffect(() => { load(); }, [load]);

  const answer = async (action: 'accept' | 'decline' | 'won' | 'lost') => {
    setBusy(action); setError(null);
    try {
      const res = await fetch(`${API}/api/v2/public/referrals/${encodeURIComponent(token)}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action, reference: reference || undefined, notes: notes || undefined,
          deal_value: action === 'won' && value ? Number(value) : undefined }),
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(body?.error || 'That didn’t work. Please try again.');
      setView(body.data);
      setDone({ accept: 'Thanks — you accepted. We’ll be in touch to connect you.', decline: 'Thanks for letting us know.',
        won: 'Congratulations, and thanks for telling us.', lost: 'Thanks for letting us know.' }[action]);
      setNotes('');
    } catch (e) {
      setError(e instanceof Error ? e.message : 'That didn’t work. Please try again.');
    } finally {
      setBusy(null);
    }
  };

  const field = 'w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-teal-600 focus:outline-none focus:ring-2 focus:ring-teal-600/20';

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-10">
      <div className="mx-auto max-w-xl">
        <div className="flex items-center gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-teal-600/10 text-teal-700"><Handshake className="h-5 w-5" aria-hidden="true" /></span>
          <div>
            <p className="text-xs uppercase tracking-wide text-slate-500">Referral</p>
            <h1 className="text-xl font-bold text-slate-900">{view ? `From ${view.from}` : 'Loading…'}</h1>
          </div>
        </div>

        {error && <p className="mt-6 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700" role="alert">{error}</p>}
        {!view && !error && <p className="mt-6 flex items-center gap-2 text-sm text-slate-500"><Loader2 className="h-4 w-4 animate-spin" />Opening…</p>}

        {view && (
          <div className="mt-6 space-y-5">
            {done && <p className="flex items-center gap-2 rounded-lg border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-800"><CheckCircle2 className="h-4 w-4" />{done}</p>}
            <section className="rounded-xl border border-slate-200 bg-white p-5">
              <p className="text-xs text-slate-500">For {view.partner} · {view.status_label}</p>
              <h2 className="mt-1 text-lg font-semibold text-slate-900">{view.title}</h2>
              {view.wants && <p className="mt-2 text-sm text-slate-700"><span className="text-slate-500">Wanted: </span>{view.wants}</p>}
              {view.summary && <p className="mt-2 text-sm text-slate-700">{view.summary}</p>}
              {view.message && <p className="mt-3 whitespace-pre-wrap rounded-lg bg-slate-50 p-3 text-sm text-slate-700">{view.message}</p>}
              <dl className="mt-4 grid grid-cols-2 gap-3 text-sm">
                <div><dt className="text-xs text-slate-500">Estimated value</dt><dd className="font-semibold text-slate-900">{money(view.deal_value, view.currency)}</dd></div>
                <div><dt className="text-xs text-slate-500">Commission to {view.from}</dt><dd className="font-semibold text-slate-900">
                  {view.commission_type === 'percent' ? `${view.commission_value}% of the deal` : money(view.commission_value, view.currency)}</dd></div>
              </dl>
              {view.customer ? (
                <div className="mt-4 rounded-lg border border-slate-200 p-3 text-sm">
                  <p className="text-xs text-slate-500">The customer (they agreed to us sharing their details)</p>
                  <p className="mt-1 font-medium text-slate-900">{[view.customer.name, view.customer.company].filter(Boolean).join(', ')}</p>
                  <p className="text-slate-700">{[view.customer.email, view.customer.phone].filter(Boolean).join(' · ')}</p>
                </div>
              ) : (
                <p className="mt-4 text-xs text-slate-500">We’ll introduce you to the customer once you accept.</p>
              )}
            </section>

            {(view.can.accept || view.can.won) && (
              <section className="rounded-xl border border-slate-200 bg-white p-5">
                <h2 className="text-sm font-semibold text-slate-900">{view.can.accept ? 'Can you take this on?' : 'How did it go?'}</h2>
                <div className="mt-3 space-y-3">
                  <div>
                    <label htmlFor="ref" className="block text-sm font-medium text-slate-700">Your reference (optional)</label>
                    <input id="ref" className={`${field} mt-1`} value={reference} maxLength={120} onChange={(e) => setReference(e.target.value)} />
                  </div>
                  {view.can.won && (
                    <div>
                      <label htmlFor="val" className="block text-sm font-medium text-slate-700">Final deal value, if you won it</label>
                      <input id="val" type="number" min={0} className={`${field} mt-1`} value={value} onChange={(e) => setValue(e.target.value)} />
                    </div>
                  )}
                  <div>
                    <label htmlFor="notes" className="block text-sm font-medium text-slate-700">Note (optional)</label>
                    <textarea id="notes" rows={3} className={`${field} mt-1`} value={notes} maxLength={2000} onChange={(e) => setNotes(e.target.value)} />
                  </div>
                  <div className="flex flex-wrap gap-2">
                    {view.can.accept && <button type="button" disabled={!!busy} onClick={() => answer('accept')}
                      className="inline-flex h-10 items-center gap-2 rounded-lg bg-teal-700 px-4 text-sm font-medium text-white hover:bg-teal-800 disabled:opacity-50">
                      {busy === 'accept' ? <Loader2 className="h-4 w-4 animate-spin" /> : <CheckCircle2 className="h-4 w-4" />}Accept</button>}
                    {view.can.decline && <button type="button" disabled={!!busy} onClick={() => answer('decline')}
                      className="inline-flex h-10 items-center gap-2 rounded-lg border border-slate-300 px-4 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
                      <XCircle className="h-4 w-4" />Decline</button>}
                    {view.can.won && <button type="button" disabled={!!busy} onClick={() => answer('won')}
                      className="inline-flex h-10 items-center gap-2 rounded-lg bg-teal-700 px-4 text-sm font-medium text-white hover:bg-teal-800 disabled:opacity-50">
                      {busy === 'won' ? <Loader2 className="h-4 w-4 animate-spin" /> : <CheckCircle2 className="h-4 w-4" />}We won it</button>}
                    {view.can.lost && <button type="button" disabled={!!busy} onClick={() => answer('lost')}
                      className="inline-flex h-10 items-center gap-2 rounded-lg border border-slate-300 px-4 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
                      We didn’t win it</button>}
                  </div>
                </div>
              </section>
            )}
            <p className="text-center text-xs text-slate-400">This link is private to you. It works until {new Date(view.expires_at).toLocaleDateString()}.</p>
          </div>
        )}
      </div>
    </main>
  );
}
