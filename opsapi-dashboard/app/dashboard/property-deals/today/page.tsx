'use client';

/**
 * Property Deals — Today (SPEC §3.8 #1): what's due this week (deal tasks + renovation jobs),
 * my open tasks by urgency (the "why" on hover), red deals, approvals waiting and money at risk. Refreshes every 30 seconds.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { Target, RefreshCw, Compass } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card } from '@/components/ui';
import { pdService } from '@/services/property-deals.service';
import { PdPage, Stat, UrgencyScore, TaskStatusBadge, HealthBadge, gbp, dueText, Empty, ErrorNote, Spinner, BASE } from '@/components/property-deals/ui';
import TaskActions from '@/components/property-deals/TaskActions';
import DueSoon from '@/components/property-deals/DueSoon';
import { usePdData } from '@/components/property-deals/usePd';
import { startTour } from '@/components/property-deals/Tour';
import { cn } from '@/lib/utils';

export default function TodayPage() {
  return (
    <PdPage module="tasks">
      <Today />
    </PdPage>
  );
}

function Today() {
  const { data, error, loading, refresh } = usePdData(async () => (await pdService.today(100)).data, [], 30_000);
  const [filter, setFilter] = useState<'all' | 'overdue' | 'blocking'>('all');
  const tasks = (data?.tasks || []).filter((t) => (filter === 'overdue' ? t.overdue : filter === 'blocking' ? t.blocking : true));

  return (
    <div className="space-y-6">
      <PageHeader
        title="Today"
        description={data?.today ? `Your deals work for ${new Date(data.today).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })}` : 'Your deals work'}
        icon={<Target className="h-6 w-6" />}
        actions={
          <>
            <Button variant="ghost" leftIcon={<Compass className="h-4 w-4" />} onClick={() => startTour()} data-tour="tour-button">
              Take the tour
            </Button>
            <Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={refresh}>
              Refresh
            </Button>
          </>
        }
      />
      <ErrorNote error={error} />
      {loading && !data ? (
        <Spinner />
      ) : data ? (
        <>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4" data-tour="today-stats">
            <Stat label="Open tasks" value={data.counts.open ?? 0} hint={`${data.counts.due_today ?? 0} due today`} />
            <Stat label="Overdue" value={data.counts.overdue ?? 0} tone={(data.counts.overdue ?? 0) > 0 ? 'error' : 'success'} />
            <Stat label="Approvals waiting" value={data.approvals_waiting_count ?? data.approvals_waiting.length} tone={data.approvals_waiting.length ? 'warning' : undefined} tour="today-approvals" />
            <Stat label="Money at risk" value={gbp(data.money_at_risk)} tone={(data.money_at_risk ?? 0) > 0 ? 'error' : undefined} hint="Late penalties if dates slip" />
          </div>

          <DueSoon />

          <div className="grid gap-6 lg:grid-cols-3">
            <Card padding="none" className="lg:col-span-2" data-tour="today-tasks">
              <div className="flex flex-wrap items-center justify-between gap-2 border-b border-secondary-200 p-4">
                <h2 className="font-semibold text-secondary-900">My tasks, most urgent first</h2>
                <div className="flex gap-1" role="group" aria-label="Filter tasks">
                  {(['all', 'overdue', 'blocking'] as const).map((f) => (
                    <Button key={f} size="sm" variant={filter === f ? 'secondary' : 'ghost'} onClick={() => setFilter(f)} aria-pressed={filter === f}>
                      {f === 'all' ? 'All' : f === 'overdue' ? 'Overdue' : 'Blocking'}
                    </Button>
                  ))}
                </div>
              </div>
              {tasks.length === 0 ? (
                <div className="p-6"><Empty title="Nothing here">No open tasks match. Nice.</Empty></div>
              ) : (
                <ul className="divide-y divide-secondary-100">
                  {tasks.map((t) => {
                    const due = dueText(t.due_at);
                    return (
                      <li key={t.task_uuid} className="flex flex-col gap-2 p-4 sm:flex-row sm:items-start">
                        <UrgencyScore score={t.urgency_score} why={t.urgency_why} />
                        <div className="min-w-0 flex-1">
                          <div className="flex flex-wrap items-center gap-2">
                            <span className="font-medium text-secondary-900">{t.title}</span>
                            <TaskStatusBadge status={t.pd_status} />
                            {t.blocking && <span className="rounded bg-secondary-100 px-1.5 text-xs text-secondary-600">blocking</span>}
                          </div>
                          <div className="mt-0.5 flex flex-wrap gap-x-3 text-sm text-secondary-500">
                            {t.deal_uuid ? (
                              <Link className="text-primary-600 hover:underline" href={`${BASE}/deals/${t.deal_uuid}`}>{t.deal_name || 'Deal'}</Link>
                            ) : (
                              <span>No deal yet</span>
                            )}
                            <span className={cn(due.overdue && 'font-semibold text-error-600')}>{due.text}</span>
                          </div>
                          <div className="mt-2">
                            <TaskActions task={t} onChanged={refresh} compact />
                          </div>
                        </div>
                      </li>
                    );
                  })}
                </ul>
              )}
            </Card>

            <div className="space-y-6">
              <Card padding="none" data-tour="today-red-deals">
                <h2 className="border-b border-secondary-200 p-4 font-semibold text-secondary-900">Deals at risk</h2>
                {data.red_deals.length === 0 ? (
                  <p className="p-4 text-sm text-secondary-500">No red deals.</p>
                ) : (
                  <ul className="divide-y divide-secondary-100">
                    {data.red_deals.map((d) => (
                      <li key={d.uuid} className="p-4">
                        <div className="flex items-center justify-between gap-2">
                          <Link href={`${BASE}/deals/${d.uuid}`} className="font-medium text-primary-600 hover:underline">{d.name}</Link>
                          <HealthBadge health={d.health} reasons={d.health_reasons} />
                        </div>
                        <div className="mt-1 text-sm text-secondary-500">{gbp(d.money_at_risk)} at risk</div>
                        {d.health_reasons?.[0] && <div className="mt-1 text-xs text-secondary-500">{d.health_reasons[0]}</div>}
                      </li>
                    ))}
                  </ul>
                )}
              </Card>
              <Card padding="none">
                <div className="flex items-center justify-between border-b border-secondary-200 p-4">
                  <h2 className="font-semibold text-secondary-900">Waiting for approval</h2>
                  <Link className="text-sm text-primary-600 hover:underline" href={`${BASE}/approvals`}>Open inbox</Link>
                </div>
                {data.approvals_waiting.length === 0 ? (
                  <p className="p-4 text-sm text-secondary-500">Nothing to approve.</p>
                ) : (
                  <ul className="divide-y divide-secondary-100">
                    {data.approvals_waiting.slice(0, 6).map((a) => (
                      <li key={a.uuid} className="p-4 text-sm">
                        <div className="font-medium text-secondary-900">{a.title}</div>
                        <div className="text-secondary-500">
                          {a.agent_key ? `AI: ${a.agent_key.replace(/_/g, ' ')}` : 'Requested by a person'}
                          {a.from_jobshout ? ' · JobShout' : ''}
                        </div>
                      </li>
                    ))}
                  </ul>
                )}
              </Card>
            </div>
          </div>
        </>
      ) : null}
    </div>
  );
}
