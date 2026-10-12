'use client';

/** A task's AI run history (GET /tasks/:uuid/runs), for the task page. Nothing renders while the plugin is off. */
import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { Bot } from 'lucide-react';
import { aiRunner, type Run } from '@/services/ai-runner.service';
import { BASE, RunResult, RunStatusBadge, useAiRunnerOn, when } from './ui';

export default function TaskRuns({ taskUuid }: { taskUuid: string }) {
  const on = useAiRunnerOn();
  const [runs, setRuns] = useState<Run[] | null>(null);
  useEffect(() => {
    if (!on) return;
    let live = true;
    aiRunner.taskRuns(taskUuid).then((r) => { if (live) setRuns(r); }, () => { if (live) setRuns(null); });
    return () => { live = false; };
  }, [on, taskUuid]);
  if (!on || !runs) return null;
  return (
    <section className="rounded-xl border border-secondary-200 bg-surface p-4" aria-labelledby="task-ai-runs">
      <h2 id="task-ai-runs" className="mb-2 flex items-center gap-1.5 text-xs font-medium text-secondary-500">
        <Bot size={14} aria-hidden /> AI runs
      </h2>
      {runs.length === 0 ? (
        <p className="text-sm text-secondary-400">No AI runs yet.</p>
      ) : (
        <ul className="space-y-1.5">
          {runs.slice(0, 10).map((r) => (
            <li key={r.uuid} className="flex items-center gap-2 text-sm">
              <RunStatusBadge status={r.status} />
              <Link href={`${BASE}/runs/${r.uuid}`} className="flex-1 truncate text-secondary-700 hover:text-primary-600 hover:underline">
                {when(r.created_at)}{r.attempt && r.attempt > 1 ? ` · attempt ${r.attempt}` : ''}
              </Link>
              <RunResult run={r} />
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
