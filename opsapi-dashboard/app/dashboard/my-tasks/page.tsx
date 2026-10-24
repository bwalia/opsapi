'use client';

/**
 * My Tasks: the open tasks assigned to me across every project, most urgent
 * first (GET /api/v2/kanban/my-tasks). "Today" includes overdue work.
 */
import React, { useCallback, useMemo, useState } from 'react';
import { ListTodo, Loader2, RefreshCw } from 'lucide-react';
import { Button, Card, Pagination } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { TaskLinkRow } from '@/components/tasks/TaskBits';
import { useDataFetch } from '@/hooks';
import { formatPriority, kanbanService, localDate, type MyTask, type MyTasksDue } from '@/services/kanban.service';
import type { KanbanTaskPriority } from '@/types';

const TABS: { key: string; label: string; due?: MyTasksDue; empty: string }[] = [
  { key: 'today', label: 'Today', due: 'today_and_overdue', empty: 'Nothing due today or overdue.' },
  { key: 'week', label: 'This week', due: 'week', empty: 'Nothing due in the next 7 days.' },
  { key: 'all', label: 'All open', empty: 'No open tasks are assigned to you.' },
];
const PRIORITIES: KanbanTaskPriority[] = ['critical', 'high', 'medium', 'low', 'none'];
const PER_PAGE = 50;

function MyTasksContent() {
  const [tab, setTab] = useState(TABS[0]);
  const [priority, setPriority] = useState<'' | KanbanTaskPriority>('');
  const [page, setPage] = useState(1);
  // The user's local "today", fixed for the visit so every tab agrees.
  const today = useMemo(() => localDate(), []);

  const fetcher = useCallback(
    () => kanbanService.getMyTasks({ due: tab.due, date: today, priority: priority || undefined, page, perPage: PER_PAGE }),
    [tab, today, priority, page]
  );
  const { data, isLoading, error, refetch } = useDataFetch(fetcher);
  const meta = data?.meta;
  const tasks = data?.data;
  // How many open tasks there are in all, so an empty "Today" doesn't look like "nothing to do"
  // (tasks with no due date, or due later, only show under "All open").
  const countFetcher = useCallback(() => kanbanService.getMyTasks({ date: today, page: 1, perPage: 1 }), [today]);
  const { data: allOpen } = useDataFetch(countFetcher);
  const openTotal = allOpen?.meta?.total ?? 0;

  // Already sorted by priority, then due date: group consecutive rows.
  const groups = useMemo(() => {
    const out: { priority: KanbanTaskPriority; tasks: MyTask[] }[] = [];
    for (const t of tasks ?? []) {
      const last = out[out.length - 1];
      if (last && last.priority === t.priority) last.tasks.push(t);
      else out.push({ priority: t.priority, tasks: [t] });
    }
    return out;
  }, [tasks]);

  const choose = (next: (typeof TABS)[number]) => {
    setTab(next);
    setPage(1);
  };

  return (
    <div className="space-y-5">
      <PageHeader
        title="My Tasks"
        description="Open tasks assigned to you across all projects, most urgent first."
        icon={<ListTodo className="h-5 w-5" />}
        actions={
          <Button variant="ghost" size="sm" onClick={() => void refetch()} disabled={isLoading} aria-label="Refresh">
            <RefreshCw className={isLoading ? 'h-4 w-4 animate-spin' : 'h-4 w-4'} />
          </Button>
        }
      />

      <div className="flex flex-wrap items-center justify-between gap-3">
        <div role="group" aria-label="Which tasks" className="inline-flex rounded-lg border border-secondary-200 bg-surface p-1">
          {TABS.map((t) => (
            <button
              key={t.key}
              type="button"
              onClick={() => choose(t)}
              aria-pressed={tab.key === t.key}
              className={`rounded-md px-3 py-1.5 text-sm font-medium transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 ${
                tab.key === t.key ? 'bg-primary-500 text-white' : 'text-secondary-600 hover:bg-secondary-100'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>
        <label className="flex items-center gap-2 text-sm text-secondary-600">
          Priority
          <select
            value={priority}
            onChange={(e) => {
              setPriority(e.target.value as '' | KanbanTaskPriority);
              setPage(1);
            }}
            className="rounded-lg border border-secondary-300 bg-surface px-2.5 py-1.5 text-sm text-secondary-900 focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500"
          >
            <option value="">All</option>
            {PRIORITIES.map((p) => (
              <option key={p} value={p}>
                {formatPriority(p)}
              </option>
            ))}
          </select>
        </label>
      </div>

      <Card padding="none" aria-busy={isLoading}>
        {error ? (
          <div className="flex flex-col items-center gap-3 p-10 text-center" role="alert">
            <p className="text-sm text-secondary-600">Couldn&apos;t load your tasks.</p>
            <Button variant="outline" size="sm" onClick={() => void refetch()}>
              Try again
            </Button>
          </div>
        ) : isLoading && !data ? (
          <div className="flex justify-center p-10 text-secondary-400">
            <Loader2 className="h-6 w-6 animate-spin" aria-label="Loading" />
          </div>
        ) : groups.length === 0 ? (
          <div className="flex flex-col items-center gap-3 p-10 text-center">
            <p className="text-sm text-secondary-500">
              {priority ? `No ${formatPriority(priority).toLowerCase()}-priority tasks here.` : tab.empty}
            </p>
            {tab.due && !priority && openTotal > 0 && (
              <>
                <p className="text-sm text-secondary-700">
                  You have {openTotal} other open {openTotal === 1 ? 'task' : 'tasks'}.
                </p>
                <Button variant="outline" size="sm" onClick={() => choose(TABS[2])}>
                  Show all open tasks
                </Button>
              </>
            )}
          </div>
        ) : (
          groups.map((g) => (
            <section key={g.priority} aria-label={`${formatPriority(g.priority)} priority`}>
              <h2 className="border-b border-secondary-200 bg-secondary-50 px-4 py-2 text-xs font-semibold uppercase tracking-wide text-secondary-500">
                {formatPriority(g.priority)} <span className="font-normal">({g.tasks.length})</span>
              </h2>
              <ul className="divide-y divide-secondary-100">
                {g.tasks.map((t) => (
                  <li key={t.uuid}>
                    <TaskLinkRow
                      url={t.url}
                      taskNumber={t.task_number}
                      title={t.title}
                      priority={t.priority}
                      project={t.project_name}
                      dueDate={t.due_date}
                      today={meta?.date || today}
                    />
                  </li>
                ))}
              </ul>
            </section>
          ))
        )}
      </Card>

      {meta && meta.total_pages > 1 && (
        <Pagination
          currentPage={meta.page}
          totalPages={meta.total_pages}
          totalItems={meta.total}
          perPage={meta.per_page}
          onPageChange={setPage}
        />
      )}
    </div>
  );
}

export default function MyTasksPage() {
  return (
    <ProtectedPage module="projects" action="read" title="My Tasks">
      <MyTasksContent />
    </ProtectedPage>
  );
}
