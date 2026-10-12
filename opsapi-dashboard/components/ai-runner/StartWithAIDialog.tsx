'use client';

/**
 * Start with AI (docs/AI_RUNNER.md §16.2, §22.3): pick a runner, an agent profile (+ model) and the
 * repo folder on that machine, preview the prompt and the conflicts, then start the run and open it.
 * Phase 4 (§24.2-24.3): similar open work needs "Start anyway"; open-run caps, the daily token limit and
 * unavailable profiles stop the start, with a reason.
 * StartWithAIButton shows itself only when the plugin is on here and the user holds ai_runs.create;
 * the server still decides (assignee, ai_runs.manage or project owner/admin).
 * §25.1: the runner list is only the runners this user may use, and a runner they can't use (its access changed
 * since) answers 403 "You can't use this runner", shown as such. Only ai_runs.manage may edit the prompt.
 */
import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { AlertTriangle, Bot, CopyCheck, ShieldCheck } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Modal, Select, Textarea } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  aiRunner, aiError, type Conflicts, type Limits, type Preview, type Runner, type SimilarRun,
} from '@/services/ai-runner.service';
import { BASE, ago, compact, outputModeLabel, runStatusLabel, useAiRunnerOn, when } from './ui';

interface TaskRef {
  taskUuid: string;
  /** "#12 Fix the login" — names the task in the dialog and in the button's label. */
  taskLabel: string;
}

const usable = (r: Runner) => r.status === 'online';
/** The runner's first profile that can take work (§24.3: a logged-out agent reports available: false). */
const firstProfile = (r?: Runner) => r?.capabilities?.profiles?.find((p) => p.available !== false)?.key || '';
const byOnline = (a: Runner, b: Runner) => Number(usable(b)) - Number(usable(a));
const inputsKey = (runner: string, profile: string, repo: string) => JSON.stringify([runner, profile, repo.trim()]);

function conflictLines(c?: Conflicts): { text: string; href?: string }[] {
  const out: { text: string; href?: string }[] = [];
  if (c?.open_run) {
    out.push({
      text: `This task already has an AI run (${runStatusLabel(c.open_run.status || 'queued')}). Only one run per task at a time.`,
      href: c.open_run.uuid ? `${BASE}/runs/${c.open_run.uuid}` : undefined,
    });
  }
  if (c?.folder_lock) {
    const l = c.folder_lock;
    out.push({
      text: l.message || `Another run is working in this folder${l.since ? ` since ${when(l.since)}` : ''}${l.holder ? ` (${l.holder})` : ''}.`,
      href: l.run_uuid ? `${BASE}/runs/${l.run_uuid}` : undefined,
    });
  }
  if (c?.busy_session) {
    const s = c.busy_session;
    out.push({ text: s.message || `A ${s.tool || 'coding'} session is busy in this folder${s.branch ? ` on ${s.branch}` : ''}. Wait until it finishes.` });
  }
  return out;
}

const capText = (scope: string | undefined, limit: number) => scope === 'workspace'
  ? `The workspace already has ${limit} open AI runs, the most allowed. Wait for one to finish before starting another.`
  : `You already have ${limit} open AI runs, the most allowed. Wait for one to finish, or cancel one, before starting another.`;
const tokenText = (limit: number) =>
  `The workspace has used its daily limit of ${compact(limit)} agent tokens. New runs can start after midnight UTC; running ones finish.`;

