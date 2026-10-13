'use client';

/**
 * Runners & sources (ai_runners.manage): the connections that feed this workspace — runners (PromptPilot machines
 * that run AI tasks and report sessions) and sources (anything that only reports sessions, §27.1). Register (token
 * shown once + setup), rotate the token, pause / resume, revoke, each connection's sessions, what it reports
 * (§27.2), and who may start runs on a runner (Access, §25.1). §28: the built-in runner (inside OpsAPI, no machine) is
 * listed too — pause it or limit who may use it — with the GitHub installations whose repositories it works in.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { Bot, Copy, ExternalLink, Filter, GitBranch, KeyRound, ListTree, Pause, Play, Plus, RefreshCw, Server, Trash2, Users } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, ConfirmDialog, Input, Modal, Select, Table } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import { AiRunnerPage, BASE, PRODUCT, ProfileList, RunnerStatusBadge, ago, useAiData } from '@/components/ai-runner/ui';
import { CheckList, TagsInput, strings, useMembers, useProjects } from '@/components/ai-runner/fields';
import apiClient from '@/lib/api-client';
import {
  aiRunner, aiErrorText, type ConnectionKind, type GithubInstallation, type Runner, type RunnerAccess, type RunnerAccessMode,
} from '@/services/ai-runner.service';

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

/** §27.1: any tool can report its sessions with the connection's token (the same storage and tracking as a heartbeat). */
function sessionsCurl(auth: string): string {
  const body = JSON.stringify({
    sessions: [{
      key: 'build-42', tool: 'codex', status: 'busy', cwd: '/work/app', branch: 'feature/login', session_id: 'build-42',
      started_at: '2026-10-13T09:00:00Z', first_prompt: 'Fix the login redirect',
    }],
  });
  return [
    `curl -X POST ${opsapiUrl()}/api/v2/ai-runner/public/runner/sessions`,
    `  -H "Authorization: Bearer ${auth}"`,
    '  -H "Content-Type: application/json"',
    `  -d '${body}'`,
  ].join(' \\\n');
}

const KINDS: { value: ConnectionKind; label: string; hint: string }[] = [
  { value: 'runner', label: 'Runner', hint: 'A machine running PromptPilot: it runs AI tasks from OpsAPI and reports its sessions.' },
  { value: 'source', label: 'Source', hint: 'Only reports sessions (a CI job, another observer, an IDE plugin…); it never runs tasks.' },
];
const kindOf = (r: Pick<Runner, 'kind'>): ConnectionKind => (r.kind === 'source' || r.kind === 'builtin' ? r.kind : 'runner');
const KIND_LABEL: Record<ConnectionKind, string> = { runner: 'Runner', source: 'Source', builtin: 'Built-in' };

type Shown = { name: string; token: string; rotated: boolean; kind: ConnectionKind };

