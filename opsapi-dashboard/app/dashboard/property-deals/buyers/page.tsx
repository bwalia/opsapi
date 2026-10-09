'use client';

/**
 * Property Deals — Buyers (SPEC §3.8 #5): buyer profiles on CRM contacts/companies, proof of
 * funds status and expiry, matches with the score breakdown, "send deal pack" (an approval),
 * and Companies House checks for company buyers.
 */
import React, { useState } from 'react';
import { Handshake, Plus, Building2, RefreshCw } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input, Modal, Select, Textarea } from '@/components/ui';
import { pdService, pdErrorText, type BuyerProfile, type CompanyCheck } from '@/services/property-deals.service';
import { crmService } from '@/services/crm.service';
import { PdPage, ErrorNote, Spinner, Empty, gbp, dateText, label } from '@/components/property-deals/ui';
import { usePdData, usePdMe } from '@/components/property-deals/usePd';
import MatchRow from '@/components/property-deals/MatchRow';
import { cn } from '@/lib/utils';

const POF: Record<string, 'default' | 'success' | 'warning' | 'error' | 'info'> = { none: 'default', requested: 'info', received: 'warning', verified: 'success', expired: 'error' };
const STRATEGIES = ['btl', 'brr', 'flip', 'hmo', 'blocks', 'semi_commercial', 'commercial', 'tenanted'];

export default function BuyersPage() {
  return (
    <PdPage module="buyers">
      <Buyers />
    </PdPage>
  );
}