/** What the caps and today's tokens allow (0 = no limit): lines to show, and what stops the start. */
function limitLines(raw?: Limits | null): { info: string[]; blocks: string[] } {
  const info: string[] = [];
  const blocks: string[] = [];
  if (!raw) return { info, blocks };
  // Sums of BIGINT columns may arrive as strings.
  const l = Object.fromEntries(Object.entries(raw).map(([k, v]) => [k, Number(v) || 0])) as unknown as Limits;
  if (l.user_max > 0) {
    info.push(`You have ${l.user_open} of ${l.user_max} open runs.`);
    if (l.user_open >= l.user_max) blocks.push(capText('user', l.user_max));
  }
  if (l.workspace_max > 0) {
    info.push(`The workspace has ${l.workspace_open} of ${l.workspace_max} open runs.`);
    if (l.workspace_open >= l.workspace_max) blocks.push(capText('workspace', l.workspace_max));
  }
  if (l.daily_token_limit > 0) {
    info.push(`${compact(l.tokens_today)} of ${compact(l.daily_token_limit)} agent tokens used today.`);
    if (l.tokens_today >= l.daily_token_limit) blocks.push(tokenText(l.daily_token_limit));
  }
  return { info, blocks };
}

/** A 409 from start in words (§24.2, §24.3); null = the server's own message says it. */
function startConflictText(conflict: unknown): string | null {
  const c = (conflict && typeof conflict === 'object' ? conflict : {}) as {
    type?: string; scope?: string; limit?: number; used?: number; reason?: string; unavailable_reason?: string;
  };
  const reason = c.unavailable_reason || c.reason;
  switch (c.type) {
    case 'similar_work': return 'Similar work is already open. Check it above, then tick Start anyway.';
    case 'cap_reached': return capText(c.scope, Number(c.limit) || 0);
    case 'token_limit': return tokenText(Number(c.limit) || 0);
    case 'profile_unavailable':
      return `This agent profile can't take work on that runner${reason ? ` (${reason})` : ''}. Choose another profile, or fix it on the machine.`;
    default: return null;
  }
}

