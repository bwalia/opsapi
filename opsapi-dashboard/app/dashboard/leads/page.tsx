'use client';

/**
 * Leads: the lead pipeline (docs/plans/LEAD_TO_CASH_PIPELINE.md).
 *
 *   Pipeline  every stage as a column; drag a lead to move it
 *   Insights  the funnel, speed to lead, sources, why leads are lost
 *   List      search, filter and sort every lead you can see
 *
 * "Your next steps" sits on top: late and today's calls and meetings.
 * Managers (crm_leads manage) see every lead; everyone else their own and
 * unassigned ones (the API decides; the page just shows what it gets).
 */
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import toast from 'react-hot-toast';
import {
  BarChart3, Bell, Handshake, KanbanSquare, List as ListIcon, Plus, RefreshCw, Search, Settings2, Target, Users,
} from 'lucide-react';
import { Button, Input, Pagination } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import TourHost from '@/components/property-deals/Tour';
import { CreateLeadModal, LeadNotificationsModal } from '@/components/crm/leads-shared';
import { PipelineBoard } from '@/components/leads/PipelineBoard';
import { VipBadge } from '@/components/shop/VipBadge';
import { useVipStatus } from '@/hooks/useVipStatus';
import { FunnelPanel } from '@/components/leads/FunnelPanel';
import { MyStepsPanel } from '@/components/leads/MySteps';
import {
  Avatar, dueText, fullName, money, ScoreBadge, StageBadge, STEP_LABEL,
} from '@/components/leads/ui';
import { cn } from '@/lib/utils';
import {
  ALL_STAGES, leadError, leadsService, type Board, type Funnel, type Lead, type LeadListQuery, type MySteps,
  type LeadStats, type SettingsBundle,
} from '@/services/leads.service';

type View = 'pipeline' | 'insights' | 'list';

function isoDay(offsetDays = 0): string {
  return new Date(Date.now() + offsetDays * 86400000).toISOString().slice(0, 10);
}

const RANGES = [
  { label: 'Last 30 days', days: 30 },
  { label: 'Last 90 days', days: 90 },
  { label: 'Last 12 months', days: 365 },
];

