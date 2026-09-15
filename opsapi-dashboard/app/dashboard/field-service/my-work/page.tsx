'use client';

/**
 * My Work — /dashboard/field-service/my-work
 *
 * The engineer's home. No calendar, no filters. The job in front of them is a
 * big hero card with one action; a small summary sits beside it, and the rest
 * of the schedule follows. Phone-first, but fills the width on desktop.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { MapPin, ChevronRight, RefreshCw, Loader2, CheckCircle2, ArrowRight, Navigation } from 'lucide-react';
import { Button } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { fieldService, parseFsDate, formatFsDateTime, type FsVisit } from '@/services/field-service.service';
import { siteAddressFromJob, mapsUrl, apiError } from '@/components/field-service/shared';
import { cn } from '@/lib/utils';

type Bucket = { key: string; label: string; visits: FsVisit[] };

function startOfDay(d: Date) {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x;
}
function addDays(d: Date, n: number) {
  const x = new Date(d);
  x.setDate(x.getDate() + n);
  return x;
}

const ACTIVE = new Set(['en_route', 'on_site']);
const DONE = new Set(['completed', 'cancelled']);

function statusLine(v: FsVisit): { text: string; tone: string } {
  if (v.status === 'on_site') return { text: 'On site now', tone: 'text-emerald-700 bg-emerald-50' };
  if (v.status === 'en_route') return { text: 'On the way', tone: 'text-blue-700 bg-blue-50' };
  if (v.status === 'no_access') return { text: 'No access — revisit', tone: 'text-amber-700 bg-amber-50' };
  return { text: formatFsDateTime(v.scheduled_start), tone: 'text-secondary-700 bg-secondary-100' };
}

function isUrgent(v: FsVisit) {
  return v.job_priority === 'high' || v.job_priority === 'urgent';
}

/** The big focal card for the job the engineer should deal with next. */
function HeroCard({ visit, onOpen }: { visit: FsVisit; onOpen: () => void }) {
  const s = statusLine(visit);
  const active = ACTIVE.has(visit.status);
  const address = siteAddressFromJob(visit);
  const maps = mapsUrl(address);
  const cta = active ? 'Continue job' : visit.status === 'no_access' ? 'Revisit' : 'Start job';
  return (
    <div className="rounded-3xl border border-secondary-200 bg-surface p-6 sm:p-8 shadow-sm flex flex-col">
      <div className="flex items-center gap-2 mb-3">
        <span className="text-xs font-bold uppercase tracking-wide text-secondary-400">
          {active ? 'Current job' : 'Next up'}
        </span>
        <span className={cn('rounded-full px-3 py-1 text-xs font-semibold', s.tone)}>{s.text}</span>
        {isUrgent(visit) && <span className="rounded-full px-2.5 py-1 text-xs font-semibold text-red-700 bg-red-50">Urgent</span>}
      </div>
      <h2 className="text-2xl sm:text-3xl font-bold text-secondary-900 leading-tight">{visit.job_title || 'Service visit'}</h2>
      <p className="text-secondary-600 mt-1">{visit.customer_name || 'No customer'}</p>
      {(visit.site_name || address) && (
        <p className="mt-3 flex items-center gap-1.5 text-secondary-600">
          <MapPin className="w-4 h-4 shrink-0 text-secondary-400" /> {visit.site_name || address}
        </p>
      )}
      <div className="mt-6 flex flex-wrap gap-3">
        <Button size="lg" onClick={onOpen} rightIcon={<ArrowRight className="w-5 h-5" />}>{cta}</Button>
        {maps && (
          <a href={maps} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-2 rounded-lg border border-secondary-300 px-4 text-secondary-700 font-medium hover:bg-secondary-50" style={{ minHeight: 44 }}>
            <Navigation className="w-4 h-4 text-primary-600" /> Directions
          </a>
        )}
      </div>
    </div>
  );
}