export function StartWithAIDialog({ open, onClose, taskUuid, taskLabel }: TaskRef & { open: boolean; onClose: () => void }) {
  const router = useRouter();
  const { hasPermission } = usePermissions();
  const isManager = hasPermission('ai_runs', 'manage');

  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState<'preview' | 'start' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [runners, setRunners] = useState<Runner[]>([]);
  const [runnerUuid, setRunnerUuid] = useState('');
  const [profile, setProfile] = useState('');
  const [model, setModel] = useState('');
  const [repo, setRepo] = useState('');
  const [preview, setPreview] = useState<Preview | null>(null);
  // The server decides (it also enforces it on start); ai_runs.manage is the fallback for older servers.
  const canEditPrompt = preview?.can_edit_prompt ?? isManager;
  const [previewFor, setPreviewFor] = useState('');
  const [prompt, setPrompt] = useState('');
  const [confirmSimilar, setConfirmSimilar] = useState(false);
  const live = useRef(0);

  const runner = runners.find((r) => r.uuid === runnerUuid);
  const profiles = runner?.capabilities?.profiles || [];
  const chosen = profiles.find((p) => p.key === profile);
  const models = chosen?.models || [];
  const repos = runner?.repos || [];
  const repoInfo = repos.find((r) => r.path === repo.trim());

  /** Preview for these inputs; with no folder yet, take the suggested one and preview again. */
  async function runPreview(r: string, p: string, folder: string) {
    const id = live.current;
    let res = await aiRunner.preview(taskUuid, { runner_uuid: r || undefined, profile: p || undefined, repo_path: folder.trim() || undefined });
    if (!folder.trim() && res.default_repo_path && r) {
      folder = res.default_repo_path;
      res = await aiRunner.preview(taskUuid, { runner_uuid: r, profile: p || undefined, repo_path: folder });
    }
    if (id !== live.current) return;
    setRepo(folder);
    setPreview(res);
    setPrompt(res.prompt || '');
    setPreviewFor(inputsKey(r, p, folder));
    setConfirmSimilar(false);
  }

  useEffect(() => {
    if (!open) return;
    const id = ++live.current;
    setError(null);
    setPreview(null);
    setPreviewFor('');
    setModel('');
    setLoading(true);
    (async () => {
      try {
        const first = await aiRunner.preview(taskUuid);
        const list = [...(first.runners ?? (await aiRunner.listRunners()))].sort(byOnline);
        if (id !== live.current) return;
        const r = list.find(usable);
        const p = firstProfile(r);
        setRunners(list);
        setRunnerUuid(r?.uuid || '');
        setProfile(p);
        if (r) await runPreview(r.uuid, p, first.default_repo_path || '');
        else {
          setPreview(first);
          setPrompt(first.prompt || '');
          setRepo(first.default_repo_path || '');
        }
      } catch (e) {
        if (id === live.current) setError(aiError(e).message);
      } finally {
        if (id === live.current) setLoading(false);
      }
    })();
    return () => { live.current += 1; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, taskUuid]);

  const stale = !!preview && previewFor !== inputsKey(runnerUuid, profile, repo);
  const limits = limitLines(preview?.limits);
  const conflicts = [...conflictLines(preview?.conflicts), ...limits.blocks.map((text) => ({ text, href: undefined }))];
  const similar: SimilarRun[] = Array.isArray(preview?.conflicts?.similar) ? preview.conflicts.similar : [];
  const profileDown = chosen?.available === false;
  const blocked = !runner || !usable(runner) || !profile || profileDown || !repo.trim() || !preview || stale
    || conflicts.length > 0 || (similar.length > 0 && !confirmSimilar) || !prompt.trim();

  async function doPreview() {
    setBusy('preview');
    setError(null);
    try {
      await runPreview(runnerUuid, profile, repo);
    } catch (e) {
      setError(aiError(e).message);
    } finally {
      setBusy(null);
    }
  }

  async function doStart() {
    if (blocked) return;
    setBusy('start');
    setError(null);
    try {
      const edited = canEditPrompt && prompt !== preview?.prompt;
      const run = await aiRunner.start(taskUuid, {
        runner_uuid: runnerUuid,
        profile,
        model: model || undefined,
        repo_path: repo.trim(),
        prompt: edited ? prompt : undefined,
        confirm_similar: similar.length > 0 && confirmSimilar ? true : undefined,
      });
      toast.success(run.status === 'pending_approval' ? 'Sent to a manager for approval' : 'AI run started');
      onClose();
      router.push(`${BASE}/runs/${run.uuid}`);
    } catch (e) {
      const err = aiError(e);
      const c = err.conflict as { type?: string; runs?: SimilarRun[] } | undefined;
      if (c?.type === 'similar_work' && Array.isArray(c.runs)) {
        // Found since the preview: show it and ask again.
        setPreview((p) => p && { ...p, conflicts: { ...p.conflicts, similar: c.runs } });
        setConfirmSimilar(false);
      }
      setError((err.status === 409 && startConflictText(c)) || err.message);
    } finally {
      setBusy(null);
    }
  }

  const reason = (r: Runner) =>
    r.status === 'paused' ? 'paused' : r.status === 'online' ? 'online' : `${r.status}, last seen ${ago(r.last_heartbeat_at)}`;

  return (
    <Modal
      isOpen={open}
      onClose={onClose}
      size="2xl"
      title="Start with AI"
      description={taskLabel}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button variant="outline" onClick={doPreview} isLoading={busy === 'preview'} disabled={loading || !runnerUuid || busy !== null}>
            Preview
          </Button>
          <Button onClick={doStart} isLoading={busy === 'start'} disabled={loading || blocked || busy !== null} leftIcon={<Bot className="h-4 w-4" aria-hidden />}>
            Start
          </Button>
        </>
      }
    >
      {loading ? (
        <p className="py-8 text-center text-sm text-secondary-500" role="status">Loading runners and the prompt…</p>
      ) : (
        <div className="space-y-4">
          <Select id="air-runner" label="Runner" value={runnerUuid} onChange={(e) => { const r = runners.find((x) => x.uuid === e.target.value); setRunnerUuid(e.target.value); setProfile(firstProfile(r)); setModel(''); }}
            helperText={runners.some(usable) ? undefined : 'No runner is online. Start PromptPilot on a machine registered under Runners.'} error={!runners.some(usable)}>
            {!runnerUuid && <option value="">Choose a runner</option>}
            {runners.map((r) => (
              <option key={r.uuid} value={r.uuid} disabled={!usable(r)}>
                {r.name}{r.host ? ` (${r.host})` : ''} — {reason(r)}
              </option>
            ))}
          </Select>

          <div className="grid gap-4 sm:grid-cols-2">
            <Select id="air-profile" label="Agent profile" value={profile} onChange={(e) => { setProfile(e.target.value); setModel(''); }} disabled={!profiles.length}
              error={profileDown}
              helperText={runner && !profiles.length ? 'This runner reports no agent profiles.'
                : profileDown ? `Unavailable on this runner${chosen?.unavailable_reason ? `: ${chosen.unavailable_reason}` : ''}. Choose another profile.`
                : profiles.length && profiles.every((p) => p.available === false) ? 'No profile on this runner can take work right now.' : undefined}>
              {!profile && <option value="">Choose a profile</option>}
              {profiles.map((p) => (
                <option key={p.key} value={p.key} disabled={p.available === false}>
                  {p.label || p.key}{p.available === false ? ` — unavailable${p.unavailable_reason ? `: ${p.unavailable_reason}` : ''}` : ''}
                </option>
              ))}
            </Select>
            <Select id="air-model" label="Model" value={model} onChange={(e) => setModel(e.target.value)} disabled={!models.length}>
              <option value="">{models.length ? "The profile's default" : 'No choice for this profile'}</option>
              {models.map((m) => <option key={m} value={m}>{m}</option>)}
            </Select>
          </div>

          <div>
            <Input id="air-repo" label="Repo folder on that machine" value={repo} onChange={(e) => setRepo(e.target.value)} list="air-repos"
              placeholder="/Users/you/projects/my-repo" spellCheck={false} autoComplete="off" className="font-mono"
              helperText={repoInfo?.dirty
                ? 'This folder has uncommitted changes: the runner will refuse it until they are committed or stashed.'
                : repoInfo?.branch ? `Currently on ${repoInfo.branch}. The run works on a new branch, never on main.` : 'Pick one the runner found, or type a path. The run works on a new branch, never on main.'} />
            <datalist id="air-repos">
              {repos.map((r) => <option key={r.path} value={r.path}>{r.branch ? `on ${r.branch}` : ''}</option>)}
            </datalist>
          </div>

          {stale && (
            <p className="rounded-lg bg-info-500/10 p-3 text-sm text-info-700" role="status">
              You changed the runner, profile or folder. Press Preview to check them before starting.
            </p>
          )}

          {conflicts.length > 0 && (
            <div className="space-y-2 rounded-lg bg-error-500/10 p-3 text-sm text-error-700" role="alert">
              <p className="font-semibold">This run can&apos;t start yet:</p>
              <ul className="list-disc space-y-1 pl-5">
                {conflicts.map((c) => (
                  <li key={c.text}>
                    {c.text}{' '}
                    {c.href && <Link className="underline" href={c.href} onClick={onClose}>Open that run</Link>}
                  </li>
                ))}
              </ul>
            </div>
          )}

          {similar.length > 0 && (
            <div className="space-y-2 rounded-lg bg-warning-500/10 p-3 text-sm text-warning-800" role="status" data-testid="air-similar">
              <p className="flex items-start gap-2 font-semibold">
                <CopyCheck className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /> Similar work is already open
              </p>
              <p>These open runs are on tasks with a similar title. Make sure this isn&apos;t the same work.</p>
              <ul className="list-disc space-y-1 pl-5">
                {similar.map((w) => (
                  <li key={w.run_uuid}>
                    <Link className="font-medium underline" href={`${BASE}/runs/${w.run_uuid}`} onClick={onClose}>
                      {w.task_number != null ? `#${w.task_number} ` : ''}{w.task_title || 'Task'}
                    </Link>
                    {' '}— {runStatusLabel(w.status || 'queued')}{w.requested_by_name ? `, started by ${w.requested_by_name}` : ''}
                  </li>
                ))}
              </ul>
              <label className="flex items-center gap-2 font-medium">
                <input type="checkbox" checked={confirmSimilar} onChange={(e) => setConfirmSimilar(e.target.checked)} /> Start anyway
              </label>
            </div>
          )}

          {preview?.needs_approval && !stale && (
            <p className="flex items-start gap-2 rounded-lg bg-warning-500/10 p-3 text-sm text-warning-700" role="status">
              <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /> A manager must approve this run before it starts.
            </p>
          )}

          {preview && (
            <>
              <p className="text-sm text-secondary-600">
                <span className="font-medium text-secondary-800">Output:</span> {outputModeLabel(preview.output_mode)}
                {preview.output_mode === 'pull_request' && ' — the agent commits on its branch and opens a pull request; nothing is merged.'}
              </p>
              {limits.info.length > 0 && <p className="text-sm text-secondary-600" data-testid="air-limits">{limits.info.join(' ')}</p>}
              {canEditPrompt ? (
                <Textarea id="air-prompt" label={`Prompt${preview.template_version ? ` (template v${preview.template_version})` : ''}`} rows={12}
                  value={prompt} onChange={(e) => setPrompt(e.target.value)} className="font-mono text-xs" spellCheck={false}
                  helperText={prompt !== preview.prompt ? 'Edited: the run uses your text.' : 'You may edit it before starting.'} />
              ) : (
                <div>
                  <p className="mb-1.5 text-sm font-medium text-secondary-700" id="air-prompt-label">
                    Prompt{preview.template_version ? ` (template v${preview.template_version})` : ''}
                  </p>
                  <pre aria-labelledby="air-prompt-label" tabIndex={0}
                    className="max-h-72 overflow-auto whitespace-pre-wrap rounded-lg border border-secondary-200 bg-secondary-50 p-3 font-mono text-xs text-secondary-800">
                    {preview.prompt}
                  </pre>
                </div>
              )}
            </>
          )}

          {error && (
            <p className="flex items-start gap-2 rounded-lg bg-error-500/10 p-3 text-sm text-error-700" role="alert">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /> {error}
            </p>
          )}
        </div>
      )}
    </Modal>
  );
}

