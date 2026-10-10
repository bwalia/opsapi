'use client';

/**
 * Property Deals fields on the existing lead drawer (Prompt 2: extend, don't duplicate):
 * kind, situation, deadline, vulnerability flag + note, consent, Companies House links (the daily news
 * watch), how hot their last reply was, recent news + replies, and "Create deal".
 * Renders nothing when the plugin is off for the workspace or the user has no access.
 */
import React, { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { Building2, Search } from 'lucide-react';
import toast from 'react-hot-toast';
import { pdService, pdError, pdErrorText, type ChOfficer, type Lead } from '@/services/property-deals.service';
import { Button, Input, Select, Textarea } from '@/components/ui';
import { label } from './ui';
import LeadActivity, { TemperatureBadge } from './LeadActivity';

const KINDS = ['seller', 'buyer_investor', 'landlord', 'agent', 'solicitor', 'broker', 'agent_referral', 'other'];
const SITUATIONS = ['probate', 'broken_chain', 'divorce', 'relocation', 'care_fees', 'repossession_risk', 'tenanted', 'unmortgageable', 'other'];
const CONSENT = ['consent', 'contract', 'legitimate_interests', 'legal_obligation'];

export default function PropertyDealsLeadPanel({ leadUuid }: { leadUuid: string }) {
  const router = useRouter();
  const [lead, setLead] = useState<Lead | null>(null);
  const [hidden, setHidden] = useState(false);
  const [f, setF] = useState<Record<string, string | boolean>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [officers, setOfficers] = useState<ChOfficer[] | null>(null);

  useEffect(() => {
    let off = false;
    pdService.lead(leadUuid).then((r) => {
      if (off) return;
      setLead(r.data);
      const d = (r.data.details || {}) as Record<string, unknown>;
      setF({
        lead_kind: String(d.lead_kind || ''), situation: String(d.situation || ''), situation_note: String(d.situation_note || ''),
        deadline_date: d.deadline_date ? String(d.deadline_date).slice(0, 10) : '', vulnerability_flag: Boolean(d.vulnerability_flag),
        vulnerability_note: String(d.vulnerability_note || ''), consent_basis: String(d.consent_basis || ''),
        company_number: String(d.company_number || ''), ch_officer_id: String(d.ch_officer_id || ''),
      });
    }).catch((e) => { if ([403, 404].includes(pdError(e).status)) setHidden(true); });
    return () => { off = true; };
  }, [leadUuid]);

  if (hidden || !lead) return null;
  const details = (lead.details || {}) as Record<string, unknown>;
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => setF({ ...f, [k]: e.target.value });

  return (
    <section className="rounded-xl border border-secondary-200 p-4" aria-labelledby="pd-lead-title" data-tour="lead-panel">
      <h3 id="pd-lead-title" className="mb-3 flex flex-wrap items-center gap-2 font-semibold text-secondary-900">
        <Building2 className="h-4 w-4" aria-hidden /> Property Deals
        <TemperatureBadge temperature={details.temperature as string | undefined} score={details.hot_score as number | undefined} />
      </h3>
      {details.temperature === 'hot' && details.hot_reason ? (
        <p className="-mt-2 mb-3 text-xs text-error-700">{String(details.hot_reason)}</p>
      ) : null}
      <div className="grid gap-3 sm:grid-cols-2">
        <Select label="Kind" value={String(f.lead_kind)} onChange={set('lead_kind')}><option value="">—</option>{KINDS.map((k) => <option key={k} value={k}>{label(k)}</option>)}</Select>
        <Select label="Situation" value={String(f.situation)} onChange={set('situation')}><option value="">—</option>{SITUATIONS.map((k) => <option key={k} value={k}>{label(k)}</option>)}</Select>
        <Input label="Seller's deadline" type="date" value={String(f.deadline_date)} onChange={set('deadline_date')} />
        <Select label="Consent basis" value={String(f.consent_basis)} onChange={set('consent_basis')}><option value="">—</option>{CONSENT.map((k) => <option key={k} value={k}>{label(k)}</option>)}</Select>
        <Textarea className="sm:col-span-2" label="Situation note" rows={2} value={String(f.situation_note)} onChange={set('situation_note')} />
        <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" checked={Boolean(f.vulnerability_flag)} onChange={(e) => setF({ ...f, vulnerability_flag: e.target.checked })} /> Vulnerable customer (handle with extra care)</label>
        {f.vulnerability_flag && <Textarea className="sm:col-span-2" label="What we should know (factual)" rows={2} value={String(f.vulnerability_note)} onChange={set('vulnerability_note')} />}
        <Input label="Their company number (Companies House)" placeholder="01234567" value={String(f.company_number)} onChange={set('company_number')} />
        <div>
          <Input label="Companies House officer id" placeholder="Find by name →" value={String(f.ch_officer_id)} onChange={set('ch_officer_id')} />
          <button
            type="button"
            className="mt-1 inline-flex items-center gap-1 text-xs text-primary-600 hover:underline"
            onClick={async () => {
              const q = `${lead.first_name || ''} ${lead.last_name || ''}`.trim();
              if (q.length < 3) return toast.error('The lead needs a name to search');
              try { setOfficers((await pdService.chOfficers(q)).data); } catch (e) { toast.error(pdErrorText(e)); }
            }}
          >
            <Search className="h-3 w-3" aria-hidden /> Find {lead.first_name || 'them'} on Companies House
          </button>
        </div>
        {officers && (
          <ul className="divide-y divide-secondary-100 rounded-lg border border-secondary-200 text-sm sm:col-span-2" aria-label="Companies House officers">
            {officers.length === 0 && <li className="p-2 text-secondary-500">No match.</li>}
            {officers.map((o) => (
              <li key={o.officer_id} className="flex items-center justify-between gap-2 p-2">
                <span>
                  <span className="font-medium">{o.name}</span>
                  <span className="text-secondary-500">{o.born ? ` · born ${o.born}` : ''}{o.address ? ` · ${o.address}` : ''}{o.appointments ? ` · ${o.appointments} appointment(s)` : ''}</span>
                </span>
                <Button size="sm" variant="ghost" onClick={() => { setF({ ...f, ch_officer_id: o.officer_id }); setOfficers(null); }}>Use</Button>
              </li>
            ))}
          </ul>
        )}
      </div>
      <div className="mt-3 flex flex-wrap justify-end gap-2">
        <Button size="sm" variant="outline" isLoading={busy === 'save'} onClick={async () => {
          setBusy('save');
          try {
            const body: Record<string, unknown> = { vulnerability_flag: Boolean(f.vulnerability_flag) };
            for (const k of ['lead_kind', 'situation', 'situation_note', 'deadline_date', 'vulnerability_note', 'consent_basis', 'company_number', 'ch_officer_id']) if (f[k]) body[k] = f[k];
            await pdService.saveLeadDetails(leadUuid, body as never);
            toast.success('Saved');
          } catch (e) { toast.error(pdErrorText(e)); } finally { setBusy(null); }
        }}>Save deal fields</Button>
        {lead.deal_uuid ? (
          <Button size="sm" onClick={() => router.push(`/dashboard/property-deals/deals/${lead.deal_uuid}`)}>Open deal</Button>
        ) : (
          <Button size="sm" isLoading={busy === 'deal'} onClick={async () => {
            setBusy('deal');
            try {
              const d = (await pdService.createDeal({ lead_uuid: leadUuid, deal_type: f.lead_kind === 'buyer_investor' ? 'sell' : 'buy' })).data;
              toast.success('Deal created');
              router.push(`/dashboard/property-deals/deals/${d.uuid}`);
            } catch (e) { toast.error(pdErrorText(e)); } finally { setBusy(null); }
          }}>Create deal</Button>
        )}
      </div>
      <LeadActivity leadUuid={leadUuid} />
    </section>
  );
}
