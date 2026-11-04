'use client';

/**
 * Partners: the companies you pass work to (they fulfil it, you earn a
 * commission), and every referral from sent to commission paid.
 */
import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { ArrowLeft, Handshake, Pencil, Plus } from 'lucide-react';
import { Button, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { useNamespace } from '@/contexts/NamespaceContext';
import { cn } from '@/lib/utils';
import { leadError, leadsService, type Partner, type Referral } from '@/services/leads.service';
import { dateOnly, FieldError, money } from '@/components/leads/ui';

const input = 'w-full rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20';

const STATUS_TONE: Record<string, string> = {
  draft: 'bg-secondary-100 text-secondary-600', sent: 'bg-sky-50 text-sky-700', accepted: 'bg-indigo-50 text-indigo-700',
  declined: 'bg-secondary-100 text-secondary-500', won: 'bg-emerald-50 text-emerald-700', lost: 'bg-secondary-100 text-secondary-500',
  commission_invoiced: 'bg-amber-50 text-amber-800', commission_paid: 'bg-emerald-600 text-white', cancelled: 'bg-secondary-100 text-secondary-400',
};

function PartnerForm({ partner, onClose, onSaved }: { partner: Partner | null; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState({
    name: partner?.name ?? '', website: partner?.website ?? '', offering: partner?.offering ?? '',
    categories: (partner?.categories ?? []).join(', '), regions: (partner?.regions ?? []).join(', '),
    referral_email: partner?.referral_email ?? '', referral_contact_name: partner?.referral_contact_name ?? '',
    commission_type: partner?.commission_type ?? 'percent', commission_value: partner ? String(Number(partner.commission_value)) : '5',
    terms: partner?.terms ?? '', active: partner?.active ?? true,
  });
  const [busy, setBusy] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const upd = (k: keyof typeof f, v: string | boolean) => setF((x) => ({ ...x, [k]: v }));
  const submit = async () => {
    setBusy(true); setErrors({});
    try {
      await leadsService.savePartner({
        name: f.name, website: f.website || null, offering: f.offering, categories: f.categories, regions: f.regions,
        referral_email: f.referral_email || null, referral_contact_name: f.referral_contact_name || null,
        commission_type: f.commission_type, commission_value: Number(f.commission_value) || 0, terms: f.terms || null, active: f.active,
      }, partner?.uuid);
      toast.success(partner ? 'Partner saved' : 'Partner added');
      onSaved();
    } catch (e) {
      const err = leadError(e);
      setErrors(err.fields ?? {});
      toast.error(err.message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <Modal isOpen onClose={onClose} size="lg" title={partner ? `Edit ${partner.name}` : 'Add a partner'}
      description="The AI suggests partners whose description matches what a lead wants, so describe what they supply."
      footer={<><Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
        <Button onClick={submit} isLoading={busy}>{partner ? 'Save' : 'Add partner'}</Button></>}>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="sm:col-span-2">
          <label className="block text-sm font-medium text-secondary-700" htmlFor="p-name">Company</label>
          <input id="p-name" className={cn(input, 'mt-1')} value={f.name} maxLength={200} onChange={(e) => upd('name', e.target.value)} placeholder="e.g. Bosch, Apple, Microsoft" />
          <FieldError message={errors.name} />
        </div>
        <div className="sm:col-span-2">
          <label className="block text-sm font-medium text-secondary-700" htmlFor="p-off">What they supply</label>
          <textarea id="p-off" rows={3} className={cn(input, 'mt-1')} value={f.offering} maxLength={2000} onChange={(e) => upd('offering', e.target.value)}
            placeholder="e.g. Business laptops and tablets, bulk orders, next-day delivery in the UK" />
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700" htmlFor="p-cat">Categories</label>
          <input id="p-cat" className={cn(input, 'mt-1')} value={f.categories} onChange={(e) => upd('categories', e.target.value)} placeholder="laptops, hardware" />
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700" htmlFor="p-reg">Regions</label>
          <input id="p-reg" className={cn(input, 'mt-1')} value={f.regions} onChange={(e) => upd('regions', e.target.value)} placeholder="UK, Ireland" />
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700" htmlFor="p-email">Send referrals to</label>
          <input id="p-email" type="email" className={cn(input, 'mt-1')} value={f.referral_email} onChange={(e) => upd('referral_email', e.target.value)} placeholder="partners@company.com" />
          <FieldError message={errors.referral_email} />
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700" htmlFor="p-contact">Contact name</label>
          <input id="p-contact" className={cn(input, 'mt-1')} value={f.referral_contact_name} onChange={(e) => upd('referral_contact_name', e.target.value)} />
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700" htmlFor="p-ctype">Commission</label>
          <select id="p-ctype" className={cn(input, 'mt-1')} value={f.commission_type} onChange={(e) => upd('commission_type', e.target.value)}>
            <option value="percent">% of the deal</option><option value="fixed">Fixed fee per deal</option>
          </select>
          <FieldError message={errors.commission_type} />
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700" htmlFor="p-cval">{f.commission_type === 'percent' ? 'Percent' : 'Amount'}</label>
          <input id="p-cval" type="number" min={0} step="0.01" className={cn(input, 'mt-1')} value={f.commission_value} onChange={(e) => upd('commission_value', e.target.value)} />
          <FieldError message={errors.commission_value} />
        </div>
        <div className="sm:col-span-2">
          <label className="block text-sm font-medium text-secondary-700" htmlFor="p-terms">Agreement notes (optional)</label>
          <textarea id="p-terms" rows={2} className={cn(input, 'mt-1')} value={f.terms} maxLength={2000} onChange={(e) => upd('terms', e.target.value)} />
        </div>
        {partner && (
          <label className="flex items-center gap-2 text-sm text-secondary-700 sm:col-span-2">
            <input type="checkbox" className="h-4 w-4 rounded border-secondary-300" checked={f.active} onChange={(e) => upd('active', e.target.checked)} />
            Active (suggested and available for new referrals)
          </label>
        )}
      </div>
    </Modal>
  );
}

function PartnersContent() {
  const { hasPermission } = useNamespace();
  const canEdit = hasPermission('crm_accounts', 'update');
  const [partners, setPartners] = useState<Partner[] | null>(null);
  const [referrals, setReferrals] = useState<Referral[] | null>(null);
  const [status, setStatus] = useState('');
  const [editing, setEditing] = useState<Partner | null | 'new'>(null);
  const [error, setError] = useState<string | null>(null);

  const [tick, setTick] = useState(0);
  const load = useCallback(() => setTick((t) => t + 1), []);
  useEffect(() => {
    let alive = true;
    Promise.all([leadsService.partners({ active: 'all' }), leadsService.referrals({ status: status || undefined })])
      .then(([p, r]) => { if (alive) { setPartners(p); setReferrals(r); setError(null); } })
      .catch((e) => { if (alive) setError(leadError(e).message); });
    return () => { alive = false; };
  }, [status, tick]);

  const earned = (partners ?? []).reduce((n, p) => n + p.commission_paid, 0);

  return (
    <div className="space-y-6">
      <div>
        <Link href="/dashboard/leads" className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800">
          <ArrowLeft className="h-4 w-4" aria-hidden="true" />Leads
        </Link>
        <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-start gap-3">
            <span className="mt-0.5 flex h-11 w-11 items-center justify-center rounded-xl bg-primary-500/10 text-primary-500"><Handshake className="h-5 w-5" aria-hidden="true" /></span>
            <div>
              <h1 className="text-2xl font-bold tracking-tight text-secondary-900">Partners</h1>
              <p className="text-sm text-secondary-500">Companies you pass work to. They fulfil it; you earn the commission.</p>
            </div>
          </div>
          {canEdit && <Button onClick={() => setEditing('new')} leftIcon={<Plus className="h-4 w-4" />}>Add partner</Button>}
        </div>
      </div>
      {error && <p className="rounded-lg border border-error-200 bg-error-50 p-3 text-sm text-error-700" role="alert">{error}</p>}

      <section className="rounded-xl border border-secondary-200 bg-white">
        <div className="flex items-center justify-between border-b border-secondary-200 px-5 py-3">
          <h2 className="text-sm font-semibold text-secondary-900">Directory</h2>
          <p className="text-xs text-secondary-500">Commission received: <strong className="text-secondary-800">{money(earned, 'GBP')}</strong></p>
        </div>
        {partners === null ? <p className="p-6 text-sm text-secondary-500">Loading…</p> : partners.length === 0 ? (
          <p className="p-8 text-center text-sm text-secondary-500">No partners yet. Add the companies you pass work to, and the AI will suggest them on matching leads.</p>
        ) : (
          <ul className="divide-y divide-secondary-100">
            {partners.map((p) => (
              <li key={p.uuid} className={cn('flex flex-wrap items-start justify-between gap-3 px-5 py-4', !p.active && 'opacity-60')}>
                <div className="min-w-0">
                  <p className="text-sm font-semibold text-secondary-900">{p.name}{!p.active && <span className="ml-2 text-xs font-normal text-secondary-500">(off)</span>}</p>
                  <p className="text-xs text-secondary-500">{p.offering || 'No description'}</p>
                  <p className="mt-1 text-xs text-secondary-500">
                    {p.commission_type === 'percent' ? `${Number(p.commission_value)}% of the deal` : `${money(p.commission_value, p.currency || 'GBP')} per deal`}
                    {' · '}{p.referral_email || <span className="text-amber-700">no referral email</span>}
                  </p>
                </div>
                <div className="flex items-center gap-4 text-xs text-secondary-600">
                  <span><strong className="text-secondary-900">{p.referrals}</strong> sent</span>
                  <span><strong className="text-secondary-900">{p.won}</strong> won</span>
                  <span><strong className="text-secondary-900">{money(p.commission_paid, p.currency || 'GBP')}</strong> received</span>
                  {canEdit && <Button size="sm" variant="ghost" onClick={() => setEditing(p)} leftIcon={<Pencil className="h-3.5 w-3.5" />}>Edit</Button>}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="rounded-xl border border-secondary-200 bg-white">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-secondary-200 px-5 py-3">
          <h2 className="text-sm font-semibold text-secondary-900">Referrals</h2>
          <select aria-label="Status" value={status} onChange={(e) => setStatus(e.target.value)} className="rounded-lg border border-secondary-200 px-3 py-1.5 text-sm">
            <option value="">All</option><option value="sent">Waiting for the partner</option><option value="accepted">Accepted</option>
            <option value="won">Won — invoice the commission</option><option value="commission_invoiced">Commission invoiced</option>
            <option value="commission_paid">Commission paid</option><option value="declined">Declined</option>
          </select>
        </div>
        {referrals === null ? <p className="p-6 text-sm text-secondary-500">Loading…</p> : referrals.length === 0 ? (
          <p className="p-8 text-center text-sm text-secondary-500">No referrals{status ? ' with this status' : ' yet'}. Use “Pass to partner” on a lead or deal.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead><tr className="border-b border-secondary-200 text-left text-xs text-secondary-500">
                <th className="px-5 py-2.5 font-medium">Partner</th><th className="px-5 py-2.5 font-medium">For</th>
                <th className="px-5 py-2.5 font-medium">Status</th><th className="px-5 py-2.5 text-right font-medium">Value</th>
                <th className="px-5 py-2.5 text-right font-medium">Commission</th><th className="px-5 py-2.5 font-medium">Sent</th></tr></thead>
              <tbody>
                {referrals.map((r) => (
                  <tr key={r.uuid} className="border-b border-secondary-100">
                    <td className="px-5 py-3 font-medium text-secondary-900">{r.partner_name}</td>
                    <td className="px-5 py-3">{r.lead_uuid
                      ? <Link className="text-primary-600 hover:underline" href={`/dashboard/leads/${r.lead_uuid}`}>{r.deal_name ?? 'Open the lead'}</Link>
                      : (r.deal_name ?? '—')}</td>
                    <td className="px-5 py-3"><span className={cn('rounded-full px-2 py-0.5 text-xs font-medium', STATUS_TONE[r.status])}>{r.status_label}</span></td>
                    <td className="px-5 py-3 text-right tabular-nums">{money(r.deal_value, r.currency || 'GBP')}</td>
                    <td className="px-5 py-3 text-right tabular-nums">{money(r.commission_amount, r.currency || 'GBP')}</td>
                    <td className="px-5 py-3 text-xs text-secondary-500">{dateOnly(r.sent_at ?? r.created_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {editing && <PartnerForm partner={editing === 'new' ? null : editing} onClose={() => setEditing(null)}
        onSaved={() => { setEditing(null); load(); }} />}
    </div>
  );
}

export default function PartnersPage() {
  return (
    <ProtectedPage module="crm_accounts" title="Partners">
      <PartnersContent />
    </ProtectedPage>
  );
}
