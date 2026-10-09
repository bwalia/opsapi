'use client';

/**
 * Property Deals — Reports (SPEC §3.8 #10): time per stage, late days, conversion, supplier and
 * solicitor/council speed, AI usage and cost. Simple bar charts + tables; export any data.
 */
import React, { useState } from 'react';
import { BarChart as BarIcon, Download } from 'lucide-react';
import toast from 'react-hot-toast';
import { ResponsiveContainer, BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid, Legend } from 'recharts';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Select } from '@/components/ui';
import { pdService, pdErrorText } from '@/services/property-deals.service';
import { PdPage, ErrorNote, Spinner, Stat, gbp, label } from '@/components/property-deals/ui';
import { usePdData, usePdMe } from '@/components/property-deals/usePd';

type Row = Record<string, unknown>;
const EXPORTS = ['deals', 'tasks', 'properties', 'buyer_profiles', 'suppliers', 'bookings', 'enquiries', 'chases', 'compliance_checks', 'approvals', 'agent_runs', 'matches', 'market_records', 'stage_history'];
const ax = { fontSize: 12, fill: 'currentColor' };

export default function ReportsPage() {
  return (
    <PdPage module="reports">
      <Reports />
    </PdPage>
  );
}

function iso(d: Date) { return d.toISOString().slice(0, 10); }

