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
 * §28: the built-in runner runs inside OpsAPI (no machine): it is listed last, so it is picked when no machine is
 * online; its profiles are models and its "folders" are the connected GitHub repositories, or none.
 * Web terminal (docs/AI_RUNNER_WEB_TERMINAL.md): when the workspace has one, the dialog first asks how — "Let AI do it"
 * or "Work on it with AI myself" (a folder on that machine and an agent; OpsAPI signs a short-lived link and the terminal
 * opens the folder in a new tab and starts the agent with the task). The person drives the agent there, so anyone who
 * may start AI work may edit that prompt.
 * Guided in steps: 1 How (only when both ways exist) → 2 Set it up (the essentials; executor and project context under
 * More options) → 3 Check & start ("What happens next", warnings, the prompt to read or edit). Next on step 2 runs the
 * preview, so there is no separate Preview button.
 */
import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import {
  AlertTriangle, ArrowLeft, ArrowRight, Bot, Check, ChevronRight, CopyCheck, ExternalLink, KeyRound, ShieldCheck, Terminal,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Modal, Select, Textarea } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  aiRunner, aiError, type Conflicts, type Limits, type Preview, type Runner, type SimilarRun, type TerminalAutologin,
  type TerminalOffer,
} from '@/services/ai-runner.service';
import { BASE, ago, compact, outputModeLabel, runStatusLabel, useAiRunnerOn, when } from './ui';

const EXECUTOR_LABELS: Record<string, string> = {
  machine: 'Machine runner (PromptPilot / local IDE)',
  builtin: 'Built-in (OpsAPI)',
  jobshout: 'JobShout workflow',
  provider: 'Workspace AI provider',
};

interface TaskRef {
  taskUuid: string;
  /** "#12 Fix the login" — names the task in the dialog and in the button's label. */
  taskLabel: string;
}

const usable = (r: Runner) => r.status === 'online';
const isBuiltin = (r?: Runner) => r?.kind === 'builtin';
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

type Mode = 'terminal' | 'run';
type Step = 1 | 2 | 3;
const MODE_KEY = 'air-start-with-ai-mode';
/** The way this browser chose last time (step 1 preselects it). */
function lastMode(): Mode | null {
  try {
    const v = localStorage.getItem(MODE_KEY);
    return v === 'run' || v === 'terminal' ? v : null;
  } catch {
    return null;
  }
}
function remember(m: Mode) {
  try {
    localStorage.setItem(MODE_KEY, m);
  } catch {
    // private mode: nothing to remember
  }
}
/** The first agent that runs something (not "just a terminal") and stops to ask before it changes things, else
 * the first one. An unattended agent is only ever picked by hand. */
const firstAgent = (t?: TerminalOffer) => t?.agents.find((a) => a.id !== 'shell' && !a.unattended)?.id
  || t?.agents.find((a) => !a.unattended)?.id || t?.agents[0]?.id || '';
