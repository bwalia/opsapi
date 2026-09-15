'use client';

/**
 * My Work — /dashboard/field-service/my-work
 *
 * The engineer's home. No calendar, no filters: just a phone-first list of the
 * jobs they need to do — what's in progress now, today's visits, anything
 * overdue, then what's coming up. Tapping a card opens the guided work screen.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { MapPin, ChevronRight, RefreshCw, Loader2, CheckCircle2, Wrench } from 'lucide-react';
import { ProtectedPage } from '@/components/permissions';
import { fieldService, parseFsDate, formatFsDateTime, type FsVisit } from '@/services/field-service.service';
import { siteAddressFromJob, apiError } from '@/components/field-service/shared';
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

/** A short, plain-language line for where the visit is in its lifecycle. */
function statusLine(v: FsVisit): { text: string; tone: string } {
  if (v.status === 'on_site') return { text: 'On site now', tone: 'text-emerald-700 bg-emerald-50' };
  if (v.status === 'en_route') return { text: 'On the way', tone: 'text-blue-700 bg-blue-50' };
  if (v.status === 'no_access') return { text: 'No access — revisit', tone: 'text-amber-700 bg-amber-50' };
  // Date + time so multiple visits to the same job stay distinguishable.
  return { text: formatFsDateTime(v.scheduled_start), tone: 'text-secondary-700 bg-secondary-100' };
}

function VisitCard({ visit, onOpen }: { visit: FsVisit; onOpen: () => void }) {
  const s = statusLine(visit);
  const address = siteAddressFromJob(visit);
  const urgent = visit.job_priority === 'high' || visit.job_priority === 'urgent';
  return (
    <button
      type="button"
      onClick={onOpen}
      className="w-full text-left bg-surface rounded-2xl border border-secondary-200 p-4 shadow-sm active:scale-[0.99] transition flex items-center gap-3"
      style={{ minHeight: 88 }}
    >
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2 mb-1">
          <span className={cn('inline-block rounded-full px-2.5 py-1 text-xs font-semibold', s.tone)}>{s.text}</span>
          {urgent && <span className="inline-block rounded-full px-2 py-0.5 text-xs font-semibold text-red-700 bg-red-50">Urgent</span>}
        </div>
        <p className="text-base font-semibold text-secondary-900 truncate">{visit.job_title || 'Service visit'}</p>
        <p className="text-sm text-secondary-600 truncate">{visit.customer_name || 'No customer'}</p>
        {address && (
          <p className="mt-1 flex items-center gap-1 text-sm text-secondary-500 truncate">
            <MapPin className="w-4 h-4 shrink-0" /> {address}
          </p>
        )}
      </div>
      <ChevronRight className="w-6 h-6 text-secondary-300 shrink-0" />
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

  const buckets = useMemo<Bucket[]>(() => {
    const today = startOfDay(new Date());
    const tomorrow = addDays(today, 1);
    const now: FsVisit[] = [];
    const todayList: FsVisit[] = [];
    const overdue: FsVisit[] = [];
    const upcoming: FsVisit[] = [];

    for (const v of visits) {
      if (DONE.has(v.status)) continue; // done jobs drop off the list
      const d = parseFsDate(v.scheduled_start);
      if (ACTIVE.has(v.status)) { now.push(v); continue; }
      if (!d) { todayList.push(v); continue; }
      if (d >= today && d < tomorrow) todayList.push(v);
      else if (d < today) overdue.push(v);
      else upcoming.push(v);
    }
    const byTime = (a: FsVisit, b: FsVisit) => (a.scheduled_start || '').localeCompare(b.scheduled_start || '');
    now.sort(byTime); todayList.sort(byTime); overdue.sort(byTime); upcoming.sort(byTime);

    const out: Bucket[] = [];
    if (now.length) out.push({ key: 'now', label: 'In progress', visits: now });
    if (overdue.length) out.push({ key: 'overdue', label: 'Overdue', visits: overdue });
    out.push({ key: 'today', label: 'Today', visits: todayList });
    if (upcoming.length) out.push({ key: 'upcoming', label: 'Coming up', visits: upcoming });
    return out;
  }, [visits]);

  const totalOpen = buckets.reduce((n, b) => n + b.visits.length, 0);
  const open = (uuid: string) => router.push(`/dashboard/field-service/my-work/${uuid}`);
  const todayLabel = new Date().toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });

  return (
    <div className="min-h-dvh px-4 sm:px-6 lg:px-8 pb-16" style={{ paddingBlock: 16 }}>
      <div className="flex items-center justify-between mb-1">
        <h1 className="text-2xl font-bold text-secondary-900">My Work</h1>
        <button
          type="button"
          onClick={load}
          aria-label="Refresh"
          className="p-2 rounded-full hover:bg-secondary-100 text-secondary-500"
        >
          <RefreshCw className={cn('w-5 h-5', loading && 'animate-spin')} />
        </button>
      </div>
      <p className="text-sm text-secondary-500 mb-5">{todayLabel}</p>

      {loading && visits.length === 0 ? (
        <div className="flex items-center justify-center py-24 text-secondary-500">
          <Loader2 className="w-6 h-6 animate-spin mr-2" /> Loading your jobs…
        </div>
      ) : totalOpen === 0 ? (
        <div className="text-center py-20">
          <CheckCircle2 className="w-14 h-14 text-emerald-400 mx-auto mb-3" />
          <p className="text-lg font-semibold text-secondary-900">All clear</p>
          <p className="text-secondary-500">No jobs waiting for you right now.</p>
        </div>
      ) : (
        <div className="space-y-6">
          {buckets.map((b) => (
            <section key={b.key}>
              <h2
                className={cn(
                  'text-xs font-bold uppercase tracking-wide mb-2',
                  b.key === 'overdue' ? 'text-red-600' : b.key === 'now' ? 'text-emerald-600' : 'text-secondary-400'
                )}
              >
                {b.label}
                {b.visits.length > 0 && <span className="ml-1 font-medium">({b.visits.length})</span>}
              </h2>
              {b.visits.length === 0 ? (
                <p className="text-sm text-secondary-400 flex items-center gap-2">
                  <Wrench className="w-4 h-4" /> Nothing scheduled today.
                </p>
              ) : (
                <ul className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4 gap-3">
                  {b.visits.map((v) => (
                    <li key={v.uuid}>
                      <VisitCard visit={v} onOpen={() => open(v.uuid)} />
                    </li>
                  ))}
                </ul>
              )}
            </section>
          ))}
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
