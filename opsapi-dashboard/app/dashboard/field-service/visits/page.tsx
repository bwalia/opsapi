'use client';

/**
 * Site Visits — /dashboard/field-service/visits
 *
 * The engineer schedule. Engineers see "My visits"; service managers can
 * switch to every engineer's visits, filter by engineer (or unassigned) and
 * status, and page through days or weeks.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { CalendarClock, ChevronLeft, ChevronRight, MapPin, RefreshCw, User, AlertTriangle, Loader2 } from 'lucide-react';
import { Button, Card } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { fieldService, formatFsTime, parseFsDate, type FsEngineer, type FsVisit } from '@/services/field-service.service';
import {
  FieldServiceNav,
  FilterSelect,
  JobPriorityPill,
  VisitStatusPill,
  VISIT_STATUS_OPTIONS,
  apiError,
} from '@/components/field-service/shared';
import { cn } from '@/lib/utils';

type Range = 'day' | 'week';

function startOfDay(d: Date): Date {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x;
}

function startOfWeek(d: Date): Date {
  const x = startOfDay(d);
  const day = (x.getDay() + 6) % 7; // Monday = 0
  x.setDate(x.getDate() - day);
  return x;
}

function addDays(d: Date, n: number): Date {
  const x = new Date(d);
  x.setDate(x.getDate() + n);
  return x;
}

function dayKey(d: Date): string {
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

function VisitsPageContent() {
  const router = useRouter();
  const { canRead } = usePermissions();
  const canSeeAll = canRead('fs_visits');

  const [mine, setMine] = useState(!canSeeAll);
  const [range, setRange] = useState<Range>('week');
  const [anchor, setAnchor] = useState(() => startOfDay(new Date()));
  const [engineerFilter, setEngineerFilter] = useState('all');
  const [statusFilter, setStatusFilter] = useState('all');
  const [engineers, setEngineers] = useState<FsEngineer[]>([]);
  const [visits, setVisits] = useState<FsVisit[]>([]);
  const [loading, setLoading] = useState(true);
  const fetchIdRef = useRef(0);

  const from = range === 'day' ? startOfDay(anchor) : startOfWeek(anchor);
  const to = addDays(from, range === 'day' ? 1 : 7);
  const fromIso = from.toISOString();
  const toIso = to.toISOString();

  useEffect(() => {
    if (canSeeAll) fieldService.getEngineers().then(setEngineers).catch(() => setEngineers([]));
  }, [canSeeAll]);

  const load = useCallback(async () => {
    const id = ++fetchIdRef.current;
    setLoading(true);
    try {
      const res = await fieldService.getVisits({
        mine,
        engineer_uuid: mine || engineerFilter === 'all' ? undefined : engineerFilter,
        status: statusFilter,
        from: fromIso,
        to: toIso,
        per_page: 200,
      });
      if (id === fetchIdRef.current) setVisits(res.data);
    } catch (err) {
      if (id === fetchIdRef.current) toast.error(apiError(err, 'Failed to load visits'));
    } finally {
      if (id === fetchIdRef.current) setLoading(false);
    }
  }, [mine, engineerFilter, statusFilter, fromIso, toIso]);

  useEffect(() => {
    load();
  }, [load]);

  const days = useMemo(() => {
    const count = range === 'day' ? 1 : 7;
    const start = new Date(fromIso);
    const buckets = Array.from({ length: count }, (_, i) => ({ date: addDays(start, i), visits: [] as FsVisit[] }));
    const index = new Map(buckets.map((b) => [dayKey(b.date), b]));
    for (const v of visits) {
      const d = parseFsDate(v.scheduled_start);
      if (!d) continue;
      index.get(dayKey(d))?.visits.push(v);
    }
    return buckets;
  }, [visits, range, fromIso]);

  const step = (dir: number) => setAnchor((a) => addDays(a, dir * (range === 'day' ? 1 : 7)));
  const today = startOfDay(new Date());

  const label =
    range === 'day'
      ? from.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })
      : `${from.toLocaleDateString(undefined, { day: 'numeric', month: 'short' })} – ${addDays(to, -1).toLocaleDateString(undefined, {
          day: 'numeric',
          month: 'short',
          year: 'numeric',
        })}`;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Site Visits"
        description={mine ? 'Your booked site visits.' : 'Every engineer visit across your jobs.'}
        icon={<CalendarClock className="w-5 h-5" />}
        actions={
          <Button variant="ghost" onClick={load} title="Refresh">
            <RefreshCw className="w-4 h-4" />
          </Button>
        }
      />
      <FieldServiceNav />

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-3">
          {canSeeAll && (
            <div className="inline-flex rounded-lg border border-secondary-300 p-0.5" role="group" aria-label="Whose visits">
              {[
                { v: true, l: 'My visits' },
                { v: false, l: 'All visits' },
              ].map((o) => (
                <button
                  key={o.l}
                  type="button"
                  onClick={() => setMine(o.v)}
                  className={cn(
                    'px-3 py-1.5 text-sm rounded-md',
                    mine === o.v ? 'bg-primary-500 text-white' : 'text-secondary-600 hover:bg-secondary-100'
                  )}
                  aria-pressed={mine === o.v}
                >
                  {o.l}
                </button>
              ))}
            </div>
          )}
          <div className="inline-flex rounded-lg border border-secondary-300 p-0.5" role="group" aria-label="Range">
            {(['day', 'week'] as Range[]).map((r) => (
              <button
                key={r}
                type="button"
                onClick={() => setRange(r)}
                className={cn('px-3 py-1.5 text-sm rounded-md capitalize', range === r ? 'bg-secondary-800 text-white' : 'text-secondary-600 hover:bg-secondary-100')}
                aria-pressed={range === r}
              >
                {r}
              </button>
            ))}
          </div>
          <div className="flex items-center gap-1">
            <Button variant="ghost" size="sm" onClick={() => step(-1)} aria-label="Previous">
              <ChevronLeft className="w-4 h-4" />
            </Button>
            <Button variant="ghost" size="sm" onClick={() => setAnchor(today)}>
              Today
            </Button>
            <Button variant="ghost" size="sm" onClick={() => step(1)} aria-label="Next">
              <ChevronRight className="w-4 h-4" />
            </Button>
            <span className="ml-2 text-sm font-medium text-secondary-800">{label}</span>
          </div>
          <div className="flex-1" />
          {!mine && (
            <FilterSelect
              ariaLabel="Engineer"
              value={engineerFilter}
              onChange={setEngineerFilter}
              options={[
                { value: 'all', label: 'All engineers' },
                { value: 'unassigned', label: 'Unassigned' },
                ...engineers.map((e) => ({ value: e.uuid, label: e.name || e.email })),
              ]}
            />
          )}
          <FilterSelect ariaLabel="Status" value={statusFilter} onChange={setStatusFilter} options={VISIT_STATUS_OPTIONS} />
        </div>
      </Card>

      {loading && visits.length === 0 ? (
        <div className="flex items-center justify-center py-16 text-secondary-500">
          <Loader2 className="w-5 h-5 animate-spin mr-2" /> Loading visits…
        </div>
      ) : (
        <div className="space-y-5">
          {days.map(({ date, visits: dayVisits }) => {
            const isToday = dayKey(date) === dayKey(today);
            if (range === 'week' && dayVisits.length === 0) {
              return (
                <div key={dayKey(date)} className="flex items-center gap-3 text-sm text-secondary-400">
                  <span className={cn('w-28 font-medium', isToday && 'text-primary-600')}>
                    {date.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' })}
                  </span>
                  <span>No visits</span>
                </div>
              );
            }
            return (
              <div key={dayKey(date)}>
                <h2 className={cn('text-sm font-semibold mb-2', isToday ? 'text-primary-600' : 'text-secondary-700')}>
                  {date.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' })}
                  {isToday && ' · Today'}
                  <span className="ml-2 font-normal text-secondary-400">{dayVisits.length} visit(s)</span>
                </h2>
                {dayVisits.length === 0 ? (
                  <p className="text-sm text-secondary-500">No visits.</p>
                ) : (
                  <ul className="grid grid-cols-1 lg:grid-cols-2 gap-3">
                    {dayVisits.map((v) => (
                      <li key={v.uuid}>
                        <button
                          type="button"
                          onClick={() => router.push(`/dashboard/field-service/visits/${v.uuid}`)}
                          className="w-full text-left bg-surface rounded-xl border border-secondary-200 p-4 shadow-sm hover:border-primary-300 hover:shadow transition"
                        >
                          <div className="flex items-start justify-between gap-3">
                            <div className="min-w-0">
                              <p className="text-sm font-semibold text-secondary-900">
                                {formatFsTime(v.scheduled_start)}
                                {v.scheduled_end ? ` – ${formatFsTime(v.scheduled_end)}` : ''}
                              </p>
                              <p className="font-medium text-secondary-900 truncate">
                                {v.job_number} · {v.job_title}
                              </p>
                              <p className="text-sm text-secondary-600 truncate">
                                {v.account_name || 'No customer'}
                                {v.phase_name ? ` · ${v.phase_name}` : ''}
                              </p>
                            </div>
                            <div className="flex flex-col items-end gap-1 shrink-0">
                              <VisitStatusPill status={v.status} />
                              {(v.job_priority === 'high' || v.job_priority === 'urgent') && <JobPriorityPill priority={v.job_priority} />}
                            </div>
                          </div>
                          <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-secondary-500">
                            {(v.site_postal_code || v.site_city) && (
                              <span className="inline-flex items-center gap-1">
                                <MapPin className="w-3 h-3" /> {[v.site_name, v.site_city, v.site_postal_code].filter(Boolean).join(', ')}
                              </span>
                            )}
                            <span className={cn('inline-flex items-center gap-1', !v.engineer_name && 'text-amber-600')}>
                              <User className="w-3 h-3" /> {v.engineer_name || 'Unassigned'}
                            </span>
                            {v.follow_up_required && (
                              <span className="inline-flex items-center gap-1 text-amber-600">
                                <AlertTriangle className="w-3 h-3" /> Follow-up
                              </span>
                            )}
                          </div>
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

export default function FieldServiceVisitsPage() {
  return (
    <ProtectedPage module="fs_visits" title="Site Visits">
      <VisitsPageContent />
    </ProtectedPage>
  );
}
