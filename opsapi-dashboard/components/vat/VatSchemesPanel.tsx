'use client';

/**
 * Less common VAT schemes (docs/plans/VAT_MTD.md, phase 10), under the VAT return:
 *   - Partial exemption: the annual adjustment (Notice 706)
 *   - Capital goods scheme items and their interval adjustments (Notice 706/2)
 *   - VAT group: invite member workspaces, or join a group (workspace VAT only)
 *   - EC Sales List for Northern Ireland goods sold to EU customers (workspace VAT only)
 * Figures come from the VAT engine (lapis/lib/vat-schemes.lua), never the AI.
 */

import React, { useCallback, useEffect, useState } from 'react';
import { ChevronDown, ChevronRight, Loader2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { extractApiError, formatCurrency } from '@/lib/utils';
import vatService, {
  type CapitalKind,
  type VatAnnualAdjustment,
  type VatCapitalItem,
  type VatEcSalesList,
  type VatGroupInfo,
  type VatRegistration,
} from '@/services/vat.service';

const gbp = (n?: number | null) => (n === null || n === undefined ? '—' : formatCurrency(Number(n), 'GBP', 'en-GB'));
const btn = 'inline-flex items-center gap-2 rounded-lg px-3 py-1.5 text-sm font-medium transition disabled:opacity-50';
const primary = `${btn} bg-primary-600 text-white hover:bg-primary-700`;
const ghost = `${btn} border border-secondary-300 text-secondary-700 hover:bg-secondary-50`;
const input = 'w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm';

const KINDS: Array<{ key: CapitalKind; label: string }> = [
  { key: 'building', label: 'Building (£250,000+)' },
  { key: 'land', label: 'Land (£250,000+)' },
  { key: 'civil_engineering', label: 'Civil engineering work (£250,000+)' },
  { key: 'refurbishment', label: 'Refurbishment / fitting out (£250,000+)' },
  { key: 'ship', label: 'Ship or boat (£50,000+)' },
  { key: 'aircraft', label: 'Aircraft (£50,000+)' },
];

function Section({ title, hint, children, testId }: { title: string; hint: string; children: React.ReactNode;
  testId: string }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="border-t border-secondary-100 py-3 first:border-t-0" data-testid={testId}>
      <button type="button" className="flex w-full items-start gap-2 text-left" onClick={() => setOpen(!open)}>
        {open ? <ChevronDown className="mt-0.5 h-4 w-4" /> : <ChevronRight className="mt-0.5 h-4 w-4" />}
        <span>
          <span className="block text-sm font-medium text-secondary-900">{title}</span>
          <span className="block text-xs text-secondary-500">{hint}</span>
        </span>
      </button>
      {open && <div className="mt-3 pl-6">{children}</div>}
    </div>
  );
}