const clock = (unix: number) => new Date(unix * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

export function StartWithAIDialog({ open, onClose, taskUuid, taskLabel, initialMode }: TaskRef & {
  open: boolean; onClose: () => void; initialMode?: Mode;
}) {
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
  const [executorKind, setExecutorKind] = useState('machine');
  const [selectedSkills, setSelectedSkills] = useState<string[]>([]);
  const [selectedMd, setSelectedMd] = useState<string[]>([]);
  const [mode, setMode] = useState<Mode>(initialMode || 'run');
  const [step, setStep] = useState<Step>(1);
  // Step 1's choice; the last one used in this browser is preselected.
  const [chosen1, setChosen1] = useState<Mode | null>(null);
  const [terminals, setTerminals] = useState<TerminalOffer[]>([]);
  const [termUuid, setTermUuid] = useState('');
  const [folder, setFolder] = useState('');
  const [agent, setAgent] = useState('');
  // The task prompt keeps {{repo_path}}; until the person edits it, the folder they type is shown in its place.
  const [termPromptTpl, setTermPromptTpl] = useState('');
  const [termPromptEdited, setTermPromptEdited] = useState<string | null>(null);
  const termPrompt =
    termPromptEdited ?? termPromptTpl.replace(/\{\{\s*repo_path\s*\}\}/g, folder.trim() || 'the folder you choose');
  const [launchUrl, setLaunchUrl] = useState<string | null>(null);
  // Auto sign-in (docs/AI_RUNNER_WEB_TERMINAL.md §8): power users, on a terminal that allows it, after an emailed code.
  const [auto, setAuto] = useState<TerminalAutologin>({ allowed: false, stepup: null });
  const [signMeIn, setSignMeIn] = useState(true);
  const [codeSent, setCodeSent] = useState(false);
  const [code, setCode] = useState('');
  const [codeBusy, setCodeBusy] = useState(false);
  const live = useRef(0);
  const terminal = terminals.find((t) => t.uuid === termUuid);
  const stepupLive = !!auto.stepup && auto.stepup.expires_at * 1000 > Date.now();
  const autoOffered = !!terminal?.autologin && auto.allowed;
  const autologin = autoOffered && signMeIn;

  const runner = runners.find((r) => r.uuid === runnerUuid);
  const profiles = runner?.capabilities?.profiles || [];
  const chosen = profiles.find((p) => p.key === profile);
  const models = chosen?.models || [];
  const repos = runner?.repos || [];
  const repoInfo = repos.find((r) => r.path === repo.trim());
  const builtin = isBuiltin(runner);
  const githubRepos = repos.filter((r) => r.path !== 'none');

  /** Preview for these inputs; with no folder yet, take the suggested one and preview again. */
  async function runPreview(r: string, p: string, folder: string, exec?: string) {
    const id = live.current;
    const base = {
      runner_uuid: r || undefined, profile: p || undefined, repo_path: folder.trim() || undefined,
      executor_kind: exec || executorKind || undefined,
      selected_skill_urls: selectedSkills.length ? selectedSkills : undefined,
      selected_md: selectedMd.length ? selectedMd : undefined,
    };
    let res = await aiRunner.preview(taskUuid, base);
    if (!folder.trim() && res.default_repo_path && r) {
      folder = res.default_repo_path;
      res = await aiRunner.preview(taskUuid, { ...base, repo_path: folder });
    }
    if (id !== live.current) return;
    setRepo(folder);
    setPreview(res);
    setPrompt(res.prompt || '');
    setPreviewFor(inputsKey(r, p, folder));
    setConfirmSimilar(false);
    if (res.executor_kind) setExecutorKind(res.executor_kind);
    const skills = res.context?.skills_git_urls || [];
    const mds = res.context?.md_refs || [];
    if (!selectedSkills.length && skills.length) setSelectedSkills(skills.map((s) => s.url));
    if (!selectedMd.length && mds.length) {
      setSelectedMd(mds.map((m) => m.path || m.url || '').filter(Boolean));
    }
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
        const offers = first.terminals || [];
        setTerminals(offers);
        setTermUuid(offers[0]?.uuid || '');
        setFolder(offers[0]?.default_path || '');
        setAgent(firstAgent(offers[0]));
        setTermPromptTpl(first.terminal_prompt || '');
        setTermPromptEdited(null);
        setLaunchUrl(null);
        setCodeSent(false);
        setCode('');
        const pick = initialMode || (offers.length ? lastMode() : 'run');
        setChosen1(pick);
        if (pick) setMode(pick);
        // One way only (no web terminal), or the caller already chose: straight to setting it up.
        setStep(offers.length && !initialMode ? 1 : 2);
        if (offers.some((t) => t.autologin)) {
          aiRunner.terminalAutologin().then((a) => { if (id === live.current && a) setAuto(a); }).catch(() => {});
        }
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
        executor_kind: executorKind || undefined,
        selected_skill_urls: selectedSkills.length ? selectedSkills : undefined,
        selected_md: selectedMd.length ? selectedMd : undefined,
      });
      toast.success(run.status === 'pending_approval' ? 'Sent to a manager for approval' : 'AI work started (saved on the task)');
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

  const folderOk = folder.trim().startsWith('/');
  const launchBlocked = !terminal || !folderOk || !agent || (autologin && !stepupLive);

  async function sendCode() {
    setCodeBusy(true);
    setError(null);
    try {
      await aiRunner.sendAutologinCode();
      setCodeSent(true);
      toast.success('We emailed you a code');
    } catch (e) {
      setError(aiError(e).message);
    } finally {
      setCodeBusy(false);
    }
  }

  async function confirmCode() {
    setCodeBusy(true);
    setError(null);
    try {
      setAuto(await aiRunner.verifyAutologinCode(code.trim()));
      setCodeSent(false);
      setCode('');
    } catch (e) {
      setError(aiError(e).message);
    } finally {
      setCodeBusy(false);
    }
  }

  async function forgetCode() {
    try {
      setAuto(await aiRunner.forgetAutologin());
    } catch (e) {
      setError(aiError(e).message);
    }
  }

  async function doLaunch() {
    if (launchBlocked || !terminal) return;
    // Open the tab inside the click, or a popup blocker eats it; point it at the terminal once the link exists.
    const win = window.open('', '_blank');
    if (win) {
      win.opener = null;
      win.document.title = 'Opening the terminal…';
    }
    setBusy('start');
    setError(null);
    setLaunchUrl(null);
    try {
      const res = await aiRunner.launchTerminal(taskUuid, {
        terminal_uuid: terminal.uuid, path: folder.trim(), agent, prompt: termPrompt.trim() || undefined,
        autologin: autologin || undefined,
      });
      if (win && !win.closed) {
        win.location.href = res.launch_url;
        toast.success(`Opening ${terminal.name} in a new tab`);
        onClose();
      } else {
        setLaunchUrl(res.launch_url);
      }
    } catch (e) {
      win?.close();
      setError(aiError(e).message);
    } finally {
      setBusy(null);
    }
  }

  const reason = (r: Runner) =>
    r.status === 'paused' ? 'paused' : r.status === 'online' ? 'online' : `${r.status}, last seen ${ago(r.last_heartbeat_at)}`;

  // The guided steps: 1 How (only when both ways exist) → 2 Set it up → 3 Check & start.
  const bothWays = terminals.length > 0;
  const steps = bothWays ? ['How', 'Set it up', 'Check & start'] : ['Set it up', 'Check & start'];
  const stepIndex = bothWays ? step - 1 : step - 2;
  const agentLabel = terminal?.agents.find((a) => a.id === agent)?.label || 'the AI';
  const setupBlocked = mode === 'terminal'
    ? launchBlocked
    : !runner || !usable(runner) || !profile || profileDown || !repo.trim();

  async function next() {
    setError(null);
    if (step === 1) {
      if (!chosen1) return;
      setMode(chosen1);
      remember(chosen1);
      setStep(2);
      return;
    }
    if (mode === 'run' && (stale || !preview)) {
      // Check the runner, folder and limits before showing the summary (what Preview used to do).
      setBusy('preview');
      try {
        await runPreview(runnerUuid, profile, repo);
      } catch (e) {
        setError(aiError(e).message);
        return;
      } finally {
        setBusy(null);
      }
    }
    setStep(3);
  }

  const stepper = (
    <ol className="flex flex-wrap items-center gap-1.5 text-xs" aria-label="Steps" data-testid="air-steps">
      {steps.map((label, i) => (
        <li key={label} className="flex items-center gap-1.5" aria-current={i === stepIndex ? 'step' : undefined}>
          {i > 0 && <ChevronRight className="h-3.5 w-3.5 text-secondary-300" aria-hidden />}
          <span className={`inline-flex items-center gap-1 rounded-full px-2.5 py-1 font-medium ${i === stepIndex
            ? 'bg-primary-500 text-white' : i < stepIndex ? 'bg-success-500/10 text-success-600' : 'bg-secondary-100 text-secondary-500'}`}>
            {i < stepIndex ? <Check className="h-3 w-3" aria-hidden /> : <span aria-hidden>{i + 1}</span>} {label}
          </span>
        </li>
      ))}
    </ol>
  );

  const errorNote = error && (
    <p className="flex items-start gap-2 rounded-lg bg-error-500/10 p-3 text-sm text-error-600" role="alert">
      <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /> {error}
    </p>
  );

  const howStep = (
    <div className="space-y-3">
      <p className="text-sm font-medium text-secondary-900">How do you want to work on this task?</p>
      <div role="radiogroup" aria-label="How to work on this task" className="grid gap-3 sm:grid-cols-2">
        {([
          ['run', <Bot key="i" className="h-5 w-5" aria-hidden />, 'Let AI do it',
            'The AI works on its own and opens a pull request for you to review.', 'Best for clear, self-contained tasks.'],
          ['terminal', <Terminal key="i" className="h-5 w-5" aria-hidden />, 'Work on it with AI myself',
            `A terminal opens on ${terminals[0]?.name || 'the machine'} in the task's folder, with the AI ready. You talk to it and guide it.`,
            'Best when you want to stay in control.'],
        ] as [Mode, React.ReactNode, string, string, string][]).map(([m, icon, title, what, when_]) => (
          <button key={m} type="button" role="radio" aria-checked={chosen1 === m} onClick={() => setChosen1(m)}
            data-testid={`air-how-${m}`}
            className={`rounded-xl border p-4 text-left transition ${chosen1 === m
              ? 'border-primary-500 bg-primary-50 ring-2 ring-primary-500' : 'border-secondary-200 hover:border-secondary-300 hover:bg-secondary-50'}`}>
            <span className="flex items-center gap-2 font-semibold text-secondary-900">{icon} {title}</span>
            <span className="mt-1.5 block text-sm text-secondary-600">{what}</span>
            <span className="mt-1 block text-xs text-secondary-500">{when_}</span>
          </button>
        ))}
      </div>
      <p className="text-xs text-secondary-500">Either way, everything the AI does is saved under AI work on this task.</p>
    </div>
  );

  const termSetup = (
    <div className="space-y-4" data-testid="air-terminal">
      {terminals.length > 1 && (
        <Select id="air-terminal-pick" label="Which terminal" value={termUuid}
          onChange={(e) => {
            const t = terminals.find((x) => x.uuid === e.target.value);
            setTermUuid(e.target.value); setFolder(t?.default_path || ''); setAgent(firstAgent(t));
          }}>
          {terminals.map((t) => <option key={t.uuid} value={t.uuid}>{t.name}</option>)}
        </Select>
      )}
      <div>
        <Input id="air-terminal-folder" label={`Folder on ${terminal?.name || 'the machine'}`} value={folder}
          onChange={(e) => setFolder(e.target.value)} list="air-terminal-folders" placeholder="/Users/you/projects/my-repo"
          spellCheck={false} autoComplete="off" className="font-mono"
          error={folder.trim() !== '' && !folderOk ? 'Use the full path, starting with /.' : undefined}
          helperText="Where the task's code is on that machine. Folders used before for this project are suggested." />
        <datalist id="air-terminal-folders">
          {(terminal?.recent_paths || []).map((p) => <option key={p} value={p} />)}
        </datalist>
      </div>
      <Select id="air-terminal-agent" label="AI assistant to start" value={agent} onChange={(e) => setAgent(e.target.value)}
        helperText={terminal?.agents.find((a) => a.id === agent)?.unattended
          ? 'This one works without stopping to ask you before it changes or runs things.' : undefined}>
        {(terminal?.agents || []).map((a) => <option key={a.id} value={a.id}>{a.label}</option>)}
      </Select>
      {autoOffered && (
        <div className="space-y-2 rounded-lg border border-secondary-200 p-3" data-testid="air-terminal-autologin">
          <label className="flex items-start gap-2 text-sm text-secondary-800">
            <input type="checkbox" className="mt-0.5" checked={signMeIn} onChange={(e) => setSignMeIn(e.target.checked)} />
            <span>
              Sign me in to {terminal?.name} automatically
              <span className="block text-xs text-secondary-500">No key file needed.</span>
            </span>
          </label>
          {signMeIn && (stepupLive ? (
            <p className="flex flex-wrap items-center gap-2 text-xs text-success-600">
              <ShieldCheck className="h-3.5 w-3.5" aria-hidden /> Confirmed until {clock(auto.stepup!.expires_at)}.
              <button type="button" className="text-secondary-500 underline" onClick={forgetCode}>Sign out of this</button>
            </p>
          ) : codeSent ? (
            <div className="flex flex-wrap items-end gap-2">
              <Input id="air-terminal-code" label="Code from the email" value={code} inputMode="numeric"
                autoComplete="one-time-code" maxLength={12} onChange={(e) => setCode(e.target.value)} className="w-40 font-mono" />
              <Button size="sm" onClick={confirmCode} isLoading={codeBusy} disabled={code.trim().length < 6}>Confirm</Button>
              <button type="button" className="pb-2 text-xs text-secondary-500 underline" onClick={sendCode}
                disabled={codeBusy}>Send another</button>
            </div>
          ) : (
            <div className="flex flex-wrap items-center gap-2">
              <Button size="sm" variant="outline" onClick={sendCode} isLoading={codeBusy}
                leftIcon={<KeyRound className="h-4 w-4" aria-hidden />}>Email me a code</Button>
              <span className="text-xs text-secondary-500">Once every 12 hours, so a stolen password alone can&apos;t open a shell.</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );

  const runSetup = (
    <div className="space-y-4">
      <Select id="air-runner" label="Where the AI works" value={runnerUuid}
        onChange={(e) => {
          const r = runners.find((x) => x.uuid === e.target.value);
          // The built-in runner's "folders" are repositories (or none); a machine's are its own paths.
          if (isBuiltin(r) !== builtin) setRepo(isBuiltin(r) ? 'none' : '');
          setRunnerUuid(e.target.value); setProfile(firstProfile(r)); setModel('');
        }}
        helperText={builtin ? 'Inside OpsAPI on an AI model: no machine needed. It can’t run code or tests.'
          : runners.some(usable) ? 'A machine of yours that runs the AI (a "runner").'
          : 'No runner is online. Start PromptPilot on a machine registered under Runners.'}
        error={!runners.some(usable)}>
        {!runnerUuid && <option value="">Choose where</option>}
        {runners.map((r) => (
          <option key={r.uuid} value={r.uuid} disabled={!usable(r)}>
            {r.name}{isBuiltin(r) ? ' (no machine needed)' : r.host ? ` (${r.host})` : ''} — {reason(r)}
          </option>
        ))}
      </Select>

      <div className={builtin ? '' : 'grid gap-4 sm:grid-cols-2'}>
        <Select id="air-profile" label={builtin ? 'AI model' : 'AI agent'} value={profile} onChange={(e) => { setProfile(e.target.value); setModel(''); }} disabled={!profiles.length}
          error={profileDown}
          helperText={runner && !profiles.length ? 'This runner reports no AI agents.'
            : profileDown ? `Unavailable on this runner${chosen?.unavailable_reason ? `: ${chosen.unavailable_reason}` : ''}. Choose another.`
            : profiles.length && profiles.every((p) => p.available === false) ? 'No agent on this runner can take work right now.' : undefined}>
          {!profile && <option value="">Choose an agent</option>}
          {profiles.map((p) => (
            <option key={p.key} value={p.key} disabled={p.available === false}>
              {p.label || p.key}{p.available === false ? ` — unavailable${p.unavailable_reason ? `: ${p.unavailable_reason}` : ''}` : ''}
            </option>
          ))}
        </Select>
        {!builtin && (
          <Select id="air-model" label="Model" value={model} onChange={(e) => setModel(e.target.value)} disabled={!models.length}>
            <option value="">{models.length ? "The agent's default" : 'No choice for this agent'}</option>
            {models.map((m) => <option key={m} value={m}>{m}</option>)}
          </Select>
        )}
      </div>

      {builtin ? (
        <Select id="air-repo" label="Repository" value={repo} onChange={(e) => setRepo(e.target.value)}
          helperText={repo === 'none' ? 'It plans, answers and writes on the task (comments and subtasks); no code changes.'
            : repoInfo ? `It reads the code and commits to its own branch from ${repoInfo.branch || 'the default branch'}, then opens a pull request. Nothing is merged.`
            : undefined}>
          {repos.map((r) => <option key={r.path} value={r.path}>{r.label || r.path}</option>)}
          {!githubRepos.length && <option value="" disabled>Connect GitHub under Runners &amp; sources to work in a repository</option>}
        </Select>
      ) : (
        <div>
          <Input id="air-repo" label="Code folder on that machine" value={repo} onChange={(e) => setRepo(e.target.value)} list="air-repos"
            placeholder="/Users/you/projects/my-repo" spellCheck={false} autoComplete="off" className="font-mono"
            helperText={repoInfo?.dirty
              ? 'This folder has uncommitted changes: the runner will refuse it until they are committed or stashed.'
              : repoInfo?.branch ? `Currently on ${repoInfo.branch}. The AI works on a new branch, never on main.` : 'Pick one the runner found, or type a path. The AI works on a new branch, never on main.'} />
          <datalist id="air-repos">
            {repos.map((r) => <option key={r.path} value={r.path}>{r.branch ? `on ${r.branch}` : ''}</option>)}
          </datalist>
        </div>
      )}

      {preview && (
        <details className="rounded-lg border border-secondary-200 p-3" data-testid="air-more">
          <summary className="cursor-pointer text-sm font-medium text-secondary-700">More options</summary>
          <div className="mt-3 space-y-4">
            <Select id="air-executor" label="Executor" value={executorKind}
              disabled={preview.executor_locked && !preview.can_change_executor}
              onChange={(e) => setExecutorKind(e.target.value)}
              helperText={preview.executor_locked && !preview.can_change_executor
                ? 'An admin locked the executor for this project.'
                : 'Machine / built-in / JobShout. Admins can restrict which options appear.'}>
              {(preview.allowed_executors?.length
                ? preview.allowed_executors
                : ['machine', 'builtin', 'jobshout']).map((k) => (
                <option key={k} value={k.startsWith('provider:') ? 'provider' : k}>
                  {EXECUTOR_LABELS[k] || EXECUTOR_LABELS[k.split(':')[0]] || k}
                </option>
              ))}
            </Select>
            {preview.context && (
              <div className="space-y-2" data-testid="air-context">
                <p className="text-sm font-medium text-secondary-800">Project context for the AI</p>
                <p className="text-xs text-secondary-500">Skills, notes (MD files) and the target repo from the project. Untick what it shouldn&apos;t load.</p>
                {preview.context.target_repo_url && (
                  <p className="text-xs text-secondary-600">
                    <span className="font-medium">Target PR repo:</span> {preview.context.target_repo_url}
                    {preview.context.vault_configured ? ' · vault credentials configured' : ''}
                  </p>
                )}
                {(preview.context.skills_git_urls || []).map((sk) => (
                  <label key={sk.url} className="flex items-start gap-2 text-xs text-secondary-700">
                    <input type="checkbox" className="mt-0.5" checked={selectedSkills.includes(sk.url)}
                      onChange={(e) => setSelectedSkills((prev) => e.target.checked
                        ? [...prev, sk.url] : prev.filter((u) => u !== sk.url))} />
                    <span><span className="font-medium">{sk.label || 'Skill'}</span> — {sk.url}{sk.ref ? ` @${sk.ref}` : ''}</span>
                  </label>
                ))}
                {(preview.context.md_refs || []).map((m) => {
                  const key = m.path || m.url || '';
                  return (
                    <label key={key} className="flex items-start gap-2 text-xs text-secondary-700">
                      <input type="checkbox" className="mt-0.5" checked={selectedMd.includes(key)}
                        onChange={(e) => setSelectedMd((prev) => e.target.checked
                          ? [...prev, key] : prev.filter((u) => u !== key))} />
                      <span><span className="font-medium">{m.label || 'MD'}</span> — {key}</span>
                    </label>
                  );
                })}
                {!preview.context.target_repo_url && !(preview.context.skills_git_urls?.length)
                  && !(preview.context.md_refs?.length) && (
                  <p className="text-xs text-secondary-400">No project skills, notes or target repo yet. Set them under Project settings → AI.</p>
                )}
              </div>
            )}
          </div>
        </details>
      )}
    </div>
  );

  const outputLine = builtin && repo === 'none' ? 'It writes its answer, plan and subtasks on the task.'
    : preview?.output_mode === 'pull_request' ? 'When it’s done it opens a pull request for you to review. Nothing is merged without you.'
    : preview?.output_mode === 'branch' ? 'When it’s done it pushes its branch for you to review.'
    : preview?.output_mode === 'local' ? 'When it’s done its commit stays on that machine.'
    : `When it’s done: ${outputModeLabel(preview?.output_mode)}.`;

  const runCheck = (
    <div className="space-y-4" data-testid="air-check">
      <div className="rounded-lg bg-secondary-50 p-3">
        <p className="mb-1.5 text-sm font-semibold text-secondary-900">What happens next</p>
        <ol className="list-decimal space-y-1 pl-5 text-sm text-secondary-700">
          <li>
            {builtin ? 'The AI works inside OpsAPI' : `The AI works on ${runner?.name || 'your machine'}`}
            {builtin && repo === 'none' ? '.' : ` in ${repoInfo?.label || repo}, on a new branch (never on main).`}
          </li>
          {!builtin && <li>Before anything risky it asks first; you get a notification to Allow or Deny.</li>}
          <li>{outputLine}</li>
          <li>The run page opens next, so you can follow it live.</li>
        </ol>
      </div>

      {conflicts.length > 0 && (
        <div className="space-y-2 rounded-lg bg-error-500/10 p-3 text-sm text-error-600" role="alert">
          <p className="font-semibold">This can&apos;t start yet:</p>
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
        <div className="space-y-2 rounded-lg bg-warning-500/10 p-3 text-sm text-warning-600" role="status" data-testid="air-similar">
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

      {preview?.needs_approval && (
        <p className="flex items-start gap-2 rounded-lg bg-warning-500/10 p-3 text-sm text-warning-600" role="status">
          <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /> A manager must approve this before the AI starts.
        </p>
      )}
      {limits.info.length > 0 && <p className="text-xs text-secondary-500" data-testid="air-limits">{limits.info.join(' ')}</p>}

      {preview && (
        <details className="rounded-lg border border-secondary-200 p-3">
          <summary className="cursor-pointer text-sm font-medium text-secondary-700">
            The instructions the AI gets{canEditPrompt ? ' (you can edit them)' : ''}
          </summary>
          <div className="mt-3">
            {canEditPrompt ? (
              <Textarea id="air-prompt" label={`Prompt${preview.template_version ? ` (template v${preview.template_version})` : ''}`} rows={12}
                value={prompt} onChange={(e) => setPrompt(e.target.value)} className="font-mono text-xs" spellCheck={false}
                helperText={prompt !== preview.prompt ? 'Edited: the AI gets your text.' : 'Edit them if you like.'} />
            ) : (
              <pre aria-label="The instructions the AI gets" tabIndex={0}
                className="max-h-72 overflow-auto whitespace-pre-wrap rounded-lg border border-secondary-200 bg-secondary-50 p-3 font-mono text-xs text-secondary-800">
                {preview.prompt}
              </pre>
            )}
          </div>
        </details>
      )}
    </div>
  );

  const termCheck = (
    <div className="space-y-4" data-testid="air-check">
      <div className="rounded-lg bg-secondary-50 p-3">
        <p className="mb-1.5 text-sm font-semibold text-secondary-900">What happens next</p>
        <ol className="list-decimal space-y-1 pl-5 text-sm text-secondary-700">
          <li>
            A new tab opens the terminal on {terminal?.name || 'the machine'}
            {autologin ? ' and signs you in.' : '. If it asks, sign in with your key.'}
          </li>
          <li>
            It opens <span className="font-mono text-xs">{folder.trim()}</span>
            {agent === 'shell' ? ' with an empty terminal.' : ` and starts ${agentLabel} with this task.`}
          </li>
          <li>You work with it there. When it opens a pull request, this task moves to Review, and to Done when it merges.</li>
          <li>Your session (what you asked, its cost and a replay) is saved under AI work on this task.</li>
        </ol>
        <p className="mt-2 text-xs text-secondary-500">The link works once, for {autologin ? '2' : '15'} minutes.</p>
      </div>
      {agent !== 'shell' && (
        <details className="rounded-lg border border-secondary-200 p-3">
          <summary className="cursor-pointer text-sm font-medium text-secondary-700">The first message to the AI (you can edit it)</summary>
          <div className="mt-3">
            <Textarea id="air-terminal-prompt" label="First message" rows={10} value={termPrompt}
              onChange={(e) => setTermPromptEdited(e.target.value)} className="font-mono text-xs" spellCheck={false}
              helperText="The task, ready for the AI. You can keep talking to it in the terminal." />
          </div>
        </details>
      )}
      {launchUrl && (
        <p className="rounded-lg bg-warning-500/10 p-3 text-sm text-warning-600" role="status">
          Your browser didn&apos;t open a new tab.{' '}
          <a href={launchUrl} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 font-medium underline"
            onClick={() => setTimeout(onClose, 0)}>
            Open the terminal <ExternalLink className="h-3.5 w-3.5" aria-hidden />
          </a>
        </p>
      )}
    </div>
  );

  const back = step > (bothWays ? 1 : 2) && (
    <Button variant="ghost" onClick={() => { setError(null); setStep((x) => (x - 1) as Step); }}
      leftIcon={<ArrowLeft className="h-4 w-4" aria-hidden />}>Back</Button>
  );

  return (
    <Modal
      isOpen={open}
      onClose={onClose}
      size="2xl"
      title="Start with AI"
      description={taskLabel}
      footer={
        <>
          {back || <Button variant="ghost" onClick={onClose}>Cancel</Button>}
          {step < 3 ? (
            <Button onClick={next} isLoading={busy === 'preview'} rightIcon={<ArrowRight className="h-4 w-4" aria-hidden />}
              disabled={loading || busy !== null || (step === 1 ? !chosen1 : setupBlocked)}>
              Next
            </Button>
          ) : mode === 'terminal' ? (
            <Button onClick={doLaunch} isLoading={busy === 'start'} disabled={loading || launchBlocked || busy !== null}
              leftIcon={<Terminal className="h-4 w-4" aria-hidden />}>
              Open the terminal
            </Button>
          ) : (
            <Button onClick={doStart} isLoading={busy === 'start'} disabled={loading || blocked || busy !== null}
              leftIcon={<Bot className="h-4 w-4" aria-hidden />}>
              {preview?.needs_approval ? 'Ask for approval' : 'Start the AI'}
            </Button>
          )}
        </>
      }
    >
      {loading ? (
        <p className="py-8 text-center text-sm text-secondary-500" role="status">Getting things ready…</p>
      ) : (
        <div className="space-y-4">
          {stepper}
          {step === 1 ? howStep : step === 2 ? (mode === 'terminal' ? termSetup : runSetup) : mode === 'terminal' ? termCheck : runCheck}
          {errorNote}
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
        <button ref={ref} type="button" onClick={() => setOpen(true)} aria-label={`Start ${task.taskLabel} with AI`} data-tour="start-ai"
          className="inline-flex min-h-8 items-center gap-1 rounded-lg px-2 text-xs font-semibold text-primary-600 transition hover:bg-primary-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500">
          <Bot className="h-3 w-3" aria-hidden /> Start with AI
        </button>
      ) : (
        <Button ref={ref} size="sm" variant="outline" onClick={() => setOpen(true)} leftIcon={<Bot className="h-4 w-4" aria-hidden />}
          data-tour="start-ai">
          Start with AI
        </Button>
      )}
      {/* Portalled: the assistant panel may sit in a transformed container that would clip a fixed overlay. */}
      {open && createPortal(<StartWithAIDialog open={open} onClose={close} {...task} />, document.body)}
    </>
  );
}

export default StartWithAIDialog;
