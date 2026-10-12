'use client';

/**
 * Runners (ai_runners.manage): the machines that run AI tasks for this workspace through PromptPilot.
 * Register (token shown once + setup), rotate the token, pause / resume, revoke, each machine's sessions, and
 * who may start runs on it (Access, §25.1).
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { Copy, KeyRound, ListTree, Pause, Play, Plus, Server, Trash2, Users } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, ConfirmDialog, Input, Modal, Table } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import { AiRunnerPage, BASE, PRODUCT, ProfileList, RunnerStatusBadge, ago, useAiData } from '@/components/ai-runner/ui';
import apiClient from '@/lib/api-client';
import { kanbanService } from '@/services/kanban.service';
import namespaceService from '@/services/namespace.service';
import { aiRunner, aiErrorText, type Runner, type RunnerAccess, type RunnerAccessMode } from '@/services/ai-runner.service';

export default function RunnersPage() {
  return (
    <AiRunnerPage module="ai_runners" action="manage">
      <Runners />
    </AiRunnerPage>
  );
}

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'runner';

function opsapiUrl(): string {
  const base = apiClient.defaults.baseURL || '';
  return /^https?:\/\//.test(base) ? base.replace(/\/$/, '') : `${window.location.origin}${base}`.replace(/\/$/, '');
}

function copy(text: string, what: string) {
  navigator.clipboard.writeText(text).then(() => toast.success(`${what} copied`), () => toast.error('Could not copy'));
}

function CopyBlock({ text, what, testId }: { text: string; what: string; testId?: string }) {
  return (
    <div className="relative">
      <pre data-testid={testId} className="overflow-x-auto whitespace-pre rounded-lg bg-secondary-900 p-3 pr-24 font-mono text-xs text-secondary-100">{text}</pre>
      <Button size="sm" variant="ghost" className="absolute right-1.5 top-1.5 bg-surface/90" onClick={() => copy(text, what)}
        leftIcon={<Copy className="h-3.5 w-3.5" aria-hidden />} aria-label={`Copy ${what.toLowerCase()}`}>
        Copy
      </Button>
    </div>
  );
}

function runnerJson(name: string): string {
  const s = slug(name);
  return JSON.stringify({
    registrations: [{
      name,
      opsapi_url: opsapiUrl(),
      token_file: `/Users/you/.promptpilot/${s}.token`,
      allowed_roots: ['/Users/you/projects'],
      max_concurrency: 1,
    }],
    profiles: [{
      key: 'claude',
      label: 'Claude Code',
      approval: 'none',
      models: [],
      command: ['claude', '-p', '{{prompt}}', '--output-format', 'stream-json', '--verbose', '--session-id', '{{run_uuid}}',
        '--restricted', '--strict-mcp-config', '--permission-mode', 'acceptEdits', '--permission-prompts', 'none',
        '--allowedTools', 'Read,Grep,Glob,Edit,MultiEdit,Write',
        // Secrets on the machine stay out of the agent's reach (§25.6).
        '--disallowedTools', 'Read(**/.env),Read(**/.env.*),Read(**/*.pem),Read(**/id_*),Read(~/.ssh/**),Read(~/.aws/**),'
          + 'Read(~/.config/gh/**),Read(~/.netrc),Read(~/.npmrc),Read(~/.kube/**)'],
      env: {},
      // Checked at start and every 5 minutes: a logged-out agent is reported unavailable and takes no work.
      health: { command: ['claude', 'auth', 'status', '--json'], every_s: 300 },
    }],
    claude_oauth_token_file: '/Users/you/.promptpilot/claude-oauth.token',
    restore_branch: true,
  }, null, 2);
}

/** The token, once, with how to set the machine up. */
function TokenModal({ shown, onClose }: { shown: { name: string; token: string; rotated: boolean } | null; onClose: () => void }) {
  if (!shown) return null;
  const s = slug(shown.name);
  return (
    <Modal isOpen onClose={onClose} size="2xl" title={shown.rotated ? `New token for ${shown.name}` : `Runner ${shown.name} registered`}
      footer={<Button onClick={onClose}>I saved the token</Button>}>
      <div className="space-y-4 text-sm text-secondary-700">
        <p className="rounded-lg bg-warning-500/10 p-3 font-medium text-warning-700" role="alert">
          Copy this token now. You won&apos;t see it again{shown.rotated ? ', and the old token no longer works' : ''}.
        </p>
        <CopyBlock text={shown.token} what="Token" testId="runner-token" />
        <ol className="list-decimal space-y-3 pl-5">
          <li>
            Save the token on the machine (macOS, after Copy; on Linux paste it into the file with an editor):
            <CopyBlock what="Command" text={`mkdir -p ~/.promptpilot && pbpaste > ~/.promptpilot/${s}.token && chmod 600 ~/.promptpilot/${s}.token`} />
          </li>
          {!shown.rotated && (
            <li>
              Save this as <code className="font-mono">runner.json</code>, changing <code className="font-mono">/Users/you</code> and{' '}
              <code className="font-mono">allowed_roots</code> to the folders the agent may work in:
              <CopyBlock what="runner.json" text={runnerJson(shown.name)} />
            </li>
          )}
          <li>
            {shown.rotated ? 'Restart the runner' : 'Start the runner'}:
            <CopyBlock what="Command" text="promptpilot runner -config runner.json" />
          </li>
          <li>Within about 15 seconds the runner shows as Online here.</li>
        </ol>
      </div>
    </Modal>
  );
}

function SessionsModal({ runner, onClose }: { runner: Runner | null; onClose: () => void }) {
  const sessions = useAiData(() => (runner ? aiRunner.runnerSessions(runner.uuid) : Promise.resolve([])), [runner?.uuid]);
  if (!runner) return null;
  return (
    <Modal isOpen onClose={onClose} size="3xl" title={`Sessions on ${runner.name}`} description="What the runner last reported: runs it manages and sessions started by hand.">
      <ErrorNote error={sessions.error} product={PRODUCT} />
      <Table
        caption={`Sessions on ${runner.name}`}
        data={sessions.data || []}
        isLoading={sessions.loading && !sessions.data}
        keyExtractor={(s) => s.key}
        emptyMessage="No sessions reported."
        columns={[
          { key: 'tool', header: 'Tool', render: (s) => s.tool || '—' },
          { key: 'status', header: 'Status', render: (s) => s.status || '—' },
          { key: 'cwd', header: 'Folder', render: (s) => <span className="break-all font-mono text-xs">{s.cwd || '—'}</span> },
          { key: 'branch', header: 'Branch', render: (s) => <span className="font-mono text-xs">{s.branch || '—'}</span> },
          {
            key: 'run', header: 'Run', render: (s) => s.run_uuid
              ? <Link href={`${BASE}/runs/${s.run_uuid}`} className="text-primary-600 hover:underline" onClick={onClose}>Open run</Link>
              : <span className="text-secondary-400">by hand</span>,
          },
        ]}
      />
    </Modal>
  );
}

// An empty Lua table arrives as {} rather than [].
const ids = (v: unknown) => (Array.isArray(v) ? (v as string[]) : []);
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

const ACCESS_MODES: { value: RunnerAccessMode; label: string; hint: string }[] = [
  { value: 'owner', label: 'Only its owner and AI-run managers', hint: 'The person who registered it, and people who manage AI runs or runners.' },
  { value: 'everyone', label: 'Everyone who can start runs', hint: 'Anyone in the workspace allowed to start a run on a task.' },
  { value: 'listed', label: 'Selected people and projects', hint: 'Its owner and AI-run managers, the people you pick, and runs on tasks in the projects you pick.' },
];

/** The Access column: who may start runs on this machine. */
function accessText(a?: RunnerAccess | null): string {
  if (!a?.mode) return '—';
  if (a.mode === 'everyone') return 'Everyone';
  if (a.mode === 'listed') {
    return `Selected: ${plural(ids(a.users).length, 'person', 'people')}, ${plural(ids(a.projects).length, 'project', 'projects')}`;
  }
  return 'Owner and managers';
}

type Choice = { value: string; label: string; hint?: string };

/** Checkboxes with a filter. Picked uuids the list doesn't show (no access, or gone) stay listed so they can be removed. */
function CheckList({ legend, items, picked, onChange, loading, error }: {
  legend: string; items: Choice[]; picked: string[]; onChange: (v: string[]) => void; loading: boolean; error?: string;
}) {
  const [q, setQ] = useState('');
  const known = new Set(items.map((i) => i.value));
  const all = [...items, ...picked.filter((v) => !known.has(v)).map((v) => ({ value: v, label: 'Not in the list', hint: v }))];
  const shown = all.filter((i) => !q || `${i.label} ${i.hint || ''}`.toLowerCase().includes(q.trim().toLowerCase()));
  return (
    <fieldset className="min-w-0 space-y-2">
      <legend className="text-sm font-medium text-secondary-800">
        {legend} <span className="font-normal text-secondary-500">({picked.length} selected)</span>
      </legend>
      <Input aria-label={`Filter ${legend.toLowerCase()}`} placeholder="Filter" value={q} onChange={(e) => setQ(e.target.value)} />
      <div className="max-h-48 space-y-1 overflow-auto rounded-lg border border-secondary-200 p-2">
        {error && <p className="text-sm text-error-600">{error}</p>}
        {!error && loading && !all.length && <p className="text-sm text-secondary-500">Loading…</p>}
        {!loading && !shown.length && <p className="text-sm text-secondary-500">None found.</p>}
        {shown.map((i) => (
          <label key={i.value} className="flex items-start gap-2 text-sm">
            <input type="checkbox" className="mt-0.5" checked={picked.includes(i.value)}
              onChange={(e) => onChange(e.target.checked ? [...picked, i.value] : picked.filter((v) => v !== i.value))} />
            <span className="min-w-0">
              {i.label}
              {i.hint && <span className="block break-all text-xs text-secondary-500">{i.hint}</span>}
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

/** Who may start runs on a runner (PUT /runners/:uuid/access). */
function AccessModal({ runner, onClose, onSaved }: { runner: Runner; onClose: () => void; onSaved: () => void }) {
  const [mode, setMode] = useState<RunnerAccessMode>(runner.access?.mode || 'owner');
  const [users, setUsers] = useState(ids(runner.access?.users));
  const [projects, setProjects] = useState(ids(runner.access?.projects));
  const [busy, setBusy] = useState(false);
  // ponytail: the first 200 members and projects; add server-side search if workspaces outgrow that.
  const members = useAiData(async () => (await namespaceService.getMembers({ perPage: 200, status: 'active' })).data || [], [runner.uuid]);
  const kanban = useAiData(async () => (await kanbanService.getProjects({ perPage: 200 })).data || [], [runner.uuid]);
  const people: Choice[] = (members.data || []).flatMap((m) => m.user ? [{
    value: m.user.uuid,
    label: m.user.full_name || [m.user.first_name, m.user.last_name].filter(Boolean).join(' ') || m.user.email,
    hint: m.user.email,
  }] : []);
  const projectChoices: Choice[] = (kanban.data || []).map((p) => ({ value: p.uuid, label: p.name }));

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      await aiRunner.setRunnerAccess(runner.uuid, mode === 'listed' ? { mode, users, projects } : { mode });
      toast.success(`Access to ${runner.name} saved`);
      onSaved();
      onClose();
    } catch (err) {
      toast.error(aiErrorText(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal isOpen onClose={onClose} size="2xl" title={`Access to ${runner.name}`}
      description="Who can start runs on this machine. New runners start as owner-only: only the person who registered the runner and AI-run managers can use them until you change it here.">
      <form onSubmit={save} className="space-y-4">
        <fieldset className="space-y-2">
          <legend className="text-sm font-medium text-secondary-800">Who can start runs on this machine</legend>
          {ACCESS_MODES.map((m) => (
            <label key={m.value} className="flex items-start gap-2 text-sm">
              <input type="radio" name="air-access-mode" className="mt-1" value={m.value} checked={mode === m.value} onChange={() => setMode(m.value)} />
              <span>
                <span className="font-medium text-secondary-900">{m.label}</span>
                <span className="block text-xs text-secondary-500">{m.hint}</span>
              </span>
            </label>
          ))}
        </fieldset>
        {mode === 'listed' && (
          <div className="grid gap-4 sm:grid-cols-2">
            <CheckList legend="People" items={people} picked={users} onChange={setUsers} loading={members.loading}
              error={members.error && "Can't load the workspace's members."} />
            <CheckList legend="Projects" items={projectChoices} picked={projects} onChange={setProjects} loading={kanban.loading}
              error={kanban.error && "Can't load the projects."} />
          </div>
        )}
        <p className="text-xs text-secondary-500">
          AI-run managers can always use every runner. Someone without access doesn&apos;t see this runner when starting a run.
        </p>
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>Cancel</Button>
          <Button type="submit" isLoading={busy}>Save access</Button>
        </div>
      </form>
    </Modal>
  );
}

function Runners() {
  const runners = useAiData(() => aiRunner.listRunners(), [], 15_000);
  const [registerOpen, setRegisterOpen] = useState(false);
  const [name, setName] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [token, setToken] = useState<{ name: string; token: string; rotated: boolean } | null>(null);
  const [confirm, setConfirm] = useState<{ kind: 'rotate' | 'revoke'; runner: Runner } | null>(null);
  const [sessionsOf, setSessionsOf] = useState<Runner | null>(null);
  const [accessOf, setAccessOf] = useState<Runner | null>(null);

  async function act(key: string, fn: () => Promise<unknown>, ok: string) {
    setBusy(key);
    try {
      await fn();
      toast.success(ok);
      runners.refresh();
      return true;
    } catch (e) {
      toast.error(aiErrorText(e));
      return false;
    } finally {
      setBusy(null);
    }
  }

  async function register(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim()) return;
    await act('register', async () => {
      const res = await aiRunner.registerRunner(name.trim());
      setRegisterOpen(false);
      setToken({ name: res.runner?.name || name.trim(), token: res.token, rotated: false });
      setName('');
    }, 'Runner registered');
  }

  async function confirmed() {
    if (!confirm) return;
    const r = confirm.runner;
    if (confirm.kind === 'rotate') {
      await act(`rotate:${r.uuid}`, async () => {
        const res = await aiRunner.rotateToken(r.uuid);
        setToken({ name: r.name, token: res.token, rotated: true });
      }, 'New token issued');
    } else {
      await act(`revoke:${r.uuid}`, () => aiRunner.revokeRunner(r.uuid), 'Runner revoked');
    }
    setConfirm(null);
  }

  const columns = [
    { key: 'name', header: 'Name', render: (r: Runner) => <span className="font-medium">{r.name}</span> },
    { key: 'status', header: 'Status', render: (r: Runner) => <RunnerStatusBadge status={r.status} /> },
    {
      key: 'machine', header: 'Machine', render: (r: Runner) => (
        <div>
          <div>{r.host || '—'}</div>
          {(r.os || r.version) && <div className="text-xs text-secondary-500">{[r.os, r.version && `v${r.version}`].filter(Boolean).join(' · ')}</div>}
        </div>
      ),
    },
    { key: 'heartbeat', header: 'Last heartbeat', render: (r: Runner) => ago(r.last_heartbeat_at) },
    { key: 'profiles', header: 'Profiles', render: (r: Runner) => <ProfileList profiles={r.capabilities?.profiles} /> },
    { key: 'repos', header: 'Repos', render: (r: Runner) => (r.repos || []).length },
    { key: 'access', header: 'Access', render: (r: Runner) => accessText(r.access) },
    {
      key: 'actions', header: 'Actions', render: (r: Runner) => r.status === 'revoked' ? null : (
        <div className="flex flex-wrap gap-1">
          <Button size="sm" variant="ghost" onClick={() => setSessionsOf(r)} leftIcon={<ListTree className="h-4 w-4" aria-hidden />} aria-label={`Sessions on ${r.name}`}>Sessions</Button>
          <Button size="sm" variant="ghost" onClick={() => setAccessOf(r)} leftIcon={<Users className="h-4 w-4" aria-hidden />} aria-label={`Access to ${r.name}`}>Access</Button>
          {r.status === 'paused' ? (
            <Button size="sm" variant="ghost" isLoading={busy === `resume:${r.uuid}`} onClick={() => act(`resume:${r.uuid}`, () => aiRunner.resumeRunner(r.uuid), 'Runner resumed')}
              leftIcon={<Play className="h-4 w-4" aria-hidden />} aria-label={`Resume ${r.name}`}>Resume</Button>
          ) : (
            <Button size="sm" variant="ghost" isLoading={busy === `pause:${r.uuid}`} onClick={() => act(`pause:${r.uuid}`, () => aiRunner.pauseRunner(r.uuid), 'Runner paused')}
              leftIcon={<Pause className="h-4 w-4" aria-hidden />} aria-label={`Pause ${r.name}`}>Pause</Button>
          )}
          <Button size="sm" variant="ghost" onClick={() => setConfirm({ kind: 'rotate', runner: r })} leftIcon={<KeyRound className="h-4 w-4" aria-hidden />} aria-label={`Rotate the token of ${r.name}`}>Rotate token</Button>
          <Button size="sm" variant="ghost" className="text-error-600" onClick={() => setConfirm({ kind: 'revoke', runner: r })} leftIcon={<Trash2 className="h-4 w-4" aria-hidden />} aria-label={`Revoke ${r.name}`}>Revoke</Button>
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Runners"
        description="Machines that run AI tasks for this workspace through PromptPilot."
        icon={<Server className="h-6 w-6" />}
        actions={<Button leftIcon={<Plus className="h-4 w-4" aria-hidden />} onClick={() => setRegisterOpen(true)}>Register runner</Button>}
      />
      <ErrorNote error={runners.error} product={PRODUCT} />
      <Table<Runner>
        caption="Runners"
        columns={columns}
        data={runners.data || []}
        keyExtractor={(r) => r.uuid}
        isLoading={runners.loading && !runners.data}
        emptyMessage="No runners yet. Register one, then start PromptPilot on that machine."
      />

      <Modal isOpen={registerOpen} onClose={() => setRegisterOpen(false)} title="Register a runner" size="md"
        description="One runner per machine (or per set of folders). You get its token once.">
        <form onSubmit={register} className="space-y-4">
          <Input id="air-runner-name" label="Name" value={name} onChange={(e) => setName(e.target.value)} placeholder="mac-studio" required maxLength={100} />
          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" onClick={() => setRegisterOpen(false)}>Cancel</Button>
            <Button type="submit" isLoading={busy === 'register'} disabled={!name.trim()}>Register</Button>
          </div>
        </form>
      </Modal>

      <TokenModal shown={token} onClose={() => setToken(null)} />
      <SessionsModal runner={sessionsOf} onClose={() => setSessionsOf(null)} />
      {accessOf && <AccessModal runner={accessOf} onClose={() => setAccessOf(null)} onSaved={runners.refresh} />}

      <ConfirmDialog
        isOpen={!!confirm}
        onClose={() => setConfirm(null)}
        onConfirm={confirmed}
        title={confirm?.kind === 'rotate' ? `Rotate the token of ${confirm.runner.name}?` : `Revoke ${confirm?.runner.name}?`}
        message={confirm?.kind === 'rotate'
          ? 'The current token stops working at once. Put the new one on the machine and restart the runner.'
          : 'The runner can no longer claim or report runs. This cannot be undone; register it again to bring it back.'}
        confirmText={confirm?.kind === 'rotate' ? 'Rotate token' : 'Revoke'}
        variant={confirm?.kind === 'rotate' ? 'warning' : 'danger'}
        isLoading={!!busy && busy !== 'register'}
      />
    </div>
  );
}
