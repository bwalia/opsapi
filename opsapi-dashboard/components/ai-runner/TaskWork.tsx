'use client';

/**
 * AI work panel on a task: latest prompt/context, conversation summary, PRs with manager sign-off, and its web terminal
 * sessions (docs/AI_RUNNER_WEB_TERMINAL.md). With nothing yet it explains the two ways (Let AI do it / Work on it with AI
 * myself) and offers Start with AI — the one way in, which asks how — plus "Show me how", a short tour of the page.
 */
import React, { useCallback, useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import Link from 'next/link';
import { Bot, Check, Compass, ExternalLink, GitPullRequest, MessageSquare, Terminal, X } from 'lucide-react';
import toast from 'react-hot-toast';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  aiRunner, aiError, type TaskPr, type TaskWorkBundle, type TerminalSession,
} from '@/services/ai-runner.service';
import { Button } from '@/components/ui';
import { PageTour, type TourStep } from '@/components/ui/PageTour';
import { StartWithAIDialog } from './StartWithAIDialog';
import { BASE, RunStatusBadge, compact, cost, duration, elapsed, useAiRunnerOn, when } from './ui';

const SESSION_STATUS: Record<string, { label: string; className: string }> = {
  launched: { label: 'Waiting to start', className: 'bg-info-500/10 text-info-700' },
  active: { label: 'Working now', className: 'bg-success-500/10 text-success-700' },
  ended: { label: 'Ended', className: 'bg-secondary-100 text-secondary-600' },
  expired: { label: 'Link not used', className: 'bg-secondary-100 text-secondary-500' },
};

function SessionLine({ s }: { s: TerminalSession }) {
  const st = SESSION_STATUS[s.status] || { label: s.status, className: 'bg-secondary-100 text-secondary-600' };
  const what = [s.agent_label || s.agent, s.path && `in ${s.path}`].filter(Boolean).join(' ');
  return (
    <li className="space-y-0.5 text-xs text-secondary-600">
      <div className="flex flex-wrap items-center gap-2">
        <span className={`shrink-0 rounded px-1.5 py-0.5 font-medium ${st.className}`}>{st.label}</span>
        <span className="min-w-0 truncate font-mono" title={what || undefined}>{what || 'Web terminal'}</span>
      </div>
      <p className="text-secondary-500">
        {s.opened_by_name || 'Someone'}
        {s.terminal_name ? ` · ${s.terminal_name}` : ''}
        {s.autologin ? ' · signed in by OpsAPI' : ''}
        {s.started_at ? ` · started ${when(s.started_at)}` : ` · ${when(s.created_at)}`}
        {s.reported_at ? ` · agent reported ${when(s.reported_at)}` : ''}
        {s.started_at && (s.status === 'ended' || s.status === 'active')
          ? ` · ${duration({ started_at: s.started_at, finished_at: s.ended_at })}` : ''}
        {s.status === 'active' && (
          <>
            {' · '}
            <a href={s.terminal_url} target="_blank" rel="noreferrer" className="inline-flex items-center gap-0.5 text-primary-600 hover:underline">
              Open the terminal <ExternalLink size={11} aria-hidden />
            </a>
          </>
        )}
      </p>
      {s.work_log && (
        <p className="text-secondary-500">
          {elapsed(s.work_log.active_secs)} active · {s.work_log.prompts} prompt{s.work_log.prompts === 1 ? '' : 's'} ·{' '}
          {compact(s.work_log.tokens)} tokens · {cost(s.work_log.cost_usd)} ·{' '}
          <Link href={`${BASE}/work-log/${s.work_log.uuid}`} className="text-primary-600 hover:underline">
            What happened
          </Link>
        </p>
      )}
    </li>
  );
}

/** "Show me how": where to start, the two ways, how the task moves, where it's all kept. */
const TOUR: TourStep[] = [
  {
    target: 'start-ai', title: 'Step 1 · Start here',
    body: 'Click Start with AI whenever you want AI help with this task. It guides you through the rest, one step at a time.',
  },
  {
    title: 'Step 2 · Choose how',
    body: (
      <ul className="list-disc space-y-1 pl-4">
        <li><strong>Let AI do it</strong>: the AI works on its own and opens a pull request for you to review.</li>
        <li><strong>Work on it with AI myself</strong>: a terminal opens on the machine, in the task&apos;s folder, with the AI
          ready for you to guide.</li>
      </ul>
    ),
  },
  {
    target: 'task-status', title: 'Step 3 · The task moves by itself',
    body: 'When the AI opens a pull request, the task moves to Review, and to Done when the pull request is merged.',
  },
  {
    target: 'ai-work', title: 'Step 4 · Follow it here',
    body: 'Every AI run, terminal session and pull request for this task shows here: what was asked, the cost and a replay.',
  },
];

