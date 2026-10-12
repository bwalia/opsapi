'use client';

/**
 * Start with AI (docs/AI_RUNNER.md §16.2, §22.3): pick a runner, an agent profile (+ model) and the
 * repo folder on that machine, preview the prompt and the conflicts, then start the run and open it.
 * StartWithAIButton shows itself only when the plugin is on here and the user holds ai_runs.create;
 * the server still decides (assignee, ai_runs.manage or project owner/admin).
 */
import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { AlertTriangle, Bot, ShieldCheck } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Modal, Select, Textarea } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { kanbanService } from '@/services/kanban.service';
import {
  aiRunner, aiError, type Conflicts, type Preview, type Runner,
} from '@/services/ai-runner.service';
import { BASE, ago, outputModeLabel, runStatusLabel, useAiRunnerOn, when } from './ui';

interface TaskRef {
  taskUuid: string;
  projectUuid?: string;
  /** "#12 Fix the login" — names the task in the dialog and in the button's label. */
  taskLabel: string;
}

const usable = (r: Runner) => r.status === 'online';
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

export function StartWithAIDialog({ open, onClose, taskUuid, projectUuid, taskLabel }: TaskRef & { open: boolean; onClose: () => void }) {
  const router = useRouter();
  const { hasPermission } = usePermissions();
  const isManager = hasPermission('ai_runs', 'manage');
  const [projectRole, setProjectRole] = useState<string>();

  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState<'preview' | 'start' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [runners, setRunners] = useState<Runner[]>([]);
  const [runnerUuid, setRunnerUuid] = useState('');
  const [profile, setProfile] = useState('');
  const [model, setModel] = useState('');
  const [repo, setRepo] = useState('');
  const [preview, setPreview] = useState<Preview | null>(null);
  // The server decides (it also enforces it on start); the project role is only a fallback for older servers.
  const canEditPrompt = preview?.can_edit_prompt ?? (isManager || projectRole === 'owner' || projectRole === 'admin');
  const [previewFor, setPreviewFor] = useState('');
  const [prompt, setPrompt] = useState('');
  const live = useRef(0);

  const runner = runners.find((r) => r.uuid === runnerUuid);
  const profiles = runner?.capabilities?.profiles || [];
  const models = profiles.find((p) => p.key === profile)?.models || [];
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
  }

  useEffect(() => {
    if (!open) return;
    const id = ++live.current;
    setError(null);
    setPreview(null);
    setPreviewFor('');
    setModel('');
    setLoading(true);
    if (!isManager && projectUuid) {
      kanbanService.getProject(projectUuid).then((p) => { if (id === live.current) setProjectRole(p.current_user_role); }, () => {});
    }
    (async () => {
      try {
        const first = await aiRunner.preview(taskUuid);
        const list = [...(first.runners ?? (await aiRunner.listRunners()))].sort(byOnline);
        if (id !== live.current) return;
        const r = list.find(usable);
        const p = r?.capabilities?.profiles?.[0]?.key || '';
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
  const conflicts = conflictLines(preview?.conflicts);
  const blocked =
    !runner || !usable(runner) || !profile || !repo.trim() || !preview || stale || conflicts.length > 0 || !prompt.trim();

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
      });
      toast.success(run.status === 'pending_approval' ? 'Sent to a manager for approval' : 'AI run started');
      onClose();
      router.push(`${BASE}/runs/${run.uuid}`);
    } catch (e) {
      setError(aiError(e).message);
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
          <Select id="air-runner" label="Runner" value={runnerUuid} onChange={(e) => { const r = runners.find((x) => x.uuid === e.target.value); setRunnerUuid(e.target.value); setProfile(r?.capabilities?.profiles?.[0]?.key || ''); setModel(''); }}
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
              helperText={runner && !profiles.length ? 'This runner reports no agent profiles.' : undefined}>
              {!profile && <option value="">Choose a profile</option>}
              {profiles.map((p) => <option key={p.key} value={p.key}>{p.label || p.key}</option>)}
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
