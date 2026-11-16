'use client';

/**
 * VAT (docs/plans/VAT_MTD.md, phase 5): one page, top to bottom —
 *   1. Your VAT registration
 *   2. Code your VAT (rules, your past decisions, then AI) with live progress
 *   3. Check these lines (the AI's flagged lines, with reasons; change, accept or add a receipt)
 *   4. Your VAT return (9 boxes in plain English; click a box to see its lines)
 *   5. File with HMRC (connect for VAT, pick HMRC's open period, declare, file; receipt;
 *      our figures next to HMRC's copy)
 *   6. Other VAT schemes (partial exemption annual adjustment, capital goods, VAT group,
 *      EC Sales List) — components/vat/VatSchemesPanel.tsx
 *   7. Past returns
 * The figures come from our VAT engine (lapis/lib/vat-return.lua), never the AI.
 */

import React, { Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { CheckCircle2, FileCheck2, Loader2, Receipt, RefreshCw, Sparkles, Upload } from 'lucide-react';
import toast from 'react-hot-toast';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { confirmDialog } from '@/components/ui';
import VatSchemesPanel from '@/components/vat/VatSchemesPanel';
import { extractApiError, formatCurrency } from '@/lib/utils';
import vatService, {
  BOX_LABELS,
  setVatClient,
  setVatScope,
  type Boxes,
  type VatAccountant,
  type VatCode,
  type VatObligation,
  type VatRegistration,
  type VatReturnRow,
  type VatReviewLine,
  type VatScheme,
  type VatReport,
  type VatStatus,
  type VatThreshold,
} from '@/services/vat.service';

const gbp = (n?: number | null) => (n === null || n === undefined ? '—' : formatCurrency(Number(n), 'GBP', 'en-GB'));
const pounds = (n?: number | null) => (n === null || n === undefined ? '—'
  : '£' + Math.trunc(Number(n)).toLocaleString('en-GB'));

const card = 'rounded-2xl border border-secondary-200 bg-surface-elevated p-4 sm:p-6';
const btn = 'inline-flex items-center gap-2 rounded-lg px-3.5 py-2 text-sm font-medium transition disabled:opacity-50';
const primary = `${btn} bg-primary-600 text-white hover:bg-primary-700`;
const ghost = `${btn} border border-secondary-300 text-secondary-700 hover:bg-secondary-50`;
const input = 'w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm';

// The VAT periods for a stagger, most recent first (quarters end Mar/Jun/Sep/Dec for
// quarterly_mar, Apr/Jul/Oct/Jan for quarterly_apr, May/Aug/Nov/Feb for quarterly_may).
function periodsFor(stagger: string, count = 8): Array<{ start: string; end: string; label: string }> {
  const iso = (d: Date) => d.toISOString().slice(0, 10);
  const out: Array<{ start: string; end: string; label: string }> = [];
  const now = new Date();
  const monthly = stagger === 'monthly';
  const len = monthly ? 1 : stagger === 'annual' ? 12 : 3;
  const offset = stagger === 'quarterly_apr' ? 1 : stagger === 'quarterly_may' ? 2 : 0;
  // Latest period end at or before the end of last month.
  let endMonth = now.getUTCMonth() - 1; // 0-based month index
  let year = now.getUTCFullYear();
  if (endMonth < 0) { endMonth += 12; year -= 1; }
  if (!monthly) {
    while (((endMonth - 2 - offset) % len + len) % len !== 0) {
      endMonth -= 1;
      if (endMonth < 0) { endMonth += 12; year -= 1; }
    }
  }
  for (let i = 0; i < count; i++) {
    const end = new Date(Date.UTC(year, endMonth + 1, 0));
    const start = new Date(Date.UTC(year, endMonth - len + 1, 1));
    const fmt = (d: Date) => d.toLocaleDateString('en-GB', { month: 'short', year: 'numeric', timeZone: 'UTC' });
    out.push({ start: iso(start), end: iso(end), label: len === 1 ? fmt(end) : `${fmt(start)} – ${fmt(end)}` });
    endMonth -= len;
    while (endMonth < 0) { endMonth += 12; year -= 1; }
  }
  return out;
}

function Registration({ reg, schemes, onSaved }: {
  reg: VatRegistration | null; schemes: Array<{ key: VatScheme; label: string }>; onSaved: (r: VatRegistration) => void;
}) {
  const [editing, setEditing] = useState(!reg);
  const [form, setForm] = useState<Partial<VatRegistration>>(reg || { scheme: 'standard', stagger: 'quarterly_mar' });
  const [saving, setSaving] = useState(false);
  useEffect(() => { if (reg) { setForm(reg); setEditing(false); } }, [reg]);
  const set = (k: keyof VatRegistration, v: unknown) => setForm((f) => ({ ...f, [k]: v }));
  const save = async () => {
    setSaving(true);
    try {
      const r = await vatService.saveRegistration(form);
      onSaved(r);
      toast.success('VAT registration saved');
      setEditing(false);
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save'));
    } finally {
      setSaving(false);
    }
  };
  if (reg && !editing) {
    return (
      <div className={card}>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-secondary-500">Your VAT registration</p>
            <p className="mt-1 text-lg font-semibold text-secondary-900">{reg.business_name || 'Your business'}</p>
            <p className="text-sm text-secondary-600">
              VAT number GB {reg.vrn} · {reg.scheme_label || reg.scheme}
              {reg.scheme === 'flat_rate' && reg.flat_rate_pct ? ` (${reg.flat_rate_pct}%)` : ''}
              {reg.partially_exempt ? ` · partially exempt (${reg.recovery_pct}% recovered)` : ''}
            </p>
          </div>
          <button type="button" className={ghost} onClick={() => setEditing(true)}>Change</button>
        </div>
      </div>
    );
  }
  return (
    <div className={card}>
      <p className="font-semibold text-secondary-900">Your VAT registration</p>
      <p className="mt-1 text-sm text-secondary-600">Your VAT number is on your VAT registration certificate.</p>
      <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2">
        <label className="text-sm">VAT number
          <input className={input} placeholder="GB 123 4567 82" value={form.vrn || ''}
            onChange={(e) => set('vrn', e.target.value)} />
        </label>
        <label className="text-sm">Business name
          <input className={input} value={form.business_name || ''} onChange={(e) => set('business_name', e.target.value)} />
        </label>
        <label className="text-sm sm:col-span-2">Business address (shown on VAT invoices)
          <input className={input} value={form.business_address || ''}
            onChange={(e) => set('business_address', e.target.value)} />
        </label>
        <label className="text-sm">Sales on the VAT return come from
          <select className={input} value={form.sales_from || 'auto'} onChange={(e) => set('sales_from', e.target.value)}>
            <option value="auto">Invoices if you issue them here, otherwise the bank</option>
            <option value="invoices">The invoices you issue here</option>
            <option value="bank">Money received in the bank</option>
          </select>
        </label>
        <label className="text-sm">VAT scheme
          <select className={input} value={form.scheme} onChange={(e) => set('scheme', e.target.value)}>
            {schemes.map((s) => <option key={s.key} value={s.key}>{s.label}</option>)}
          </select>
        </label>
        <label className="text-sm">Your VAT periods
          <select className={input} value={form.stagger} onChange={(e) => set('stagger', e.target.value)}>
            <option value="quarterly_mar">Quarters ending Mar, Jun, Sep, Dec</option>
            <option value="quarterly_apr">Quarters ending Apr, Jul, Oct, Jan</option>
            <option value="quarterly_may">Quarters ending May, Aug, Nov, Feb</option>
            <option value="monthly">Monthly</option>
            <option value="annual">Yearly (annual accounting)</option>
          </select>
        </label>
        {form.scheme === 'flat_rate' && (
          <>
            <label className="text-sm">Your flat rate %
              <input className={input} type="number" step="0.5" value={form.flat_rate_pct ?? ''}
                onChange={(e) => set('flat_rate_pct', e.target.value)} />
            </label>
            <div className="flex flex-col justify-end gap-1 text-sm">
              <label><input type="checkbox" checked={!!form.flat_rate_first_year}
                onChange={(e) => set('flat_rate_first_year', e.target.checked)} /> First year of VAT registration</label>
              <label><input type="checkbox" checked={!!form.limited_cost_trader}
                onChange={(e) => set('limited_cost_trader', e.target.checked)} /> Limited-cost trader (16.5%)</label>
            </div>
          </>
        )}
        <div className="flex flex-col justify-end gap-1 text-sm">
          <label><input type="checkbox" checked={!!form.partially_exempt}
            onChange={(e) => set('partially_exempt', e.target.checked)} /> Partly exempt (you make exempt sales)</label>
        </div>
        {form.partially_exempt && (
          <label className="text-sm">Share of VAT you can recover (%)
            <input className={input} type="number" value={form.recovery_pct ?? ''}
              onChange={(e) => set('recovery_pct', e.target.value)} />
          </label>
        )}
      </div>
      <div className="mt-4 flex gap-2">
        <button type="button" className={primary} onClick={save} disabled={saving}>
          {saving && <Loader2 className="h-4 w-4 animate-spin" />} Save
        </button>
        {reg && <button type="button" className={ghost} onClick={() => setEditing(false)}>Cancel</button>}
      </div>
    </div>
  );
}

function CodeVat({ status, onStart, starting }: { status: VatStatus | null; onStart: () => void; starting: boolean }) {
  if (!status) return null;
  const done = status.total - status.uncoded;
  const pct = status.total ? Math.round((done / status.total) * 100) : 0;
  return (
    <div className={card}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="font-semibold text-secondary-900">Code your VAT</p>
          <p className="mt-1 text-sm text-secondary-600">
            Every bank line needs a VAT treatment. We use your rules first, then what you decided before, then AI.
          </p>
        </div>
        <button type="button" className={primary} onClick={onStart} disabled={starting || status.running || status.uncoded === 0}>
          {status.running || starting ? <Loader2 className="h-4 w-4 animate-spin" /> : <Sparkles className="h-4 w-4" />}
          {status.running ? 'Coding…' : 'Code with AI'}
        </button>
      </div>
      <div className="mt-4 h-2 overflow-hidden rounded-full bg-secondary-100">
        <div className="h-full bg-primary-500 transition-all" style={{ width: `${pct}%` }} />
      </div>
      <div className="mt-3 grid grid-cols-2 gap-2 text-sm sm:grid-cols-5">
        {[
          ['Lines', status.total], ['By your rules', status.by_rule], ['By AI', status.by_ai],
          ['By you', status.by_you], ['Still to code', status.uncoded],
        ].map(([l, v]) => (
          <div key={l as string} className="rounded-lg border border-secondary-200 bg-surface p-2">
            <p className="text-xs text-secondary-500">{l}</p>
            <p className="text-base font-semibold tabular-nums text-secondary-900">{v}</p>
          </div>
        ))}
      </div>
    </div>
  );
}

function CheckLines({ lines, codes, onChanged }: { lines: VatReviewLine[]; codes: VatCode[]; onChanged: () => void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const [receiptFor, setReceiptFor] = useState<string | null>(null);
  const decide = async (l: VatReviewLine, code: string) => {
    setBusy(l.uuid);
    try {
      const r = await vatService.setLineVat(l.uuid, { vat_code: code,
        reclaimable_pct: code === l.vat_code && l.vat_reclaimable_pct !== null ? Number(l.vat_reclaimable_pct) : undefined });
      if (r?.learned_rule) {
        const label = codes.find((c) => c.code === r.learned_rule!.vat_code)?.label || r.learned_rule.vat_code;
        toast.success(`We'll now treat ${r.learned_rule.match_value} as ${label}.`);
      }
      onChanged();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save'));
    } finally {
      setBusy(null);
    }
  };
  const upload = async (file: File) => {
    if (!receiptFor) return;
    setBusy(receiptFor);
    try {
      await vatService.readReceipt(receiptFor, file);
      toast.success('Read from the receipt');
      onChanged();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not read the receipt'));
    } finally {
      setBusy(null);
      setReceiptFor(null);
    }
  };
  if (lines.length === 0) return null;
  return (
    <div className={card} data-testid="vat-check-lines">
      <p className="font-semibold text-secondary-900">Check these lines ({lines.length})</p>
      <p className="mt-1 text-sm text-secondary-600">The AI wasn&apos;t sure, or these need a receipt or a decision only you can make.</p>
      <input ref={fileRef} type="file" accept="image/*,application/pdf" className="hidden"
        onChange={(e) => { const f = e.target.files?.[0]; if (f) upload(f); e.target.value = ''; }} />
      <div className="mt-3 divide-y divide-secondary-100">
        {lines.map((l) => (
          <div key={l.uuid} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center">
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium text-secondary-900">{l.description}</p>
              <p className="text-xs text-secondary-500">
                {l.transaction_date} · {l.transaction_type === 'CREDIT' ? 'money in' : 'money out'} {gbp(Math.abs(l.amount))}
                {l.vat_reason ? ` · ${l.vat_reason}` : ''}
              </p>
              <ul className="mt-1 space-y-0.5">
                {l.vat_review_reasons.map((r) => (
                  <li key={r} className="text-xs text-amber-800">• {r}</li>
                ))}
              </ul>
            </div>
            <div className="flex shrink-0 flex-wrap items-center gap-2">
              <select className="rounded-lg border border-secondary-300 bg-surface px-2 py-1.5 text-sm" value={l.vat_code || ''}
                disabled={busy === l.uuid} onChange={(e) => decide(l, e.target.value)} aria-label="VAT treatment">
                {!l.vat_code && <option value="">Choose…</option>}
                {codes.map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}
              </select>
              {l.vat_code && (
                <button type="button" className={ghost} disabled={busy === l.uuid} onClick={() => decide(l, l.vat_code!)}>
                  {busy === l.uuid ? <Loader2 className="h-4 w-4 animate-spin" /> : <CheckCircle2 className="h-4 w-4" />}
                  Looks right
                </button>
              )}
              {l.transaction_type === 'DEBIT' && (
                <button type="button" className={ghost} disabled={busy === l.uuid}
                  onClick={() => { setReceiptFor(l.uuid); fileRef.current?.click(); }}>
                  <Upload className="h-4 w-4" /> Receipt
                </button>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function BoxesGrid({ boxes, onBox }: { boxes: Boxes; onBox?: (k: keyof Boxes) => void }) {
  return (
    <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
      {BOX_LABELS.map((b) => (
        <button key={b.key} type="button" onClick={() => onBox?.(b.key)}
          className={`rounded-lg border p-3 text-left ${b.key === 'box5' ? 'border-primary-300 bg-primary-50/40'
            : 'border-secondary-200 bg-surface'} hover:border-primary-300`}>
          <p className="text-xs text-secondary-500">Box {b.n} · {b.label}</p>
          <p className="mt-1 text-lg font-semibold tabular-nums text-secondary-900">
            {b.whole ? pounds(boxes[b.key]) : gbp(boxes[b.key])}
          </p>
        </button>
      ))}
    </div>
  );
}

function ThresholdCard({ t }: { t: VatThreshold }) {
  const colour = t.status === 'over' ? 'border-red-200 bg-red-50 text-red-900'
    : t.status === 'approaching' ? 'border-amber-200 bg-amber-50 text-amber-900' : 'border-secondary-200 bg-surface';
  return (
    <div className={`rounded-2xl border p-4 sm:p-6 ${colour}`} data-testid="vat-threshold">
      <p className="font-semibold">Do you need to register for VAT?</p>
      <p className="mt-1 text-sm">
        Your taxable turnover for the 12 months to {t.as_of} is <strong>{gbp(t.turnover)}</strong> — {t.pct}% of the
        {' '}{gbp(t.threshold)} registration threshold.
      </p>
      {t.status === 'over' && t.register_by && (
        <p className="mt-2 text-sm font-medium">You went over at the end of {t.crossed_month}. You must register with HMRC
          by {t.register_by}.</p>
      )}
      {t.status === 'approaching' && (
        <p className="mt-2 text-sm">You&apos;re getting close. You must register within 30 days of going over.</p>
      )}
      <div className="mt-3 h-2 overflow-hidden rounded-full bg-white/60">
        <div className={`h-full ${t.status === 'over' ? 'bg-red-500' : t.status === 'approaching' ? 'bg-amber-500'
          : 'bg-primary-500'}`} style={{ width: `${Math.min(100, t.pct)}%` }} />
      </div>
    </div>
  );
}

function ReportCard({ report }: { report: VatReport }) {
  return (
    <div className="mt-4 space-y-3" data-testid="vat-report">
      <div className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
        {[['VAT on sales', report.totals.output_vat], ['VAT on purchases', report.totals.input_vat],
          ['Reclaimable', report.totals.reclaimable], ['Can\'t be reclaimed', report.totals.blocked]].map(([l, v]) => (
          <div key={l as string} className="rounded-lg border border-secondary-200 bg-surface p-2">
            <p className="text-xs text-secondary-500">{l}</p>
            <p className="font-semibold tabular-nums">{gbp(v as number)}</p>
          </div>
        ))}
      </div>
      <div className="overflow-x-auto rounded-lg border border-secondary-200">
        <table className="w-full text-xs">
          <thead className="bg-secondary-50 text-secondary-500">
            <tr><th className="px-2 py-1.5 text-left">VAT code</th><th className="px-2 py-1.5 text-right">Lines</th>
              <th className="px-2 py-1.5 text-right">Sales (net)</th><th className="px-2 py-1.5 text-right">Purchases (net)</th>
              <th className="px-2 py-1.5 text-right">Reclaimable</th></tr>
          </thead>
          <tbody className="divide-y divide-secondary-100">
            {report.by_code.map((c) => (
              <tr key={c.vat_code}><td className="px-2 py-1">{c.label || c.vat_code}</td>
                <td className="px-2 py-1 text-right">{c.lines}</td><td className="px-2 py-1 text-right">{gbp(c.sales_net)}</td>
                <td className="px-2 py-1 text-right">{gbp(c.purchases_net)}</td>
                <td className="px-2 py-1 text-right">{gbp(c.reclaimable)}</td></tr>
            ))}
          </tbody>
        </table>
      </div>
      {report.top_suppliers.length > 0 && (
        <p className="text-xs text-secondary-600">Biggest suppliers: {report.top_suppliers.slice(0, 5)
          .map((s) => `${s.supplier} (${gbp(s.spend)})`).join(', ')}</p>
      )}
    </div>
  );
}

// The accountants linked to this VAT: the business can see them and stop one acting for it.
function Accountants() {
  const [list, setList] = useState<VatAccountant[]>([]);
  const load = useCallback(() => { vatService.accountants().then(setList).catch(() => undefined); }, []);
  useEffect(load, [load]);
  if (list.length === 0) return null;
  const remove = async (a: VatAccountant) => {
    if (!(await confirmDialog({ title: 'Stop this accountant working on your VAT?', danger: true, confirmText: 'Stop',
      message: 'They will no longer see or file your VAT here. To end their authority at HMRC too, remove them '
        + 'in your HMRC business tax account.' }))) return;
    try {
      await vatService.removeAccountant(a.uuid);
      toast.success('They can no longer work on your VAT here');
      load();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not remove them'));
    }
  };
  return (
    <div className={card} data-testid="vat-accountants">
      <p className="font-semibold text-secondary-900">Accountants who can work on your VAT</p>
      <div className="mt-2 divide-y divide-secondary-100 text-sm">
        {list.map((a) => (
          <div key={a.uuid} className="flex flex-wrap items-center justify-between gap-2 py-2">
            <span>{[a.first_name, a.last_name].filter(Boolean).join(' ') || a.email || 'An accountant'} · agent {a.arn}
              {' · '}{a.status === 'active' ? 'confirmed by HMRC' : 'waiting for you to accept at HMRC'}</span>
            <button type="button" className="text-xs text-red-700 underline" onClick={() => remove(a)}>Stop</button>
          </div>
        ))}
      </div>
    </div>
  );
}

function VatPage() {
  const params = useSearchParams();
  // An accountant opening a client's VAT (from Tax → VAT clients): every call carries it.
  const client = params.get('client');
  setVatClient(client);
  // ?scope=namespace: the workspace's own VAT (its invoices, accounting bank lines).
  const workspace = !client && params.get('scope') === 'namespace';
  setVatScope(workspace ? 'namespace' : null);
  const [loading, setLoading] = useState(true);
  const [reg, setReg] = useState<VatRegistration | null>(null);
  const [codes, setCodes] = useState<VatCode[]>([]);
  const [schemes, setSchemes] = useState<Array<{ key: VatScheme; label: string }>>([]);
  const [status, setStatus] = useState<VatStatus | null>(null);
  const [review, setReview] = useState<VatReviewLine[]>([]);
  const [starting, setStarting] = useState(false);
  const [period, setPeriod] = useState<{ start: string; end: string } | null>(null);
  const [draft, setDraft] = useState<VatReturnRow | null>(null);
  const [building, setBuilding] = useState(false);
  const [openBox, setOpenBox] = useState<keyof Boxes | null>(null);
  const [obligations, setObligations] = useState<VatObligation[] | null>(null);
  const [hmrcState, setHmrcState] = useState<'unknown' | 'connected' | 'connect' | 'error'>('unknown');
  const [hmrcMsg, setHmrcMsg] = useState<string>('');
  const [periodKey, setPeriodKey] = useState('');
  const [declared, setDeclared] = useState(false);
  const [filing, setFiling] = useState(false);
  const [theirs, setTheirs] = useState<Record<string, number | string> | null>(null);
  const [history, setHistory] = useState<VatReturnRow[]>([]);
  const [threshold, setThreshold] = useState<VatThreshold | null>(null);
  const [report, setReport] = useState<VatReport | null>(null);
  const [penalties, setPenalties] = useState<Record<string, unknown> | null>(null);

  const periods = useMemo(() => periodsFor(reg?.stagger || 'quarterly_mar'), [reg?.stagger]);

  const refresh = useCallback(async () => {
    try {
      const [s, q, h] = await Promise.all([vatService.status(), vatService.reviewQueue(), vatService.returns()]);
      setStatus(s); setReview(q); setHistory(h);
    } catch { /* registration may be missing */ }
  }, []);

  useEffect(() => {
    (async () => {
      try {
        const [c, r] = await Promise.all([vatService.codes(), vatService.registration()]);
        setCodes(c.codes); setSchemes(c.schemes); setReg(r);
        if (r) await refresh();
        else vatService.threshold().then(setThreshold).catch(() => undefined);
      } catch (e) {
        toast.error(extractApiError(e, 'Could not load VAT'));
      } finally {
        setLoading(false);
      }
    })();
  }, [refresh]);

  useEffect(() => {
    if (params.get('hmrc_connected')) toast.success('Connected to HMRC for VAT');
    if (params.get('hmrc_error')) toast.error('HMRC connection did not complete: ' + params.get('hmrc_error'));
  }, [params]);

  // While AI coding runs, refresh every 10 seconds.
  useEffect(() => {
    if (!status?.running) return;
    const t = setInterval(refresh, 10000);
    return () => clearInterval(t);
  }, [status?.running, refresh]);

  useEffect(() => { if (!period && periods.length) setPeriod(periods[0]); }, [periods, period]);

  const loadObligations = useCallback(async () => {
    try {
      const list = await vatService.obligations({ status: 'O' });
      setObligations(list); setHmrcState('connected');
      vatService.penalties().then(setPenalties).catch(() => undefined);
      if (period) {
        const match = list.find((o) => o.start === period.start && o.end === period.end);
        setPeriodKey(match?.periodKey || list[0]?.periodKey || '');
      }
    } catch (e: unknown) {
      const code = (e as { response?: { data?: { code?: string } } })?.response?.data?.code;
      setHmrcState(code === 'VAT_SCOPE_MISSING' || code === 'NOT_CONNECTED' ? 'connect' : 'error');
      setHmrcMsg(extractApiError(e, 'HMRC is not available'));
    }
  }, [period]);
  useEffect(() => { if (reg) loadObligations(); }, [reg, loadObligations]);

  const startCoding = async () => {
    setStarting(true);
    try {
      const r = await vatService.classify({});
      if (r.already_running) toast('Already coding — it will finish shortly.');
      await refresh();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not start'));
    } finally {
      setStarting(false);
    }
  };

  const build = async () => {
    if (!period) return;
    setBuilding(true); setTheirs(null);
    try {
      const d = await vatService.saveDraft(period.start, period.end);
      setDraft(await vatService.getReturn(d.uuid, true));
      vatService.report(period.start, period.end).then(setReport).catch(() => setReport(null));
      await refresh();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not build the return'));
    } finally {
      setBuilding(false);
    }
  };

  const connect = async () => {
    try {
      window.location.href = await vatService.connectUrl(`${window.location.origin}/dashboard/tax`);
    } catch (e) {
      toast.error(extractApiError(e, 'Could not start the HMRC connection'));
    }
  };

  const file = async () => {
    if (!draft || !periodKey) return;
    setFiling(true);
    try {
      const done = await vatService.submit(draft.uuid, periodKey);
      setDraft(await vatService.getReturn(done.uuid, true));
      toast.success('Your VAT return has been filed with HMRC');
      try { setTheirs(await vatService.hmrcReturn(periodKey)); } catch { /* shown when HMRC has it */ }
      await refresh();
    } catch (e) {
      toast.error(extractApiError(e, 'HMRC did not accept the return'));
    } finally {
      setFiling(false);
    }
  };

  if (loading) {
    return <div className="flex h-60 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-secondary-400" /></div>;
  }

  const calc = draft?.calculation || {};
  const boxLines = openBox && draft?.lines_by_box?.[openBox];
  const filed = draft && draft.status === 'submitted';
  const receipt = (draft?.hmrc_receipt || {}) as Record<string, string>;

  return (
    <div className="space-y-4">
      <PageHeader title="VAT" icon={<Receipt className="h-5 w-5" />}
        description="Code your VAT with AI, check the few lines it's unsure about, and file your VAT return with HMRC." />
      {workspace && (
        <div className="rounded-lg border border-primary-200 bg-primary-50 p-3 text-sm text-primary-900">
          You&apos;re working on this workspace&apos;s VAT (its invoices and accounts), not your own.
        </div>
      )}
      {client && (
        <div className="rounded-lg border border-primary-200 bg-primary-50 p-3 text-sm text-primary-900">
          You&apos;re working on a client&apos;s VAT{reg ? ` — ${reg.business_name || 'VAT number ' + reg.vrn}` : ''}.
          {' '}<a href="/dashboard/tax/vat/clients" className="underline">Back to your clients</a>
        </div>
      )}

      {!reg && threshold && <ThresholdCard t={threshold} />}
      <Registration reg={reg} schemes={schemes} onSaved={async (r) => { setReg(r); await refresh(); }} />

      {reg && (
        <>
          <CodeVat status={status} onStart={startCoding} starting={starting} />
          <CheckLines lines={review} codes={codes} onChanged={refresh} />

          <div className={card} data-testid="vat-return">
            <div className="flex flex-wrap items-end justify-between gap-3">
              <div>
                <p className="font-semibold text-secondary-900">Your VAT return</p>
                <p className="mt-1 text-sm text-secondary-600">Worked out from your coded lines — never by the AI.</p>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <select className="rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm"
                  value={period ? `${period.start}|${period.end}` : ''} aria-label="VAT period"
                  onChange={(e) => { const [s, en] = e.target.value.split('|'); setPeriod({ start: s, end: en }); setDraft(null); }}>
                  {periods.map((p) => <option key={p.start} value={`${p.start}|${p.end}`}>{p.label}</option>)}
                </select>
                <button type="button" className={primary} onClick={build} disabled={building || !period}>
                  {building ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />} Work it out
                </button>
              </div>
            </div>
            {draft && (
              <div className="mt-4 space-y-3">
                {(calc.warnings || []).map((w) => (
                  <p key={w} className="rounded-lg border border-amber-200 bg-amber-50 p-2 text-xs text-amber-900">{w}</p>
                ))}
                <BoxesGrid boxes={draft as unknown as Boxes} onBox={(k) => setOpenBox(openBox === k ? null : k)} />
                <p className="text-sm text-secondary-700">
                  {draft.direction === 'repay' ? 'HMRC owes you ' : draft.direction === 'pay' ? 'You owe HMRC ' : 'Nothing to pay: '}
                  <strong>{gbp(Number(draft.box5))}</strong>
                  {draft.due_date ? ` · due by ${draft.due_date}` : ''} · {draft.line_count} lines
                </p>
                {report && <ReportCard report={report} />}
                {boxLines && (
                  <div className="rounded-lg border border-secondary-200 bg-surface p-3">
                    <p className="text-sm font-medium text-secondary-900">Behind Box {openBox?.replace('box', '')} ({boxLines.length})</p>
                    <div className="mt-2 max-h-72 divide-y divide-secondary-100 overflow-y-auto text-xs">
                      {boxLines.map((l) => (
                        <div key={l.ref} className="flex justify-between gap-3 py-1">
                          <span className="truncate text-secondary-700">{l.date ? `${l.date} · ` : ''}{l.description || l.adjustment}</span>
                          <span className="shrink-0 tabular-nums">{l.vat_code || ''} net {gbp(l.net)} · VAT {gbp(l.vat)}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>

          <div className={card} data-testid="vat-file">
            <p className="font-semibold text-secondary-900">File with HMRC</p>
            {hmrcState === 'connect' && (
              <div className="mt-2 space-y-2">
                <p className="text-sm text-secondary-600">{hmrcMsg}</p>
                <button type="button" className={primary} onClick={connect}>Connect to HMRC for VAT</button>
              </div>
            )}
            {hmrcState === 'error' && <p className="mt-2 text-sm text-red-700">{hmrcMsg}</p>}
            {penalties && (() => {
              const pts = (penalties as { lateSubmissionPenalty?: { summary?: { activePenaltyPoints?: number;
                penaltyChargeAmount?: number } } }).lateSubmissionPenalty?.summary;
              return pts ? (
                <p className="mt-2 text-xs text-secondary-600">HMRC late-filing penalty points: <strong>
                  {pts.activePenaltyPoints ?? 0}</strong>{pts.penaltyChargeAmount ? ` · penalty ${gbp(pts.penaltyChargeAmount)}` : ''}</p>
              ) : null;
            })()}
            {hmrcState === 'connected' && !filed && (
              <div className="mt-2 space-y-3">
                <label className="block text-sm">VAT period HMRC is waiting for
                  <select className={input} value={periodKey} onChange={(e) => setPeriodKey(e.target.value)}>
                    {(obligations || []).map((o) => (
                      <option key={o.periodKey} value={o.periodKey}>{o.start} to {o.end} (due {o.due})</option>
                    ))}
                  </select>
                </label>
                {!draft && <p className="text-sm text-secondary-600">Work out the return above first.</p>}
                {draft && (
                  <>
                    <label className="flex items-start gap-2 rounded-lg border border-secondary-200 bg-surface p-3 text-sm">
                      <input type="checkbox" className="mt-0.5" checked={declared} onChange={(e) => setDeclared(e.target.checked)} />
                      <span>When I submit this VAT information I am making a legal declaration that the information is
                        true and complete. A false declaration can result in prosecution.</span>
                    </label>
                    <button type="button" className={primary} onClick={file} disabled={!declared || filing || !periodKey}>
                      {filing ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileCheck2 className="h-4 w-4" />} File my VAT return now
                    </button>
                  </>
                )}
              </div>
            )}
            {filed && (
              <div className="mt-3 space-y-3">
                <div className="rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">
                  <p className="font-medium">Your VAT return has been filed with HMRC.</p>
                  <p className="text-xs">Period {draft?.period_key} · receipt {receipt.formBundleNumber || '—'}
                    {receipt.chargeRefNumber ? ` · charge ref ${receipt.chargeRefNumber}` : ''}
                    {receipt.processingDate ? ` · ${receipt.processingDate}` : ''}</p>
                </div>
                {theirs && (
                  <div className="overflow-x-auto rounded-lg border border-secondary-200">
                    <table className="w-full text-sm">
                      <thead className="bg-secondary-50 text-xs uppercase text-secondary-500">
                        <tr><th className="px-3 py-2 text-left">Box</th><th className="px-3 py-2 text-right">Ours</th>
                          <th className="px-3 py-2 text-right">HMRC&apos;s copy</th></tr>
                      </thead>
                      <tbody className="divide-y divide-secondary-100">
                        {BOX_LABELS.map((b, i) => {
                          const f = ['vatDueSales', 'vatDueAcquisitions', 'totalVatDue', 'vatReclaimedCurrPeriod', 'netVatDue',
                            'totalValueSalesExVAT', 'totalValuePurchasesExVAT', 'totalValueGoodsSuppliedExVAT',
                            'totalAcquisitionsExVAT'][i];
                          const ours = Number((draft as unknown as Boxes)[b.key]);
                          const h = Number(theirs[f]);
                          return (
                            <tr key={b.key} className={Math.abs(ours - h) > 0.004 ? 'bg-amber-50/60' : ''}>
                              <td className="px-3 py-1.5">Box {b.n}</td>
                              <td className="px-3 py-1.5 text-right tabular-nums">{gbp(ours)}</td>
                              <td className="px-3 py-1.5 text-right tabular-nums">{gbp(h)}</td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                )}
              </div>
            )}
          </div>

          {reg && <VatSchemesPanel reg={reg} workspace={workspace} period={period}
            onChanged={() => { if (draft) build(); }} />}

          {!client && <Accountants />}

          {history.length > 0 && (
            <div className={card}>
              <p className="font-semibold text-secondary-900">Your VAT returns</p>
              <div className="mt-2 divide-y divide-secondary-100 text-sm">
                {history.map((h) => (
                  <div key={h.uuid} className="flex flex-wrap justify-between gap-2 py-2">
                    <span>{h.period_start} to {h.period_end}{h.period_key ? ` · ${h.period_key}` : ''}</span>
                    <span className="tabular-nums">
                      <button type="button" className="mr-2 text-primary-700 underline"
                        onClick={() => vatService.exportReturn(h.uuid).catch((e) => toast.error(extractApiError(e, 'Export failed')))}>
                        Download lines (CSV)</button>
                      Box 5 {gbp(Number(h.box5))} ·{' '}
                      <span className={h.status === 'submitted' ? 'text-green-700' : h.status === 'failed' ? 'text-red-700' : 'text-secondary-600'}>
                        {h.status === 'submitted' ? 'filed' : h.status}</span></span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}

export default function Page() {
  return (
    <ProtectedPage module="tax_statements" title="VAT">
      <Suspense fallback={null}>
        <VatPage />
      </Suspense>
    </ProtectedPage>
  );
}