export default function TaskWork({ taskUuid, taskLabel }: { taskUuid: string; taskLabel?: string }) {
  const on = useAiRunnerOn();
  const { hasPermission } = usePermissions();
  const canReview = hasPermission('ai_runs', 'manage') || hasPermission('ai_runs_approvals', 'manage');
  const canStart = hasPermission('ai_runs', 'create') || hasPermission('ai_runs', 'manage');
  const [bundle, setBundle] = useState<TaskWorkBundle | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [startOpen, setStartOpen] = useState(false);
  const [tour, setTour] = useState(false);

  const load = useCallback(() => {
    if (!on) return;
    aiRunner.taskWork(taskUuid).then(setBundle, () => setBundle(null));
  }, [on, taskUuid]);

  useEffect(() => { load(); }, [load]);

  async function review(pr: TaskPr, decision: 'approved' | 'changes_requested') {
    setBusy(pr.uuid);
    try {
      await aiRunner.reviewPr(taskUuid, pr.uuid, decision);
      toast.success(decision === 'approved' ? 'PR approved (not merged)' : 'Changes requested');
      load();
    } catch (e) {
      toast.error(aiError(e).message);
    } finally {
      setBusy(null);
    }
  }

  if (!on || !bundle) return null;
  const work = bundle.work;
  const prs = bundle.pull_requests || [];
  const sessions: TerminalSession[] = bundle.terminal_sessions || [];
  const links = bundle.manager_links;
  const empty = !work && prs.length === 0 && sessions.length === 0;

  return (
    <section className="rounded-xl border border-secondary-200 bg-surface p-4 space-y-3" aria-labelledby="task-ai-work"
      data-tour="ai-work">
      <div className="flex items-center gap-2">
        <h2 id="task-ai-work" className="flex items-center gap-1.5 text-xs font-medium text-secondary-500">
          <Bot size={14} aria-hidden /> AI work
        </h2>
        <button type="button" onClick={() => setTour(true)}
          className="ml-auto inline-flex items-center gap-1 text-xs font-medium text-primary-600 hover:underline">
          <Compass size={12} aria-hidden /> Show me how
        </button>
      </div>
      {startOpen && createPortal(
        <StartWithAIDialog open taskUuid={taskUuid} taskLabel={taskLabel || 'This task'}
          onClose={() => { setStartOpen(false); load(); }} />,
        document.body,
      )}
      {tour && <PageTour steps={TOUR} onClose={() => setTour(false)} />}

      {empty && (
        <div className="space-y-3" data-testid="ai-work-empty">
          <p className="text-sm text-secondary-600">Get this task done with AI, in one of two ways:</p>
          <ul className="space-y-2 text-sm">
            <li className="flex gap-2">
              <Bot size={16} className="mt-0.5 shrink-0 text-primary-600" aria-hidden />
              <span><strong className="text-secondary-900">Let AI do it.</strong>{' '}
                <span className="text-secondary-600">It works on its own and opens a pull request for you to review.</span></span>
            </li>
            <li className="flex gap-2">
              <Terminal size={16} className="mt-0.5 shrink-0 text-primary-600" aria-hidden />
              <span><strong className="text-secondary-900">Work on it with AI yourself.</strong>{' '}
                <span className="text-secondary-600">A terminal opens with the AI ready in the task&apos;s folder; you guide it.</span></span>
            </li>
          </ul>
          {canStart && (
            <Button size="sm" onClick={() => setStartOpen(true)} leftIcon={<Bot className="h-4 w-4" aria-hidden />}>
              Start with AI
            </Button>
          )}
        </div>
      )}

      {work && (
        <div className="space-y-2">
          <div className="flex items-center gap-2 text-sm">
            <RunStatusBadge status={work.status as never} />
            <span className="text-secondary-600">{work.executor_kind}</span>
            {work.run_uuid && (
              <Link href={`${BASE}/runs/${work.run_uuid}`} className="ml-auto text-xs text-primary-600 hover:underline">
                Full conversation
              </Link>
            )}
          </div>
          {work.context_snapshot && (
            <div className="rounded-lg bg-secondary-50 p-2 text-xs text-secondary-600 space-y-1">
              {work.context_snapshot.target_repo_url && (
                <p><span className="font-medium">Target repo:</span>{' '}
                  <a href={work.context_snapshot.target_repo_url} target="_blank" rel="noreferrer"
                    className="text-primary-600 hover:underline">
                    {work.context_snapshot.target_repo_url}
                  </a>
                </p>
              )}
              {(work.context_snapshot.skills_git_urls?.length ?? 0) > 0 && (
                <p><span className="font-medium">Skills:</span>{' '}
                  {work.context_snapshot.skills_git_urls!.map((s) => s.label || s.url).join(', ')}
                </p>
              )}
              {(work.context_snapshot.md_refs?.length ?? 0) > 0 && (
                <p><span className="font-medium">MD refs:</span>{' '}
                  {work.context_snapshot.md_refs!.map((m) => m.label || m.path || m.url).join(', ')}
                </p>
              )}
            </div>
          )}
          {work.prompt && (
            <details className="text-xs">
              <summary className="cursor-pointer text-secondary-600 font-medium">Prompt used</summary>
              <pre className="mt-1 max-h-40 overflow-auto whitespace-pre-wrap rounded border border-secondary-200 bg-secondary-50 p-2 font-mono text-[11px]">
                {work.prompt}
              </pre>
            </details>
          )}
          {(work.conversation_summary || work.summary) && (
            <div className="rounded-lg border border-secondary-100 p-2 text-xs text-secondary-700">
              <p className="mb-1 flex items-center gap-1 font-medium text-secondary-600">
                <MessageSquare size={12} aria-hidden /> Result / conversation
              </p>
              <pre className="whitespace-pre-wrap font-sans max-h-48 overflow-auto">
                {work.summary || work.conversation_summary}
              </pre>
            </div>
          )}
        </div>
      )}

      {sessions.length > 0 && (
        <div className="space-y-2" id="task-terminal-sessions">
          <p className="flex items-center gap-1 text-xs font-medium text-secondary-500">
            <Terminal size={12} aria-hidden /> Web terminal sessions
          </p>
          <ul className="space-y-2">
            {sessions.map((s) => <SessionLine key={s.uuid} s={s} />)}
          </ul>
        </div>
      )}

      {prs.length > 0 && (
        <div className="space-y-2" id="task-ai-prs">
          <p className="flex items-center gap-1 text-xs font-medium text-secondary-500">
            <GitPullRequest size={12} aria-hidden /> Pull requests
          </p>
          <ul className="space-y-2">
            {prs.map((pr) => (
              <li key={pr.uuid} className="rounded-lg border border-secondary-200 p-2 text-sm space-y-1.5">
                <div className="flex items-start gap-2">
                  <a href={pr.pr_url} target="_blank" rel="noreferrer"
                    className="flex-1 truncate text-primary-600 hover:underline inline-flex items-center gap-1">
                    {pr.repo ? `${pr.repo}#${pr.pr_number || ''}` : pr.pr_url}
                    <ExternalLink size={12} aria-hidden />
                  </a>
                  <span className="text-xs text-secondary-500 shrink-0">{pr.review_status}</span>
                  {pr.state && pr.state !== 'open' && (
                    <span className="text-xs text-secondary-400 shrink-0">gh:{pr.state}</span>
                  )}
                </div>
                {canReview && pr.review_status === 'pending' && (
                  <div className="flex gap-2">
                    <button type="button" disabled={busy === pr.uuid} onClick={() => review(pr, 'approved')}
                      className="inline-flex items-center gap-1 rounded-md bg-green-50 px-2 py-1 text-xs font-medium text-green-700 hover:bg-green-100 disabled:opacity-50">
                      <Check size={12} /> Approve
                    </button>
                    <button type="button" disabled={busy === pr.uuid} onClick={() => review(pr, 'changes_requested')}
                      className="inline-flex items-center gap-1 rounded-md bg-amber-50 px-2 py-1 text-xs font-medium text-amber-800 hover:bg-amber-100 disabled:opacity-50">
                      <X size={12} /> Request changes
                    </button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      {links && (links.run_url || (links.pr_urls && links.pr_urls.length > 0)) && (
        <p className="text-[11px] text-secondary-400">
          Manager links:{' '}
          {links.run_url && <Link href={links.run_url} className="underline">run</Link>}
          {links.pr_urls?.map((u) => (
            <a key={u} href={u} target="_blank" rel="noreferrer" className="ml-2 underline">PR</a>
          ))}
        </p>
      )}
    </section>
  );
}