function Reports() {
  const { can } = usePdMe();
  const [from, setFrom] = useState(() => iso(new Date(Date.now() - 90 * 864e5)));
  const [to, setTo] = useState(() => iso(new Date(Date.now() + 864e5)));
  const p = { from, to };
  const load = (name: string) => async () => (await pdService.report(name, p)).data as Row & Row[];
  const stages = usePdData(load('stage-times'), [from, to]);
  const late = usePdData(load('late-days'), [from, to]);
  const conv = usePdData(load('conversion'), [from, to]);
  const sup = usePdData(load('supplier-speed'), [from, to]);
  const party = usePdData(load('party-speed'), [from, to]);
  const ai = usePdData(load('ai-usage'), [from, to]);
  const [entity, setEntity] = useState('deals');

  const lateD = late.data as Row | undefined;
  const convD = conv.data as { totals?: Row; by_month?: Row[]; by_source?: Row[] } | undefined;
  const stageD = stages.data as { completed_stages?: Row[]; current?: Row[] } | undefined;
  const partyD = party.data as { chases?: Row[]; enquiries?: Row[] } | undefined;
  const aiD = ai.data as { total_cost_usd?: number; daily?: Row[]; approval_outcomes?: Row[] } | undefined;
  const aiByAgent = Object.values(((aiD?.daily || []) as Row[]).reduce<Record<string, Row>>((acc, r) => {
    const k = String(r.agent_key);
    acc[k] = acc[k] || { agent: label(k), runs: 0, failed: 0, cost: 0 };
    acc[k].runs = Number(acc[k].runs) + Number(r.runs || 0);
    acc[k].failed = Number(acc[k].failed) + Number(r.failed || 0);
    acc[k].cost = Number(acc[k].cost) + Number(r.cost_usd || 0);
    return acc;
  }, {}));

  return (
    <div className="space-y-6" data-tour="reports">
      <PageHeader title="Deal reports" description="How fast deals move, where they get stuck, and what AI costs." icon={<BarIcon className="h-6 w-6" />}
        actions={<div className="flex items-end gap-2"><Input type="date" label="From" value={from} onChange={(e) => setFrom(e.target.value)} /><Input type="date" label="To" value={to} onChange={(e) => setTo(e.target.value)} /></div>} />
      {[stages, late, conv].map((r, i) => <ErrorNote key={i} error={r.error} />)}
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Deals completed" value={String(lateD?.completed ?? '—')} hint={lateD?.on_time_pct !== undefined ? `${lateD.on_time_pct}% on time` : undefined} />
        <Stat label="Avg days late" value={String(lateD?.avg_days_late ?? '—')} tone={Number(lateD?.late || 0) > 0 ? 'warning' : undefined} />
        <Stat label="Late penalty cost" value={gbp(lateD?.penalty_cost)} tone={Number(lateD?.penalty_cost || 0) > 0 ? 'error' : undefined} />
        <Stat label="AI cost" value={`$${Number(aiD?.total_cost_usd || 0).toFixed(2)}`} />
      </div>
      <div className="grid gap-6 xl:grid-cols-2">
        <Card>
          <h2 className="mb-3 font-semibold text-secondary-900">Time per stage (days, completed)</h2>
          {stages.loading && !stages.data ? <Spinner /> : (
            <ResponsiveContainer width="100%" height={260}>
              <BarChart data={(stageD?.completed_stages || []).map((r) => ({ ...r, stage: label(String(r.stage_key)) }))} layout="vertical" margin={{ left: 40 }}>
                <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
                <XAxis type="number" tick={ax} /><YAxis type="category" dataKey="stage" tick={ax} width={120} />
                <Tooltip /><Legend />
                <Bar dataKey="avg_days" name="Average" fill="#6366f1" /><Bar dataKey="median_days" name="Median" fill="#a5b4fc" />
              </BarChart>
            </ResponsiveContainer>
          )}
          {(stageD?.current || []).length > 0 && <p className="mt-2 text-sm text-secondary-500">Now: {(stageD?.current || []).map((r) => `${label(String(r.stage_key))} ${r.deals} deal(s), ${r.avg_days_so_far} days so far`).join(' · ')}</p>}
        </Card>
        <Card>
          <h2 className="mb-3 font-semibold text-secondary-900">Conversion by month</h2>
          <ResponsiveContainer width="100%" height={260}>
            <BarChart data={convD?.by_month || []}>
              <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
              <XAxis dataKey="month" tick={ax} /><YAxis tick={ax} allowDecimals={false} /><Tooltip /><Legend />
              <Bar dataKey="leads" name="Leads" fill="#0ea5e9" /><Bar dataKey="deals" name="Deals" fill="#6366f1" />
              <Bar dataKey="completed" name="Completed" fill="#16a34a" /><Bar dataKey="fell_through" name="Fell through" fill="#dc2626" />
            </BarChart>
          </ResponsiveContainer>
          {convD?.totals && <p className="mt-2 text-sm text-secondary-500">Lead → deal {String(convD.totals.lead_to_deal_pct ?? '—')}% · deal → completion {String(convD.totals.deal_to_completion_pct ?? '—')}%</p>}
        </Card>
        <Card>
          <h2 className="mb-3 font-semibold text-secondary-900">Who replies slowest (hours to reply to chases)</h2>
          <ResponsiveContainer width="100%" height={240}>
            <BarChart data={(partyD?.chases || []).map((r) => ({ ...r, party: label(String(r.to_party)) }))}>
              <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
              <XAxis dataKey="party" tick={ax} /><YAxis tick={ax} /><Tooltip /><Legend />
              <Bar dataKey="avg_hours_to_reply" name="Average hours" fill="#f97316" /><Bar dataKey="median_hours_to_reply" name="Median hours" fill="#fdba74" />
            </BarChart>
          </ResponsiveContainer>
          <table className="mt-3 w-full text-sm">
            <thead className="text-left text-xs text-secondary-500"><tr><th>Enquiries waiting on</th><th>Raised</th><th>Resolved</th><th>Open</th><th>Days to resolve</th></tr></thead>
            <tbody>{(partyD?.enquiries || []).map((r) => <tr key={String(r.owner_party)} className="border-t border-secondary-100"><td className="py-1">{label(String(r.owner_party))}</td><td>{String(r.raised)}</td><td>{String(r.resolved)}</td><td>{String(r.still_open)}</td><td>{String(r.avg_days_to_resolve ?? '—')}</td></tr>)}</tbody>
          </table>
        </Card>
        <Card>
          <h2 className="mb-3 font-semibold text-secondary-900">Suppliers</h2>
          <table className="w-full text-sm">
            <thead className="text-left text-xs text-secondary-500"><tr><th>Supplier</th><th>Bookings</th><th>Hours to confirm</th><th>Hours to done</th><th>On time</th></tr></thead>
            <tbody>
              {((sup.data as Row[] | undefined) || []).filter((r) => Number(r.bookings) > 0).map((r) => (
                <tr key={String(r.supplier_uuid)} className="border-t border-secondary-100"><td className="py-1">{String(r.name)}</td><td>{String(r.bookings)}</td><td>{String(r.avg_hours_to_confirm ?? '—')}</td><td>{String(r.avg_hours_to_done ?? '—')}</td><td>{r.on_time_pct !== null && r.on_time_pct !== undefined ? `${r.on_time_pct}%` : '—'}</td></tr>
              ))}
            </tbody>
          </table>
        </Card>
        <Card className="xl:col-span-2">
          <h2 className="mb-3 font-semibold text-secondary-900">AI by agent</h2>
          <div className="grid gap-6 lg:grid-cols-2">
            <ResponsiveContainer width="100%" height={240}>
              <BarChart data={aiByAgent}>
                <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
                <XAxis dataKey="agent" tick={ax} interval={0} angle={-20} textAnchor="end" height={60} /><YAxis tick={ax} allowDecimals={false} /><Tooltip /><Legend />
                <Bar dataKey="runs" name="Runs" fill="#6366f1" /><Bar dataKey="failed" name="Failed" fill="#dc2626" />
              </BarChart>
            </ResponsiveContainer>
            <table className="w-full text-sm">
              <thead className="text-left text-xs text-secondary-500"><tr><th>Agent</th><th>Drafts</th><th>Approved</th><th>Edited</th><th>Rejected</th><th>Pending</th></tr></thead>
              <tbody>{(aiD?.approval_outcomes || []).map((r) => <tr key={String(r.agent_key)} className="border-t border-secondary-100"><td className="py-1">{label(String(r.agent_key))}</td><td>{String(r.drafts)}</td><td>{String(r.approved)}</td><td>{String(r.edited)}</td><td>{String(r.rejected)}</td><td>{String(r.pending)}</td></tr>)}</tbody>
            </table>
          </div>
        </Card>
      </div>
      {can('reports', 'manage') && (
        <Card>
          <h2 className="font-semibold text-secondary-900">Export data</h2>
          <p className="text-sm text-secondary-500">Everything in this workspace, as CSV (opens in a spreadsheet) or JSON. Up to 50,000 rows.</p>
          <div className="mt-3 flex flex-wrap items-end gap-2">
            <Select label="What" value={entity} onChange={(e) => setEntity(e.target.value)}>{EXPORTS.map((x) => <option key={x} value={x}>{label(x)}</option>)}</Select>
            {(['csv', 'json'] as const).map((fmt) => (
              <Button key={fmt} variant="outline" leftIcon={<Download className="h-4 w-4" />} onClick={async () => {
                try {
                  const blob = await pdService.exportFile(entity, fmt);
                  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = `property-deals-${entity}.${fmt}`; a.click();
                } catch (e) { toast.error(pdErrorText(e)); }
              }}>{fmt.toUpperCase()}</Button>
            ))}
          </div>
        </Card>
      )}
    </div>
  );
}
