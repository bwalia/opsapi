'use client';

/** Home widget: my top 5 tasks due today or overdue, by priority, with a link to My Tasks. */
import React, { useCallback, useMemo } from 'react';
import Link from 'next/link';
import { ListTodo, Loader2 } from 'lucide-react';
import { Card } from '@/components/ui';
import { TaskLinkRow } from '@/components/tasks/TaskBits';
import { useDataFetch } from '@/hooks';
import { kanbanService, localDate } from '@/services/kanban.service';

export default function MyTasksToday() {
  const today = useMemo(() => localDate(), []);
  const fetcher = useCallback(
    () => kanbanService.getMyTasks({ due: 'today_and_overdue', date: today, perPage: 5 }),
    [today]
  );
  const { data, isLoading, error } = useDataFetch(fetcher);
  // Projects not deployed on this server: no widget rather than an error.
  if ((error as { response?: { status?: number } } | null)?.response?.status === 404) return null;
  const tasks = data?.data ?? [];
  const total = data?.meta.total ?? 0;

  return (
    <Card padding="none">
      <div className="flex items-center justify-between gap-2 border-b border-secondary-200 p-4">
        <h2 className="flex items-center gap-2 font-semibold text-secondary-900">
          <ListTodo className="h-5 w-5 text-primary-600" aria-hidden />
          My tasks today
          {total > 0 && (
            <span className="rounded-full bg-secondary-100 px-2 text-xs font-medium text-secondary-700">{total}</span>
          )}
        </h2>
        <Link href="/dashboard/my-tasks" className="text-sm font-medium text-primary-600 hover:underline">
          View all
        </Link>
      </div>
      {error ? (
        <p className="p-4 text-sm text-secondary-500" role="alert">Couldn&apos;t load your tasks.</p>
      ) : isLoading && !data ? (
        <div className="flex justify-center p-6 text-secondary-400">
          <Loader2 className="h-5 w-5 animate-spin" aria-label="Loading" />
        </div>
      ) : tasks.length === 0 ? (
        <p className="p-4 text-sm text-secondary-500">Nothing due today or overdue.</p>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {tasks.map((t) => (
            <li key={t.uuid}>
              <TaskLinkRow
                url={t.url}
                taskNumber={t.task_number}
                title={t.title}
                priority={t.priority}
                project={t.project_name}
                dueDate={t.due_date}
                today={data?.meta.date || today}
              />
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