function PartialExemption({ period, onChanged }: { period: { start: string; end: string } | null;
  onChanged: () => void }) {
  const y = new Date().getFullYear();
  const [start, setStart] = useState(`${y - 1}-04-01`);
  const [end, setEnd] = useState(`${y}-03-31`);
  const [res, setRes] = useState<VatAnnualAdjustment | null>(null);
  const [busy, setBusy] = useState(false);
  const work = async () => {
    setBusy(true);
    try { setRes(await vatService.peAnnual(start, end)); } catch (e) { toast.error(extractApiError(e, 'Could not work it out')); }
    finally { setBusy(false); }
  };
  const apply = async () => {
    if (!period) return;
    try {
      await vatService.peAnnualApply({ year_start: start, year_end: end, period_start: period.start, period_end: period.end });
      toast.success('Added to the return for ' + period.start + ' to ' + period.end);
      onChanged();
    } catch (e) { toast.error(extractApiError(e, 'Could not add it')); }
  };
  return (
    <div className="space-y-3 text-sm">
      <div className="grid gap-2 sm:grid-cols-3">
        <label>Year from<input type="date" className={input} value={start} onChange={(e) => setStart(e.target.value)} /></label>
        <label>to<input type="date" className={input} value={end} onChange={(e) => setEnd(e.target.value)} /></label>
        <div className="flex items-end"><button type="button" className={primary} onClick={work} disabled={busy}>
          {busy && <Loader2 className="h-4 w-4 animate-spin" />} Work out the adjustment</button></div>
      </div>
      {res && (
        <div className="rounded-lg border border-secondary-200 bg-surface p-3">
          <p>The year&apos;s recovery rate is <strong>{res.annual_pct}%</strong>
            {res.de_minimis ? ' — and you are under the de minimis limits, so all input VAT is recoverable.' : '.'}</p>
          <p className="mt-1">Recoverable for the year {gbp(res.should_recover)} · recovered on your returns {gbp(res.claimed)}
            {' '}→ <strong>{res.direction === 'claim' ? `claim ${gbp(res.adjustment)} more`
              : res.direction === 'repay' ? `pay back ${gbp(-res.adjustment)}` : 'no adjustment'}</strong></p>
          <p className="mt-1 text-xs text-secondary-500">{res.note}</p>
          {res.warnings.map((w) => <p key={w} className="mt-1 text-xs text-amber-700">{w}</p>)}
          {res.direction !== 'none' && period && (
            <button type="button" className={`${ghost} mt-2`} onClick={apply}>
              Put it on the {period.start} to {period.end} return</button>
          )}
        </div>
      )}
    </div>
  );
}

