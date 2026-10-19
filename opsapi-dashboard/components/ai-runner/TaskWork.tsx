'use client';

/**
 * AI work panel on a task: latest prompt/context, conversation summary, PRs with manager sign-off,
 * and one-click web terminal (workstation-terminal) with session links in comments.
 */
import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { Bot, Check, ExternalLink, GitPullRequest, MessageSquare, Terminal, X } from 'lucide-react';
import toast from 'react-hot-toast';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  aiRunner, aiError, type TaskPr, type TaskWorkBundle, type TerminalSession,
} from '@/services/ai-runner.service';
import { BASE, RunStatusBadge, useAiRunnerOn } from './ui';

export default function TaskWork({ taskUuid }: { taskUuid: string }) {
  const on = useAiRunnerOn();
  const { hasPermission } = usePermissions();
  const canReview = hasPermission('ai_runs', 'manage') || hasPermission('ai_runs_approvals', 'manage');
  const canTerminal = hasPermission('ai_runs', 'read') || hasPermission('ai_runs', 'manage')
    || hasPermission('ai_runs', 'create');
  const [bundle, setBundle] = useState<TaskWorkBundle | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

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

  async function openTerminal() {
    setBusy('terminal');
    try {
      const session = await aiRunner.openTerminalSession(taskUuid);
      const url = session.terminal_url || bundle?.terminal_base_url || 'https://dev.workstation.co.uk/';
      window.open(url, '_blank', 'noopener,noreferrer');
      toast.success('Terminal link posted to task comments');
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
    <section className="rounded-xl border border-secondary-200 bg-surface p-4 space-y-3" aria-labelledby="task-ai-work">
      <div className="flex items-center gap-2">
        <h2 id="task-ai-work" className="flex items-center gap-1.5 text-xs font-medium text-secondary-500">
          <Bot size={14} aria-hidden /> AI work
        </h2>
        {canTerminal && (
          <button type="button" disabled={busy === 'terminal'} onClick={openTerminal}
            className="ml-auto inline-flex items-center gap-1 rounded-md bg-secondary-900 px-2.5 py-1 text-xs font-medium text-white hover:bg-secondary-800 disabled:opacity-50">
            <Terminal size={12} aria-hidden />
            {busy === 'terminal' ? 'Opening…' : 'Open web terminal'}
          </button>
        )}
      </div>

      {empty && (
        <p className="text-sm text-secondary-400">
          No AI work recorded yet. Use Start with AI, or open a web terminal to work on this task.
        </p>
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
            <Terminal size={12} aria-hidden /> Terminal sessions
          </p>
          <ul className="space-y-1.5">
            {sessions.map((s) => (
              <li key={s.uuid} className="flex items-center gap-2 text-xs text-secondary-600">
                <span className="shrink-0 rounded bg-secondary-100 px-1.5 py-0.5 font-medium">{s.status}</span>
                <a href={s.terminal_url} target="_blank" rel="noreferrer"
                  className="truncate text-primary-600 hover:underline inline-flex items-center gap-1">
                  Open session <ExternalLink size={11} aria-hidden />
                </a>
                {s.repo_url && (
                  <a href={s.repo_url} target="_blank" rel="noreferrer" className="truncate text-secondary-500 hover:underline">
                    repo
                  </a>
                )}
              </li>
            ))}
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
