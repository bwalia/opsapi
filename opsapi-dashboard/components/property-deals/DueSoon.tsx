'use client';

/**
 * "Due" on the Today screen: deal tasks and renovation jobs due in the next
 * week, grouped Overdue / Today / Tomorrow / Later. Managers see the whole team
 * (with a "Mine" switch); everyone else sees their own.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { CalendarClock, Hammer, ListChecks } from 'lucide-react';
import { Button, Card } from '@/components/ui';
import { pdService, type DueItem } from '@/services/property-deals.service';
import { usePdData } from './usePd';
import { BASE, dueText, Spinner, ErrorNote } from './ui';
import { cn } from '@/lib/utils';

type Bucket = 'overdue' | 'today' | 'tomorrow' | 'later';
const BUCKETS: { key: Bucket; label: string; tone: string }[] = [
  { key: 'overdue', label: 'Overdue', tone: 'text-error-600' },
  { key: 'today', label: 'Due today', tone: 'text-warning-700' },
  { key: 'tomorrow', label: 'Due tomorrow', tone: 'text-secondary-900' },
  { key: 'later', label: 'Later', tone: 'text-secondary-700' },
];

function dayKey(d: Date): string {
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

function bucketOf(item: DueItem, now: Date): Bucket {
  const due = new Date(item.due_at);
  if (item.overdue || due.getTime() < now.getTime()) return 'overdue';
  if (dayKey(due) === dayKey(now)) return 'today';
  const tomorrow = new Date(now);
  tomorrow.setDate(now.getDate() + 1);
  return dayKey(due) === dayKey(tomorrow) ? 'tomorrow' : 'later';
}

export default function DueSoon() {
  const [days, setDays] = useState(7);
  const [mine, setMine] = useState(false);
  const { data, error, loading } = usePdData(async () => (await pdService.due(days, mine)).data, [days, mine], 60_000);
  const [now] = useState(() => new Date());

  const grouped: Record<Bucket, DueItem[]> = { overdue: [], today: [], tomorrow: [], later: [] };
  for (const item of data?.items || []) grouped[bucketOf(item, now)].push(item);

  return (
    <Card padding="none" data-tour="today-due">
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-secondary-200 p-4">
        <div className="flex items-center gap-2">
          <CalendarClock className="h-5 w-5 text-primary-600" aria-hidden />
          <h2 className="font-semibold text-secondary-900">
            Due {days === 7 ? 'this week' : `in the next ${days} days`}
            {data && !data.everyone ? ' — mine' : data?.everyone ? ' — whole team' : ''}
          </h2>
        </div>
        <div className="flex flex-wrap gap-1">
          {(data?.everyone || mine) && (
            <Button size="sm" variant={mine ? 'secondary' : 'ghost'} onClick={() => setMine((m) => !m)} aria-pressed={mine}>
              Only mine
            </Button>
          )}
          {[7, 14, 30].map((d) => (
            <Button key={d} size="sm" variant={days === d ? 'secondary' : 'ghost'} onClick={() => setDays(d)} aria-pressed={days === d}>
              {d} days
            </Button>
          ))}
        </div>
      </div>
      <ErrorNote error={error} />
      {loading && !data ? (
        <Spinner />
      ) : (data?.items.length ?? 0) === 0 ? (
        <p className="p-4 text-sm text-secondary-500">Nothing due. Deal tasks and renovation jobs with a due date show here.</p>
      ) : (
        <div className="grid gap-px bg-secondary-100 md:grid-cols-2 xl:grid-cols-4">
          {BUCKETS.map((b) => (
            <section key={b.key} className="bg-surface p-4" aria-label={b.label}>
              <h3 className={cn('mb-2 flex items-center justify-between text-sm font-semibold', b.tone)}>
                {b.label}
                <span className="rounded-full bg-secondary-100 px-2 text-xs text-secondary-700">{grouped[b.key].length}</span>
              </h3>
              {grouped[b.key].length === 0 ? (
                <p className="text-xs text-secondary-400">None</p>
              ) : (
                <ul className="space-y-2">
                  {grouped[b.key].slice(0, 12).map((item) => (
                    <DueRow key={`${item.kind}:${item.uuid}`} item={item} />
                  ))}
                  {grouped[b.key].length > 12 && (
                    <li className="text-xs text-secondary-500">+{grouped[b.key].length - 12} more</li>
                  )}
                </ul>
              )}
            </section>
          ))}
        </div>
      )}
    </Card>
  );
}

function DueRow({ item }: { item: DueItem }) {
  const due = dueText(item.due_at);
  const renovation = item.kind === 'renovation_job';
  const href = renovation
    ? `/dashboard/projects/${item.project_uuid}`
    : item.deal_uuid
      ? `${BASE}/deals/${item.deal_uuid}`
      : `${BASE}/today`;
  const Icon = renovation ? Hammer : ListChecks;
  return (
    <li className="rounded-lg border border-secondary-200 p-2 text-sm">
      <Link href={href} className="flex items-start gap-2 hover:text-primary-600">
        <Icon className="mt-0.5 h-4 w-4 shrink-0 text-secondary-400" aria-label={renovation ? 'Renovation job' : 'Deal task'} />
        <span className="min-w-0 flex-1">
          <span className="block font-medium text-secondary-900">{item.title}</span>
          <span className="block truncate text-xs text-secondary-500">
            {renovation ? `${item.project_name}${item.column_name ? ` · ${item.column_name}` : ''}` : item.deal_name || 'No deal yet'}
          </span>
          <span className="mt-0.5 flex flex-wrap gap-x-2 text-xs">
            <span className={cn(due.overdue ? 'font-semibold text-error-600' : 'text-secondary-500')}>{due.text}</span>
            {item.assignee && <span className="text-secondary-500">{item.assignee}</span>}
          </span>
        </span>
      </Link>
    </li>
  );
}