/** The "Start with AI" button + its dialog; renders nothing unless the plugin is on and the user holds ai_runs.create. */
export function StartWithAIButton({ compact, ...task }: TaskRef & { compact?: boolean }) {
  const { hasPermission, isLoading } = usePermissions();
  const can = !isLoading && hasPermission('ai_runs', 'create');
  const on = useAiRunnerOn(can);
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLButtonElement>(null);
  if (!can || !on) return null;
  const close = () => {
    setOpen(false);
    setTimeout(() => ref.current?.focus(), 0); // focus back on the button that opened the dialog
  };
  return (
    <>
      {compact ? (
        <button ref={ref} type="button" onClick={() => setOpen(true)} aria-label={`Start ${task.taskLabel} with AI`}
          className="inline-flex min-h-8 items-center gap-1 rounded-lg px-2 text-xs font-semibold text-primary-600 transition hover:bg-primary-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500">
          <Bot className="h-3 w-3" aria-hidden /> Start with AI
        </button>
      ) : (
        <Button ref={ref} size="sm" variant="outline" onClick={() => setOpen(true)} leftIcon={<Bot className="h-4 w-4" aria-hidden />}>
          Start with AI
        </Button>
      )}
      {/* Portalled: the assistant panel may sit in a transformed container that would clip a fixed overlay. */}
      {open && createPortal(<StartWithAIDialog open={open} onClose={close} {...task} />, document.body)}
    </>
  );
}

export default StartWithAIDialog;
