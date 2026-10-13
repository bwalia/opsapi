/**
 * Small shared pieces for "my tasks" lists: the My Tasks page, the home widget
 * and the assistant's task cards.
 */
import React from 'react';
import Link from 'next/link';
import { cn } from '@/lib/utils';
import { formatPriority, getPriorityColor } from '@/services/kanban.service';
import type { KanbanTaskPriority } from '@/types';

/** Priority as colour AND text (never colour alone). */
export function PriorityBadge({ priority }: { priority: KanbanTaskPriority }) {
  return (
    <span
      className={cn(
        'inline-flex shrink-0 items-center rounded border px-1.5 py-0.5 text-[11px] font-semibold leading-none',
        getPriorityColor(priority)
      )}
    >
      {formatPriority(priority)}
    </span>
  );
}

function shortDate(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  return date.toLocaleDateString(undefined, {
    day: 'numeric',
    month: 'short',
    ...(y !== new Date().getFullYear() ? { year: 'numeric' } : {}),
  });
}

/** "Overdue · 9 Oct" / "Today" / "14 Oct", relative to `today` (YYYY-MM-DD). */
export function dueLabel(due: string | null | undefined, today: string): { text: string; className: string } | null {
  if (!due) return null;
  const day = due.slice(0, 10);
  if (day < today) return { text: `Overdue · ${shortDate(day)}`, className: 'text-error-600' };
  if (day === today) return { text: 'Today', className: 'text-warning-700' };
  return { text: shortDate(day), className: 'text-secondary-500' };
}

export interface TaskLinkRowProps {
  url: string;
  taskNumber?: number | string;
  title: string;
  priority: KanbanTaskPriority;
  project?: string | null;
  dueDate?: string | null;
  today: string;
}

/** One task as a single keyboard-focusable link to its task page. */
export function TaskLinkRow({ url, taskNumber, title, priority, project, dueDate, today }: TaskLinkRowProps) {
  const due = dueLabel(dueDate, today);
  return (
    <Link
      href={url}
      className="flex items-center gap-3 px-4 py-3 transition hover:bg-secondary-50 focus-visible:bg-secondary-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary-500"
    >
      <PriorityBadge priority={priority} />
      <span className="min-w-0 flex-1">
        <span className="block truncate text-sm font-medium text-secondary-900">
          {taskNumber != null && <span className="text-secondary-400">#{taskNumber} </span>}
          {title}
        </span>
        {project && <span className="block truncate text-xs text-secondary-500">{project}</span>}
      </span>
      {due && <span className={cn('shrink-0 text-xs font-medium', due.className)}>{due.text}</span>}
    </Link>
  );
}
