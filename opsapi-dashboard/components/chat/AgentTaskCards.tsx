'use client';

/**
 * Task cards under an assistant reply: the tasks a successful `list_my_tasks`
 * tool call returned (lapis/lib/agent/tools.lua), each with an in-app Open link.
 */
import React from 'react';
import Link from 'next/link';
import { ArrowRight } from 'lucide-react';
import type { AgentAction } from '@/services/chat.service';
import type { KanbanTaskPriority } from '@/types';
import { localDate } from '@/services/kanban.service';
import { PriorityBadge, dueLabel } from '@/components/tasks/TaskBits';

/** A row of the list_my_tasks tool result. */
export interface AgentTask {
  uuid: string;
  task_number?: number;
  title: string;
  priority: KanbanTaskPriority;
  status?: string;
  due_date?: string | null;
  overdue?: boolean;
  project?: string;
  project_uuid?: string;
  column?: string;
  url: string;
}

/** The tasks of the turn's last successful list_my_tasks call, and the "today" it used. */
export function tasksFromActions(actions?: AgentAction[]): { tasks: AgentTask[]; today: string } | null {
  for (let i = (actions?.length ?? 0) - 1; i >= 0; i--) {
    const a = actions![i];
    if (a.name !== 'list_my_tasks' || a.error) continue;
    const result = (a.result ?? {}) as { tasks?: unknown; date?: string };
    // An empty Lua table arrives as {} rather than [].
    const tasks = Array.isArray(result.tasks)
      ? (result.tasks as AgentTask[]).filter((t) => t && typeof t.url === 'string' && t.url.startsWith('/') && !t.url.startsWith('//'))
      : [];
    return tasks.length ? { tasks, today: result.date || localDate() } : null;
  }
  return null;
}

interface AgentTaskCardsProps {
  tasks: AgentTask[];
  today: string;
  /**
   * The "Start with AI" action for a task (AI Task Runner, docs/AI_RUNNER.md §16). AgentPane passes
   * StartWithAIButton, which renders nothing unless AI Runs is on here and the user may start runs.
   */
  renderStartWithAI?: (task: AgentTask) => React.ReactNode;
}

export function AgentTaskCards({ tasks, today, renderStartWithAI }: AgentTaskCardsProps) {
  return (
    <ul className="mt-1.5 space-y-1.5" aria-label="Your tasks">
      {tasks.map((t) => {
        const due = dueLabel(t.due_date, today);
        const name = `${t.task_number != null ? `#${t.task_number} ` : ''}${t.title}`;
        return (
          <li key={t.uuid} className="rounded-xl border border-secondary-200 bg-surface px-3 py-2 shadow-sm">
            <div className="flex items-start gap-2">
              <PriorityBadge priority={t.priority} />
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm font-medium text-secondary-900" title={name}>{name}</p>
                <p className="truncate text-xs text-secondary-500">
                  {t.project}
                  {due && (
                    <>
                      {t.project ? ' · ' : ''}
                      <span className={due.className}>{due.text}</span>
                    </>
                  )}
                </p>
              </div>
              <div className="flex shrink-0 items-center gap-1">
                {renderStartWithAI?.(t)}
                <Link
                  href={t.url}
                  aria-label={`Open ${name}`}
                  className="inline-flex min-h-8 items-center gap-1 rounded-lg px-2 text-xs font-semibold text-primary-600 transition hover:bg-primary-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500"
                >
                  Open <ArrowRight className="h-3 w-3" aria-hidden />
                </Link>
              </div>
            </div>
          </li>
        );
      })}
    </ul>
  );
}

export default AgentTaskCards;