function SummaryCard({ inProgress, scheduled, done }: { inProgress: number; scheduled: number; done: number }) {
  const rows = [
    { label: 'In progress', value: inProgress, tone: 'text-emerald-600' },
    { label: 'Scheduled', value: scheduled, tone: 'text-secondary-900' },
    { label: 'Done today', value: done, tone: 'text-secondary-400' },
  ];
  return (
    <div className="rounded-3xl border border-secondary-200 bg-surface p-6 shadow-sm">
      <h3 className="text-xs font-bold uppercase tracking-wide text-secondary-400 mb-4">Today at a glance</h3>
      <div className="space-y-4">
        {rows.map((r) => (
          <div key={r.label} className="flex items-baseline justify-between border-b border-secondary-100 pb-3 last:border-0 last:pb-0">
            <span className="text-secondary-600">{r.label}</span>
            <span className={cn('text-3xl font-bold tabular-nums', r.tone)}>{r.value}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function VisitRow({ visit, onOpen }: { visit: FsVisit; onOpen: () => void }) {
  const s = statusLine(visit);
  const address = siteAddressFromJob(visit);
  return (
    <button
      type="button"
      onClick={onOpen}
      className="w-full text-left bg-surface rounded-2xl border border-secondary-200 p-4 shadow-sm active:scale-[0.99] hover:border-secondary-300 transition flex items-center gap-3"
      style={{ minHeight: 80 }}
    >
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2 mb-1">
          <span className={cn('inline-block rounded-full px-2.5 py-0.5 text-xs font-semibold', s.tone)}>{s.text}</span>
          {isUrgent(visit) && <span className="inline-block rounded-full px-2 py-0.5 text-xs font-semibold text-red-700 bg-red-50">Urgent</span>}
        </div>
        <p className="font-semibold text-secondary-900 truncate">{visit.job_title || 'Service visit'}</p>
        <p className="text-sm text-secondary-600 truncate">
          {visit.customer_name || 'No customer'}
          {(visit.site_name || address) ? ` · ${visit.site_name || address}` : ''}
        </p>
      </div>
      <ChevronRight className="w-5 h-5 text-secondary-300 shrink-0" />
    </button>
  );
}

function MyWorkContent() {
  const router = useRouter();
  const [visits, setVisits] = useState<FsVisit[]>([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const from = addDays(startOfDay(new Date()), -3);
      const to = addDays(startOfDay(new Date()), 21);
      const res = await fieldService.getVisits({ mine: true, from: from.toISOString(), to: to.toISOString(), per_page: 200 });
      setVisits(res.data || []);
    } catch (err) {
      toast.error(apiError(err, 'Failed to load your work'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const model = useMemo(() => {
    const today = startOfDay(new Date());
    const tomorrow = addDays(today, 1);
    const onDay = (v: FsVisit) => {
      const d = parseFsDate(v.scheduled_start);
      return d && d >= today && d < tomorrow;
    };
    const now: FsVisit[] = [];
    const todayList: FsVisit[] = [];
    const overdue: FsVisit[] = [];
    const upcoming: FsVisit[] = [];
    let doneToday = 0;

    for (const v of visits) {
      if (v.status === 'completed' && onDay(v)) doneToday += 1;
      if (DONE.has(v.status)) continue;
      const d = parseFsDate(v.scheduled_start);
      if (ACTIVE.has(v.status)) { now.push(v); continue; }
      if (!d) { todayList.push(v); continue; }
      if (d >= today && d < tomorrow) todayList.push(v);
      else if (d < today) overdue.push(v);
      else upcoming.push(v);
    }
    const byTime = (a: FsVisit, b: FsVisit) => (a.scheduled_start || '').localeCompare(b.scheduled_start || '');
    now.sort(byTime); todayList.sort(byTime); overdue.sort(byTime); upcoming.sort(byTime);

    const hero = now[0] || todayList[0] || overdue[0] || upcoming[0] || null;
    const buckets: Bucket[] = [];
    if (now.length) buckets.push({ key: 'now', label: 'In progress', visits: now });
    if (overdue.length) buckets.push({ key: 'overdue', label: 'Overdue', visits: overdue });
    if (todayList.length) buckets.push({ key: 'today', label: 'Later today', visits: todayList });
    if (upcoming.length) buckets.push({ key: 'upcoming', label: 'Coming up', visits: upcoming });
    // Drop the hero from the follow-on lists.
    const remaining = buckets
      .map((b) => ({ ...b, visits: b.visits.filter((v) => v.uuid !== hero?.uuid) }))
      .filter((b) => b.visits.length > 0);

    return {
      hero,
      remaining,
      stats: { inProgress: now.length, scheduled: todayList.length, done: doneToday },
      total: now.length + overdue.length + todayList.length + upcoming.length,
    };
  }, [visits]);

  const open = (uuid: string) => router.push(`/dashboard/field-service/my-work/${uuid}`);
  const todayLabel = new Date().toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });

  return (
    <div className="min-h-dvh px-4 sm:px-6 lg:px-8 pb-16" style={{ paddingBlock: 16 }}>
      <div className="flex items-center justify-between mb-1">
        <h1 className="text-2xl font-bold text-secondary-900">My Work</h1>
        <button type="button" onClick={load} aria-label="Refresh" className="p-2 rounded-full hover:bg-secondary-100 text-secondary-500">
          <RefreshCw className={cn('w-5 h-5', loading && 'animate-spin')} />
        </button>
      </div>
      <p className="text-sm text-secondary-500 mb-5">{todayLabel}</p>

      {loading && visits.length === 0 ? (
        <div className="flex items-center justify-center py-24 text-secondary-500">
          <Loader2 className="w-6 h-6 animate-spin mr-2" /> Loading your jobs…
        </div>
      ) : model.total === 0 ? (
        <div className="rounded-3xl border border-secondary-200 bg-surface p-12 text-center">
          <CheckCircle2 className="w-16 h-16 text-emerald-400 mx-auto mb-4" />
          <p className="text-xl font-semibold text-secondary-900">All clear</p>
          <p className="text-secondary-500 mt-1">
            No jobs waiting for you right now{model.stats.done > 0 ? ` — ${model.stats.done} done today.` : '.'}
          </p>
        </div>
      ) : (
        <div className="space-y-6">
          {/* Hero + summary fill the top row */}
          <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
            <div className="lg:col-span-2">
              {model.hero && <HeroCard visit={model.hero} onOpen={() => open(model.hero!.uuid)} />}
            </div>
            <div className="lg:col-span-1">
              <SummaryCard inProgress={model.stats.inProgress} scheduled={model.stats.scheduled} done={model.stats.done} />
            </div>
          </div>

          {/* Everything else */}
          {model.remaining.length > 0 ? (
            model.remaining.map((b) => (
              <section key={b.key}>
                <h2 className={cn('text-xs font-bold uppercase tracking-wide mb-2', b.key === 'overdue' ? 'text-red-600' : 'text-secondary-400')}>
                  {b.label} <span className="font-medium">({b.visits.length})</span>
                </h2>
                <ul className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
                  {b.visits.map((v) => (
                    <li key={v.uuid}>
                      <VisitRow visit={v} onOpen={() => open(v.uuid)} />
                    </li>
                  ))}
                </ul>
              </section>
            ))
          ) : (
            <p className="text-sm text-secondary-400">That&apos;s everything for now.</p>
          )}
        </div>
      )}
    </div>
  );
}

export default function MyWorkPage() {
  return (
    <ProtectedPage module="fs_visits" title="My Work">
      <MyWorkContent />
    </ProtectedPage>
  );
}