/** The token, once, with how to set the machine (or the source) up. */
function TokenModal({ shown, onClose }: { shown: Shown | null; onClose: () => void }) {
  if (!shown) return null;
  const s = slug(shown.name);
  if (shown.kind === 'source') {
    return (
      <Modal isOpen onClose={onClose} size="2xl" title={shown.rotated ? `New token for ${shown.name}` : `Source ${shown.name} registered`}
        footer={<Button onClick={onClose}>I saved the token</Button>}>
        <div className="space-y-4 text-sm text-secondary-700">
          <p className="rounded-lg bg-warning-500/10 p-3 font-medium text-warning-700" role="alert">
            Copy this token now. You won&apos;t see it again{shown.rotated ? ', and the old token no longer works' : ''}.
          </p>
          <CopyBlock text={shown.token} what="Token" testId="runner-token" />
          <p>
            Keep it where the source runs (for example in <code className="font-mono">~/.promptpilot/{s}.token</code>, readable only by you),
            then report sessions with it. Each call replaces what this source reported before:
          </p>
          <CopyBlock what="Command" text={sessionsCurl(`$(cat ~/.promptpilot/${s}.token)`)} />
          <p className="text-xs text-secondary-500">
            Fields: key, tool, status, cwd, branch, session_id, started_at, updated_at, first_prompt, prompt_preview, labels. Tool and
            status are free text. With PromptPilot on the machine, add <code className="font-mono">&quot;report_only&quot;: true</code> to its
            registration instead: it reports sessions and never runs tasks.
          </p>
        </div>
      </Modal>
    );
  }
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

const ids = strings;
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

/** Who may start runs on a runner (PUT /runners/:uuid/access). */
function AccessModal({ runner, onClose, onSaved }: { runner: Runner; onClose: () => void; onSaved: () => void }) {
  const [mode, setMode] = useState<RunnerAccessMode>(runner.access?.mode || 'owner');
  const [users, setUsers] = useState(ids(runner.access?.users));
  const [projects, setProjects] = useState(ids(runner.access?.projects));
  const [busy, setBusy] = useState(false);
  const members = useMembers();
  const kanban = useProjects();

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
            <CheckList legend="People" items={members.choices} picked={users} onChange={setUsers} loading={members.loading}
              error={members.error && "Can't load the workspace's members."} />
            <CheckList legend="Projects" items={kanban.choices} picked={projects} onChange={setProjects} loading={kanban.loading}
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

/** "Reports: 2 folders, 1 tool" — what a connection's report filter keeps (§27.2). */
function filterText(f?: Runner['report_filter']): string {
  const parts = [
    [strings(f?.folders).length, 'folder', 'folders'],
    [strings(f?.exclude_folders).length, 'excluded folder', 'excluded folders'],
    [strings(f?.tools).length, 'tool', 'tools'],
  ].flatMap(([n, one, many]) => (n ? [plural(n as number, one as string, many as string)] : []));
  return parts.length ? `Reports: ${parts.join(', ')}` : 'Reports all the machine allows';
}

/** What a connection reports (PUT /runners/:uuid/report-filter): it only ever narrows what the machine owner allows. */
function ReportFilterModal({ runner, onClose, onSaved }: { runner: Runner; onClose: () => void; onSaved: () => void }) {
  const f = runner.report_filter;
  const [folders, setFolders] = useState(strings(f?.folders));
  const [exclude, setExclude] = useState(strings(f?.exclude_folders));
  const [tools, setTools] = useState(strings(f?.tools));
  const [busy, setBusy] = useState(false);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      await aiRunner.setReportFilter(runner.uuid, { folders, exclude_folders: exclude, tools });
      toast.success(`What ${runner.name} reports saved`);
      onSaved();
      onClose();
    } catch (err) {
      toast.error(aiErrorText(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal isOpen onClose={onClose} size="2xl" title={`What ${runner.name} reports`}
      description="Which sessions this connection reports to this workspace. Empty fields keep everything the machine's owner allows.">
      <form onSubmit={save} className="space-y-4">
        <p className="rounded-lg bg-secondary-100 p-3 text-xs text-secondary-700">
          This can only narrow what the machine&apos;s owner allows in its <code className="font-mono">runner.json</code>{' '}
          (<code className="font-mono">inventory_roots</code>, and <code className="font-mono">share_manual_prompts</code> for prompt
          text), never widen it. The runner applies it on the machine, and OpsAPI applies it again to whatever arrives.
        </p>
        <TagsInput id="air-rf-folders" label="Only these folders" values={folders} onChange={setFolders} placeholder="~/work/**"
          hint="Globs. A session is reported only when its folder matches one. Empty: every folder allowed." />
        <TagsInput id="air-rf-exclude" label="Never these folders" values={exclude} onChange={setExclude} placeholder="~/work/private/**"
          hint="Globs. Sessions in matching folders are never reported, even inside the folders above." />
        <TagsInput id="air-rf-tools" label="Only these tools" values={tools} onChange={setTools} placeholder="claude"
          hint="Tool names as the connection reports them (claude, cursor, codex…). Empty: every tool." />
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>Cancel</Button>
          <Button type="submit" isLoading={busy}>Save</Button>
        </div>
      </form>
    </Modal>
  );
}

/**
 * §28: the built-in runner runs inside OpsAPI, so no machine is needed. It works without a repository (plans,
 * comments, subtasks); with the GitHub App installed it works in the repositories chosen there, through pull requests.
 */
function BuiltinCard({ runner, onChanged }: { runner?: Runner; onChanged: () => void }) {
  const github = useAiData(() => aiRunner.github(), []);
  const [busy, setBusy] = useState<string | null>(null);
  const [disconnect, setDisconnect] = useState<GithubInstallation | null>(null);
  const repos = (runner?.repos || []).filter((r) => r.path !== 'none');
  const g = github.data;

  async function run(key: string, fn: () => Promise<unknown>, ok: string) {
    setBusy(key);
    try {
      await fn();
      toast.success(ok);
      github.refresh();
      onChanged();
    } catch (e) {
      toast.error(aiErrorText(e));
    } finally {
      setBusy(null);
    }
  }

  return (
    <section className="space-y-3 rounded-xl border border-secondary-200 bg-surface p-4" aria-labelledby="air-builtin-title" data-testid="air-builtin">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 id="air-builtin-title" className="flex items-center gap-2 text-base font-semibold text-secondary-900">
            <Bot className="h-5 w-5 text-primary-600" aria-hidden /> Built-in runner: no machine needed
          </h2>
          <p className="mt-1 max-w-3xl text-sm text-secondary-600">
            Runs inside OpsAPI on an AI model: the workspace&apos;s own (AI providers), else the platform&apos;s. Without a repository it
            plans, answers and adds comments and subtasks. With GitHub connected it reads the code and opens a pull request from its
            own branch. It has no shell, so it can&apos;t run code or tests; for that, use a machine runner.
          </p>
        </div>
        {runner && <RunnerStatusBadge status={runner.status} />}
      </div>
      <ErrorNote error={github.error} product={PRODUCT} />
      {g && !g.configured && (
        <p className="rounded-lg bg-secondary-100 p-3 text-sm text-secondary-700">
          To work in repositories, a platform admin first sets up the GitHub App under{' '}
          <Link className="underline" href={`${BASE}/platform`}>AI Runs platform settings</Link>.
        </p>
      )}
      {g?.configured && (
        <div className="space-y-2">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="text-sm font-medium text-secondary-800">GitHub</h3>
            {g.install_url && (
              <a href={g.install_url} className="inline-flex items-center gap-1 rounded-lg bg-primary-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-primary-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500">
                <GitBranch className="h-4 w-4" aria-hidden /> {g.installations.length ? 'Connect another account or change repositories' : 'Connect GitHub'}
                <ExternalLink className="h-3.5 w-3.5" aria-hidden />
              </a>
            )}
            <Button size="sm" variant="ghost" isLoading={busy === 'refresh'} leftIcon={<RefreshCw className="h-4 w-4" aria-hidden />}
              onClick={() => run('refresh', () => aiRunner.refreshRunners(), 'Repositories read from GitHub')}>
              Refresh repositories
            </Button>
          </div>
          {g.installations.length === 0 ? (
            <p className="text-sm text-secondary-600">
              No GitHub account connected yet. Connect GitHub installs the App on the repositories you choose; GitHub then brings you
              back here to confirm.
            </p>
          ) : (
            <ul className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
              {g.installations.map((i) => (
                <li key={i.uuid} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm">
                  <span>
                    <span className="font-medium text-secondary-900">{i.account_login || `Installation ${i.installation_id}`}</span>
                    <span className="text-secondary-500">
                      {' '}· {i.account_type || 'account'} · {i.repository_selection === 'all' ? 'all repositories' : 'selected repositories'}
                      {i.created_by_name ? ` · connected by ${i.created_by_name}` : ''}
                    </span>
                  </span>
                  {g.can_manage && (
                    <Button size="sm" variant="ghost" className="text-error-600" onClick={() => setDisconnect(i)}
                      leftIcon={<Trash2 className="h-4 w-4" aria-hidden />} aria-label={`Disconnect ${i.account_login || i.installation_id}`}>
                      Disconnect
                    </Button>
                  )}
                </li>
              ))}
            </ul>
          )}
          <p className="text-xs text-secondary-500" data-testid="air-builtin-repos">
            {repos.length ? `Repositories it can work in: ${repos.map((r) => r.label || r.path).join(', ')}` : 'No repositories yet.'}
          </p>
        </div>
      )}
      <ConfirmDialog
        isOpen={!!disconnect}
        onClose={() => setDisconnect(null)}
        onConfirm={async () => {
          const i = disconnect;
          setDisconnect(null);
          if (i) await run(`disconnect:${i.uuid}`, () => aiRunner.githubDisconnect(i.uuid), 'GitHub account disconnected');
        }}
        title={`Disconnect ${disconnect?.account_login || 'this account'}?`}
        message="The built-in runner stops offering its repositories to this workspace. The App stays installed on GitHub (uninstall it there to remove it everywhere)."
        confirmText="Disconnect"
        variant="danger"
      />
    </section>
  );
}

function Runners() {
  const runners = useAiData(() => aiRunner.listRunners(), [], 15_000);
  const [registerOpen, setRegisterOpen] = useState(false);
  const [name, setName] = useState('');
  const [kind, setKind] = useState<ConnectionKind>('runner');
  const [kindFilter, setKindFilter] = useState<'' | ConnectionKind>('');
  const [busy, setBusy] = useState<string | null>(null);
  const [token, setToken] = useState<Shown | null>(null);
  const [confirm, setConfirm] = useState<{ kind: 'rotate' | 'revoke'; runner: Runner } | null>(null);
  const [sessionsOf, setSessionsOf] = useState<Runner | null>(null);
  const [accessOf, setAccessOf] = useState<Runner | null>(null);
  const [filterOf, setFilterOf] = useState<Runner | null>(null);

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
      const res = await aiRunner.registerRunner(name.trim(), kind);
      setRegisterOpen(false);
      setToken({ name: res.runner?.name || name.trim(), token: res.token, rotated: false, kind });
      setName('');
    }, kind === 'source' ? 'Source registered' : 'Runner registered');
  }

  async function confirmed() {
    if (!confirm) return;
    const r = confirm.runner;
    if (confirm.kind === 'rotate') {
      await act(`rotate:${r.uuid}`, async () => {
        const res = await aiRunner.rotateToken(r.uuid);
        setToken({ name: r.name, token: res.token, rotated: true, kind: kindOf(r) });
      }, 'New token issued');
    } else {
      await act(`revoke:${r.uuid}`, () => aiRunner.revokeRunner(r.uuid), 'Runner revoked');
    }
    setConfirm(null);
  }

  const columns = [
    { key: 'name', header: 'Name', render: (r: Runner) => <span className="font-medium">{r.name}</span> },
    {
      key: 'kind', header: 'Kind', render: (r: Runner) => (
        <div>
          <Badge size="sm" variant={kindOf(r) === 'source' ? 'info' : kindOf(r) === 'builtin' ? 'success' : 'default'}>{KIND_LABEL[kindOf(r)]}</Badge>
          {kindOf(r) !== 'builtin' && <div className="mt-1 text-xs text-secondary-500">{filterText(r.report_filter)}</div>}
        </div>
      ),
    },
    { key: 'status', header: 'Status', render: (r: Runner) => <RunnerStatusBadge status={r.status} /> },
    {
      key: 'machine', header: 'Machine', render: (r: Runner) => (
        kindOf(r) === 'builtin' ? (
          <div>
            <div>Inside OpsAPI</div>
            <div className="text-xs text-secondary-500">{plural((r.repos || []).filter((x) => x.path !== 'none').length, 'GitHub repo', 'GitHub repos')}</div>
          </div>
        ) : (
        <div>
          <div>{r.host || '—'}</div>
          {(r.os || r.version) && <div className="text-xs text-secondary-500">{[r.os, r.version && `v${r.version}`].filter(Boolean).join(' · ')}</div>}
          {kindOf(r) === 'runner' && <div className="text-xs text-secondary-500">{plural((r.repos || []).length, 'repo', 'repos')}</div>}
        </div>
        )
      ),
    },
    { key: 'heartbeat', header: 'Last heartbeat', render: (r: Runner) => (kindOf(r) === 'builtin' ? 'Always on' : ago(r.last_heartbeat_at)) },
    { key: 'profiles', header: 'Profiles', render: (r: Runner) => <ProfileList profiles={r.capabilities?.profiles} /> },
    { key: 'access', header: 'Access', render: (r: Runner) => (kindOf(r) === 'source' ? <span className="text-secondary-400">—</span> : accessText(r.access)) },
    {
      key: 'actions', header: 'Actions', render: (r: Runner) => r.status === 'revoked' ? null : (
        <div className="flex flex-wrap gap-1">
          {kindOf(r) !== 'builtin' && (
            <>
              <Button size="sm" variant="ghost" onClick={() => setSessionsOf(r)} leftIcon={<ListTree className="h-4 w-4" aria-hidden />} aria-label={`Sessions on ${r.name}`}>Sessions</Button>
              <Button size="sm" variant="ghost" onClick={() => setFilterOf(r)} leftIcon={<Filter className="h-4 w-4" aria-hidden />} aria-label={`What ${r.name} reports`}>Reports</Button>
            </>
          )}
          {kindOf(r) !== 'source' && (
            <Button size="sm" variant="ghost" onClick={() => setAccessOf(r)} leftIcon={<Users className="h-4 w-4" aria-hidden />} aria-label={`Access to ${r.name}`}>Access</Button>
          )}
          {r.status === 'paused' ? (
            <Button size="sm" variant="ghost" isLoading={busy === `resume:${r.uuid}`} onClick={() => act(`resume:${r.uuid}`, () => aiRunner.resumeRunner(r.uuid), 'Runner resumed')}
              leftIcon={<Play className="h-4 w-4" aria-hidden />} aria-label={`Resume ${r.name}`}>Resume</Button>
          ) : (
            <Button size="sm" variant="ghost" isLoading={busy === `pause:${r.uuid}`} onClick={() => act(`pause:${r.uuid}`, () => aiRunner.pauseRunner(r.uuid), 'Runner paused')}
              leftIcon={<Pause className="h-4 w-4" aria-hidden />} aria-label={`Pause ${r.name}`}>Pause</Button>
          )}
          {kindOf(r) !== 'builtin' && (
            <>
              <Button size="sm" variant="ghost" onClick={() => setConfirm({ kind: 'rotate', runner: r })} leftIcon={<KeyRound className="h-4 w-4" aria-hidden />} aria-label={`Rotate the token of ${r.name}`}>Rotate token</Button>
              <Button size="sm" variant="ghost" className="text-error-600" onClick={() => setConfirm({ kind: 'revoke', runner: r })} leftIcon={<Trash2 className="h-4 w-4" aria-hidden />} aria-label={`Revoke ${r.name}`}>Revoke</Button>
            </>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Runners & sources"
        description="Connections that feed this workspace: runners run AI tasks through PromptPilot and report their sessions; sources only report sessions."
        icon={<Server className="h-6 w-6" />}
        actions={<Button leftIcon={<Plus className="h-4 w-4" aria-hidden />} onClick={() => setRegisterOpen(true)}>Register</Button>}
      />
      <BuiltinCard runner={(runners.data || []).find((r) => kindOf(r) === 'builtin')} onChanged={runners.refresh} />
      <div className="w-56 max-w-full">
        <Select id="air-r-kind" label="Kind" value={kindFilter} onChange={(e) => setKindFilter(e.target.value as '' | ConnectionKind)}>
          <option value="">Runners and sources</option>
          <option value="runner">Runners</option>
          <option value="source">Sources</option>
          <option value="builtin">Built-in</option>
        </Select>
      </div>
      <ErrorNote error={runners.error} product={PRODUCT} />
      <Table<Runner>
        caption="Runners and sources"
        columns={columns}
        data={(runners.data || []).filter((r) => !kindFilter || kindOf(r) === kindFilter)}
        keyExtractor={(r) => r.uuid}
        isLoading={runners.loading && !runners.data}
        emptyMessage={kindFilter === 'source' ? 'No sources yet.'
          : 'Nothing registered yet. Register a runner, then start PromptPilot on that machine.'}
      />

      <Modal isOpen={registerOpen} onClose={() => setRegisterOpen(false)} title="Register a connection" size="xl"
        description="One per machine (or per set of folders), or per tool that reports sessions. You get its token once.">
        <form onSubmit={register} className="space-y-4">
          <Input id="air-runner-name" label="Name" value={name} onChange={(e) => setName(e.target.value)}
            placeholder={kind === 'source' ? 'ci-sessions' : 'mac-studio'} required maxLength={100} />
          <fieldset className="space-y-2">
            <legend className="text-sm font-medium text-secondary-800">Kind</legend>
            {KINDS.map((k) => (
              <label key={k.value} className="flex items-start gap-2 text-sm">
                <input type="radio" name="air-kind" className="mt-1" value={k.value} checked={kind === k.value} onChange={() => setKind(k.value)} />
                <span>
                  <span className="font-medium text-secondary-900">{k.label}</span>
                  <span className="block text-xs text-secondary-500">{k.hint}</span>
                </span>
              </label>
            ))}
          </fieldset>
          {kind === 'source' && (
            <div className="min-w-0 space-y-2 text-sm text-secondary-700">
              <p>A source reports its sessions with its token (shown once after you register), for example:</p>
              <CopyBlock what="Example" text={sessionsCurl('$TOKEN')} testId="air-source-example" />
            </div>
          )}
          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" onClick={() => setRegisterOpen(false)}>Cancel</Button>
            <Button type="submit" isLoading={busy === 'register'} disabled={!name.trim()}>Register</Button>
          </div>
        </form>
      </Modal>

      <TokenModal shown={token} onClose={() => setToken(null)} />
      <SessionsModal runner={sessionsOf} onClose={() => setSessionsOf(null)} />
      {accessOf && <AccessModal runner={accessOf} onClose={() => setAccessOf(null)} onSaved={runners.refresh} />}
      {filterOf && <ReportFilterModal runner={filterOf} onClose={() => setFilterOf(null)} onSaved={runners.refresh} />}

      <ConfirmDialog
        isOpen={!!confirm}
        onClose={() => setConfirm(null)}
        onConfirm={confirmed}
        title={confirm?.kind === 'rotate' ? `Rotate the token of ${confirm.runner.name}?` : `Revoke ${confirm?.runner.name}?`}
        message={confirm?.kind === 'rotate'
          ? 'The current token stops working at once. Put the new one on the machine and restart the runner.'
          : 'It can no longer claim or report runs or sessions. This cannot be undone; register it again to bring it back.'}
        confirmText={confirm?.kind === 'rotate' ? 'Rotate token' : 'Revoke'}
        variant={confirm?.kind === 'rotate' ? 'warning' : 'danger'}
        isLoading={!!busy && busy !== 'register'}
      />
    </div>
  );
}