function CapitalGoods({ period, onChanged }: { period: { start: string; end: string } | null; onChanged: () => void }) {
  const [items, setItems] = useState<VatCapitalItem[]>([]);
  const [form, setForm] = useState({ description: '', kind: 'building' as CapitalKind, cost_ex_vat: '', input_vat: '',
    original_use_pct: '100', short_lease: false });
  const [useFor, setUseFor] = useState<Record<string, { interval: string; use: string }>>({});
  const load = useCallback(() => { vatService.capitalItems().then(setItems).catch(() => undefined); }, []);
  useEffect(load, [load]);
  const add = async () => {
    try {
      await vatService.addCapitalItem({ description: form.description, kind: form.kind, cost_ex_vat: Number(form.cost_ex_vat),
        input_vat: Number(form.input_vat), original_use_pct: Number(form.original_use_pct), short_lease: form.short_lease });
      setForm({ ...form, description: '', cost_ex_vat: '', input_vat: '' });
      load();
    } catch (e) { toast.error(extractApiError(e, 'Could not add the item')); }
  };
  const adjust = async (it: VatCapitalItem) => {
    const u = useFor[it.uuid];
    if (!period || !u) return;
    try {
      await vatService.adjustCapitalItem(it.uuid, { interval_no: Number(u.interval), use_pct: Number(u.use),
        period_start: period.start, period_end: period.end });
      toast.success('Adjustment added to the return'); load(); onChanged();
    } catch (e) { toast.error(extractApiError(e, 'Could not add the adjustment')); }
  };
  return (
    <div className="space-y-3 text-sm">
      {items.length > 0 && (
        <div className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
          {items.map((it) => {
            const next = (it.adjustments.reduce((m, a) => Math.max(m, Number(a.interval_no) || 1), 1)) + 1;
            const u = useFor[it.uuid] || { interval: String(next), use: '' };
            return (
              <div key={it.uuid} className="space-y-2 p-3">
                <p className="font-medium">{it.description} <span className="text-xs text-secondary-500">· {it.kind_label}
                  · input VAT {gbp(it.input_vat)} · {it.intervals} intervals · first use {it.original_use_pct}% taxable
                  {it.disposed_on ? ` · sold ${it.disposed_on}` : ''}</span></p>
                {it.adjustments.map((a) => (
                  <p key={a.uuid} className="text-xs text-secondary-600">{a.interval_no ? `Interval ${a.interval_no}` : 'Sale'}:
                    {' '}{gbp(a.vat)} on the {a.period_start} to {a.period_end} return</p>
                ))}
                {!it.disposed_on && next <= it.intervals && period && (
                  <div className="flex flex-wrap items-end gap-2">
                    <label className="w-28 text-xs">Interval<input className={input} value={u.interval}
                      onChange={(e) => setUseFor({ ...useFor, [it.uuid]: { ...u, interval: e.target.value } })} /></label>
                    <label className="w-36 text-xs">Taxable use %<input className={input} value={u.use}
                      onChange={(e) => setUseFor({ ...useFor, [it.uuid]: { ...u, use: e.target.value } })} /></label>
                    <button type="button" className={ghost} disabled={u.use === ''} onClick={() => adjust(it)}>
                      Adjust on this return</button>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
      <div className="grid gap-2 sm:grid-cols-2">
        <label>What is it<input className={input} value={form.description}
          onChange={(e) => setForm({ ...form, description: e.target.value })} /></label>
        <label>Kind<select className={input} value={form.kind}
          onChange={(e) => setForm({ ...form, kind: e.target.value as CapitalKind })}>
          {KINDS.map((k) => <option key={k.key} value={k.key}>{k.label}</option>)}</select></label>
        <label>Cost excluding VAT (£)<input className={input} inputMode="decimal" value={form.cost_ex_vat}
          onChange={(e) => setForm({ ...form, cost_ex_vat: e.target.value })} /></label>
        <label>VAT paid (£)<input className={input} inputMode="decimal" value={form.input_vat}
          onChange={(e) => setForm({ ...form, input_vat: e.target.value })} /></label>
        <label>Taxable use when first used (%)<input className={input} value={form.original_use_pct}
          onChange={(e) => setForm({ ...form, original_use_pct: e.target.value })} /></label>
        <label className="flex items-center gap-2 pt-5"><input type="checkbox" checked={form.short_lease}
          onChange={(e) => setForm({ ...form, short_lease: e.target.checked })} /> Lease under 10 years (5 intervals)</label>
      </div>
      <button type="button" className={primary} onClick={add} disabled={!form.description || !form.cost_ex_vat}>Add item</button>
    </div>
  );
}

function VatGroup() {
  const [g, setG] = useState<VatGroupInfo | null>(null);
  const [name, setName] = useState('');
  const [code, setCode] = useState('');
  const load = useCallback(() => { vatService.group().then(setG).catch(() => undefined); }, []);
  useEffect(load, [load]);
  if (g?.member_of) {
    return <p className="text-sm">This workspace is in the VAT group <strong>{g.member_of.group_name}</strong>
      {g.member_of.group_vrn ? ` (VAT ${g.member_of.group_vrn})` : ''}. The group&apos;s representative files one return
      for every member.</p>;
  }
  return (
    <div className="space-y-3 text-sm">
      <p className="text-xs text-secondary-500">This workspace is the representative member: its return includes every
        member&apos;s sales and purchases, and supplies between members are left out. Register the group with HMRC first
        (form VAT50/51).</p>
      {(g?.members || []).map((m) => (
        <div key={m.uuid} className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-secondary-200 p-2">
          <span>{m.member_name} · {m.status === 'active' ? 'joined' : <>waiting — give them this code:{' '}
            <code className="rounded bg-secondary-100 px-1">{m.invite_code}</code></>}</span>
          <button type="button" className="text-xs text-red-700 underline" onClick={() =>
            vatService.removeGroupMember(m.uuid).then(load).catch((e) => toast.error(extractApiError(e, 'Failed')))}>
            Remove</button>
        </div>
      ))}
      <div className="flex flex-wrap items-end gap-2">
        <label className="min-w-[14rem] flex-1">Member company name (as on its invoices)
          <input className={input} value={name} onChange={(e) => setName(e.target.value)} /></label>
        <button type="button" className={primary} disabled={!name} onClick={() => vatService.inviteGroupMember(name)
          .then(() => { setName(''); load(); }).catch((e) => toast.error(extractApiError(e, 'Failed')))}>Invite</button>
      </div>
      <div className="flex flex-wrap items-end gap-2 border-t border-secondary-100 pt-3">
        <label className="min-w-[14rem] flex-1">Or join another group with its code
          <input className={input} value={code} onChange={(e) => setCode(e.target.value.trim())} /></label>
        <button type="button" className={ghost} disabled={code.length !== 32} onClick={() => vatService.joinGroup(code)
          .then(() => { toast.success('Joined the VAT group'); setCode(''); load(); })
          .catch((e) => toast.error(extractApiError(e, 'Could not join')))}>Join</button>
      </div>
    </div>
  );
}

function EcSales({ period }: { period: { start: string; end: string } | null }) {
  const [esl, setEsl] = useState<VatEcSalesList | null>(null);
  useEffect(() => {
    if (period) vatService.ecSalesList(period.start, period.end).then(setEsl).catch(() => setEsl(null));
  }, [period]);
  if (!period) return null;
  if (!esl) return <p className="text-sm text-secondary-500">Loading…</p>;
  return (
    <div className="space-y-2 text-sm">
      {esl.rows.length === 0 ? <p>No Northern Ireland goods sold to EU customers in this period.</p> : (
        <table className="w-full text-xs">
          <thead className="text-secondary-500"><tr><th className="text-left">Country</th><th className="text-left">Customer VAT number</th>
            <th className="text-right">Value (£)</th><th className="text-right">Indicator</th></tr></thead>
          <tbody>{esl.rows.map((r) => (
            <tr key={r.country + r.vat_number + r.indicator}><td>{r.country}</td><td>{r.vat_number}</td>
              <td className="text-right tabular-nums">{r.value.toLocaleString('en-GB')}</td>
              <td className="text-right">{r.indicator}</td></tr>))}</tbody>
        </table>
      )}
      {esl.notes.map((n) => <p key={n} className="text-xs text-secondary-500">{n}</p>)}
      {esl.rows.length > 0 && (
        <button type="button" className={ghost} onClick={() => vatService.downloadEcSalesList(period.start, period.end)
          .catch((e) => toast.error(extractApiError(e, 'Download failed')))}>Download CSV</button>
      )}
    </div>
  );
}

export default function VatSchemesPanel({ reg, workspace, period, onChanged }: {
  reg: VatRegistration; workspace: boolean; period: { start: string; end: string } | null; onChanged: () => void;
}) {
  return (
    <div className="rounded-2xl border border-secondary-200 bg-surface-elevated p-4 sm:p-6" data-testid="vat-schemes">
      <p className="font-semibold text-secondary-900">Other VAT schemes</p>
      <p className="text-xs text-secondary-500">Only if they apply to you. The margin scheme for second-hand goods is a VAT
        code: code that stock &quot;Margin scheme&quot;.</p>
      <div className="mt-2">
        {reg.partially_exempt && (
          <Section testId="vat-pe" title="Partial exemption: the annual adjustment"
            hint="At the end of your VAT year, recover VAT on the whole year's figures.">
            <PartialExemption period={period} onChanged={onChanged} />
          </Section>
        )}
        <Section testId="vat-cgs" title="Capital goods scheme"
          hint="Property costing £250,000+ or a ship or aircraft costing £50,000+: adjust the VAT as its use changes.">
          <CapitalGoods period={period} onChanged={onChanged} />
        </Section>
        {workspace && (
          <Section testId="vat-group" title="VAT group" hint="Companies under common control filing one VAT return.">
            <VatGroup />
          </Section>
        )}
        {workspace && (
          <Section testId="vat-esl" title="EC Sales List (Northern Ireland)"
            hint="Goods sold from Northern Ireland to VAT-registered customers in the EU.">
            <EcSales period={period} />
          </Section>
        )}
      </div>
    </div>
  );
}