function LeadsContent() {
  const router = useRouter();
  const params = useSearchParams();
  const [view, setView] = useState<View>((params.get('view') as View) || 'pipeline');
  const [mine, setMine] = useState(false);
  const [board, setBoard] = useState<Board | null>(null);
  const [funnel, setFunnel] = useState<Funnel | null>(null);
  const [steps, setSteps] = useState<MySteps | null>(null);
  const [stats, setStats] = useState<LeadStats | null>(null);
  const [settings, setSettings] = useState<SettingsBundle | null>(null);
  const [range, setRange] = useState(90);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [createOpen, setCreateOpen] = useState(false);
  const [notifOpen, setNotifOpen] = useState(false);

  // List view state
  const [query, setQuery] = useState<LeadListQuery>({
    stage: params.get('stage') ?? undefined, owner: (params.get('owner') as LeadListQuery['owner']) ?? undefined,
    sort: 'next_action', page: 1, per_page: 25,
  });
  const [search, setSearch] = useState('');
  const [list, setList] = useState<{ items: Lead[]; total: number; total_pages: number } | null>(null);
  const vips = useVipStatus((list?.items ?? []).map((l) => l.email));

  const setViewAndUrl = (v: View) => {
    setView(v);
    const sp = new URLSearchParams(params.toString());
    sp.set('view', v);
    router.replace(`/dashboard/leads?${sp.toString()}`, { scroll: false });
  };

  const loadTop = useCallback(async () => {
    try {
      const [s, st, totals] = await Promise.all([
        leadsService.mySteps(), settings ? Promise.resolve(settings) : leadsService.settings(), leadsService.stats(),
      ]);
      setSteps(s);
      setStats(totals);
      if (!settings) setSettings(st);
    } catch (e) {
      setError(leadError(e).message);
    }
  }, [settings]);

  const loadView = useCallback(async () => {
    setError(null);
    try {
      if (view === 'pipeline') setBoard(await leadsService.board({ owner: mine ? 'me' : undefined }));
      else if (view === 'insights') setFunnel(await leadsService.funnel(isoDay(-(range - 1)), isoDay(0)));
      else {
        const res = await leadsService.list({ ...query, search: search || undefined, owner: mine ? 'me' : query.owner });
        setList(res);
      }
    } catch (e) {
      setError(leadError(e).message);
    } finally {
      setLoading(false);
    }
  }, [view, mine, range, query, search]);

  useEffect(() => { loadTop(); }, [loadTop]);
  useEffect(() => { setLoading(true); loadView(); }, [loadView]);

  // Light polling so AI scores and new leads appear without a reload.
  useEffect(() => {
    const t = setInterval(() => { if (document.visibilityState === 'visible') { loadView(); loadTop(); } }, 30000);
    return () => clearInterval(t);
  }, [loadView, loadTop]);

  const refresh = () => { loadTop(); loadView(); };
  const lostReasons = settings?.settings.lost_reasons ?? ['Not interested', 'Other'];
  const labels = settings?.stage_labels;

  const totals = useMemo(() => {
    if (!stats) return null;
    const n = (v: number | string) => Number(v) || 0;
    return {
      open: n(stats.new_leads) + n(stats.contacting_leads) + n(stats.qualified_leads) + n(stats.meeting_leads),
      value: n(stats.open_value),
      overdue: n(stats.overdue_leads),
    };
  }, [stats]);

  return (
    <div className="space-y-6">
      <PageHeader
        icon={<Target className="h-5 w-5" aria-hidden="true" />}
        title="Leads"
        description="Every enquiry from arrival to deal: who owns it, what's next, and what it's worth."
        actions={
          <div className="flex flex-wrap items-center gap-2">
            <Link href="/dashboard/leads/partners"
              className="inline-flex h-10 items-center gap-2 rounded-lg px-3 text-sm font-medium text-secondary-600 hover:bg-secondary-100">
              <Handshake className="h-4 w-4" aria-hidden="true" />Partners
            </Link>
            {settings?.can_edit && (
              <Link href="/dashboard/leads/settings"
                className="inline-flex h-10 items-center gap-2 rounded-lg px-3 text-sm font-medium text-secondary-600 hover:bg-secondary-100">
                <Settings2 className="h-4 w-4" aria-hidden="true" />Settings
              </Link>
            )}
            <Button variant="ghost" onClick={() => setNotifOpen(true)} leftIcon={<Bell className="h-4 w-4" />}>Alerts</Button>
            <Button onClick={() => setCreateOpen(true)} leftIcon={<Plus className="h-4 w-4" />} data-tour="add-lead">Add lead</Button>
          </div>
        }
      />

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="grid grid-cols-3 gap-3 lg:col-span-2">
          <div className="rounded-xl border border-secondary-200 bg-white p-4">
            <p className="text-xs font-medium text-secondary-500">Open leads</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-secondary-900">{totals ? totals.open : '—'}</p>
          </div>
          <div className="rounded-xl border border-secondary-200 bg-white p-4">
            <p className="text-xs font-medium text-secondary-500">Pipeline value</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-secondary-900">
              {totals ? money(totals.value, stats?.currency, true) : '—'}
            </p>
          </div>
          <div className="rounded-xl border border-secondary-200 bg-white p-4">
            <p className="text-xs font-medium text-secondary-500">Late next steps</p>
            <p className={cn('mt-1 text-2xl font-bold tabular-nums', totals && totals.overdue > 0 ? 'text-error-600' : 'text-secondary-900')}>
              {totals ? totals.overdue : '—'}
            </p>
          </div>
        </div>
        {steps && (
          <MyStepsPanel steps={steps} onShowUnassigned={() => {
            setQuery((q) => ({ ...q, owner: 'unassigned', stage: undefined, page: 1 }));
            setMine(false);
            setViewAndUrl('list');
          }} />
        )}
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="inline-flex rounded-lg border border-secondary-200 bg-white p-1" role="tablist" aria-label="Leads view">
          {([
            ['pipeline', 'Pipeline', KanbanSquare], ['insights', 'Insights', BarChart3], ['list', 'List', ListIcon],
          ] as const).map(([key, label, Icon]) => (
            <button key={key} type="button" role="tab" aria-selected={view === key} onClick={() => setViewAndUrl(key)}
              className={cn('inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-sm font-medium transition',
                view === key ? 'bg-primary-500 text-white shadow-sm' : 'text-secondary-600 hover:bg-secondary-100')}>
              <Icon className="h-4 w-4" aria-hidden="true" />{label}
            </button>
          ))}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {view !== 'insights' && (
            <label className="inline-flex cursor-pointer items-center gap-2 rounded-lg border border-secondary-200 bg-white px-3 py-2 text-sm text-secondary-700">
              <input type="checkbox" className="h-4 w-4 rounded border-secondary-300 text-primary-500" checked={mine}
                onChange={(e) => setMine(e.target.checked)} />
              <Users className="h-4 w-4 text-secondary-400" aria-hidden="true" />Only mine
            </label>
          )}
          {view === 'insights' && (
            <select value={range} onChange={(e) => setRange(Number(e.target.value))} aria-label="Period"
              className="rounded-lg border border-secondary-200 bg-white px-3 py-2 text-sm">
              {RANGES.map((r) => <option key={r.days} value={r.days}>{r.label}</option>)}
            </select>
          )}
          <Button variant="ghost" size="sm" onClick={refresh} leftIcon={<RefreshCw className="h-4 w-4" />}>Refresh</Button>
        </div>
      </div>

      {error && (
        <div className="rounded-lg border border-error-200 bg-error-50 px-4 py-3 text-sm text-error-700" role="alert">
          {error} <button type="button" className="ml-2 font-medium underline" onClick={refresh}>Try again</button>
        </div>
      )}

      {loading && !board && !funnel && !list ? (
        <div className="flex h-64 items-center justify-center text-sm text-secondary-500">Loading leads…</div>
      ) : view === 'pipeline' ? (
        board && <PipelineBoard board={board} lostReasons={lostReasons} onChanged={refresh} />
      ) : view === 'insights' ? (
        funnel && (funnel.total === 0
          ? <div className="rounded-xl border border-dashed border-secondary-300 bg-white p-10 text-center text-sm text-secondary-500">
              No leads arrived in this period. Leads from your website, forms and shop show here as they come in.
            </div>
          : <FunnelPanel funnel={funnel} />)
      ) : (
        <section className="rounded-xl border border-secondary-200 bg-white">
          <div className="flex flex-wrap items-center gap-2 border-b border-secondary-200 p-3">
            <form className="relative min-w-[14rem] flex-1" onSubmit={(e) => { e.preventDefault(); setQuery((q) => ({ ...q, page: 1 })); loadView(); }}>
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-secondary-400" aria-hidden="true" />
              <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search name, email, company or phone"
                className="pl-9" aria-label="Search leads" />
            </form>
            <select value={query.stage ?? ''} aria-label="Stage" onChange={(e) => setQuery((q) => ({ ...q, stage: e.target.value || undefined, page: 1 }))}
              className="rounded-lg border border-secondary-200 px-3 py-2 text-sm">
              <option value="">All stages</option>
              {ALL_STAGES.map((s) => <option key={s} value={s}>{labels?.[s] ?? s}</option>)}
            </select>
            <select value={query.owner ?? ''} aria-label="Owner" onChange={(e) => setQuery((q) => ({ ...q, owner: e.target.value || undefined, page: 1 }))}
              className="rounded-lg border border-secondary-200 px-3 py-2 text-sm">
              <option value="">Anyone</option>
              <option value="me">Mine</option>
              <option value="unassigned">No owner</option>
            </select>
            <select value={query.due ?? ''} aria-label="Due" onChange={(e) => setQuery((q) => ({ ...q, due: (e.target.value || undefined) as LeadListQuery['due'], page: 1 }))}
              className="rounded-lg border border-secondary-200 px-3 py-2 text-sm">
              <option value="">Any time</option>
              <option value="overdue">Late</option>
              <option value="today">Due today</option>
            </select>
            <select value={query.sort ?? 'next_action'} aria-label="Sort" onChange={(e) => setQuery((q) => ({ ...q, sort: e.target.value as LeadListQuery['sort'] }))}
              className="rounded-lg border border-secondary-200 px-3 py-2 text-sm">
              <option value="next_action">Next step first</option>
              <option value="newest">Newest</option>
              <option value="score">Best AI score</option>
              <option value="value">Highest value</option>
              <option value="stage_changed">Recently moved</option>
            </select>
          </div>
          {list && list.items.length === 0 ? (
            <p className="p-10 text-center text-sm text-secondary-500">No leads match. Try another filter, or add one.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-secondary-200 text-left text-xs text-secondary-500">
                    <th className="px-4 py-2.5 font-medium">Lead</th><th className="px-4 py-2.5 font-medium">Stage</th>
                    <th className="px-4 py-2.5 font-medium">Next step</th><th className="px-4 py-2.5 font-medium">AI</th>
                    <th className="px-4 py-2.5 text-right font-medium">Value</th><th className="px-4 py-2.5 font-medium">Owner</th>
                    <th className="px-4 py-2.5 font-medium">Source</th>
                  </tr>
                </thead>
                <tbody>
                  {(list?.items ?? []).map((l) => {
                    const due = dueText(l.next_action_at);
                    return (
                      <tr key={l.uuid} className="cursor-pointer border-b border-secondary-100 hover:bg-secondary-50"
                        onClick={() => router.push(`/dashboard/leads/${l.uuid}`)}>
                        <td className="px-4 py-3">
                          <Link href={`/dashboard/leads/${l.uuid}`} className="font-medium text-secondary-900 hover:text-primary-600"
                            onClick={(e) => e.stopPropagation()}>{fullName(l)}</Link>
                          <VipBadge vip={vips[(l.email ?? '').toLowerCase()]} className="ml-2 align-middle" />
                          <p className="text-xs text-secondary-500">{l.company_name || l.email || l.phone || ''}</p>
                        </td>
                        <td className="px-4 py-3"><StageBadge stage={l.stage} label={l.stage_label} /></td>
                        <td className={cn('px-4 py-3 text-xs', due.overdue ? 'font-medium text-error-600' : 'text-secondary-600')}>
                          {l.next_action_at ? `${STEP_LABEL[l.next_action_type ?? ''] ?? 'Step'} · ${due.text}` : '—'}
                        </td>
                        <td className="px-4 py-3"><ScoreBadge score={l.ai_score} /></td>
                        <td className="px-4 py-3 text-right tabular-nums">{l.estimated_value ? money(l.estimated_value, l.currency || board?.currency) : '—'}</td>
                        <td className="px-4 py-3"><span className="inline-flex items-center gap-2"><Avatar name={l.owner_name} />
                          <span className="text-xs text-secondary-600">{l.owner_name ?? 'No owner'}</span></span></td>
                        <td className="px-4 py-3 text-xs capitalize text-secondary-600">{(l.source ?? '').replace(/_/g, ' ')}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
          {list && list.total_pages > 1 && (
            <div className="border-t border-secondary-200 p-3">
              <Pagination currentPage={query.page ?? 1} totalPages={list.total_pages} totalItems={list.total}
                perPage={query.per_page ?? 25} onPageChange={(p: number) => setQuery((q) => ({ ...q, page: p }))} />
            </div>
          )}
        </section>
      )}

      <CreateLeadModal isOpen={createOpen} onClose={() => setCreateOpen(false)}
        onSuccess={() => { setCreateOpen(false); toast.success('Lead added. The AI is looking at it now.'); refresh(); }} />
      <LeadNotificationsModal isOpen={notifOpen} onClose={() => setNotifOpen(false)} />
    </div>
  );
}

export default function LeadsPage() {
  return (
    <>
      <ProtectedPage module="crm_leads" title="Leads">
        <React.Suspense fallback={<div className="p-10 text-sm text-secondary-500">Loading…</div>}>
          <LeadsContent />
        </React.Suspense>
      </ProtectedPage>
      <TourHost />
    </>
  );
}