function Buyers() {
  const { can } = usePdMe();
  const [q, setQ] = useState('');
  const list = usePdData(async () => (await pdService.buyerDirectory({ q })).data, [q]);
  const [sel, setSel] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const current = (list.data || []).find((b) => b.uuid === sel) || list.data?.[0];
  return (
    <div className="space-y-6">
      <PageHeader title="Buyers" description="Investors and cash buyers, what they want, and which homes fit them." icon={<Handshake className="h-6 w-6" />}
        actions={can('buyers', 'create') && <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setAdding(true)}>New buyer</Button>} />
      <div className="max-w-sm"><Input placeholder="Search buyers by name or email" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search buyers" /></div>
      <ErrorNote error={list.error} />
      {list.loading && !list.data ? <Spinner /> : !list.data?.length ? <Empty title="No buyers yet">Add a buyer profile to start matching homes.</Empty> : (
        <div className="grid gap-6 lg:grid-cols-[22rem_1fr]">
          <Card padding="none" data-tour="buyers-list">
            <ul className="max-h-[70vh] divide-y divide-secondary-100 overflow-y-auto" role="listbox" aria-label="Buyers">
              {list.data.map((b) => (
                <li key={b.uuid}>
                  <button type="button" role="option" aria-selected={current?.uuid === b.uuid} onClick={() => setSel(b.uuid)}
                    className={cn('w-full p-4 text-left text-sm hover:bg-secondary-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary-500', current?.uuid === b.uuid && 'bg-primary-500/5')}>
                    <div className="font-medium text-secondary-900">{b.name || label(b.entity_type)}</div>{b.email && <div className="text-xs text-secondary-500">{b.email}</div>}
                    <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-secondary-500">
                      <Badge size="sm" variant={POF[b.pof_status || 'none']}>POF {label(b.pof_status)}</Badge>
                      {b.price_max ? <span>up to {gbp(b.price_max)}</span> : null}
                      {b.pof_expires_on && <span>exp {dateText(b.pof_expires_on)}</span>}
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          </Card>
          {current && <Detail key={current.uuid} b={current} onChanged={list.refresh} />}
        </div>
      )}
      {adding && <NewBuyer onClose={() => setAdding(false)} onCreated={() => { setAdding(false); list.refresh(); }} />}
    </div>
  );
}

function Detail({ b, onChanged }: { b: BuyerProfile & { name?: string; email?: string }; onChanged: () => void }) {
  const { can } = usePdMe();
  const matches = usePdData(async () => (await pdService.buyerMatches(b.uuid)).data, [b.uuid]);
  const [check, setCheck] = useState<CompanyCheck | null>((b as { company_check?: CompanyCheck }).company_check || null);
  const [number, setNumber] = useState((b as { company_number?: string }).company_number || '');
  const [pof, setPof] = useState<{ status: string; expires: string }>({ status: b.pof_status || 'none', expires: b.pof_expires_on?.slice(0, 10) || '' });
  const isCompany = b.entity_type && b.entity_type !== 'person';
  return (
    <div className="space-y-6">
      <Card>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold text-secondary-900">{b.name || label(b.entity_type)}</h2>
            <p className="text-sm text-secondary-500">{label(b.entity_type)} · {label(b.funding_route)} · {b.price_min ? `${gbp(b.price_min)}–` : 'up to '}{gbp(b.price_max)}</p>
            <p className="mt-1 text-sm text-secondary-600">Strategies: {(b.strategies as string[] | undefined)?.map(label).join(', ') || '—'} · min yield {b.min_yield_pct ?? '—'}% · min discount {b.min_discount_pct ?? '—'}% · refurb {label(b.refurb_appetite)}</p>
            {(b.deal_breakers as string[] | undefined)?.length ? <p className="mt-1 text-sm text-error-600">Deal-breakers: {(b.deal_breakers as string[]).map(label).join(', ')}</p> : null}
          </div>
          {can('buyers', 'update') && (
            <div className="flex flex-wrap items-end gap-2">
              <Select label="Proof of funds" value={pof.status} onChange={(e) => setPof({ ...pof, status: e.target.value })}>
                {Object.keys(POF).map((s) => <option key={s} value={s}>{label(s)}</option>)}
              </Select>
              <Input label="Expires" type="date" value={pof.expires} onChange={(e) => setPof({ ...pof, expires: e.target.value })} />
              <Button size="sm" variant="outline" onClick={async () => {
                try { await pdService.updateBuyer(b.uuid, { pof_status: pof.status, pof_expires_on: pof.expires || null }); toast.success('Saved'); onChanged(); } catch (e) { toast.error(pdErrorText(e)); }
              }}>Save</Button>
            </div>
          )}
        </div>
      </Card>
      {isCompany && (
        <Card>
          <h3 className="flex items-center gap-2 font-semibold text-secondary-900"><Building2 className="h-4 w-4" aria-hidden /> Companies House</h3>
          <div className="mt-3 flex flex-wrap items-end gap-2">
            <Input label="Company number" value={number} onChange={(e) => setNumber(e.target.value)} />
            <Button variant="outline" disabled={!number} onClick={async () => {
              try { const r = (await pdService.companyCheck(b.uuid, number)).data; setCheck(r); toast.success('Checked'); } catch (e) { toast.error(pdErrorText(e)); }
            }}>Check now</Button>
          </div>
          {check && (
            <div className="mt-3 text-sm">
              <div className="font-medium text-secondary-900">{check.name} · {label(check.status)}</div>
              <div className="text-secondary-500">Directors: {check.officers?.map((o) => o.name).join('; ') || '—'} · checked {dateText(check.checked_at, true)}</div>
              {check.flags.length > 0 ? <div className="mt-1 text-warning-700">Flags: {check.flags.join(', ')}</div> : <div className="mt-1 text-success-700">No flags</div>}
            </div>
          )}
        </Card>
      )}
      <Card padding="none" data-tour="buyer-matches">
        <div className="flex items-center justify-between border-b border-secondary-200 p-4">
          <h3 className="font-semibold text-secondary-900">Matching homes</h3>
          <Button size="sm" variant="ghost" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={async () => { await pdService.recomputeMatches({ buyer_profile_uuid: b.uuid }); matches.refresh(); }}>Re-score</Button>
        </div>
        {!matches.data?.length ? <div className="p-6"><Empty title="No matches yet" /></div> : (
          <ul className="divide-y divide-secondary-100">{matches.data.map((m) => <MatchRow key={m.uuid} m={m} canSend={can('buyers', 'update')} onChanged={matches.refresh} showProperty />)}</ul>
        )}
      </Card>
    </div>
  );
}

function NewBuyer({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const [f, setF] = useState<Record<string, string>>({ entity_type: 'person', funding_route: 'cash' });
  const [strategies, setStrategies] = useState<string[]>(['btl']);
  const [busy, setBusy] = useState(false);
  const s = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => setF({ ...f, [k]: e.target.value });
  return (
    <Modal isOpen onClose={onClose} title="New buyer" description="Creates the CRM contact (or company) and the buyer profile on it." size="lg">
      <div className="grid gap-3 sm:grid-cols-2">
        <Select label="Buyer is" value={f.entity_type} onChange={s('entity_type')}>
          {['person', 'ltd_spv', 'overseas_company', 'pension_ssas_sipp', 'trust_family_office'].map((t) => <option key={t} value={t}>{label(t)}</option>)}
        </Select>
        <Input label={f.entity_type === 'person' ? 'Full name' : 'Company name'} value={f.name || ''} onChange={s('name')} />
        <Input label="Email" type="email" value={f.email || ''} onChange={s('email')} />
        <Select label="Funding" value={f.funding_route} onChange={s('funding_route')}>
          {['cash', 'mortgage', 'bridging', 'cash_then_refinance'].map((t) => <option key={t} value={t}>{label(t)}</option>)}
        </Select>
        <Input label="Budget from (£)" type="number" value={f.price_min || ''} onChange={s('price_min')} />
        <Input label="Budget to (£)" type="number" value={f.price_max || ''} onChange={s('price_max')} />
        <Input label="Min yield (%)" type="number" value={f.min_yield_pct || ''} onChange={s('min_yield_pct')} />
        <Select label="Refurb appetite" value={f.refurb_appetite || ''} onChange={s('refurb_appetite')}>
          <option value="">—</option>{['none', 'light', 'medium', 'heavy'].map((t) => <option key={t} value={t}>{label(t)}</option>)}
        </Select>
        <Input label="Area: town or postcode centre (lat,lng)" placeholder="53.96,-1.08" value={f.area || ''} onChange={s('area')} />
        <Input label="Area radius (miles)" type="number" value={f.miles || ''} onChange={s('miles')} />
        <fieldset className="sm:col-span-2">
          <legend className="text-sm font-medium text-secondary-700">Strategies</legend>
          <div className="mt-1 flex flex-wrap gap-2">
            {STRATEGIES.map((st) => (
              <label key={st} className="flex items-center gap-1.5 text-sm"><input type="checkbox" checked={strategies.includes(st)} onChange={(e) => setStrategies(e.target.checked ? [...strategies, st] : strategies.filter((x) => x !== st))} />{label(st)}</label>
            ))}
          </div>
        </fieldset>
        <Textarea className="sm:col-span-2" label="Deal-breakers (comma separated, e.g. short_lease, spray_foam)" rows={2} value={f.breakers || ''} onChange={s('breakers')} />
      </div>
      <div className="mt-5 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button isLoading={busy} disabled={!f.name} onClick={async () => {
          setBusy(true);
          try {
            let owner: Record<string, string>;
            if (f.entity_type === 'person') {
              const [first, ...rest] = f.name.trim().split(/\s+/);
              const c = await crmService.createContact({ first_name: first, last_name: rest.join(' ') || undefined, email: f.email || undefined });
              owner = { contact_uuid: (c as { uuid: string }).uuid };
            } else {
              const a = await crmService.createAccount({ name: f.name, email: f.email || undefined });
              owner = { account_uuid: (a as { uuid: string }).uuid };
            }
            const [lat, lng] = (f.area || '').split(',').map((x) => Number(x.trim()));
            await pdService.createBuyer({
              ...owner, entity_type: f.entity_type, funding_route: f.funding_route,
              price_min: f.price_min ? Number(f.price_min) : undefined, price_max: f.price_max ? Number(f.price_max) : undefined,
              min_yield_pct: f.min_yield_pct ? Number(f.min_yield_pct) : undefined, refurb_appetite: f.refurb_appetite || undefined,
              strategies, deal_breakers: (f.breakers || '').split(',').map((x) => x.trim()).filter(Boolean),
              areas: !Number.isNaN(lat) && !Number.isNaN(lng) && f.area ? [{ type: 'radius', lat, lng, miles: Number(f.miles || 10) }] : [],
            });
            toast.success('Buyer added — matches are being scored');
            onCreated();
          } catch (e) { toast.error(pdErrorText(e)); } finally { setBusy(false); }
        }}>Add buyer</Button>
      </div>
    </Modal>
  );
}
